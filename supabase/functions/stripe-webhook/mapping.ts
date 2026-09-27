/**
 * Pure mapping helpers for the Stripe webhook: our metadata contract, the
 * amount/tip split, card details and subscription status mapping. No I/O, so
 * every rule here is unit tested on its own.
 *
 * Metadata contract (set by the `payments` function on every PaymentIntent,
 * Checkout Session, SetupIntent and Subscription it creates on a connected
 * account; values are Stripe metadata strings):
 *
 *   shop_id        uuid   REQUIRED — must be the shop that owns event.account
 *   invoice_id     uuid   optional linkage (invoice payments)
 *   job_id         uuid   optional linkage (deposits / job payments)
 *   customer_id    uuid   optional linkage (saved cards, payments)
 *   membership_id  uuid   optional linkage (memberships / subscriptions)
 *   kind           "deposit" | "payment"   (membership is implied by membership_id)
 *   tip_cents      integer string, the tip included in the charged amount
 *
 * Anything without our `shop_id` (charges the shop made in its own
 * Dashboard, subscription-invoice PaymentIntents, other platforms' objects)
 * is not a CRM object; a `shop_id` for a different shop is rejected.
 */
import type { Stripe } from "../_shared/stripe.ts";
import { isUuid } from "../_shared/ids.ts";

export type PaymentKind = "deposit" | "payment" | "membership";
export type PaymentMethodKind = "card" | "card_present";
export type MembershipStatus = "incomplete" | "active" | "past_due" | "cancelled";

type Metadata = Readonly<Record<string, string | undefined>> | null | undefined;

/** Largest tip we accept from metadata (Stripe's max charge is 99,999,999). */
const MAX_METADATA_CENTS = 99_999_999;

export interface CrmMetadata {
  /** Lower-cased shop uuid, or null when absent/malformed (not a CRM object). */
  shopId: string | null;
  invoiceId: string | null;
  jobId: string | null;
  customerId: string | null;
  membershipId: string | null;
  kind: PaymentKind;
  /** Tip requested in metadata (validated integer >= 0; bounded by `splitTip`). */
  tipCents: number;
  /** Malformed values that were dropped (logged, never fatal). */
  problems: string[];
}

function uuidField(md: Metadata, key: string, problems: string[]): string | null {
  const raw = md?.[key];
  if (raw === undefined || raw === "") return null;
  if (!isUuid(raw)) {
    problems.push(`${key} is not a uuid`);
    return null;
  }
  return raw.toLowerCase();
}

/** Parses our metadata contract; malformed optional values are dropped. */
export function readMetadata(md: Metadata): CrmMetadata {
  const problems: string[] = [];
  const shopId = uuidField(md, "shop_id", problems);
  const invoiceId = uuidField(md, "invoice_id", problems);
  const jobId = uuidField(md, "job_id", problems);
  const customerId = uuidField(md, "customer_id", problems);
  const membershipId = uuidField(md, "membership_id", problems);

  let kind: PaymentKind = "payment";
  const rawKind = md?.kind;
  if (membershipId !== null) {
    kind = "membership";
  } else if (rawKind === "deposit" || rawKind === "payment") {
    kind = rawKind;
  } else if (rawKind !== undefined && rawKind !== "") {
    problems.push("kind is not deposit/payment (or membership without membership_id)");
  }

  let tipCents = 0;
  const rawTip = md?.tip_cents;
  if (rawTip !== undefined && rawTip !== "") {
    if (/^\d{1,9}$/.test(rawTip) && Number(rawTip) <= MAX_METADATA_CENTS) {
      tipCents = Number(rawTip);
    } else {
      problems.push("tip_cents is not a whole number of cents");
    }
  }
  return { shopId, invoiceId, jobId, customerId, membershipId, kind, tipCents, problems };
}

/**
 * Merges metadata from two objects of one payment (Checkout Session first,
 * its PaymentIntent second): each key comes from the first object that has
 * it. Ownership is checked separately on each source (see `ownership`).
 */
