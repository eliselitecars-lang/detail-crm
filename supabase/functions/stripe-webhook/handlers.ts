/**
 * Stripe Connect event handlers. Each one maps a verified event on a shop's
 * connected account to the service_role money helpers in migrations 0011,
 * 0013, 0064, 0066, 0093 and 0095 (upsert_stripe_payment,
 * apply_stripe_refund, set_stripe_refund_total, apply_stripe_dispute,
 * upsert_customer_payment_method, sync_stripe_subscription,
 * gift_card_order_paid, gift_card_order_refunded, gift_card_order_expired)
 * or to shop_stripe_accounts.
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
 *    note): upsert_stripe_payment drops the stale links itself, and when
 *    nothing it names is left (P0002) the payer is found by Stripe customer
 *    or the money is logged as unlinkable and acknowledged, never retried
 *    forever.
 *  - Money for a job / invoice whose customer changed while the payment was
 *    open (a deposit link opened for the previous customer) is kept as the
 *    payer's unapplied payment (with a note), never failed forever on 23514.
 *  - Declines and cancellations only update a payment row that already
 *    exists; they never create one (a row is a money record that blocks
 *    deleting the job / customer). A declined PaymentSheet attempt is still
 *    confirmable in Stripe, so it stays `pending` (settled by the payments
 *    function), not `failed`.
 *  - Saved cards follow Stripe: a detached card (removed in the PaymentSheet
 *    or the dashboard, or its Stripe customer deleted) is removed, and a card
 *    is only saved while it is still attached.
 *  - Disputes are flagged on the payment (note + staff notification) and
 *    their outcome is recorded in payments.disputed_cents (apply_stripe_dispute,
 *    0093): the money a lost dispute took back. Balances and revenue are not
 *    changed by a dispute; staff decide whether to bill the customer again.
 *  - Once a card payment settles an invoice in full, the invoice's other
 *    PaymentSheets (and Terminal / Tap to Pay intents) still waiting for a
 *    card are cancelled (and recorded cancelled), so an open sheet on another
 *    device cannot charge it twice.
 *  - Asynchronous methods (P-31): an ACH debit (us_bank_account -> ach_debit)
 *    is recorded `processing` while it clears (payment_intent.processing, or
 *    a Checkout completed unpaid), which the database counts as money in
 *    flight; it becomes succeeded (payment_intent.succeeded /
 *    checkout.session.async_payment_succeeded) or failed
 *    (payment_intent.payment_failed / async_payment_failed). Pay-later
 *    providers (affirm, klarna, afterpay_clearpay, zip, ...) are `bnpl`.
 *    Stripe's own type is stored in payments.stripe_method_type; a type the
 *    CRM has no method for is stored as `card` with a note.
 *  - Online gift card sales (metadata kind 'gift_card' + gift_card_order_id)
 *    are never payments: gift_card_order_paid issues the card,
 *    gift_card_order_refunded follows refunds (0066) and
 *    gift_card_order_expired closes the order of a Checkout that expired
 *    unpaid (0095).
 *  - Money for a customer merged into another (P-20) goes to the surviving
 *    customer (customers.merged_into_id).
 */
import type { SupabaseClient } from "@supabase/supabase-js";
import type { Logger } from "../_shared/log.ts";
import { formatCents } from "../_shared/money.ts";
import { idempotencyKey, onAccount, type Stripe } from "../_shared/stripe.ts";
import {
  cancelsAtPeriodEnd,
  type CardDetails,
  chargeCard,
  chargeId,
  chargeMethod,
  checkoutSessionId,
  type CrmMetadata,
  DEVICE_INTENT_SOURCES,
  hasLinkage,
  intentMethod,
  intentSavesCard,
  invoiceSubscription,
  isoFromUnix,
  isReconfirmableSheetIntent,
  type MembershipStatus,
  membershipStatusOf,
  mergeMetadata,
  ownership,
  paymentIntentId,
  paymentMethodCard,
  paymentMethodId,
  type PaymentMethodKind,
  readMetadata,
  splitTip,
  stripeCustomerId,
  stripeMethodTypeOf,
  subscriptionId,
  subscriptionPeriodEnd,
  subscriptionTerms,
  unmappedMethodType,
} from "./mapping.ts";

