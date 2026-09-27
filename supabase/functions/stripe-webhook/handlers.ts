/**
 * Stripe Connect event handlers. Each one maps a verified event on a shop's
 * connected account to the service_role money helpers in migrations 0011 and
 * 0013 (upsert_stripe_payment, apply_stripe_refund,
 * upsert_customer_payment_method, sync_stripe_subscription) or to
 * shop_stripe_accounts.
 *
 * Rules every handler follows:
 *  - The shop is ALWAYS the one that owns event.account
 *    (shop_stripe_accounts); metadata naming another shop is ignored.
 *  - Amounts come from Stripe objects (what was actually charged), never
 *    from anything a client sent; the metadata tip is bounded by the charge.
 *  - Handlers are safe to re-run (a failed attempt may have written part of
 *    its work) and to receive events in any order: the SQL helpers never
 *    downgrade received money; refund events re-read the charge and apply
 *    Stripe's CURRENT cumulative refunded total (which drops when a refund
 *    fails); subscription and account state is re-read from Stripe so an
 *    older snapshot never overwrites a newer one.
 *  - "Not ours" (unknown account, no/foreign metadata, nothing to link) is
 *    acknowledged as `ignored`; anything that might succeed on retry throws,
 *    so the webhook answers 500 and Stripe redelivers.
 *  - Money whose linked job / invoice / membership was deleted while the
 *    payment was open is kept as the customer's unapplied payment (with a
 *    note), never failed forever on the foreign key.
 *  - A declined PaymentSheet attempt is still confirmable in Stripe, so it
 *    stays `pending` (settled by the payments function), not `failed`.
 */
import type { SupabaseClient } from "@supabase/supabase-js";
import type { Logger } from "../_shared/log.ts";
import { onAccount, type Stripe } from "../_shared/stripe.ts";
import {
  cancelsAtPeriodEnd,
  type CardDetails,
  chargeCard,
  chargeId,
  checkoutSessionId,
  type CrmMetadata,
  hasLinkage,
  intentMethod,
  invoiceSubscription,
  isoFromUnix,
  isReconfirmableSheetIntent,
  type MembershipStatus,
  membershipStatusOf,
  mergeMetadata,
  nonCardMethodType,
  ownership,
  paymentIntentId,
  paymentMethodCard,
  paymentMethodId,
  type PaymentMethodKind,
  readMetadata,
  splitTip,
  stripeCustomerId,
  subscriptionId,
  subscriptionPeriodEnd,
} from "./mapping.ts";

export const HANDLED_EVENT_TYPES = [
  "checkout.session.completed",
  "payment_intent.succeeded",
  "payment_intent.payment_failed",
  "payment_intent.canceled",
  "charge.refunded",
  "charge.refund.updated",
  "refund.updated",
  "refund.failed",
  "setup_intent.succeeded",
  "customer.subscription.created",
  "customer.subscription.updated",
  "customer.subscription.deleted",
  "invoice.paid",
  "invoice.payment_failed",
  "account.updated",
] as const;

export type HandledEventType = typeof HANDLED_EVENT_TYPES[number];

export function isHandledEventType(type: string): type is HandledEventType {
  return (HANDLED_EVENT_TYPES as readonly string[]).includes(type);
}

export interface WebhookContext {
  admin: SupabaseClient;
  stripe: Stripe;
  event: Stripe.Event;
  /** Connected account the event belongs to (null for platform events). */
  account: string | null;
  log: Logger;
  now: () => Date;
}

export type Outcome =
  | { result: "applied"; detail: string }
  | { result: "ignored"; reason: string };

/** A failed database call; `code` is the Postgres SQLSTATE when known. */
export class DbError extends Error {
  readonly code: string | null;

  constructor(operation: string, error: { code?: string | null; message?: string | null }) {
    super(
      `${operation} failed${error.code ? ` (${error.code})` : ""}: ${
        error.message ?? "unknown error"
      }`,
    );
    this.name = "DbError";
    this.code = error.code ?? null;
  }
}

type PaymentStatus = "pending" | "succeeded" | "failed" | "cancelled";

const RECEIVED = new Set(["succeeded", "partially_refunded", "refunded"]);

interface PaymentRow {
  id: string;
  shop_id: string;
  customer_id: string;
  status: string;
  kind: "deposit" | "payment" | "membership";
  tip_cents: number;
  invoice_id: string | null;
  job_id: string | null;
  membership_id: string | null;
}

interface MembershipRow {
  id: string;
  shop_id: string;
}

// ---------------------------------------------------------------------------
// Dispatch
// ---------------------------------------------------------------------------