export function mergeMetadata(primary: Metadata, secondary: Metadata): Record<string, string> {
  const out: Record<string, string> = {};
  for (const source of [secondary, primary]) {
    for (const [key, value] of Object.entries(source ?? {})) {
      if (typeof value === "string" && value !== "") out[key] = value;
    }
  }
  return out;
}

export type Ownership = "ours" | "not_crm" | "shop_mismatch";

/**
 * Whether metadata belongs to `shopId` (the shop that owns event.account).
 * Every source that carries a shop_id must name this shop, and at least one
 * must carry it. A malformed shop_id counts as a mismatch, not as absent.
 */
export function ownership(shopId: string, ...sources: Metadata[]): Ownership {
  let seen = false;
  for (const md of sources) {
    const raw = md?.shop_id;
    if (raw === undefined || raw === "") continue;
    if (!isUuid(raw) || raw.toLowerCase() !== shopId.toLowerCase()) return "shop_mismatch";
    seen = true;
  }
  return seen ? "ours" : "not_crm";
}

export function hasLinkage(md: CrmMetadata): boolean {
  return md.invoiceId !== null || md.jobId !== null || md.customerId !== null ||
    md.membershipId !== null;
}

/**
 * Splits the charged total into amount + tip. The tip comes from metadata but
 * is bounded by what was actually charged: an out-of-range tip is ignored
 * (the whole charge counts as amount) and reported.
 */
export function splitTip(
  totalCents: number,
  requestedTipCents: number,
): { amountCents: number; tipCents: number; tipIgnored: boolean } {
  if (!Number.isSafeInteger(totalCents) || totalCents <= 0) {
    throw new RangeError("charged total must be a positive whole number of cents");
  }
  const valid = Number.isSafeInteger(requestedTipCents) && requestedTipCents >= 0 &&
    requestedTipCents < totalCents;
  const tip = valid ? requestedTipCents : 0;
  return {
    amountCents: totalCents - tip,
    tipCents: tip,
    tipIgnored: !valid && requestedTipCents !== 0,
  };
}

// ---------------------------------------------------------------------------
// Stripe ids (the database check constraints use these shapes)
// ---------------------------------------------------------------------------

const PI_RE = /^pi_[A-Za-z0-9]+$/;
const CHARGE_RE = /^(ch|py)_[A-Za-z0-9]+$/;
const SESSION_RE = /^cs_[A-Za-z0-9_]+$/;
const PM_RE = /^(pm|card|src)_[A-Za-z0-9]+$/;
const SUB_RE = /^sub_[A-Za-z0-9]+$/;
const CUS_RE = /^cus_[A-Za-z0-9]+$/;

function idMatching(re: RegExp) {
  return (value: string | { id: string } | null | undefined): string | null => {
    const id = typeof value === "string" ? value : value?.id;
    return typeof id === "string" && re.test(id) ? id : null;
  };
}

export const paymentIntentId = idMatching(PI_RE);
export const chargeId = idMatching(CHARGE_RE);
export const checkoutSessionId = idMatching(SESSION_RE);
export const paymentMethodId = idMatching(PM_RE);
export const subscriptionId = idMatching(SUB_RE);
export const stripeCustomerId = idMatching(CUS_RE);

// ---------------------------------------------------------------------------
// Card details (brand / last4 / expiry only — never anything else)
// ---------------------------------------------------------------------------

export interface CardDetails {
  method: PaymentMethodKind;
  brand: string | null;
  last4: string | null;
  expMonth: number | null;
  expYear: number | null;
}

function cleanBrand(brand: unknown): string | null {
  if (typeof brand !== "string") return null;
  const trimmed = brand.trim().toLowerCase();
  return trimmed.length >= 1 && trimmed.length <= 30 ? trimmed : null;
}

function cleanLast4(last4: unknown): string | null {
  return typeof last4 === "string" && /^[0-9]{4}$/.test(last4) ? last4 : null;
}