export const HANDLED_EVENT_TYPES = [
  "checkout.session.completed",
  "checkout.session.async_payment_succeeded",
  "checkout.session.async_payment_failed",
  "checkout.session.expired",
  "payment_intent.processing",
  "payment_intent.succeeded",
  "payment_intent.payment_failed",
  "payment_intent.canceled",
  "charge.refunded",
  "charge.refund.updated",
  "refund.updated",
  "refund.failed",
  "setup_intent.succeeded",
  "payment_method.detached",
  "customer.deleted",
  "charge.dispute.created",
  "charge.dispute.updated",
  "charge.dispute.closed",
  "charge.dispute.funds_withdrawn",
  "charge.dispute.funds_reinstated",
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

type PaymentStatus = "pending" | "processing" | "succeeded" | "failed" | "cancelled";

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
    case "checkout.session.async_payment_succeeded":
      return await onCheckoutSessionCompleted(ctx, object as Stripe.Checkout.Session);
    case "checkout.session.async_payment_failed":
      return await onCheckoutSessionCompleted(ctx, object as Stripe.Checkout.Session, {
        asyncFailed: true,
      });
    case "checkout.session.expired":
      return await onCheckoutSessionExpired(ctx, object as Stripe.Checkout.Session);
    case "payment_intent.processing":
      return await onPaymentIntent(ctx, object as Stripe.PaymentIntent, "processing");
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
    case "payment_method.detached":
      return await onPaymentMethodDetached(ctx, object as Stripe.PaymentMethod);
    case "customer.deleted":
      return await onCustomerDeleted(ctx, object as Stripe.Customer);
    case "charge.dispute.created":
    case "charge.dispute.updated":
    case "charge.dispute.closed":
    case "charge.dispute.funds_withdrawn":
    case "charge.dispute.funds_reinstated":
      return await onDisputeChanged(ctx, object as Stripe.Dispute);
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
    reason === "subscription_conflict" || reason === "payment_method_conflict" ||
    reason === "payment_method_customer_mismatch";
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

/**
 * Whether the intent lets the customer pay with something other than a card
 * (a Checkout Session with dynamic payment methods: ACH, pay-later). Only
 * then can a failure's method differ from a card.
 */
function offersNonCardMethods(pi: Pick<Stripe.PaymentIntent, "payment_method_types">): boolean {
  return (pi.payment_method_types ?? []).some((t) =>
    t !== "card" && t !== "card_present" && t !== "interac_present"
  );
}

/** The intent's latest charge, when Stripe has one (null otherwise; a missing charge is never fatal). */
async function chargeIfAny(
  ctx: WebhookContext,
  pi: Stripe.PaymentIntent,
): Promise<Stripe.Charge | null> {
  if (!pi.latest_charge) return null;
  try {
    return await latestCharge(ctx, pi);
  } catch (err) {
    if (isMissingResource(err)) return null;
    throw err;
  }
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
  /** Stripe's payment method type (payments.stripe_method_type), when known. */
  stripeMethodType?: string | null;
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
  // Card / bank account details and the method Stripe actually used (P-31:
  // us_bank_account -> ach_debit, affirm / klarna / ... -> bnpl).
  const details = chargeMethod(write.charge);
  const methodType = write.stripeMethodType ?? stripeMethodTypeOf(write.charge);
  const upsert = async (md: CrmMetadata) =>
    await rpc<PaymentRow>(ctx, "upsert_stripe_payment", {
      p_shop_id: write.shopId,
      p_payment_intent_id: write.paymentIntentId,
      p_status: write.status,
      p_amount_cents: split.amountCents,
      p_tip_cents: split.tipCents,
      p_kind: md.kind,
      p_method: details?.method ?? write.method,
      p_invoice_id: md.invoiceId,
      p_job_id: md.jobId,
      p_customer_id: md.customerId,
      p_membership_id: md.membershipId,
      p_charge_id: chargeId(write.charge?.id),
      p_checkout_session_id: write.checkoutSessionId ?? null,
      p_card_brand: details?.brand ?? null,
      p_card_last4: details?.last4 ?? null,
      p_paid_at: write.status === "succeeded"
        ? (write.paidAt ?? isoFromUnix(write.charge?.created) ?? isoFromUnix(ctx.event.created))
        : null,
      p_stripe_method_type: methodType,
    });

  // A payment whose links cannot be written as they are is recovered at most
  // once per cause, then retried once more; anything else fails the delivery.
  // A payer merged into another customer (P-20) pays as the surviving one.
  let md = await followMergedCustomer(ctx, write.shopId, write.md);
  let row: PaymentRow | null = null;
  const notes: string[] = [];
  const recovered = new Set<string>();
  while (row === null) {
    try {
      row = await upsert(md);
    } catch (err) {
      const code = err instanceof DbError ? err.code : null;
      if (code === null || recovered.has(code)) throw err;
      recovered.add(code);
      // P0002: none of the linked records exists any more (the SQL drops
      // stale links itself); 23503: one was deleted after that check.
      const relinked = code === "P0002" || code === "23503"
        ? await dropDeletedLinks(ctx, write, md)
        : code === "23514"
        ? await leaveChangedParent(ctx, write, md)
        : null;
      if (!relinked) throw err; // nothing to recover from: a real failure, retry
      if (!hasLinkage(relinked.md)) {
        ctx.log.error("stripe_payment_unlinkable", {
          payment_intent: write.paymentIntentId,
          status: write.status,
          total_cents: write.totalCents,
          ...relinked.details,
        });
        return null;
      }
      ctx.log.warn("stripe_payment_relinked", {
        payment_intent: write.paymentIntentId,
        ...relinked.details,
      });
      md = relinked.md;
      notes.push(relinked.note);
    }
  }

  // Links the SQL dropped because their record was deleted (a booking
  // deleted while its deposit link was open): say so on the payment.
  const dropped = await deletedLinksOf(ctx, write.shopId, md, row);
  if (dropped.length > 0) {
    ctx.log.warn("stripe_payment_relinked", {
      payment_intent: write.paymentIntentId,
      deleted: dropped,
    });
    notes.push(
      dropped.length === 1 && dropped[0] === "customer"
        ? "Paid through a link opened for a customer who has since been deleted: " +
          "check who paid before applying it"
        : `Received for a deleted ${dropped.join(" / ")}: apply it to an invoice or refund it`,
    );
  }

  const otherMethod = unmappedMethodType(write.charge);
  if (otherMethod) {
    ctx.log.warn("stripe_unmapped_payment_method", {
      payment_intent: write.paymentIntentId,
      payment_id: row.id,
      payment_method_type: otherMethod,
    });
    notes.push(`Stripe payment method: ${otherMethod.replaceAll("_", " ")} (recorded as card)`);
  }
  if (notes.length > 0) await annotatePayment(ctx, row, notes.join(". "));
  return row;
}

/** Most merge hops followed (a merged customer's target merged again, ...). */
const MAX_MERGE_HOPS = 5;

/**
 * P-20: money for a customer who was merged into another (a link opened
 * before the merge) belongs to the surviving customer, the same person: the
 * metadata's customer follows customers.merged_into_id. Unchanged when the
 * customer was never merged (one lookup) or no longer exists.
 */
async function followMergedCustomer(
  ctx: WebhookContext,
  shopId: string,
  md: CrmMetadata,
): Promise<CrmMetadata> {
  let current = md.customerId;
  const seen = new Set<string>();
  for (let hop = 0; current !== null && hop < MAX_MERGE_HOPS; hop++) {
    seen.add(current);
    const { data, error } = await ctx.admin
      .from("customers")
      .select("id, merged_into_id")
      .eq("id", current)
      .eq("shop_id", shopId)
      .maybeSingle<{ id: string; merged_into_id: string | null }>();
    if (error) throw new DbError("customers lookup", error);
    const next = data?.merged_into_id ?? null;
    if (next === null || seen.has(next)) break;
    current = next;
  }
  if (current === md.customerId) return md;
  ctx.log.info("stripe_payment_merged_customer", {
    from_customer: md.customerId,
    to_customer: current,
  });
  return { ...md, customerId: current };
}

const LINK_TABLES = [
  { key: "invoiceId", table: "invoices", label: "invoice" },
  { key: "jobId", table: "jobs", label: "job" },
  { key: "membershipId", table: "memberships", label: "membership" },
  { key: "customerId", table: "customers", label: "customer" },
] as const;

interface Relinked {
  md: CrmMetadata;
  /** Why the metadata linkage was changed (logged). */
  details: Record<string, unknown>;
  /** Staff-facing note stored on the payment. */
  note: string;
}

const ROW_COLUMNS = {
  invoiceId: "invoice_id",
  jobId: "job_id",
  membershipId: "membership_id",
  customerId: "customer_id",
} as const;

/**
 * The linked records the metadata names that the recorded payment does not
 * carry because they no longer exist in the shop (upsert_stripe_payment drops
 * them). Only differing links are looked up, so a payment recorded as named
 * costs no query.
 */
async function deletedLinksOf(
  ctx: WebhookContext,
  shopId: string,
  md: CrmMetadata,
  row: PaymentRow,
): Promise<string[]> {
  const deleted: string[] = [];
  for (const { key, table, label } of LINK_TABLES) {
    const id = md[key];
    if (id === null || row[ROW_COLUMNS[key]] === id) continue;
    if (!(await existsInShop(ctx, table, id, shopId))) deleted.push(label);
  }
  return deleted;
}

/**
 * P0002 / 23503: records the metadata links to were deleted after the
 * payment started (e.g. a booking deleted while its deposit link was still open).
 * The insert can never succeed as is, so the money is kept as an unapplied
 * payment of the customer instead of failing on every redelivery. Returns
 * the linkage without the records that no longer exist in the shop (null
 * when none is missing). A deleted membership turns a membership payment
 * into a plain payment (payments_membership_kind); a missing customer falls
 * back to the shop's customer for the paying Stripe customer.
 */
async function dropDeletedLinks(
  ctx: WebhookContext,
  write: PaymentWrite,
  current: CrmMetadata,
): Promise<Relinked | null> {
  const md: CrmMetadata = { ...current };
  const deleted: string[] = [];
  for (const { key, table, label } of LINK_TABLES) {
    const id = md[key];
    if (id === null) continue;
    if (!(await existsInShop(ctx, table, id, write.shopId))) {
      md[key] = null;
      deleted.push(label);
    }
  }
  if (deleted.length === 0) return null;
  if (md.membershipId === null && md.kind === "membership") md.kind = "payment";
  if (md.customerId === null) {
    md.customerId = await customerByStripeId(ctx, write.shopId, write.stripeCustomer ?? null);
  }
  return {
    md,
    details: { deleted },
    note: `Received for a deleted ${deleted.join(" / ")}: apply it to an invoice or refund it`,
  };
}

async function existsInShop(
  ctx: WebhookContext,
  table: string,
  id: string,
  shopId: string,
): Promise<boolean> {
  const { data, error } = await ctx.admin
    .from(table)
    .select("id")
    .eq("id", id)
    .eq("shop_id", shopId)
    .maybeSingle<{ id: string }>();
  if (error) throw new DbError(`${table} lookup`, error);
  return data !== null;
}

/**
 * 23514 from payments_before_write (0012): the job / invoice the metadata
 * names now belongs to another customer than the payer (staff changed the
 * job's customer while a deposit Checkout opened for the previous one was
 * still payable), or the invoice now belongs to another job. The payer's
 * money is real and Stripe has it, so it is never failed forever: like the
 * SQL does for money that arrives for a void invoice, it stays with the
 * paying customer as an unapplied payment with a note. When the payer is no
 * longer in the CRM (e.g. merged into the job's new customer and deleted),
 * the payment goes to the job (and so to its current customer / invoice).
 * Returns null when no such conflict exists (a real failure: retried).
 */
async function leaveChangedParent(
  ctx: WebhookContext,
  write: PaymentWrite,
  current: CrmMetadata,
): Promise<Relinked | null> {
  const parent = await changedParent(ctx, write.shopId, current);
  if (!parent) return null;
  let payer = current.customerId;
  if (payer !== null && !(await existsInShop(ctx, "customers", payer, write.shopId))) payer = null;
  payer ??= await customerByStripeId(ctx, write.shopId, write.stripeCustomer ?? null);
  if (payer !== null && payer !== parent.customerId) {
    return {
      md: { ...current, invoiceId: null, jobId: null, customerId: payer },
      details: { changed: parent.label, payer_known: true },
      note: `Received for a ${parent.label} that has since moved to another customer; ` +
        "kept as this customer's unapplied payment: apply it to an invoice or refund it",
    };
  }
  // The payer is gone (or IS the parent's customer): the parent decides.
  return {
    md: {
      ...current,
      customerId: null,
      invoiceId: current.jobId !== null ? null : current.invoiceId,
    },
    details: { changed: parent.label, payer_known: false },
    note: `Paid through a link opened for this ${parent.label}'s previous customer: ` +
      "check who paid before applying it",
  };
}

/**
 * The job / invoice of the metadata whose current customer (or job) no longer
 * matches it, with that current customer; null when nothing conflicts.
 */
async function changedParent(
  ctx: WebhookContext,
  shopId: string,
  md: CrmMetadata,
): Promise<{ label: "job" | "invoice"; customerId: string } | null> {
  if (md.invoiceId !== null) {
    const { data, error } = await ctx.admin
      .from("invoices")
      .select("id, job_id, customer_id")
      .eq("id", md.invoiceId)
      .eq("shop_id", shopId)
      .maybeSingle<{ id: string; job_id: string | null; customer_id: string }>();
    if (error) throw new DbError("invoices lookup", error);
    if (
      data &&
      ((md.customerId !== null && md.customerId !== data.customer_id) ||
        (md.jobId !== null && md.jobId !== data.job_id))
    ) {
      return { label: "invoice", customerId: data.customer_id };
    }
  }
  if (md.jobId !== null && md.customerId !== null) {
    const { data, error } = await ctx.admin
      .from("jobs")
      .select("id, customer_id")
      .eq("id", md.jobId)
      .eq("shop_id", shopId)
      .maybeSingle<{ id: string; customer_id: string }>();
    if (error) throw new DbError("jobs lookup", error);
    if (data && data.customer_id !== md.customerId) {
      return { label: "job", customerId: data.customer_id };
    }
  }
  return null;
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
 *
 * `cardOwner` is the Stripe customer the card is attached to (pm.customer).
 * A new card is only ever saved for the CRM customer whose
 * stripe_customer_id IS that Stripe customer: the payment it came with may
 * have been relinked to another customer (e.g. the payer was deleted and the
 * deposit fell to the job's new customer). Saving it there would show the
 * payer's card as someone else's and make charge_saved_card pick a card
 * Stripe refuses for that customer. An already saved card is compared with
 * its own Stripe customer instead (a merge moved it; 0095). The SQL helper
 * enforces the same rule (p_stripe_customer_id).
 */
async function saveCard(
  ctx: WebhookContext,
  shopId: string,
  customerId: string,
  pmId: string,
  card: CardDetails,
  cardOwner: string,
): Promise<Outcome> {
  const { data: target, error } = await ctx.admin
    .from("customers")
    .select("id, stripe_customer_id")
    .eq("id", customerId)
    .eq("shop_id", shopId)
    .maybeSingle<{ id: string; stripe_customer_id: string | null }>();
  if (error) throw new DbError("customers lookup", error);
  if (!target) return ignore(ctx, "customer_not_found", { payment_method: pmId });
  // The Stripe customer the card must be attached to: an already saved
  // card's own (customer_payment_methods.stripe_customer_id, 0071) — a card a
  // customer merge moved keeps charging on the Stripe customer that owns it,
  // so its re-save is a refresh (0095) — else this customer's. A card saved
  // for another CRM customer is refused by the RPC (payment_method_conflict).
  const { data: saved, error: savedError } = await ctx.admin
    .from("customer_payment_methods")
    .select("stripe_customer_id")
    .eq("shop_id", shopId)
    .eq("stripe_payment_method_id", pmId)
    .maybeSingle<{ stripe_customer_id: string | null }>();
  if (savedError) throw new DbError("customer_payment_methods lookup", savedError);
  if ((saved?.stripe_customer_id ?? target.stripe_customer_id) !== cardOwner) {
    return ignore(ctx, "payment_method_customer_mismatch", { payment_method: pmId });
  }
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
      // 0011: refused (22023) unless it is the customer's Stripe customer
      p_stripe_customer_id: cardOwner,
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
 * A card paid with `setup_future_usage` (on the intent, or on its card
 * options as the Checkout links set it) is attached to the Stripe customer: remember it for the payment's customer,
 * but only when that customer IS the card's Stripe customer (saveCard). A
 * payment relinked away from its payer (leaveChangedParent / dropDeletedLinks
 * falling back to the job's current customer) records the money there, never
 * the payer's card.
 */
async function saveCardFromIntent(
  ctx: WebhookContext,
  shopId: string,
  pi: Stripe.PaymentIntent,
  charge: Stripe.Charge | null,
  payment: PaymentRow,
): Promise<void> {
  if (!intentSavesCard(pi) || !stripeCustomerId(pi.customer)) return;
  const pmId = paymentMethodId(pi.payment_method);
  const card = chargeCard(charge);
  // A Link payment is its own payment method type: the card options' saving
  // does not apply to it and the card on file is card-only. The public links
  // no longer offer Link (NO_LINK_WALLET); a link opened before that, or a
  // Link payment Stripe still let through, is flagged so a missing card on
  // file can be traced.
  if (!card && charge?.payment_method_details?.type === "link") {
    ctx.log.warn("stripe_card_not_saved", {
      reason: "link_payment",
      payment_intent: pi.id,
      payment_id: payment.id,
      shop_id: shopId,
    });
    return;
  }
  if (!pmId || !card || card.method !== "card" || !payment.customer_id) return;
  // A redelivery can arrive after the customer removed the card again.
  const pm = await retrievePaymentMethod(ctx, pmId);
  const cardOwner = stripeCustomerId(pm?.customer);
  if (!cardOwner) {
    ignore(ctx, "payment_method_detached", { payment_method: pmId });
    return;
  }
  await saveCard(ctx, shopId, payment.customer_id, pmId, card, cardOwner);
}

/** Stripe's current payment method, or null when Stripe no longer has it. */
async function retrievePaymentMethod(
  ctx: WebhookContext,
  pmId: string,
): Promise<Stripe.PaymentMethod | null> {
  try {
    return await ctx.stripe.paymentMethods.retrieve(pmId, {}, onAccount(connectedAccount(ctx)));
  } catch (err) {
    if (isMissingResource(err)) return null;
    throw err;
  }
}

function isMissingResource(err: unknown): boolean {
  if (typeof err !== "object" || err === null) return false;
  const e = err as { type?: unknown; code?: unknown; statusCode?: unknown };
  return e.type === "StripeInvalidRequestError" &&
    (e.code === "resource_missing" || e.statusCode === 404);
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
  // An online gift card sale is a gift_card_orders purchase, never a payment row.
  if (md.giftCardOrderId !== null) {
    if (status !== "succeeded") {
      return ignore(ctx, "gift_card_not_paid", { payment_intent: piId, status });
    }
    return await giftCardSold(ctx, shopId, md.giftCardOrderId, pi);
  }
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

  // An attempt that received nothing (declined / cancelled) only updates the
  // row of a payment we already track (a PaymentSheet or saved-card attempt).
  // It never creates one: payment rows are money records (they keep the job
  // and customer from being deleted and the job's customer from changing),
  // and a declined public deposit or an abandoned intent moved no money.
  // A processing payment (an ACH debit clearing for days, P-31) is money on
  // its way: it is recorded, in flight, so nothing charges the balance twice.
  const moving = recorded === "succeeded" || recorded === "processing";
  const tracked = moving ? null : await trackedMethod(ctx, shopId, piId);
  if (!moving && tracked === null) {
    return ignore(ctx, "no_money_received", { payment_intent: piId, status });
  }

  // Money that moved records the charge (method, brand / last4). A failure
  // only keeps the row's method right: an ACH debit that failed after
  // processing stays ach_debit (its failed charge says so), a declined card
  // keeps no card details (a declined sheet stays confirmable, see above).
  const charge = moving ? await latestCharge(ctx, pi) : null;
  const failedCharge = !moving && offersNonCardMethods(pi) ? await chargeIfAny(ctx, pi) : null;
  const payment = await recordPayment(ctx, {
    shopId,
    paymentIntentId: piId,
    status: recorded,
    totalCents: total,
    md,
    method: moving
      ? intentMethod(pi)
      : (chargeMethod(failedCharge)?.method ?? tracked ?? intentMethod(pi)),
    charge,
    stripeCustomer: stripeCustomerId(pi.customer),
    stripeMethodType: stripeMethodTypeOf(charge ?? failedCharge, pi),
  });
  if (!payment) return ignore(ctx, "linkage_deleted", { payment_intent: piId });
  if (status === "succeeded") {
    await syncRefund(ctx, piId, charge);
    await saveCardFromIntent(ctx, shopId, pi, charge, payment);
    await cancelSiblingSheets(ctx, shopId, payment);
  }
  return applied(ctx, reconfirmable ? "payment_declined_open" : `payment_${status}`, {
    payment_intent: piId,
    payment_id: payment.id,
  });
}

// ---------------------------------------------------------------------------
// Sibling PaymentSheets of a settled invoice
// ---------------------------------------------------------------------------

/** Sheet states in which no card was given yet (requires_action is mid-3DS: left alone). */
const WAITING_SHEET = new Set<string>(["requires_payment_method", "requires_confirmation"]);

interface SheetRow {
  id: string;
  shop_id: string;
  invoice_id: string | null;
  job_id: string | null;
  customer_id: string;
  kind: "deposit" | "payment" | "membership";
  method: PaymentMethodKind;
  amount_cents: number;
  tip_cents: number;
  stripe_payment_intent_id: string;
}

/**
 * Money just landed on an invoice. When nothing is left to pay (status paid
 * or balance <= 0), the invoice's other PaymentSheets still waiting for a card
 * (another device, a sheet left open) are cancelled in Stripe (idempotency key
 * sheet_cancel:<pi>) and recorded cancelled, so they can no longer overpay
 * it. Only PaymentSheet and Terminal / Tap to Pay intents (sources
 * payment_sheet / terminal) in requires_payment_method /
 * requires_confirmation are touched; anything else (processing, 3DS in
 * progress, other flows) is left to the payments sweep. Deposits need no
 * pass of their own: a deposit payment attaches to the job's invoice
 * (payments_before_write), and deposit links are Checkout Sessions that
 * supersede each other. Best effort: a failure is logged, never fails the
 * delivery (the money is already recorded; sweep_payment_sheets releases a
 * sheet left open).
 */
async function cancelSiblingSheets(
  ctx: WebhookContext,
  shopId: string,
  payment: PaymentRow,
): Promise<void> {
  if (!payment.invoice_id || !RECEIVED.has(payment.status)) return;
  const { data: invoice, error } = await ctx.admin
    .from("invoices")
    .select("id, status, balance_cents")
    .eq("id", payment.invoice_id)
    .eq("shop_id", shopId)
    .maybeSingle<{ id: string; status: string; balance_cents: number }>();
  if (error) throw new DbError("invoices lookup", error);
  if (!invoice || (invoice.status !== "paid" && invoice.balance_cents > 0)) return;
  const { data: rows, error: rowsError } = await ctx.admin
    .from("payments")
    .select(
      "id, shop_id, invoice_id, job_id, customer_id, kind, method, amount_cents, tip_cents, stripe_payment_intent_id",
    )
    .eq("shop_id", shopId)
    .eq("invoice_id", invoice.id)
    .eq("status", "pending")
    .in("method", ["card", "card_present"])
    .neq("kind", "membership")
    .returns<SheetRow[]>();
  if (rowsError) throw new DbError("pending payments lookup", rowsError);
  for (const row of rows ?? []) {
    if (!row.stripe_payment_intent_id || row.id === payment.id) continue;
    try {
      const account = onAccount(connectedAccount(ctx));
      const intent = await ctx.stripe.paymentIntents.retrieve(
        row.stripe_payment_intent_id,
        {},
        account,
      );
      if (
        !DEVICE_INTENT_SOURCES.has(intent.metadata?.source ?? "") ||
        !WAITING_SHEET.has(intent.status)
      ) {
        continue;
      }
      await ctx.stripe.paymentIntents.cancel(
        intent.id,
        { cancellation_reason: "duplicate" },
        onAccount(connectedAccount(ctx), {
          idempotencyKey: await idempotencyKey("sheet_cancel", intent.id),
        }),
      );
      await rpc(ctx, "upsert_stripe_payment", {
        p_shop_id: shopId,
        p_payment_intent_id: row.stripe_payment_intent_id,
        p_status: "cancelled",
        p_amount_cents: row.amount_cents,
        p_tip_cents: row.tip_cents,
        p_kind: row.kind,
        p_method: row.method,
        p_invoice_id: row.invoice_id,
        p_job_id: row.job_id,
        p_customer_id: row.customer_id,
      });
      ctx.log.info("sibling_sheet_cancelled", {
        payment_intent: row.stripe_payment_intent_id,
        payment_id: row.id,
        invoice_id: invoice.id,
      });
    } catch (err) {
      ctx.log.warn("sibling_sheet_cancel_failed", {
        payment_intent: row.stripe_payment_intent_id,
        invoice_id: invoice.id,
        error: err instanceof Error ? err.message : String(err),
      });
    }
  }
}

/** The method of this intent's payment row in the shop, or null when there is none. */
async function trackedMethod(
  ctx: WebhookContext,
  shopId: string,
  piId: string,
): Promise<PaymentMethodKind | null> {
  const { data, error } = await ctx.admin
    .from("payments")
    .select("id, method")
    .eq("stripe_payment_intent_id", piId)
    .eq("shop_id", shopId)
    .maybeSingle<{ id: string; method: string | null }>();
  if (error) throw new DbError("payments lookup", error);
  if (!data) return null;
  const method = data.method;
  return method === "card_present" || method === "ach_debit" || method === "bnpl" ? method : "card";
}

// ---------------------------------------------------------------------------
// checkout.session.completed
// ---------------------------------------------------------------------------

/**
 * checkout.session.completed, and the outcome of a Checkout paid with an
 * asynchronous method (ACH debit, P-31): async_payment_succeeded (the money
 * settled: payment_status 'paid') and async_payment_failed (the debit was
 * returned before it settled: the processing payment becomes failed).
 */
async function onCheckoutSessionCompleted(
  ctx: WebhookContext,
  session: Stripe.Checkout.Session,
  options: { asyncFailed?: boolean } = {},
): Promise<Outcome> {
  const shopId = await shopForAccount(ctx);
  if (!shopId) return ignore(ctx, "unknown_account");
  // Fail fast on a foreign session before calling Stripe.
  if (ownership(shopId, session.metadata) === "shop_mismatch") {
    return ignore(ctx, "shop_mismatch", { shop_id: shopId });
  }
  if (options.asyncFailed) {
    return session.mode === "payment"
      ? await checkoutPayment(ctx, shopId, session, { failed: true })
      : ignore(ctx, "unsupported_mode");
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
  options: { failed?: boolean } = {},
): Promise<Outcome> {
  if (!options.failed && session.payment_status === "no_payment_required") {
    return ignore(ctx, "no_payment_required");
  }
  if (!options.failed && session.payment_status !== "paid" && session.payment_status !== "unpaid") {
    return ignore(ctx, "no_payment_required");
  }
  const piId = paymentIntentId(session.payment_intent);
  if (!piId) return ignore(ctx, "no_payment_intent");

  const pi = typeof session.payment_intent === "object" && session.payment_intent !== null
    ? session.payment_intent
    : await retrieveIntent(ctx, piId);
  const owner = ownership(shopId, session.metadata, pi.metadata);
  if (owner !== "ours") return ignore(ctx, owner, { payment_intent: piId, shop_id: shopId });
  const md = readMetadata(mergeMetadata(session.metadata, pi.metadata));
  noteProblems(ctx, md);
  if (md.giftCardOrderId !== null) {
    if (options.failed || session.payment_status !== "paid" || pi.status !== "succeeded") {
      return ignore(ctx, "gift_card_not_paid", { payment_intent: piId });
    }
    return await giftCardSold(ctx, shopId, md.giftCardOrderId, pi);
  }
  if (!hasLinkage(md)) return ignore(ctx, "no_linkage", { payment_intent: piId });

  // paid -> succeeded. unpaid: an asynchronous method (ACH debit) is
  // clearing -> processing (money in flight for days), or still waiting for
  // the customer to verify the bank account -> pending. A failed async
  // payment (async_payment_failed) only updates a row we already track.
  let status: PaymentStatus;
  if (options.failed) status = pi.status === "succeeded" ? "succeeded" : "failed";
  else if (session.payment_status === "paid") status = "succeeded";
  else if (pi.status === "succeeded") status = "succeeded";
  else if (pi.status === "processing") status = "processing";
  else if (pi.status === "canceled") status = "cancelled";
  else status = "pending";
  const tracked = status === "failed" || status === "cancelled"
    ? await trackedMethod(ctx, shopId, piId)
    : null;
  if ((status === "failed" || status === "cancelled") && tracked === null) {
    return ignore(ctx, "no_money_received", { payment_intent: piId, status });
  }
  const total = intentTotal(pi, status);
  if (!Number.isSafeInteger(total) || total <= 0) return ignore(ctx, "zero_amount");

  // An unpaid (clearing) session already has its charge for bank debits:
  // read it too, so the method (ach_debit) is right while it is processing.
  const charge = await chargeIfAny(ctx, pi);
  const received = status === "succeeded" || status === "processing" || status === "pending";
  const payment = await recordPayment(ctx, {
    shopId,
    paymentIntentId: piId,
    status,
    totalCents: total,
    md,
    method: received
      ? intentMethod(pi)
      : (chargeMethod(charge)?.method ?? tracked ?? intentMethod(pi)),
    charge: received ? charge : null,
    checkoutSessionId: checkoutSessionId(session.id),
    stripeCustomer: stripeCustomerId(pi.customer) ?? stripeCustomerId(session.customer),
    stripeMethodType: stripeMethodTypeOf(charge, pi),
  });
  if (!payment) return ignore(ctx, "linkage_deleted", { payment_intent: piId });
  if (status === "succeeded") {
    await syncRefund(ctx, piId, charge);
    await saveCardFromIntent(ctx, shopId, pi, charge, payment);
    await cancelSiblingSheets(ctx, shopId, payment);
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
// Gift card sales (P-13): gift_card_orders, never payments rows
// ---------------------------------------------------------------------------

interface GiftOrderRow {
  id: string;
  shop_id: string;
  status: string;
  gift_card_id: string | null;
}

/** The gift card order of this shop, or null (another shop's id or deleted). */
async function giftOrder(
  ctx: WebhookContext,
  shopId: string,
  orderId: string,
): Promise<GiftOrderRow | null> {
  const { data, error } = await ctx.admin
    .from("gift_card_orders")
    .select("id, shop_id, status, gift_card_id")
    .eq("id", orderId)
    .eq("shop_id", shopId)
    .maybeSingle<GiftOrderRow>();
  if (error) throw new DbError("gift_card_orders lookup", error);
  return data;
}

/**
 * An online gift card purchase was paid (checkout.session.completed /
 * payment_intent.succeeded with metadata kind 'gift_card'):
 * gift_card_order_paid (0066) issues the card once (idempotent: a replay
 * returns the card it already issued) and queues its delivery. The sale is
 * the shop's revenue from a gift card order, never a payments row: the money
 * is tender only when the card is redeemed on an invoice. A refund that
 * arrived first is applied right after.
 */
async function giftCardSold(
  ctx: WebhookContext,
  shopId: string,
  orderId: string,
  pi: Stripe.PaymentIntent,
): Promise<Outcome> {
  const piId = paymentIntentId(pi.id);
  if (!piId) return ignore(ctx, "invalid_object");
  const order = await giftOrder(ctx, shopId, orderId);
  if (!order) return ignore(ctx, "gift_card_order_not_found", { payment_intent: piId });
  const received = pi.amount_received;
  if (!Number.isSafeInteger(received) || received <= 0) return ignore(ctx, "zero_amount");
  let result: { gift_card_id?: string; first_time?: boolean } | null;
  try {
    result = await rpc(ctx, "gift_card_order_paid", {
      p_order_id: order.id,
      p_payment_intent_id: piId,
      p_amount_received_cents: received,
    });
  } catch (err) {
    // 22023: the amount does not match the order's price, or the intent
    // already issued another shop's card; P0002: the order is gone. No retry
    // can change either: staff sort it out in Stripe (the money is there).
    if (err instanceof DbError && (err.code === "22023" || err.code === "P0002")) {
      ctx.log.error("gift_card_order_unpaid", {
        payment_intent: piId,
        order_id: order.id,
        code: err.code,
        amount_received_cents: received,
      });
      return ignore(ctx, "gift_card_order_rejected", { payment_intent: piId });
    }
    throw err;
  }
  const charge = await chargeIfAny(ctx, pi);
  if ((charge?.amount_refunded ?? 0) > 0) await giftCardRefunded(ctx, piId, charge);
  return applied(
    ctx,
    result?.first_time === false ? "gift_card_already_issued" : "gift_card_issued",
    {
      payment_intent: piId,
      order_id: order.id,
      gift_card_id: result?.gift_card_id ?? null,
    },
  );
}

/**
 * checkout.session.expired: a Checkout that ended unpaid. Only an online gift
 * card sale has a record waiting on it: gift_card_order_expired (0095) turns
 * its pending order `expired` (idempotent: a replay, or an order already
 * paid or refunded, changes nothing). Every other session the CRM creates
 * (invoice and deposit links, card saving, memberships) recorded nothing
 * before payment, so its expiry needs nothing.
 */
async function onCheckoutSessionExpired(
  ctx: WebhookContext,
  session: Stripe.Checkout.Session,
): Promise<Outcome> {
  const shopId = await shopForAccount(ctx);
  if (!shopId) return ignore(ctx, "unknown_account");
  const owner = ownership(shopId, session.metadata);
  if (owner !== "ours") return ignore(ctx, owner, { shop_id: shopId });
  const md = readMetadata(session.metadata);
  noteProblems(ctx, md);
  if (md.giftCardOrderId === null) return ignore(ctx, "nothing_to_expire");
  const sessionId = checkoutSessionId(session.id);
  if (!sessionId) return ignore(ctx, "invalid_object");
  // The order must be this shop's (the RPC finds it by the session alone).
  const order = await giftOrder(ctx, shopId, md.giftCardOrderId);
  if (!order) return ignore(ctx, "gift_card_order_not_found", { session: sessionId });
  let result: { order_id?: string; status?: string; changed?: boolean } | null;
  try {
    result = await rpc(ctx, "gift_card_order_expired", { p_session_id: sessionId });
  } catch (err) {
    // P0002: no order carries this session (its id was never saved on the
    // order); 22023: not a Checkout Session id. No retry changes either.
    if (err instanceof DbError && (err.code === "P0002" || err.code === "22023")) {
      return ignore(ctx, "gift_card_order_not_found", { session: sessionId, code: err.code });
    }
    throw err;
  }
  if (result?.order_id !== order.id) {
    // The session's metadata and the order that recorded it disagree: a bug
    // or tampering upstream. The RPC only ever expires a pending order.
    ctx.log.warn("gift_card_order_session_mismatch", {
      session: sessionId,
      order_id: order.id,
      expired_order_id: result?.order_id ?? null,
    });
  }
  if (result?.changed !== true) {
    return ignore(ctx, "gift_card_order_not_pending", {
      session: sessionId,
      order_id: result?.order_id ?? order.id,
      status: result?.status ?? null,
    });
  }
  return applied(ctx, "gift_card_order_expired", {
    session: sessionId,
    order_id: result.order_id ?? order.id,
  });
}

/**
 * A gift card purchase was refunded (in the Stripe dashboard):
 * gift_card_order_refunded (0066) takes the refunded share of the value off
 * the card (and voids an unused card refunded in full). It only ever raises
 * the refunded total; a refund that later failed is not given back to the
 * card (logged for staff).
 */
async function giftCardRefunded(
  ctx: WebhookContext,
  piId: string,
  charge: Stripe.Charge | null,
): Promise<Outcome> {
  const refunded = charge?.amount_refunded ?? 0;
  if (!Number.isSafeInteger(refunded) || refunded <= 0) return ignore(ctx, "nothing_refunded");
  try {
    const result = await rpc<{ removed_cents?: number; unrecovered_cents?: number } | null>(
      ctx,
      "gift_card_order_refunded",
      { p_payment_intent_id: piId, p_refunded_total_cents: refunded },
    );
    if ((result?.unrecovered_cents ?? 0) > 0) {
      // Part of the refunded value was already spent on invoices.
      ctx.log.warn("gift_card_refund_unrecovered", {
        payment_intent: piId,
        unrecovered_cents: result?.unrecovered_cents,
      });
    }
    return applied(ctx, "gift_card_refunded", {
      payment_intent: piId,
      refunded_cents_total: refunded,
      removed_cents: result?.removed_cents ?? 0,
    });
  } catch (err) {
    // P0002: no card was issued for this intent (not paid yet, or not a sale
    // of this platform); 22023: a total outside the order's price.
    if (err instanceof DbError && (err.code === "P0002" || err.code === "22023")) {
      return ignore(ctx, "gift_card_refund_unmatched", { payment_intent: piId, code: err.code });
    }
    throw err;
  }
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
    : await retrievePaymentMethod(ctx, pmId);
  const card = paymentMethodCard(pm);
  if (!card) return ignore(ctx, "not_a_card", { payment_method: pmId });
  // Only a card attached to a Stripe customer can be charged later; one
  // removed before this (possibly late) event is processed is not saved.
  const cardOwner = stripeCustomerId(pm?.customer);
  if (!cardOwner) {
    return ignore(ctx, "payment_method_detached", { payment_method: pmId });
  }

  const md = readMetadata(metadata);
  noteProblems(ctx, md);
  const customerId = md.customerId ?? await customerByStripeId(ctx, shopId, si.customer);
  if (!customerId) return ignore(ctx, "unknown_customer", { payment_method: pmId });
  return await saveCard(ctx, shopId, customerId, pmId, card, cardOwner);
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
// payment_method.detached / customer.deleted
// ---------------------------------------------------------------------------

/**
 * A saved card was removed in Stripe (the PaymentSheet's "remove card", the
 * Express dashboard, the API). remove_customer_payment_method (0011) deletes
 * it from the CRM and promotes the customer's newest remaining card to
 * default, so charge_saved_card never picks a card Stripe will refuse.
 * Detaching is final in Stripe, so the event alone is authoritative.
 */
async function onPaymentMethodDetached(
  ctx: WebhookContext,
  pm: Stripe.PaymentMethod,
): Promise<Outcome> {
  const shopId = await shopForAccount(ctx);
  if (!shopId) return ignore(ctx, "unknown_account");
  const pmId = paymentMethodId(pm.id);
  if (!pmId) return ignore(ctx, "invalid_object");
  const removed = await rpc<boolean>(ctx, "remove_customer_payment_method", {
    p_shop_id: shopId,
    p_stripe_payment_method_id: pmId,
  });
  if (!removed) return ignore(ctx, "card_not_saved", { payment_method: pmId });
  return applied(ctx, "card_removed", { payment_method: pmId });
}

/**
 * A Stripe customer was deleted: its cards can no longer be charged. Every
 * card saved for the shop's customer mapped to it (or saved on it and moved
 * by a customer merge) is re-read and removed unless Stripe shows it
 * attached to another (live) customer.
 */
async function onCustomerDeleted(ctx: WebhookContext, cus: Stripe.Customer): Promise<Outcome> {
  const shopId = await shopForAccount(ctx);
  if (!shopId) return ignore(ctx, "unknown_account");
  const cusId = stripeCustomerId(cus.id);
  if (!cusId) return ignore(ctx, "invalid_object");
  const customerId = await customerByStripeId(ctx, shopId, cusId);
  // Cards saved on this Stripe customer: those of the CRM customer it maps
  // to, and cards a customer merge (P-20) moved to another customer, which
  // keep their Stripe customer (customer_payment_methods.stripe_customer_id).
  const cards = new Set<string>();
  if (customerId) {
    const { data, error } = await ctx.admin
      .from("customer_payment_methods")
      .select("stripe_payment_method_id")
      .eq("shop_id", shopId)
      .eq("customer_id", customerId)
      .returns<{ stripe_payment_method_id: string }[]>();
    if (error) throw new DbError("customer_payment_methods lookup", error);
    for (const row of data ?? []) cards.add(row.stripe_payment_method_id);
  }
  const moved = await ctx.admin
    .from("customer_payment_methods")
    .select("stripe_payment_method_id")
    .eq("shop_id", shopId)
    .eq("stripe_customer_id", cusId)
    .returns<{ stripe_payment_method_id: string }[]>();
  if (moved.error) throw new DbError("customer_payment_methods lookup", moved.error);
  for (const row of moved.data ?? []) cards.add(row.stripe_payment_method_id);
  if (!customerId && cards.size === 0) return ignore(ctx, "unknown_customer");
  let removed = 0;
  for (const pmId of cards) {
    const pm = await retrievePaymentMethod(ctx, pmId);
    const owner = stripeCustomerId(pm?.customer);
    if (owner && owner !== cusId) continue;
    const done = await rpc<boolean>(ctx, "remove_customer_payment_method", {
      p_shop_id: shopId,
      p_stripe_payment_method_id: pmId,
    });
    if (done) removed++;
  }
  if (removed === 0) return ignore(ctx, "no_saved_cards", { customer_id: customerId });
  return applied(ctx, "cards_removed", { customer_id: customerId, cards: removed });
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
      // A gift card sale has no payment row: the card's value follows the refund.
      if (!existing && md.giftCardOrderId !== null) {
        const order = await giftOrder(ctx, shopId, md.giftCardOrderId);
        if (!order) return ignore(ctx, "gift_card_order_not_found", { payment_intent: piId });
        if (!order.gift_card_id && pi.status === "succeeded") {
          // refunded before the sale was recorded: issue the card first
          await giftCardSold(ctx, shopId, order.id, { ...pi, latest_charge: charge });
          return applied(ctx, "gift_card_refunded", {
            payment_intent: piId,
            refunded_cents_total: charge.amount_refunded,
          });
        }
        return await giftCardRefunded(ctx, piId, charge);
      }
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
        giftCardOrderId: null,
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
 * cannot (it keeps the greater value), so this uses set_stripe_refund_total
 * (0093), a compare-and-set on the refunded total it read: if another writer
 * (the staff refund action, a concurrent delivery) changed the row in
 * between, it raises 40001 and the delivery fails, so Stripe redelivers and
 * the charge is read again. The SQL derives the status (payment_refund_status).
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
  const updated = await rpc<RefundRow>(ctx, "set_stripe_refund_total", {
    p_shop_id: shopId,
    p_payment_intent_id: piId,
    p_expected_refunded_cents: row.refunded_cents,
    p_refunded_cents_total: refundedCents,
  });
  ctx.log.warn("stripe_refund_reversed", {
    payment_intent: piId,
    payment_id: row.id,
    previous_refunded_cents: row.refunded_cents,
    refunded_cents_total: refundedCents,
    status: updated?.status ?? null,
  });
}

// ---------------------------------------------------------------------------
// charge.dispute.*
// ---------------------------------------------------------------------------

const DISPUTE_NOTE_PREFIX = "Stripe dispute";
const DISPUTE_ID_RE = /^(dp|du)_[A-Za-z0-9]+$/;
/** Who can answer a dispute: the Express dashboard (login_link) is admin+. */
const DISPUTE_ROLES = ["owner", "admin"];

interface DisputePaymentRow {
  id: string;
  shop_id: string;
  job_id: string | null;
  invoice_id: string | null;
  customer_id: string;
  stripe_payment_intent_id: string | null;
  note: string | null;
}

/** The payments row apply_stripe_dispute returns (the column read here). */
interface DisputeOutcome {
  disputed_cents: number;
}

const DISPUTE_PAYMENT_COLUMNS =
  "id, shop_id, job_id, invoice_id, customer_id, stripe_payment_intent_id, note";

/** The staff-facing line for a dispute's current state (no personal data). */
export function disputeNoteLine(dispute: {
  amount: number;
  currency: string;
  status: string;
  reason: string;
  evidence_details?: { due_by?: number | null } | null;
}): string {
  const amount = Number.isSafeInteger(dispute.amount) && dispute.amount >= 0
    ? formatCents(dispute.amount, dispute.currency || "usd")
    : "an amount";
  const reason = String(dispute.reason || "general").replaceAll("_", " ");
  const dueBy = isoFromUnix(dispute.evidence_details?.due_by)?.slice(0, 10);
  const head = `${DISPUTE_NOTE_PREFIX} (${reason}, ${amount}):`;
  switch (dispute.status) {
    case "warning_needs_response":
    case "needs_response":
      return `${head} open. Submit evidence in the Stripe dashboard` +
        (dueBy ? ` by ${dueBy}.` : ".");
    case "warning_under_review":
    case "under_review":
      return `${head} evidence submitted, under review by the card issuer.`;
    case "won":
      return `${head} won. The money stays with the shop.`;
    case "warning_closed":
      return `${head} inquiry closed without a chargeback.`;
    case "lost":
      return `${head} LOST. The card issuer took the money back from the shop's Stripe ` +
        "balance. The payment still counts toward the invoice: bill the customer again if needed.";
    default:
      return `${head} ${String(dispute.status).replaceAll("_", " ")}.`;
  }
}

/** The payment's note with its dispute line replaced (other notes kept). */
export function withDisputeLine(note: string | null, line: string): string {
  const rest = (note ?? "")
    .split("\n")
    .filter((l) => l.trim() !== "" && !l.startsWith(DISPUTE_NOTE_PREFIX))
    .join("\n");
  if (!rest) return line.slice(0, 1000);
  const room = Math.max(0, 1000 - line.length - 1);
  return `${rest.slice(0, room)}\n${line}`.slice(0, 1000);
}

const DISPUTE_ALERTS: Record<string, string> = {
  warning_needs_response: "A card payment was disputed",
  needs_response: "A card payment was disputed",
  won: "Dispute won",
  lost: "Dispute lost: money taken back",
};

/**
 * A customer disputed a card payment. The dispute's CURRENT state is re-read
 * (events can arrive out of order), so every charge.dispute.* event applies
 * the same outcome whatever its type or order:
 *   - apply_stripe_dispute (0093) records it on the payment: `lost` sets
 *     disputed_cents to what the dispute took back (never more than the
 *     charge not yet refunded); `won` / `warning_closed` clear it; open
 *     states leave it alone (funds_withdrawn / funds_reinstated therefore
 *     follow the dispute's current status). Balances, net amounts and
 *     revenue do not change: staff decide whether to bill again.
 *   - one line of the payment's note says where the dispute stands, so staff
 *     see that evidence is due;
 *   - owners/admins are notified when it opens and when it is decided, with
 *     the payment's customer and invoice as deep links.
 * A lost dispute takes the money (and Stripe's fee) back without any refund,
 * so the charge's refunded total does not move.
 */
async function onDisputeChanged(ctx: WebhookContext, event: Stripe.Dispute): Promise<Outcome> {
  const shopId = await shopForAccount(ctx);
  if (!shopId) return ignore(ctx, "unknown_account");
  if (typeof event.id !== "string" || !DISPUTE_ID_RE.test(event.id)) {
    return ignore(ctx, "invalid_object");
  }
  const dispute = await ctx.stripe.disputes.retrieve(
    event.id,
    {},
    onAccount(connectedAccount(ctx)),
  );
  const piId = paymentIntentId(dispute.payment_intent);
  const chId = chargeId(dispute.charge);
  const payment = await disputedPayment(ctx, shopId, piId, chId);
  if (!payment) {
    ctx.log.warn("stripe_dispute_unmatched", { dispute: dispute.id, payment_intent: piId });
    return ignore(ctx, "payment_not_found", { dispute: dispute.id });
  }

  const line = disputeNoteLine(dispute);
  const fields = {
    dispute: dispute.id,
    payment_id: payment.id,
    dispute_status: dispute.status,
    amount_cents: dispute.amount,
  };
  if (dispute.status === "lost") ctx.log.error("stripe_dispute_lost", fields);
  else ctx.log.warn("stripe_dispute", fields);

  // Idempotent: a replay (or an event without a state change) writes nothing.
  const recorded = payment.stripe_payment_intent_id
    ? await rpc<DisputeOutcome>(ctx, "apply_stripe_dispute", {
      p_shop_id: shopId,
      p_payment_intent_id: payment.stripe_payment_intent_id,
      p_dispute_status: dispute.status,
      p_amount_cents: dispute.amount,
    })
    : null;

  const note = withDisputeLine(payment.note, line);
  if (note === payment.note) {
    return ignore(ctx, "dispute_unchanged", {
      dispute: dispute.id,
      disputed_cents: recorded ? recorded.disputed_cents : null,
    });
  }

  // Notify before writing the note: a failed note write retries and may
  // notify twice, but a notification is never lost.
  const title = DISPUTE_ALERTS[dispute.status];
  if (title) {
    await rpc(ctx, "notify_shop_staff", {
      p_shop_id: shopId,
      p_roles: DISPUTE_ROLES,
      // a manager-only kind (0031): the alert carries the amount and reason,
      // which a member demoted to technician must stop seeing at once
      p_kind: "payment_received",
      p_title: title,
      p_body: line,
      p_job_id: payment.job_id,
      // deep links (0031): the payment's customer and invoice
      p_customer_id: payment.customer_id,
      p_invoice_id: payment.invoice_id,
    });
  }
  let update = ctx.admin
    .from("payments")
    .update({ note })
    .eq("id", payment.id)
    .eq("shop_id", shopId);
  update = payment.note === null ? update.is("note", null) : update.eq("note", payment.note);
  const { data, error } = await update.select("id");
  if (error) throw new DbError("payments dispute note", error);
  if (!data || data.length === 0) {
    throw new Error("payment note changed concurrently; the event will be retried");
  }
  return applied(ctx, `dispute_${dispute.status}`, fields);
}

async function disputedPayment(
  ctx: WebhookContext,
  shopId: string,
  piId: string | null,
  chId: string | null,
): Promise<DisputePaymentRow | null> {
  for (
    const [column, value] of [
      ["stripe_payment_intent_id", piId],
      ["stripe_charge_id", chId],
    ] as const
  ) {
    if (!value) continue;
    const { data, error } = await ctx.admin
      .from("payments")
      .select(DISPUTE_PAYMENT_COLUMNS)
      .eq(column, value)
      .eq("shop_id", shopId)
      .limit(1)
      .maybeSingle<DisputePaymentRow>();
    if (error) throw new DbError("payments lookup", error);
    if (data) return data;
  }
  return null;
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
  // What Stripe bills this member (the plan's price may have changed since).
  const terms = subscriptionTerms(sub);
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
      p_price_id: terms?.priceId ?? null,
      p_price_cents: terms?.amountCents ?? null,
      p_interval: terms?.interval ?? null,
      p_interval_count: terms?.intervalCount ?? null,
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
        giftCardOrderId: null,
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
