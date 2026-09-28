/**
 * Platform billing event handlers (docs/BILLING.md): Stripe events of the
 * PLATFORM account about shop subscriptions, mapped to the service-role RPCs
 * of migration 0101 (billing_link_customer, billing_apply_subscription,
 * billing_payment_failed) and to the plan sync (_shared/billing_plans.ts).
 *
 * Rules:
 *  - Only platform events reach these handlers (index.ts drops any event
 *    with `account`): shop payments on connected accounts are stripe-webhook's.
 *  - A shop is found by its linked platform customer (shop_billing), never by
 *    metadata alone. The only link made here is checkout.session.completed of
 *    a session this platform created for the shop (client_reference_id AND
 *    metadata.shop_id name the same shop).
 *  - Subscription state is re-read from Stripe (the current object, not the
 *    event's snapshot) and applied with the event's `created` time;
 *    billing_apply_subscription ignores anything older than what it already
 *    applied, so out-of-order deliveries never roll a shop's state back.
 *  - "Not ours" (another product on the platform account, an unknown
 *    customer, a foreign checkout) is acknowledged as `ignored`; anything that
 *    may succeed on retry throws, so the webhook answers 500 and Stripe
 *    redelivers.
 *  - Handlers are safe to re-run (the event ledger re-runs an attempt that
 *    failed part-way): linking is idempotent, applying is ordered by time,
 *    and the payment-failed notification is the last write.
 */
import type { SupabaseClient } from "@supabase/supabase-js";
import { syncPlans } from "../_shared/billing_plans.ts";
import { isUuid } from "../_shared/ids.ts";
import type { Logger } from "../_shared/log.ts";
import type { Stripe } from "../_shared/stripe.ts";
import { isStripeError } from "../_shared/stripe_errors.ts";

/**
 * The events the platform billing endpoint subscribes to (the deploy's
 * --stripe-webhooks reads this list: scripts/deploy/lib/config.mjs).
 */
export const HANDLED_EVENT_TYPES = [
  "checkout.session.completed",
  "customer.subscription.created",
  "customer.subscription.updated",
  "customer.subscription.deleted",
  "invoice.paid",
  "invoice.payment_failed",
  "product.created",
  "product.updated",
  "product.deleted",
  "price.created",
  "price.updated",
  "price.deleted",
] as const;

export type HandledEventType = typeof HANDLED_EVENT_TYPES[number];

export function isHandledEventType(type: string): type is HandledEventType {
  return (HANDLED_EVENT_TYPES as readonly string[]).includes(type);
}

/** shop_billing.status check (0100) = Stripe's subscription statuses. */
export const SUBSCRIPTION_STATUSES = [
  "trialing",
  "active",
  "past_due",
  "canceled",
  "unpaid",
  "incomplete",
  "incomplete_expired",
  "paused",
] as const;

export type SubscriptionStatus = typeof SUBSCRIPTION_STATUSES[number];