function cleanMonth(value: unknown): number | null {
  return typeof value === "number" && Number.isInteger(value) && value >= 1 && value <= 12
    ? value
    : null;
}

function cleanYear(value: unknown): number | null {
  return typeof value === "number" && Number.isInteger(value) && value >= 2000 && value <= 2100
    ? value
    : null;
}

interface CardLike {
  brand?: unknown;
  last4?: unknown;
  exp_month?: unknown;
  exp_year?: unknown;
}

function fromCardLike(method: PaymentMethodKind, card: CardLike | null | undefined): CardDetails {
  return {
    method,
    brand: cleanBrand(card?.brand),
    last4: cleanLast4(card?.last4),
    expMonth: cleanMonth(card?.exp_month),
    expYear: cleanYear(card?.exp_year),
  };
}

/** Card details from a Charge's payment_method_details (null when not a card). */
export function chargeCard(charge: Stripe.Charge | null | undefined): CardDetails | null {
  const details = charge?.payment_method_details;
  if (!details) return null;
  switch (details.type) {
    case "card":
      return fromCardLike("card", details.card);
    case "card_present":
      return fromCardLike("card_present", details.card_present);
    case "interac_present":
      return fromCardLike("card_present", details.interac_present);
    default:
      return null;
  }
}

/** Stripe charge payment method types we store as a card row. */
const CARD_TYPES = new Set(["card", "card_present", "interac_present"]);

/**
 * The charge's payment method type when it is NOT a card (e.g.
 * us_bank_account, cashapp, klarna), else null. The payments table only
 * allows card / card_present on Stripe rows (0012 payments_card_via_stripe),
 * so such a charge is still stored as `card`; callers flag it on the row.
 */
export function nonCardMethodType(charge: Stripe.Charge | null | undefined): string | null {
  const type: unknown = charge?.payment_method_details?.type;
  if (typeof type !== "string" || CARD_TYPES.has(type)) return null;
  return /^[a-z][a-z0-9_]{0,39}$/.test(type) ? type : "other";
}

/** Card details from a PaymentMethod (null when it is not a card). */
export function paymentMethodCard(pm: Stripe.PaymentMethod | null | undefined): CardDetails | null {
  if (!pm || pm.type !== "card" || !pm.card) return null;
  return fromCardLike("card", pm.card);
}

/**
 * Our `payment_method` for a PaymentIntent before a charge exists: in-person
 * (Terminal) intents only allow card_present.
 */
export function intentMethod(
  pi: Pick<Stripe.PaymentIntent, "payment_method_types">,
): PaymentMethodKind {
  const types = pi.payment_method_types ?? [];
  const inPerson = types.some((t) => t === "card_present" || t === "interac_present");
  const online = types.some((t) => t !== "card_present" && t !== "interac_present");
  return inPerson && !online ? "card_present" : "card";
}

/** PaymentIntent statuses in which the intent can still be confirmed. */
const CONFIRMABLE = new Set([
  "requires_payment_method",
  "requires_confirmation",
  "requires_action",
]);

/**
 * A declined PaymentSheet intent is NOT finished: Stripe returns it to
 * requires_payment_method and the sheet still on screen can confirm it with
 * another card. Such a decline is recorded as `pending` (an open attempt),
 * so payment_sheet supersession, cancel_open_payments and the stale-sheet
 * sweep (which settle pending rows) still cancel it in Stripe. Other flows
 * keep `failed`: Checkout Sessions cancel their intent when they expire, and
 * charge_saved_card intents are confirmed server-side only.
 */
export function isReconfirmableSheetIntent(
  pi: Pick<Stripe.PaymentIntent, "status" | "metadata">,
): boolean {
  return pi.metadata?.source === "payment_sheet" && CONFIRMABLE.has(pi.status);
}

// ---------------------------------------------------------------------------
// Subscriptions
// ---------------------------------------------------------------------------

