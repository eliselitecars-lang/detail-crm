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
 *                  | "gift_card"           (an online gift card sale, never a payments row)
 *   gift_card_order_id  uuid  the gift_card_orders row of a gift card sale
 *   tip_cents      integer string, the tip included in the charged amount
 *   channel        "terminal" on Stripe Terminal / Tap to Pay intents (informational)
 *   source         the payments action that created the object (payment_sheet,
 *                  terminal, invoice_checkout, ...); payment_sheet and terminal
 *                  intents stay confirmable after a decline
 *
 * Anything without our `shop_id` (charges the shop made in its own
 * Dashboard, subscription-invoice PaymentIntents, other platforms' objects)
 * is not a CRM object; a `shop_id` for a different shop is rejected.
 */
import type { Stripe } from "../_shared/stripe.ts";
import { isUuid } from "../_shared/ids.ts";

export type PaymentKind = "deposit" | "payment" | "membership";
/** payment_method values Stripe-backed rows may carry (0061 payments_card_via_stripe). */
export type PaymentMethodKind = "card" | "card_present" | "ach_debit" | "bnpl";
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
  /**
   * An online gift card sale (kind "gift_card" with a gift_card_order_id):
   * recorded with gift_card_order_paid, never as a payments row.
   */
  giftCardOrderId: string | null;
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
  const orderId = uuidField(md, "gift_card_order_id", problems);

  let kind: PaymentKind = "payment";
  let giftCardOrderId: string | null = null;
  const rawKind = md?.kind;
  if (membershipId !== null) {
    kind = "membership";
  } else if (rawKind === "deposit" || rawKind === "payment") {
    kind = rawKind;
  } else if (rawKind === "gift_card") {
    if (orderId !== null) giftCardOrderId = orderId;
    else problems.push("kind gift_card without a gift_card_order_id");
  } else if (rawKind !== undefined && rawKind !== "") {
    problems.push("kind is not deposit/payment/gift_card (or membership without membership_id)");
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
  return {
    shopId,
    invoiceId,
    jobId,
    customerId,
    membershipId,
    kind,
    giftCardOrderId,
    tipCents,
    problems,
  };
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

// ---------------------------------------------------------------------------
// Payment method types (P-31): Stripe's type -> our payment_method
// ---------------------------------------------------------------------------

/** Stripe types whose money is a card (wallets and Link pay with a card). */
const CARD_TYPES = new Set(["card", "link", "apple_pay", "google_pay"]);
/** In-person card types (Stripe Terminal / Tap to Pay). */
const IN_PERSON_TYPES = new Set(["card_present", "interac_present"]);
/** US bank debits (ACH): processing for days before the money settles. */
const BANK_DEBIT_TYPES = new Set(["us_bank_account"]);
/** Buy-now-pay-later providers: the shop is paid in full, the customer pays the provider. */
const BNPL_TYPES = new Set([
  "affirm",
  "afterpay_clearpay",
  "klarna",
  "zip",
  "sunbit",
  "scalapay",
  "alma",
  "billie",
]);

const STRIPE_TYPE_RE = /^[a-z][a-z0-9_]{0,39}$/;

/**
 * Our payment_method for a Stripe payment method type, or null for a type
 * the CRM has no method for (e.g. cashapp, paypal: such a charge is stored
 * as `card` and flagged on the row, see `unmappedMethodType`).
 */
export function methodForStripeType(type: string | null | undefined): PaymentMethodKind | null {
  if (typeof type !== "string") return null;
  if (CARD_TYPES.has(type)) return "card";
  if (IN_PERSON_TYPES.has(type)) return "card_present";
  if (BANK_DEBIT_TYPES.has(type)) return "ach_debit";
  if (BNPL_TYPES.has(type)) return "bnpl";
  return null;
}

/** A Stripe payment method type as stored in payments.stripe_method_type (null when malformed). */
export function cleanStripeType(type: unknown): string | null {
  return typeof type === "string" && STRIPE_TYPE_RE.test(type) ? type : null;
}

/**
 * The Stripe payment method type actually used: the charge's
 * payment_method_details.type, else the intent's (expanded) payment method,
 * else its only allowed type. Null while the customer has not chosen one
 * (a Checkout intent with several allowed types and no charge yet).
 */
export function stripeMethodTypeOf(
  charge: Stripe.Charge | null | undefined,
  pi?: Pick<Stripe.PaymentIntent, "payment_method" | "payment_method_types"> | null,
): string | null {
  const fromCharge = cleanStripeType(charge?.payment_method_details?.type);
  if (fromCharge) return fromCharge;
  const pm = pi?.payment_method;
  if (pm && typeof pm === "object") {
    const fromPm = cleanStripeType(pm.type);
    if (fromPm) return fromPm;
  }
  const types = pi?.payment_method_types ?? [];
  return types.length === 1 ? cleanStripeType(types[0]) : null;
}

/**
 * The charge's payment method type when the CRM has no payment_method for it
 * (e.g. cashapp, paypal; "other" when malformed), else null. Such a charge
 * is stored as `card` (the only generic Stripe method) with a note.
 */
export function unmappedMethodType(charge: Stripe.Charge | null | undefined): string | null {
  const type: unknown = charge?.payment_method_details?.type;
  if (typeof type !== "string") return null;
  const clean = cleanStripeType(type);
  if (!clean) return "other";
  return methodForStripeType(clean) ? null : clean;
}

/** What a charge records on the payment row: method + the card / bank account's brand and last4. */
export interface ChargeMethod {
  method: PaymentMethodKind;
  brand: string | null;
  last4: string | null;
}

/**
 * The payment row's method and display details from a charge: cards and
 * in-person cards carry brand/last4, a US bank debit its account's last4
 * (no brand), pay-later nothing. Null when the charge has no details or its
 * type has no CRM method.
 */
export function chargeMethod(charge: Stripe.Charge | null | undefined): ChargeMethod | null {
  const card = chargeCard(charge);
  if (card) return { method: card.method, brand: card.brand, last4: card.last4 };
  const details = charge?.payment_method_details;
  const method = methodForStripeType(details?.type);
  if (!details || !method) return null;
  if (method === "ach_debit") {
    return { method, brand: null, last4: cleanLast4(details.us_bank_account?.last4) };
  }
  return { method, brand: null, last4: null };
}

/** Card details from a PaymentMethod (null when it is not a card). */
export function paymentMethodCard(pm: Stripe.PaymentMethod | null | undefined): CardDetails | null {
  if (!pm || pm.type !== "card" || !pm.card) return null;
  return fromCardLike("card", pm.card);
}

/**
 * Our `payment_method` for a PaymentIntent before a charge exists: the
 * expanded payment method's type when known, else in-person (Terminal)
 * intents that only allow card_present / interac_present, or the only
 * allowed type (ACH / pay-later); anything else is a card.
 */
export function intentMethod(
  pi: Pick<Stripe.PaymentIntent, "payment_method_types"> & {
    payment_method?: Stripe.PaymentIntent["payment_method"];
  },
): PaymentMethodKind {
  const pm = pi.payment_method;
  if (pm && typeof pm === "object") {
    const chosen = methodForStripeType(pm.type);
    if (chosen) return chosen;
  }
  const types = pi.payment_method_types ?? [];
  if (types.length > 0 && types.every((t) => IN_PERSON_TYPES.has(t))) return "card_present";
  if (types.length === 1) {
    const only = methodForStripeType(types[0]);
    if (only === "ach_debit" || only === "bnpl") return only;
  }
  return "card";
}

/**
 * Whether the intent saves the payment method for later off-session use:
 * `setup_future_usage` on the intent, or on its card options (the Checkout
 * Sessions set it there so ACH / pay-later stay available, P-31).
 */
export function intentSavesCard(
  pi: Pick<Stripe.PaymentIntent, "setup_future_usage" | "payment_method_options">,
): boolean {
  return Boolean(pi.setup_future_usage) ||
    Boolean(pi.payment_method_options?.card?.setup_future_usage);
}

/** PaymentIntent statuses in which the intent can still be confirmed. */
const CONFIRMABLE = new Set([
  "requires_payment_method",
  "requires_confirmation",
  "requires_action",
]);

/** payments actions whose intents a device confirms (and can confirm again after a decline). */
export const DEVICE_INTENT_SOURCES: ReadonlySet<string> = new Set(["payment_sheet", "terminal"]);

/**
 * A declined PaymentSheet (or Terminal / Tap to Pay) intent is NOT finished:
 * Stripe returns it to requires_payment_method and the sheet or reader still
 * on screen can confirm it with another card. Such a decline is recorded as
 * `pending` (an open attempt), so supersession, cancel_open_payments and the
 * stale-sheet sweep (which settle pending rows) still cancel it in Stripe.
 * Other flows keep `failed`: Checkout Sessions cancel their intent when they
 * expire, and charge_saved_card intents are confirmed server-side only.
 */
export function isReconfirmableSheetIntent(
  pi: Pick<Stripe.PaymentIntent, "status" | "metadata">,
): boolean {
  return DEVICE_INTENT_SOURCES.has(pi.metadata?.source ?? "") && CONFIRMABLE.has(pi.status);
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
  interval: "week" | "month" | "year";
  intervalCount: number;
}

/**
 * The subscription's billing terms, recorded on the membership (0011) so the
 * CRM shows what Stripe actually charges even after the plan's price
 * changed. Only a single-item subscription with a whole-cent weekly /
 * monthly / yearly price within the database's limits (week 1..12, month
 * 1..36, year 1..3; 0069 memberships_interval_count) maps; anything else
 * (several items, metered or decimal prices, day intervals) is null and the
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
  let interval: "week" | "month" | "year";
  if (price.recurring?.interval === "week" && count <= 12) interval = "week";
  else if (price.recurring?.interval === "month" && count <= 36) interval = "month";
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