export interface BillingContext {
  admin: SupabaseClient;
  /** Platform Stripe client (no connected account). */
  stripe: Stripe;
  event: Stripe.Event;
  log: Logger;
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

/**
 * Database answers that cannot change on a retry: not found (P0002), a
 * conflicting or missing row (23505 / 23503), a rejected value (22023).
 */
const FINAL_DB_CODES = new Set(["P0002", "23505", "23503", "22023"]);

// ---------------------------------------------------------------------------
// Mapping (pure)
// ---------------------------------------------------------------------------

const SUB_RE = /^sub_[A-Za-z0-9]+$/;
const CUS_RE = /^cus_[A-Za-z0-9]+$/;
const PRICE_RE = /^price_[A-Za-z0-9]+$/;

function idMatching(re: RegExp) {
  return (value: string | { id: string } | null | undefined): string | null => {
    const id = typeof value === "string" ? value : value?.id;
    return typeof id === "string" && re.test(id) ? id : null;
  };
}

export const subscriptionId = idMatching(SUB_RE);
export const customerId = idMatching(CUS_RE);

/** Unix seconds -> ISO timestamp (null for missing/invalid). */
export function isoFromUnix(seconds: number | null | undefined): string | null {
  if (typeof seconds !== "number" || !Number.isFinite(seconds) || seconds <= 0) return null;
  return new Date(seconds * 1000).toISOString();
}

/** current_period_end lives on subscription items (API basil+): the latest one. */
export function periodEnd(sub: Pick<Stripe.Subscription, "items">): number | null {
  let latest: number | null = null;
  for (const item of sub.items?.data ?? []) {
    const end = item.current_period_end;
    if (typeof end === "number" && Number.isFinite(end) && (latest === null || end > latest)) {
      latest = end;
    }
  }
  return latest;
}

/** The (first) item's price: what platform_plans.stripe_price_id is matched on. */
export function subscriptionPriceId(sub: Pick<Stripe.Subscription, "items">): string | null {
  const price = sub.items?.data?.[0]?.price;
  const id = typeof price === "string" ? price : price?.id;
  return typeof id === "string" && PRICE_RE.test(id) ? id : null;
}

/** Whether the subscription is scheduled to end (at period end or on a set date). */
export function cancelsAtPeriodEnd(
  sub: Pick<Stripe.Subscription, "status" | "cancel_at_period_end" | "cancel_at">,
): boolean {
  if (sub.status === "canceled" || sub.status === "incomplete_expired") return false;
  return sub.cancel_at_period_end === true || typeof sub.cancel_at === "number";
}

/** The subscription an invoice bills (API basil+: `parent.subscription_details`). */
export function invoiceSubscriptionId(invoice: Stripe.Invoice): string | null {
  return subscriptionId(invoice.parent?.subscription_details?.subscription ?? null);
}

/**
 * billing_apply_subscription arguments for a subscription, or null when it
 * cannot be applied (malformed ids, a status the database does not know).
 * `deleted` (customer.subscription.deleted) always records `canceled`.
 */
export function applySubscriptionArgs(
  sub: Stripe.Subscription,
  eventCreated: number,
  { deleted = false }: { deleted?: boolean } = {},
): Record<string, unknown> | null {
  const sid = subscriptionId(sub.id);
  const cid = customerId(sub.customer as string | { id: string } | null);
  const status = deleted ? "canceled" : sub.status;
  if (!sid || !cid || !(SUBSCRIPTION_STATUSES as readonly string[]).includes(status)) return null;
  return {
    p_stripe_customer_id: cid,
    p_subscription_id: sid,
    p_price_id: subscriptionPriceId(sub),
    p_status: status,
    p_trial_end: isoFromUnix(sub.trial_end),
    p_current_period_end: isoFromUnix(periodEnd(sub)),
    p_cancel_at_period_end: deleted ? false : cancelsAtPeriodEnd(sub),
    p_event_created: isoFromUnix(eventCreated),
  };
}

// ---------------------------------------------------------------------------
// Dispatch
// ---------------------------------------------------------------------------

export async function handleBillingEvent(ctx: BillingContext): Promise<Outcome> {
  const object = ctx.event.data.object;
  switch (ctx.event.type) {
    case "checkout.session.completed":
      return await onCheckoutCompleted(ctx, object as Stripe.Checkout.Session);
    case "customer.subscription.created":
    case "customer.subscription.updated":
      return (await refreshSubscription(ctx, object as Stripe.Subscription, false)).outcome;
    case "customer.subscription.deleted":
      return (await refreshSubscription(ctx, object as Stripe.Subscription, true)).outcome;
    case "invoice.paid":
      return await onInvoicePaid(ctx, object as Stripe.Invoice);
    case "invoice.payment_failed":
      return await onInvoicePaymentFailed(ctx, object as Stripe.Invoice);
    case "product.created":
    case "product.updated":
    case "product.deleted":
    case "price.created":
    case "price.updated":
    case "price.deleted":
      return await onCatalogChanged(ctx);
    default:
      return ignore(ctx, "unhandled_type");
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function applied(
  ctx: BillingContext,
  detail: string,
  fields: Record<string, unknown> = {},
): Outcome {
  ctx.log.info("billing_event_applied", { detail, ...fields });
  return { result: "applied", detail };
}

/** Acknowledged without changes. Mismatches and conflicts are warnings. */
function ignore(
  ctx: BillingContext,
  reason: string,
  fields: Record<string, unknown> = {},
): Outcome {
  const suspicious = reason === "shop_mismatch" || reason === "customer_conflict" ||
    reason === "subscription_conflict" || reason === "subscription_rejected";
  if (suspicious) ctx.log.warn("billing_event_ignored", { reason, ...fields });
  else ctx.log.info("billing_event_ignored", { reason, ...fields });
  return { result: "ignored", reason };
}

async function rpc<T>(ctx: BillingContext, fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await ctx.admin.rpc(fn, args);
  if (error) throw new DbError(fn, error);
  return data as T;
}

function isFinal(err: unknown): err is DbError {
  return err instanceof DbError && err.code !== null && FINAL_DB_CODES.has(err.code);
}

function isMissing(err: unknown): boolean {
  return isStripeError(err) && (err.statusCode === 404 || err.code === "resource_missing");
}

/** The subscription as Stripe has it now (the event's snapshot if it is gone). */
async function currentSubscription(
  ctx: BillingContext,
  id: string,
  fallback: Stripe.Subscription | null,
): Promise<Stripe.Subscription | null> {
  try {
    return await ctx.stripe.subscriptions.retrieve(id);
  } catch (err) {
    if (isMissing(err)) return fallback;
    throw err;
  }
}

interface ApplyResult {
  outcome: Outcome;
  /** The shop the customer is linked to (null: not a Detail CRM customer). */
  shopId: string | null;
}

async function applySubscription(
  ctx: BillingContext,
  sub: Stripe.Subscription,
  deleted: boolean,
): Promise<ApplyResult> {
  const args = applySubscriptionArgs(sub, ctx.event.created, { deleted });
  if (!args) {
    return {
      outcome: ignore(ctx, "unusable_subscription", { subscription: sub.id, status: sub.status }),
      shopId: null,
    };
  }
  let row: { shop_id?: string | null; applied?: boolean } | null;
  try {
    row = await rpc(ctx, "billing_apply_subscription", {
      p_stripe_customer_id: args.p_stripe_customer_id,
      p_subscription_id: args.p_subscription_id,
      p_price_id: args.p_price_id,
      p_status: args.p_status,
      p_trial_end: args.p_trial_end,
      p_current_period_end: args.p_current_period_end,
      p_cancel_at_period_end: args.p_cancel_at_period_end,
      p_event_created: args.p_event_created,
    });
  } catch (err) {
    // Answers no retry can change (FINAL_DB_CODES): 23505 the subscription is
    // already another shop's (0101), 22023 a value the database refuses.
    // Acknowledged — a 500 would only make Stripe redeliver it for days.
    if (isFinal(err)) {
      const reason = err.code === "23505" ? "subscription_conflict" : "subscription_rejected";
      return {
        outcome: ignore(ctx, reason, { subscription: sub.id, code: err.code }),
        shopId: null,
      };
    }
    throw err;
  }
  // 0101: an unknown customer (not a Detail CRM shop's) is not an error but
  // {shop_id: null, applied: false}.
  const shopId = typeof row?.shop_id === "string" && isUuid(row.shop_id) ? row.shop_id : null;
  if (!shopId) {
    return { outcome: ignore(ctx, "unknown_customer", { subscription: sub.id }), shopId: null };
  }
  if (row?.applied !== true) {
    // An older event than the one already applied (out of order): nothing to do.
    return {
      outcome: ignore(ctx, "stale_event", { subscription: sub.id, shop_id: shopId }),
      shopId,
    };
  }
  return {
    outcome: applied(ctx, `subscription_${args.p_status}`, {
      subscription: sub.id,
      shop_id: shopId,
    }),
    shopId,
  };
}

async function refreshSubscription(
  ctx: BillingContext,
  snapshot: Stripe.Subscription,
  deleted: boolean,
): Promise<ApplyResult> {
  const id = subscriptionId(snapshot.id);
  if (!id) return { outcome: ignore(ctx, "no_subscription"), shopId: null };
  const sub = await currentSubscription(ctx, id, snapshot);
  if (!sub) return { outcome: ignore(ctx, "subscription_missing"), shopId: null };
  return await applySubscription(ctx, sub, deleted || sub.status === "canceled");
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

/**
 * checkout.session.completed (mode subscription): links the platform customer
 * to the shop the session was created for (the `billing` checkout action
 * linked it already; this is the safety net), then applies the subscription.
 */
async function onCheckoutCompleted(
  ctx: BillingContext,
  session: Stripe.Checkout.Session,
): Promise<Outcome> {
  if (session.mode !== "subscription") return ignore(ctx, "not_a_subscription_checkout");
  const shopId = session.client_reference_id;
  // Both are set server-side by `billing`: a Payment Link can carry any
  // client_reference_id in its URL, but never our metadata.
  if (!isUuid(shopId) || session.metadata?.shop_id === undefined) {
    return ignore(ctx, "not_a_billing_checkout", { session: session.id });
  }
  if (session.metadata.shop_id !== shopId) {
    return ignore(ctx, "shop_mismatch", { session: session.id, shop_id: shopId });
  }
  const customer = customerId(session.customer as string | { id: string } | null);
  if (!customer) return ignore(ctx, "no_customer", { session: session.id });
  try {
    await rpc<null>(ctx, "billing_link_customer", {
      p_shop_id: shopId,
      p_stripe_customer_id: customer,
    });
  } catch (err) {
    if (isFinal(err)) {
      return ignore(
        ctx,
        err.code === "P0002" || err.code === "23503" ? "shop_not_found" : "customer_conflict",
        {
          session: session.id,
          shop_id: shopId,
          code: err.code,
        },
      );
    }
    throw err;
  }
  const subId = subscriptionId(session.subscription as string | { id: string } | null);
  if (!subId) return applied(ctx, "customer_linked", { session: session.id, shop_id: shopId });
  const sub = await currentSubscription(ctx, subId, null);
  if (!sub) return applied(ctx, "customer_linked", { session: session.id, shop_id: shopId });
  const result = await applySubscription(ctx, sub, sub.status === "canceled");
  // The link itself was applied even when the subscription state was stale.
  return result.outcome.result === "applied"
    ? result.outcome
    : applied(ctx, "customer_linked", { session: session.id, shop_id: shopId });
}

/** invoice.paid: the subscription's period moved on; refresh it from Stripe. */
async function onInvoicePaid(ctx: BillingContext, invoice: Stripe.Invoice): Promise<Outcome> {
  const subId = invoiceSubscriptionId(invoice);
  if (!subId) return ignore(ctx, "not_a_subscription_invoice", { invoice: invoice.id });
  const sub = await currentSubscription(ctx, subId, null);
  if (!sub) return ignore(ctx, "subscription_missing", { subscription: subId });
  return (await applySubscription(ctx, sub, sub.status === "canceled")).outcome;
}

/**
 * invoice.payment_failed: refresh the subscription (usually past_due now),
 * then notify the shop owner (billing_payment_failed). Stripe's own retry
 * schedule decides when the subscription becomes unpaid or canceled.
 */
async function onInvoicePaymentFailed(
  ctx: BillingContext,
  invoice: Stripe.Invoice,
): Promise<Outcome> {
  const subId = invoiceSubscriptionId(invoice);
  if (!subId) return ignore(ctx, "not_a_subscription_invoice", { invoice: invoice.id });
  const customer = customerId(invoice.customer as string | { id: string } | null);
  if (!customer) return ignore(ctx, "no_customer", { invoice: invoice.id });
  const sub = await currentSubscription(ctx, subId, null);
  if (sub) {
    const refreshed = await applySubscription(ctx, sub, sub.status === "canceled");
    if (refreshed.shopId === null) return refreshed.outcome; // not a Detail CRM customer
  }
  try {
    await rpc<null>(ctx, "billing_payment_failed", {
      p_stripe_customer_id: customer,
      p_event_created: isoFromUnix(ctx.event.created),
    });
  } catch (err) {
    if (err instanceof DbError && err.code === "P0002") {
      return ignore(ctx, "unknown_customer", { invoice: invoice.id });
    }
    throw err;
  }
  return applied(ctx, "payment_failed_notified", { invoice: invoice.id, subscription: subId });
}

/** product.* / price.*: re-run the plan sync (the whole catalog, idempotent). */
async function onCatalogChanged(ctx: BillingContext): Promise<Outcome> {
  const result = await syncPlans({ stripe: ctx.stripe, admin: ctx.admin, log: ctx.log });
  return applied(ctx, "plans_synced", {
    upserted: result.upserted,
    deactivated: result.deactivated,
  });
}