/**
 * Stripe subscription status -> membership_status. trialing counts as
 * active; unpaid and paused (no payment method at trial end) as past_due;
 * canceled and incomplete_expired as cancelled. Unknown future statuses map
 * to null (left unchanged, logged).
 */
export function membershipStatusOf(status: string): MembershipStatus | null {
  switch (status) {
    case "incomplete":
      return "incomplete";
    case "active":
    case "trialing":
      return "active";
    case "past_due":
    case "unpaid":
    case "paused":
      return "past_due";
    case "canceled":
    case "incomplete_expired":
      return "cancelled";
    default:
      return null;
  }
}

/**
 * current_period_end lives on subscription items since API 2025-03-31
 * (basil); the membership's period ends with the latest item period.
 */
export function subscriptionPeriodEnd(sub: Stripe.Subscription): number | null {
  let latest: number | null = null;
  for (const item of sub.items?.data ?? []) {
    const end = item.current_period_end;
    if (typeof end === "number" && Number.isFinite(end) && (latest === null || end > latest)) {
      latest = end;
    }
  }
  return latest;
}

const PRICE_RE = /^price_[A-Za-z0-9]+$/;

/** What a subscription bills: memberships.price_cents / interval / interval_count / stripe_price_id. */
export interface SubscriptionTerms {
  priceId: string;
  amountCents: number;
  interval: "month" | "year";
  intervalCount: number;
}

/**
 * The subscription's billing terms, recorded on the membership (0011) so the
 * CRM shows what Stripe actually charges even after the plan's price
 * changed. Only a single-item subscription with a whole-cent monthly / yearly
 * price within Stripe's limits (the database's) maps; anything else (several
 * items, metered or decimal prices, day/week intervals) is null and the
 * recorded terms are left alone.
 */
export function subscriptionTerms(sub: Stripe.Subscription): SubscriptionTerms | null {
  const items = sub.items?.data ?? [];
  const item = items[0];
  if (items.length !== 1 || !item) return null;
  const price = item.price;
  if (!price || typeof price.id !== "string" || !PRICE_RE.test(price.id)) return null;
  const unit = price.unit_amount;
  const quantity = item.quantity ?? 1;
  const count = price.recurring?.interval_count ?? 1;
  if (typeof unit !== "number" || !Number.isSafeInteger(unit) || unit <= 0) return null;
  if (!Number.isSafeInteger(quantity) || quantity < 1) return null;
  if (!Number.isSafeInteger(count) || count < 1) return null;
  let interval: "month" | "year";
  if (price.recurring?.interval === "month" && count <= 36) interval = "month";
  else if (price.recurring?.interval === "year" && count <= 3) interval = "year";
  else return null;
  const amount = unit * quantity;
  if (!Number.isSafeInteger(amount)) return null;
  return { priceId: price.id, amountCents: amount, interval, intervalCount: count };
}

/** Whether the subscription is scheduled to end (at period end or a set date). */
export function cancelsAtPeriodEnd(sub: Stripe.Subscription): boolean {
  if (sub.status === "canceled" || sub.status === "incomplete_expired") return false;
  return sub.cancel_at_period_end === true || typeof sub.cancel_at === "number";
}

/** The subscription an invoice belongs to (API basil+: `parent.subscription_details`). */
export function invoiceSubscription(invoice: Stripe.Invoice): {
  subscriptionId: string | null;
  metadata: Readonly<Record<string, string>> | null;
} {
  const details = invoice.parent?.subscription_details ?? null;
  return {
    subscriptionId: subscriptionId(details?.subscription ?? null),
    metadata: details?.metadata ?? null,
  };
}

/** Unix seconds -> ISO timestamp (null for missing/invalid). */
export function isoFromUnix(seconds: number | null | undefined): string | null {
  if (typeof seconds !== "number" || !Number.isFinite(seconds) || seconds <= 0) return null;
  return new Date(seconds * 1000).toISOString();
}