export async function handleEvent(ctx: WebhookContext): Promise<Outcome> {
  const object = ctx.event.data.object;
  switch (ctx.event.type) {
    case "checkout.session.completed":
      return await onCheckoutSessionCompleted(ctx, object as Stripe.Checkout.Session);
    case "payment_intent.succeeded":
      return await onPaymentIntent(ctx, object as Stripe.PaymentIntent, "succeeded");
    case "payment_intent.payment_failed":
      return await onPaymentIntent(ctx, object as Stripe.PaymentIntent, "failed");
    case "payment_intent.canceled":
      return await onPaymentIntent(ctx, object as Stripe.PaymentIntent, "cancelled");
    case "charge.refunded":
      return await onChargeRefunded(ctx, object as Stripe.Charge);
    case "charge.refund.updated":
    case "refund.updated":
    case "refund.failed":
      return await onRefundChanged(ctx, object as Stripe.Refund);
    case "setup_intent.succeeded":
      return await onSetupIntentSucceeded(ctx, object as Stripe.SetupIntent);
    case "customer.subscription.created":
    case "customer.subscription.updated":
      return await onSubscriptionChanged(ctx, object as Stripe.Subscription, false);
    case "customer.subscription.deleted":
      return await onSubscriptionChanged(ctx, object as Stripe.Subscription, true);
    case "invoice.paid":
      return await onInvoicePaid(ctx, object as Stripe.Invoice);
    case "invoice.payment_failed":
      return await onInvoicePaymentFailed(ctx, object as Stripe.Invoice);
    case "account.updated":
      return await onAccountUpdated(ctx, object as Stripe.Account);
    default:
      return ignore(ctx, "unhandled_type");
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function applied(
  ctx: WebhookContext,
  detail: string,
  fields: Record<string, unknown> = {},
): Outcome {
  ctx.log.info("stripe_event_applied", { detail, ...fields });
  return { result: "applied", detail };
}

/** Acknowledged without changes. Mismatches are warnings (possible abuse or a bug). */
function ignore(
  ctx: WebhookContext,
  reason: string,
  fields: Record<string, unknown> = {},
): Outcome {
  const suspicious = reason === "shop_mismatch" || reason === "account_mismatch" ||
    reason === "subscription_conflict" || reason === "payment_method_conflict";
  if (suspicious) ctx.log.warn("stripe_event_ignored", { reason, ...fields });
  else ctx.log.info("stripe_event_ignored", { reason, ...fields });
  return { result: "ignored", reason };
}

function noteProblems(ctx: WebhookContext, md: CrmMetadata): void {
  if (md.problems.length > 0) ctx.log.warn("stripe_metadata_invalid", { problems: md.problems });
}

async function rpc<T>(ctx: WebhookContext, fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await ctx.admin.rpc(fn, args);
  if (error) throw new DbError(fn, error);
  return data as T;
}

/** The connected account, which every handler below needs for API calls. */
function connectedAccount(ctx: WebhookContext): string {
  if (!ctx.account) throw new Error("connected account missing"); // guarded by shopForAccount
  return ctx.account;
}

/** The shop that owns event.account, or null (platform event / unknown account). */
async function shopForAccount(ctx: WebhookContext): Promise<string | null> {
  if (!ctx.account) return null;
  const { data, error } = await ctx.admin
    .from("shop_stripe_accounts")
    .select("shop_id")
    .eq("stripe_account_id", ctx.account)
    .maybeSingle<{ shop_id: string }>();
  if (error) throw new DbError("shop_stripe_accounts lookup", error);
  return data?.shop_id ?? null;
}

async function retrieveIntent(ctx: WebhookContext, id: string): Promise<Stripe.PaymentIntent> {
  return await ctx.stripe.paymentIntents.retrieve(
    id,
    { expand: ["latest_charge"] },
    onAccount(connectedAccount(ctx)),
  );
}

async function latestCharge(
  ctx: WebhookContext,
  pi: Stripe.PaymentIntent,
): Promise<Stripe.Charge | null> {
  const ref = pi.latest_charge;
  if (ref && typeof ref === "object") return ref;
  const id = chargeId(ref);
  if (!id) return null;
  return await ctx.stripe.charges.retrieve(id, {}, onAccount(connectedAccount(ctx)));
}

/** Total actually charged by a PaymentIntent (received for successes). */
function intentTotal(pi: Stripe.PaymentIntent, status: PaymentStatus): number {
  if (status === "succeeded" && pi.amount_received > 0) return pi.amount_received;
  return pi.amount;
}

interface PaymentWrite {
  shopId: string;
  paymentIntentId: string;
  status: PaymentStatus;
  totalCents: number;
  md: CrmMetadata;
  method: PaymentMethodKind;
  charge: Stripe.Charge | null;
  checkoutSessionId?: string | null;
  paidAt?: string | null;
  /** The Stripe customer paying (fallback owner when the linked records are gone). */
  stripeCustomer?: string | null;
}

/**
 * upsert_stripe_payment (0013): idempotent, never downgrades received money.
 *
 * Returns null only when the money cannot be attached to anything in the
 * shop any more (every linked record was deleted and the payer is unknown);
 * that is logged as an error and acknowledged, since no retry can fix it.
 */
async function recordPayment(
  ctx: WebhookContext,
  write: PaymentWrite,
): Promise<PaymentRow | null> {
  const split = splitTip(write.totalCents, write.md.tipCents);
  if (split.tipIgnored) {
    ctx.log.warn("stripe_tip_ignored", {
      payment_intent: write.paymentIntentId,
      total_cents: write.totalCents,
      requested_tip_cents: write.md.tipCents,
    });
  }
  const card: CardDetails | null = chargeCard(write.charge);
  const upsert = async (md: CrmMetadata) =>
    await rpc<PaymentRow>(ctx, "upsert_stripe_payment", {
      p_shop_id: write.shopId,
      p_payment_intent_id: write.paymentIntentId,
      p_status: write.status,
      p_amount_cents: split.amountCents,
      p_tip_cents: split.tipCents,
      p_kind: md.kind,
      p_method: card?.method ?? write.method,
      p_invoice_id: md.invoiceId,
      p_job_id: md.jobId,
      p_customer_id: md.customerId,
      p_membership_id: md.membershipId,
      p_charge_id: chargeId(write.charge?.id),
      p_checkout_session_id: write.checkoutSessionId ?? null,
      p_card_brand: card?.brand ?? null,
      p_card_last4: card?.last4 ?? null,
      p_paid_at: write.status === "succeeded"
        ? (write.paidAt ?? isoFromUnix(write.charge?.created) ?? isoFromUnix(ctx.event.created))
        : null,
    });

  let row: PaymentRow;
  const notes: string[] = [];
  try {
    row = await upsert(write.md);
  } catch (err) {
    // 23503: a record the metadata links to was deleted after the payment
    // started (e.g. a booking deleted while its deposit link was still open).
    // The insert can never succeed as is, so keep the money as an unapplied
    // payment of the customer instead of failing on every redelivery.
    if (!(err instanceof DbError && err.code === "23503")) throw err;
    const relinked = await dropDeletedLinks(ctx, write);
    if (!relinked) throw err; // nothing we link to is missing: a real failure, retry
    if (!hasLinkage(relinked.md)) {
      ctx.log.error("stripe_payment_unlinkable", {
        payment_intent: write.paymentIntentId,
        status: write.status,
        total_cents: write.totalCents,
        deleted: relinked.deleted,
      });
      return null;
    }
    row = await upsert(relinked.md);
    ctx.log.warn("stripe_payment_relinked", {
      payment_intent: write.paymentIntentId,
      payment_id: row.id,
      deleted: relinked.deleted,
    });
    notes.push(
      `Received for a deleted ${relinked.deleted.join(" / ")}: apply it to an invoice or refund it`,
    );
  }

  const otherMethod = nonCardMethodType(write.charge);
  if (otherMethod) {
    ctx.log.warn("stripe_non_card_payment", {
      payment_intent: write.paymentIntentId,
      payment_id: row.id,
      payment_method_type: otherMethod,
    });
    notes.push(`Paid through Stripe with ${otherMethod.replaceAll("_", " ")}, not a card`);
  }
  if (notes.length > 0) await annotatePayment(ctx, row, notes.join(". "));
  return row;
}

const LINK_TABLES = [
  { key: "invoiceId", table: "invoices", label: "invoice" },
  { key: "jobId", table: "jobs", label: "job" },
  { key: "membershipId", table: "memberships", label: "membership" },
  { key: "customerId", table: "customers", label: "customer" },
] as const;

/**
 * The payment's linkage without the records that no longer exist in the
 * shop (null when none is missing). A deleted membership turns a membership
 * payment into a plain payment (payments_membership_kind); a missing
 * customer falls back to the shop's customer for the paying Stripe customer.
 */
async function dropDeletedLinks(
  ctx: WebhookContext,
  write: PaymentWrite,
): Promise<{ md: CrmMetadata; deleted: string[] } | null> {
  const md: CrmMetadata = { ...write.md };
  const deleted: string[] = [];
  for (const { key, table, label } of LINK_TABLES) {
    const id = md[key];
    if (id === null) continue;
    const { data, error } = await ctx.admin
      .from(table)
      .select("id")
      .eq("id", id)
      .eq("shop_id", write.shopId)
      .maybeSingle<{ id: string }>();
    if (error) throw new DbError(`${table} lookup`, error);
    if (!data) {
      md[key] = null;
      deleted.push(label);
    }
  }
  if (deleted.length === 0) return null;
  if (md.membershipId === null && md.kind === "membership") md.kind = "payment";
  if (md.customerId === null) {
    md.customerId = await customerByStripeId(ctx, write.shopId, write.stripeCustomer ?? null);
  }
  return { md, deleted };
}

/** Adds a staff-facing note to a payment that has none yet (service role). */
async function annotatePayment(ctx: WebhookContext, row: PaymentRow, note: string): Promise<void> {
  const { error } = await ctx.admin
    .from("payments")
    .update({ note: note.slice(0, 1000) })
    .eq("id", row.id)
    .eq("shop_id", row.shop_id)
    .is("note", null);
  if (error) throw new DbError("payments note", error);
}

/**
 * apply_stripe_refund (0013) with the charge's cumulative refunded amount.
 * Raise-only: a lower total (a refund that failed) is applied by the refund
 * event handlers (reconcileChargeRefunds), which re-read the charge.
 */
async function syncRefund(
  ctx: WebhookContext,
  piId: string,
  charge: Stripe.Charge | null,
): Promise<boolean> {
  const refunded = charge?.amount_refunded ?? 0;
  if (!Number.isSafeInteger(refunded) || refunded <= 0) return false;
  await rpc(ctx, "apply_stripe_refund", {
    p_payment_intent_id: piId,
    p_refunded_cents_total: refunded,
  });
  return true;
}

/**
 * upsert_customer_payment_method (0011): the first card becomes the default.
 * Missing customer / card of another customer are permanent -> ignored.
 */
async function saveCard(
  ctx: WebhookContext,
  shopId: string,
  customerId: string,
  pmId: string,
  card: CardDetails,
): Promise<Outcome> {
  try {
    await rpc(ctx, "upsert_customer_payment_method", {
      p_shop_id: shopId,
      p_customer_id: customerId,
      p_stripe_payment_method_id: pmId,
      p_brand: card.brand,
      p_last4: card.last4,
      p_exp_month: card.expMonth,
      p_exp_year: card.expYear,
      p_make_default: false,
    });
  } catch (err) {
    if (err instanceof DbError && err.code === "P0002") {
      return ignore(ctx, "customer_not_found", { payment_method: pmId });
    }
    if (err instanceof DbError && err.code === "22023") {
      return ignore(ctx, "payment_method_conflict", { payment_method: pmId });
    }
    throw err;
  }
  return applied(ctx, "card_saved", { payment_method: pmId });
}

/**
 * A card paid with `setup_future_usage` (e.g. a deposit that saves the card)
 * is attached to the Stripe customer: remember it for the payment's customer.
 */
async function saveCardFromIntent(
  ctx: WebhookContext,
  shopId: string,
  pi: Stripe.PaymentIntent,
  charge: Stripe.Charge | null,
  payment: PaymentRow,
): Promise<void> {
  if (!pi.setup_future_usage || !stripeCustomerId(pi.customer)) return;
  const pmId = paymentMethodId(pi.payment_method);
  const card = chargeCard(charge);
  if (!pmId || !card || card.method !== "card" || !payment.customer_id) return;
  await saveCard(ctx, shopId, payment.customer_id, pmId, card);
}

// ---------------------------------------------------------------------------
// payment_intent.succeeded / payment_failed / canceled
// ---------------------------------------------------------------------------

async function onPaymentIntent(
  ctx: WebhookContext,
  pi: Stripe.PaymentIntent,
  status: PaymentStatus,
): Promise<Outcome> {
  const shopId = await shopForAccount(ctx);
  if (!shopId) return ignore(ctx, "unknown_account");
  const piId = paymentIntentId(pi.id);
  if (!piId) return ignore(ctx, "invalid_object");
  const owner = ownership(shopId, pi.metadata);
  // not_crm includes subscription-invoice intents: invoice.paid records those.
  if (owner !== "ours") return ignore(ctx, owner, { payment_intent: piId, shop_id: shopId });
  const md = readMetadata(pi.metadata);
  noteProblems(ctx, md);
  if (!hasLinkage(md)) return ignore(ctx, "no_linkage", { payment_intent: piId });
  const total = intentTotal(pi, status);
  if (!Number.isSafeInteger(total) || total <= 0) return ignore(ctx, "zero_amount");

  // A declined PaymentSheet attempt stays open in Stripe (see
  // isReconfirmableSheetIntent): record it as pending so it is still
  // superseded / cancelled / swept like any unconfirmed sheet.
  const reconfirmable = status === "failed" && isReconfirmableSheetIntent(pi);
  const recorded: PaymentStatus = reconfirmable ? "pending" : status;
  if (reconfirmable) {
    ctx.log.info("stripe_payment_declined_open", {
      payment_intent: piId,
      decline_code: pi.last_payment_error?.decline_code ?? pi.last_payment_error?.code ?? null,
    });
  }

  const charge = status === "succeeded" ? await latestCharge(ctx, pi) : null;
  const payment = await recordPayment(ctx, {
    shopId,
    paymentIntentId: piId,
    status: recorded,
    totalCents: total,
    md,
    method: intentMethod(pi),
    charge,
    stripeCustomer: stripeCustomerId(pi.customer),
  });
  if (!payment) return ignore(ctx, "linkage_deleted", { payment_intent: piId });
  if (status === "succeeded") {
    await syncRefund(ctx, piId, charge);
    await saveCardFromIntent(ctx, shopId, pi, charge, payment);
  }
  return applied(ctx, reconfirmable ? "payment_declined_open" : `payment_${status}`, {
    payment_intent: piId,
    payment_id: payment.id,
  });
}

// ---------------------------------------------------------------------------
// checkout.session.completed
// ---------------------------------------------------------------------------

async function onCheckoutSessionCompleted(
  ctx: WebhookContext,
  session: Stripe.Checkout.Session,
): Promise<Outcome> {
  const shopId = await shopForAccount(ctx);
  if (!shopId) return ignore(ctx, "unknown_account");
  // Fail fast on a foreign session before calling Stripe.
  if (ownership(shopId, session.metadata) === "shop_mismatch") {
    return ignore(ctx, "shop_mismatch", { shop_id: shopId });
  }
  switch (session.mode) {
    case "payment":
      return await checkoutPayment(ctx, shopId, session);
    case "setup":
      return await checkoutSetup(ctx, shopId, session);
    case "subscription":
      return await checkoutSubscription(ctx, shopId, session);
    default:
      return ignore(ctx, "unsupported_mode");
  }
}

async function checkoutPayment(
  ctx: WebhookContext,
  shopId: string,
  session: Stripe.Checkout.Session,
): Promise<Outcome> {
  let status: PaymentStatus;
  if (session.payment_status === "paid") status = "succeeded";
  else if (session.payment_status === "unpaid") status = "pending"; // async method still clearing
  else return ignore(ctx, "no_payment_required");
  const piId = paymentIntentId(session.payment_intent);
  if (!piId) return ignore(ctx, "no_payment_intent");

  const pi = typeof session.payment_intent === "object" && session.payment_intent !== null
    ? session.payment_intent
    : await retrieveIntent(ctx, piId);
  const owner = ownership(shopId, session.metadata, pi.metadata);
  if (owner !== "ours") return ignore(ctx, owner, { payment_intent: piId, shop_id: shopId });
  const md = readMetadata(mergeMetadata(session.metadata, pi.metadata));
  noteProblems(ctx, md);
  if (!hasLinkage(md)) return ignore(ctx, "no_linkage", { payment_intent: piId });
  const total = intentTotal(pi, status);
  if (!Number.isSafeInteger(total) || total <= 0) return ignore(ctx, "zero_amount");

  const charge = status === "succeeded" ? await latestCharge(ctx, pi) : null;
  const payment = await recordPayment(ctx, {
    shopId,
    paymentIntentId: piId,
    status,
    totalCents: total,
    md,
    method: intentMethod(pi),
    charge,
    checkoutSessionId: checkoutSessionId(session.id),
    stripeCustomer: stripeCustomerId(pi.customer) ?? stripeCustomerId(session.customer),
  });
  if (!payment) return ignore(ctx, "linkage_deleted", { payment_intent: piId });
  if (status === "succeeded") {
    await syncRefund(ctx, piId, charge);
    await saveCardFromIntent(ctx, shopId, pi, charge, payment);
  }
  return applied(ctx, `checkout_payment_${status}`, {
    payment_intent: piId,
    payment_id: payment.id,
  });
}

async function checkoutSetup(
  ctx: WebhookContext,
  shopId: string,
  session: Stripe.Checkout.Session,
): Promise<Outcome> {
  const ref = session.setup_intent;
  const siId = typeof ref === "string" ? ref : ref?.id;
  if (!siId || !/^seti_[A-Za-z0-9]+$/.test(siId)) return ignore(ctx, "no_setup_intent");
  const si = typeof ref === "object" && ref !== null ? ref : await ctx.stripe.setupIntents.retrieve(
    siId,
    { expand: ["payment_method"] },
    onAccount(connectedAccount(ctx)),
  );
  const owner = ownership(shopId, session.metadata, si.metadata);
  if (owner !== "ours") return ignore(ctx, owner, { shop_id: shopId });
  if (si.status !== "succeeded") return ignore(ctx, "setup_not_succeeded");
  return await saveSetupIntentCard(ctx, shopId, si, mergeMetadata(session.metadata, si.metadata));
}

async function checkoutSubscription(
  ctx: WebhookContext,
  shopId: string,
  session: Stripe.Checkout.Session,
): Promise<Outcome> {
  const subId = subscriptionId(session.subscription);
  if (!subId) return ignore(ctx, "no_subscription");
  const sub = await retrieveSubscription(ctx, subId);
  const owner = ownership(shopId, session.metadata, sub.metadata);
  if (owner !== "ours") return ignore(ctx, owner, { subscription: subId, shop_id: shopId });
  const md = readMetadata(mergeMetadata(session.metadata, sub.metadata));
  noteProblems(ctx, md);
  return await syncSubscription(ctx, shopId, sub, md.membershipId);
}

// ---------------------------------------------------------------------------
// setup_intent.succeeded
// ---------------------------------------------------------------------------

async function onSetupIntentSucceeded(
  ctx: WebhookContext,
  si: Stripe.SetupIntent,
): Promise<Outcome> {
  const shopId = await shopForAccount(ctx);
  if (!shopId) return ignore(ctx, "unknown_account");
  const owner = ownership(shopId, si.metadata);
  if (owner !== "ours") return ignore(ctx, owner, { shop_id: shopId });
  return await saveSetupIntentCard(ctx, shopId, si, si.metadata);
}

async function saveSetupIntentCard(
  ctx: WebhookContext,
  shopId: string,
  si: Stripe.SetupIntent,
  metadata: Readonly<Record<string, string>> | null,
): Promise<Outcome> {
  const pmId = paymentMethodId(si.payment_method);
  if (!pmId) return ignore(ctx, "no_payment_method");
  const pm = typeof si.payment_method === "object" && si.payment_method !== null
    ? si.payment_method
    : await ctx.stripe.paymentMethods.retrieve(pmId, {}, onAccount(connectedAccount(ctx)));
  const card = paymentMethodCard(pm);
  if (!card) return ignore(ctx, "not_a_card", { payment_method: pmId });

  const md = readMetadata(metadata);
  noteProblems(ctx, md);
  const customerId = md.customerId ?? await customerByStripeId(ctx, shopId, si.customer);
  if (!customerId) return ignore(ctx, "unknown_customer", { payment_method: pmId });
  return await saveCard(ctx, shopId, customerId, pmId, card);
}

/** Our customer for a Stripe customer id (customers.stripe_customer_id), in this shop. */
async function customerByStripeId(
  ctx: WebhookContext,
  shopId: string,
  ref: Stripe.SetupIntent["customer"],
): Promise<string | null> {
  const cus = stripeCustomerId(ref);
  if (!cus) return null;
  const { data, error } = await ctx.admin
    .from("customers")
    .select("id")
    .eq("shop_id", shopId)
    .eq("stripe_customer_id", cus)
    .maybeSingle<{ id: string }>();
  if (error) throw new DbError("customers lookup", error);
  return data?.id ?? null;
}

// ---------------------------------------------------------------------------
// charge.refunded / charge.refund.updated / refund.updated / refund.failed
// ---------------------------------------------------------------------------

/** The columns a refund reconciliation reads and writes. */
interface RefundRow {
  id: string;
  shop_id: string;
  status: string;
  amount_cents: number;
  tip_cents: number;
  refunded_cents: number;
}

const REFUND_COLUMNS = "id, shop_id, status, amount_cents, tip_cents, refunded_cents";

/** payment_refund_status (0012), for the reversal write below. */
export function refundStatus(amountCents: number, tipCents: number, refundedCents: number): string {
  if (refundedCents <= 0) return "succeeded";
  return refundedCents >= amountCents + tipCents ? "refunded" : "partially_refunded";
}

async function onChargeRefunded(ctx: WebhookContext, charge: Stripe.Charge): Promise<Outcome> {
  return await reconcileChargeRefunds(
    ctx,
    chargeId(charge.id),
    paymentIntentId(charge.payment_intent),
  );
}

/**
 * A refund changed state. The one that matters is a failure: a card refund
 * that Stripe accepted (pending, already counted in charge.amount_refunded
 * and in our refunded_cents) can still fail later (closed or expired card),
 * and Stripe then LOWERS charge.amount_refunded. Other updates are harmless:
 * the charge is re-read and the current total applied either way.
 */
async function onRefundChanged(ctx: WebhookContext, refund: Stripe.Refund): Promise<Outcome> {
  return await reconcileChargeRefunds(
    ctx,
    chargeId(refund.charge),
    paymentIntentId(refund.payment_intent),
  );
}

async function reconcileChargeRefunds(
  ctx: WebhookContext,
  chId: string | null,
  piId: string | null,
): Promise<Outcome> {
  if (!piId) return ignore(ctx, "no_payment_intent");
  if (!chId) return ignore(ctx, "invalid_object");
  const shopId = await shopForAccount(ctx);
  if (!shopId) return ignore(ctx, "unknown_account");

  const { data: existing, error } = await ctx.admin
    .from("payments")
    .select("id, shop_id, customer_id, status, kind, tip_cents, invoice_id, job_id, membership_id")
    .eq("stripe_payment_intent_id", piId)
    .maybeSingle<PaymentRow>();
  if (error) throw new DbError("payments lookup", error);
  if (existing && existing.shop_id !== shopId) {
    return ignore(ctx, "shop_mismatch", { payment_intent: piId, shop_id: shopId });
  }

  // Stripe's CURRENT state, not this event's (possibly stale) snapshot: the
  // refunded total can go DOWN (a failed refund), so a late event must not
  // re-apply an amount Stripe has since given back.
  const charge = await ctx.stripe.charges.retrieve(chId, {}, onAccount(connectedAccount(ctx)));
  if (paymentIntentId(charge.payment_intent) !== piId) {
    return ignore(ctx, "invalid_object", { payment_intent: piId });
  }

  if (!existing || !RECEIVED.has(existing.status)) {
    // The refund arrived before the success was recorded (out of order):
    // record the charge as succeeded first, from the intent's own metadata.
    const pi = await retrieveIntent(ctx, piId);
    const owner = ownership(shopId, pi.metadata);
    if (owner === "shop_mismatch") {
      return ignore(ctx, "shop_mismatch", { payment_intent: piId, shop_id: shopId });
    }
    let md: CrmMetadata;
    if (owner === "ours") {
      md = readMetadata(pi.metadata);
      noteProblems(ctx, md);
      if (!existing && !hasLinkage(md)) return ignore(ctx, "no_linkage", { payment_intent: piId });
    } else if (existing) {
      // e.g. a membership payment without intent metadata: keep its own split
      md = {
        shopId,
        invoiceId: existing.invoice_id,
        jobId: existing.job_id,
        customerId: existing.customer_id,
        membershipId: existing.membership_id,
        kind: existing.kind,
        tipCents: existing.tip_cents,
        problems: [],
      };
    } else {
      // Not a CRM charge — or a subscription payment whose invoice.paid has not
      // arrived yet; that handler applies the charge's refunds when it does.
      return ignore(ctx, "not_crm", { payment_intent: piId });
    }
    const total = pi.amount_received > 0 ? pi.amount_received : charge.amount_captured;
    if (!Number.isSafeInteger(total) || total <= 0) return ignore(ctx, "zero_amount");
    const recorded = await recordPayment(ctx, {
      shopId,
      paymentIntentId: piId,
      status: "succeeded",
      totalCents: total,
      md,
      method: intentMethod(pi),
      charge,
      stripeCustomer: stripeCustomerId(pi.customer),
    });
    if (!recorded) return ignore(ctx, "linkage_deleted", { payment_intent: piId });
  }

  const refunded = charge.amount_refunded;
  if (!Number.isSafeInteger(refunded) || refunded < 0) return ignore(ctx, "invalid_object");
  const row = refunded > 0
    ? await rpc<RefundRow>(ctx, "apply_stripe_refund", {
      p_payment_intent_id: piId,
      p_refunded_cents_total: refunded,
    })
    : await refundRow(ctx, shopId, piId);
  // apply_stripe_refund only ever raises the total: a lower one from Stripe
  // is a refund that failed after it was counted -> give the money back.
  if (row && row.refunded_cents > refunded) {
    await reverseRefund(ctx, shopId, piId, row, refunded);
    return applied(ctx, "refund_reversed", {
      payment_intent: piId,
      payment_id: row.id,
      refunded_cents_total: refunded,
    });
  }
  if (refunded === 0) return ignore(ctx, "nothing_refunded");
  return applied(ctx, "refund_applied", {
    payment_intent: piId,
    refunded_cents_total: refunded,
  });
}

async function refundRow(
  ctx: WebhookContext,
  shopId: string,
  piId: string,
): Promise<RefundRow | null> {
  const { data, error } = await ctx.admin
    .from("payments")
    .select(REFUND_COLUMNS)
    .eq("stripe_payment_intent_id", piId)
    .eq("shop_id", shopId)
    .maybeSingle<RefundRow>();
  if (error) throw new DbError("payments lookup", error);
  return data;
}

/**
 * Lower refunded_cents to Stripe's current total. apply_stripe_refund (0013)
 * cannot (it keeps the greater value), so this writes the row directly with
 * the service role, keeping the 0012 invariants (status derived with
 * payment_refund_status's rules; only received payments; 0 <= total). The
 * write is a compare-and-set on the refunded total it read: if another
 * writer (the staff refund action, a concurrent delivery) changed the row in
 * between, nothing is written and the delivery fails so Stripe redelivers and
 * the charge is read again.
 */
async function reverseRefund(
  ctx: WebhookContext,
  shopId: string,
  piId: string,
  row: RefundRow,
  refundedCents: number,
): Promise<void> {
  if (row.shop_id !== shopId || !RECEIVED.has(row.status)) {
    throw new Error("refund reversal on a payment that is not a received payment of this shop");
  }
  const status = refundStatus(row.amount_cents, row.tip_cents, refundedCents);
  const { data, error } = await ctx.admin
    .from("payments")
    .update({ refunded_cents: refundedCents, status })
    .eq("id", row.id)
    .eq("shop_id", shopId)
    .eq("stripe_payment_intent_id", piId)
    .eq("refunded_cents", row.refunded_cents)
    .eq("status", row.status)
    .select("id");
  if (error) throw new DbError("payments refund reversal", error);
  if (!data || data.length === 0) {
    throw new Error("payment refund changed concurrently; the event will be retried");
  }
  ctx.log.warn("stripe_refund_reversed", {
    payment_intent: piId,
    payment_id: row.id,
    previous_refunded_cents: row.refunded_cents,
    refunded_cents_total: refundedCents,
    status,
  });
}

// ---------------------------------------------------------------------------
// Subscriptions (memberships)
// ---------------------------------------------------------------------------

async function retrieveSubscription(ctx: WebhookContext, id: string): Promise<Stripe.Subscription> {
  return await ctx.stripe.subscriptions.retrieve(id, {}, onAccount(connectedAccount(ctx)));
}

/**
 * sync_stripe_subscription (0011). Out-of-order safe in SQL (a cancelled
 * membership never revives; active/past_due never regress to incomplete).
 */
async function syncSubscription(
  ctx: WebhookContext,
  shopId: string,
  sub: Stripe.Subscription,
  membershipHint: string | null,
  statusOverride?: MembershipStatus,
): Promise<Outcome> {
  const subId = subscriptionId(sub.id);
  if (!subId) return ignore(ctx, "invalid_object");
  const status = statusOverride ?? membershipStatusOf(sub.status);
  if (!status) return ignore(ctx, "unknown_subscription_status", { stripe_status: sub.status });
  const stamp = status === "cancelled"
    ? isoFromUnix(sub.ended_at ?? sub.canceled_at)
    : isoFromUnix(sub.start_date);
  let row: MembershipRow;
  try {
    row = await rpc<MembershipRow>(ctx, "sync_stripe_subscription", {
      p_shop_id: shopId,
      p_subscription_id: subId,
      p_status: status,
      p_current_period_end: isoFromUnix(subscriptionPeriodEnd(sub)),
      p_cancel_at_period_end: cancelsAtPeriodEnd(sub),
      p_membership_id: membershipHint,
      p_now: stamp ?? ctx.now().toISOString(),
    });
  } catch (err) {
    // P0002: no membership for this subscription (not a CRM subscription, or
    // the incomplete membership was deleted). 22023: linked to another shop /
    // subscription. Neither can succeed on retry.
    if (err instanceof DbError && err.code === "P0002") {
      return ignore(ctx, "membership_not_found", { subscription: subId });
    }
    if (err instanceof DbError && err.code === "22023") {
      return ignore(ctx, "subscription_conflict", { subscription: subId });
    }
    throw err;
  }
  return applied(ctx, `membership_${status}`, { subscription: subId, membership_id: row.id });
}

async function onSubscriptionChanged(
  ctx: WebhookContext,
  sub: Stripe.Subscription,
  deleted: boolean,
): Promise<Outcome> {
  const shopId = await shopForAccount(ctx);
  if (!shopId) return ignore(ctx, "unknown_account");
  const subId = subscriptionId(sub.id);
  if (!subId) return ignore(ctx, "invalid_object");
  if (ownership(shopId, sub.metadata) === "shop_mismatch") {
    return ignore(ctx, "shop_mismatch", { subscription: subId, shop_id: shopId });
  }
  // Apply Stripe's CURRENT state, not this (possibly stale) snapshot; a
  // deletion is terminal, so its own snapshot is authoritative.
  const current = deleted ? sub : await retrieveSubscription(ctx, subId);
  const md = readMetadata(mergeMetadata(sub.metadata, current.metadata));
  noteProblems(ctx, md);
  return await syncSubscription(
    ctx,
    shopId,
    current,
    md.membershipId,
    deleted ? "cancelled" : undefined,
  );
}

/** The membership linked to a subscription, linking it first when needed. */
async function membershipForSubscription(
  ctx: WebhookContext,
  shopId: string,
  subId: string,
  membershipHint: string | null,
): Promise<{ membership: MembershipRow } | { outcome: Outcome }> {
  const { data, error } = await ctx.admin
    .from("memberships")
    .select("id, shop_id")
    .eq("stripe_subscription_id", subId)
    .maybeSingle<MembershipRow>();
  if (error) throw new DbError("memberships lookup", error);
  if (data) {
    if (data.shop_id !== shopId) {
      return { outcome: ignore(ctx, "shop_mismatch", { subscription: subId, shop_id: shopId }) };
    }
    return { membership: data };
  }
  // invoice.paid can arrive before the subscription was linked: link it now.
  const sub = await retrieveSubscription(ctx, subId);
  if (ownership(shopId, sub.metadata) === "shop_mismatch") {
    return { outcome: ignore(ctx, "shop_mismatch", { subscription: subId, shop_id: shopId }) };
  }
  const hint = membershipHint ?? readMetadata(sub.metadata).membershipId;
  const outcome = await syncSubscription(ctx, shopId, sub, hint);
  if (outcome.result !== "applied") return { outcome };
  const linked = await ctx.admin
    .from("memberships")
    .select("id, shop_id")
    .eq("stripe_subscription_id", subId)
    .eq("shop_id", shopId)
    .maybeSingle<MembershipRow>();
  if (linked.error) throw new DbError("memberships lookup", linked.error);
  if (!linked.data) throw new Error(`membership for ${subId} missing after linking`);
  return { membership: linked.data };
}

async function invoicePayments(
  ctx: WebhookContext,
  invoice: Stripe.Invoice,
): Promise<Stripe.InvoicePayment[]> {
  const embedded = invoice.payments;
  if (embedded && !embedded.has_more && embedded.data.length > 0) return embedded.data;
  const list = await ctx.stripe.invoicePayments.list(
    { invoice: invoice.id, status: "paid", limit: 100 },
    onAccount(connectedAccount(ctx)),
  );
  return list.data;
}

async function onInvoicePaid(ctx: WebhookContext, invoice: Stripe.Invoice): Promise<Outcome> {
  const { subscriptionId: subId, metadata } = invoiceSubscription(invoice);
  if (!subId) return ignore(ctx, "not_a_subscription_invoice");
  const shopId = await shopForAccount(ctx);
  if (!shopId) return ignore(ctx, "unknown_account");
  if (ownership(shopId, metadata) === "shop_mismatch") {
    return ignore(ctx, "shop_mismatch", { subscription: subId, shop_id: shopId });
  }
  if (!(invoice.amount_paid > 0)) return ignore(ctx, "nothing_paid");
  const md = readMetadata(metadata);
  noteProblems(ctx, md);
  const found = await membershipForSubscription(ctx, shopId, subId, md.membershipId);
  if ("outcome" in found) return found.outcome;
  const membership = found.membership;

  let recorded = 0;
  for (const invoicePayment of await invoicePayments(ctx, invoice)) {
    if (invoicePayment.status !== "paid") continue;
    const piId = paymentIntentId(invoicePayment.payment?.payment_intent ?? null);
    if (!piId) continue;
    const pi = await retrieveIntent(ctx, piId);
    const charge = await latestCharge(ctx, pi);
    const total = invoicePayment.amount_paid ?? pi.amount_received;
    if (!Number.isSafeInteger(total) || total <= 0) continue;
    const row = await recordPayment(ctx, {
      shopId,
      paymentIntentId: piId,
      status: "succeeded",
      totalCents: total,
      md: {
        shopId,
        invoiceId: null,
        jobId: null,
        customerId: null,
        membershipId: membership.id,
        kind: "membership",
        tipCents: 0,
        problems: [],
      },
      method: intentMethod(pi),
      charge,
      paidAt: isoFromUnix(charge?.created ?? invoicePayment.status_transitions?.paid_at),
      stripeCustomer: stripeCustomerId(pi.customer),
    });
    if (!row) continue;
    await syncRefund(ctx, piId, charge);
    recorded++;
  }
  if (recorded === 0) return ignore(ctx, "no_payment_intent", { subscription: subId });
  return applied(ctx, "membership_payment", {
    subscription: subId,
    membership_id: membership.id,
    payments: recorded,
  });
}

async function onInvoicePaymentFailed(
  ctx: WebhookContext,
  invoice: Stripe.Invoice,
): Promise<Outcome> {
  const { subscriptionId: subId, metadata } = invoiceSubscription(invoice);
  if (!subId) return ignore(ctx, "not_a_subscription_invoice");
  const shopId = await shopForAccount(ctx);
  if (!shopId) return ignore(ctx, "unknown_account");
  if (ownership(shopId, metadata) === "shop_mismatch") {
    return ignore(ctx, "shop_mismatch", { subscription: subId, shop_id: shopId });
  }
  const sub = await retrieveSubscription(ctx, subId);
  if (ownership(shopId, sub.metadata) === "shop_mismatch") {
    return ignore(ctx, "shop_mismatch", { subscription: subId, shop_id: shopId });
  }
  let status = membershipStatusOf(sub.status);
  if (status === "active") {
    // Stripe normally moves the subscription to past_due itself. If it still
    // reads active, the failed invoice decides: still unpaid -> past_due.
    const current = await ctx.stripe.invoices.retrieve(
      invoice.id,
      {},
      onAccount(connectedAccount(ctx)),
    );
    if (current.status !== "paid") status = "past_due";
  }
  const md = readMetadata(mergeMetadata(metadata, sub.metadata));
  noteProblems(ctx, md);
  return await syncSubscription(ctx, shopId, sub, md.membershipId, status ?? undefined);
}

// ---------------------------------------------------------------------------
// account.updated
// ---------------------------------------------------------------------------

async function onAccountUpdated(ctx: WebhookContext, account: Stripe.Account): Promise<Outcome> {
  if (!ctx.account) return ignore(ctx, "unknown_account");
  if (account.id !== ctx.account) return ignore(ctx, "account_mismatch");
  // Re-read so an older snapshot delivered late never overwrites newer flags.
  const current = await ctx.stripe.accounts.retrieve(ctx.account);
  const { data, error } = await ctx.admin
    .from("shop_stripe_accounts")
    .update({
      charges_enabled: current.charges_enabled === true,
      payouts_enabled: current.payouts_enabled === true,
      details_submitted: current.details_submitted === true,
    })
    .eq("stripe_account_id", ctx.account)
    .select("shop_id");
  if (error) throw new DbError("shop_stripe_accounts update", error);
  if (!data || data.length === 0) return ignore(ctx, "unknown_account");
  return applied(ctx, "account_updated", {
    charges_enabled: current.charges_enabled === true,
    payouts_enabled: current.payouts_enabled === true,
  });
}
