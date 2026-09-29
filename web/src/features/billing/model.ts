/**
 * Shop subscription billing (SPEC §4.10, docs/BILLING.md) — pure model: the
 * shapes the server returns and the rules the web shows them by. Nothing
 * about a plan (name, price, interval, team limit, features) or the trial
 * length is written here: all of it comes from `public_billing_plans()`,
 * `public_billing_offer()` and `shop_entitlement()`; the only numbers below are UI thresholds (when a
 * trial counts as "ending soon", how long to wait for Stripe's webhook).
 */
import { z } from 'zod';
import { formatDate, localDaysBetween, shopToday, utcToShopLocal } from '@/lib/dates';
import type { ShopRole } from '@/features/shop/permissions';

/** Settings > Billing (the billing function's Checkout / portal return here). */
export const BILLING_PATH = '/app/settings/billing';
/** The platform's public pricing page. */
export const PRICING_PATH = '/pricing';
/** The owner's link / toast action next to a subscription refusal. */
export const GO_TO_BILLING = 'Go to Billing';

// ---------------------------------------------------------------------------
// Server shapes
// ---------------------------------------------------------------------------

export const ENTITLEMENT_STATES = ['active', 'trialing', 'past_due', 'lapsed', 'comped'] as const;
export type EntitlementState = (typeof ENTITLEMENT_STATES)[number];

/**
 * shop_entitlement(p_shop_id) (0101). Billing details (plan, dates, seats)
 * are null / false for technicians; they get only the standing.
 */
export const entitlementSchema = z.object({
  billing_enabled: z.boolean(),
  state: z.enum(ENTITLEMENT_STATES),
  /** billing_off, comped, subscribed, subscription_trial, past_due, trial, trial_ended, … */
  reason: z.string(),
  plan_name: z.string().nullable(),
  trial_ends_at: z.string().nullable(),
  current_period_end: z.string().nullable(),
  cancel_at_period_end: z.boolean(),
  max_members: z.number().int().nullable(),
  members_used: z.number().int().nullable(),
  can_write: z.boolean(),
  is_owner: z.boolean(),
});
export type Entitlement = z.output<typeof entitlementSchema>;

/** public_billing_plans() / the billing function's `plans` (never Stripe ids). */
export const planSchema = z.object({
  id: z.string(),
  name: z.string(),
  description: z.string().nullable(),
  amount_cents: z.number().int().nonnegative(),
  currency: z.string().regex(/^[a-z]{3}$/i),
  interval: z.enum(['month', 'year']),
  interval_count: z.number().int().positive(),
  max_members: z.number().int().positive().nullable(),
  features: z.array(z.string()),
});
export type BillingPlan = z.output<typeof planSchema>;

/**
 * public_billing_offer() (0131; anon too): the plans (exactly
 * public_billing_plans()), the in-app trial of a person's FIRST shop in days
 * (0 while billing is off or no trial is set; the trial is once per person,
 * 0120) and, signed in, whether a shop the caller creates now gets it (null
 * signed out).
 */
export const billingOfferSchema = z.object({
  plans: z.array(planSchema),
  trial_days: z
    .number()
    .int()
    .nonnegative()
    .nullish()
    .transform((v) => v ?? 0),
  trial_available: z
    .boolean()
    .nullish()
    .transform((v) => v ?? null),
});
export type BillingOffer = z.output<typeof billingOfferSchema>;

/**
 * The offer's trial, as "14-day free trial for your first shop" (null: no
 * trial). The trial is once per person (0120), hence "your first shop".
 */
export function firstShopTrialLabel(offer: BillingOffer | null | undefined): string | null {
  if (!offer || offer.plans.length === 0 || offer.trial_days <= 0) return null;
  return `${offer.trial_days}-day free trial for your first shop`;
}

/** shop_billing's Stripe subscription status (0100; `none` = never subscribed). */
export const SUBSCRIPTION_STATUSES = [
  'none',
  'trialing',
  'active',
  'past_due',
  'canceled',
  'unpaid',
  'incomplete',
  'incomplete_expired',
  'paused',
] as const;
export type SubscriptionStatus = (typeof SUBSCRIPTION_STATUSES)[number];

/**
 * The shop's own billing row (owner / admin / manager; 0100's column grant
 * without the Stripe ids).
 */
export const shopBillingSchema = z.object({
  plan_id: z.string().nullable(),
  status: z.enum(SUBSCRIPTION_STATUSES),
  trial_ends_at: z.string().nullable(),
  current_period_end: z.string().nullable(),
  cancel_at_period_end: z.boolean(),
});
export type ShopBilling = z.output<typeof shopBillingSchema>;

/**
 * A Stripe subscription that is still alive (billing_checkout_context's
 * has_live_subscription): Checkout would refuse a second one, so plan
 * changes, card updates and cancelling go through the billing portal.
 */
export function hasLiveSubscription(status: SubscriptionStatus): boolean {
  return (
    status === 'trialing' ||
    status === 'active' ||
    status === 'past_due' ||
    status === 'unpaid' ||
    status === 'paused'
  );
}

/** billing_state's reasons (0101) read from a live Stripe subscription (hasLiveSubscription). */
const LIVE_SUBSCRIPTION_REASONS: readonly string[] = [
  'subscribed',
  'subscription_trial',
  'past_due',
  'unpaid',
  'paused',
];
/** …and from one that has stopped or never completed (the portal still shows its invoices). */
const ENDED_SUBSCRIPTION_REASONS: readonly string[] = [
  'period_remaining',
  'incomplete',
  'incomplete_expired',
  'canceled',
];

/**
 * The entitlement's reason says this shop has (or, without `liveOnly`, had)
 * a Stripe subscription (billing_state in 0101). Used only when the shop's
 * own billing row can't be read, so the owner keeps the way to the billing
 * portal (e.g. to fix a past-due card) instead of being offered a new
 * checkout. A comped shop's reason hides any subscription: false.
 */
export function entitlementShowsSubscription(
  entitlement: Entitlement,
  { liveOnly = false }: { liveOnly?: boolean } = {},
): boolean {
  if (entitlement.state === 'past_due' || LIVE_SUBSCRIPTION_REASONS.includes(entitlement.reason)) {
    return true;
  }
  return !liveOnly && ENDED_SUBSCRIPTION_REASONS.includes(entitlement.reason);
}

/** Stripe's webhook has confirmed a subscription (what ?checkout=success waits for). */
export function subscriptionConfirmed(status: SubscriptionStatus): boolean {
  return status === 'trialing' || status === 'active' || status === 'past_due';
}

// ---------------------------------------------------------------------------
// Prices (from the server's amount, currency and interval only)
// ---------------------------------------------------------------------------

/**
 * Stripe amounts are in the currency's minor unit (cents for USD, yen for
 * JPY): the currency's own number of decimals decides the divisor.
 */
export function formatPlanAmount(amount: number, currency: string): string {
  let format: Intl.NumberFormat;
  try {
    format = new Intl.NumberFormat('en-US', {
      style: 'currency',
      currency: currency.toUpperCase(),
    });
  } catch {
    return `${amount} ${currency.toUpperCase()}`;
  }
  const digits = format.resolvedOptions().maximumFractionDigits ?? 2;
  const value = amount / 10 ** digits;
  const whole = Number.isInteger(value);
  return new Intl.NumberFormat('en-US', {
    style: 'currency',
    currency: currency.toUpperCase(),
    minimumFractionDigits: whole ? 0 : digits,
    maximumFractionDigits: digits,
  }).format(value);
}

/** "per month", "per year", "every 3 months", "every 2 years". */
export function planIntervalLabel(plan: Pick<BillingPlan, 'interval' | 'interval_count'>): string {
  if (plan.interval_count === 1) return `per ${plan.interval}`;
  return `every ${plan.interval_count} ${plan.interval}s`;
}

/** "$49 per month" (screen-reader and summary form). */
export function planPriceText(plan: BillingPlan): string {
  return `${formatPlanAmount(plan.amount_cents, plan.currency)} ${planIntervalLabel(plan)}`;
}

/** The plan's team size: its max_members (null = no limit). */
export function planMembersLabel(maxMembers: number | null): string {
  if (maxMembers === null) return 'Unlimited team members';
  return maxMembers === 1 ? '1 team member' : `Up to ${maxMembers} team members`;
}

/** A feature key from the plan's Stripe metadata ("online_booking") as text ("Online booking"). */
export function featureLabel(key: string): string {
  const words = key.replace(/[_-]+/g, ' ').trim();
  return words ? words.charAt(0).toUpperCase() + words.slice(1) : key;
}

// ---------------------------------------------------------------------------
// Standing → what the web shows
// ---------------------------------------------------------------------------

/** Whole shop-local days until `end` (0 = ends today; never negative). */
export function daysLeft(end: string, timezone: string, now: Date = new Date()): number {
  const endDate = utcToShopLocal(end, timezone).date;
  return Math.max(0, localDaysBetween(shopToday(timezone, now), endDate));
}

/** "today", "tomorrow", "in 5 days". */
export function daysLeftText(days: number): string {
  if (days <= 0) return 'today';
  if (days === 1) return 'tomorrow';
  return `in ${days} days`;
}

/** A trial within this many days of its end is "ending soon" (owner banner). */
export const TRIAL_ENDING_SOON_DAYS = 7;

export type BillingBannerKind = 'trial_ending' | 'past_due' | 'lapsed';

export interface BillingBanner {
  kind: BillingBannerKind;
  /** Days left in the trial (trial_ending only). */
  days?: number;
}

/**
 * The app-shell banner for this member, or null. Nothing while billing is
 * off, active or comped. Owners: their in-app trial ending soon (no
 * subscription yet), a payment problem. Everyone: lapsed.
 */
export function billingBanner(
  entitlement: Entitlement | null | undefined,
  role: ShopRole,
  timezone: string,
  now: Date = new Date(),
): BillingBanner | null {
  if (!entitlement?.billing_enabled) return null;
  if (entitlement.state === 'lapsed') return { kind: 'lapsed' };
  if (role !== 'owner') return null;
  if (entitlement.state === 'past_due') return { kind: 'past_due' };
  if (
    entitlement.state === 'trialing' &&
    entitlement.reason === 'trial' &&
    entitlement.trial_ends_at
  ) {
    const days = daysLeft(entitlement.trial_ends_at, timezone, now);
    if (days <= TRIAL_ENDING_SOON_DAYS) return { kind: 'trial_ending', days };
  }
  return null;
}

/**
 * For a shop that was just created (onboarding): the trial it starts with,
 * as "Your free trial runs until Oct 12, 2026 (14 days)." — null while
 * billing is off or when the shop is not in a platform trial (comped, or no
 * trial configured).
 */
export function newShopTrialText(
  entitlement: Entitlement | null | undefined,
  timezone: string,
  now: Date = new Date(),
): string | null {
  if (!entitlement?.billing_enabled) return null;
  if (entitlement.state !== 'trialing' || entitlement.reason !== 'trial') return null;
  if (!entitlement.trial_ends_at) return null;
  const days = daysLeft(entitlement.trial_ends_at, timezone, now);
  const end = formatDate(entitlement.trial_ends_at, timezone);
  return `Your free trial runs until ${end} (${days === 1 ? '1 day' : `${days} days`}).`;
}

export const STATE_LABELS: Record<EntitlementState, string> = {
  active: 'Active',
  trialing: 'Trial',
  past_due: 'Payment problem',
  lapsed: 'Inactive',
  comped: 'Complimentary',
};

export const STATE_TONES: Record<EntitlementState, 'success' | 'info' | 'warning' | 'danger'> = {
  active: 'success',
  trialing: 'info',
  past_due: 'warning',
  lapsed: 'danger',
  comped: 'success',
};

/**
 * One sentence on where the shop stands (the billing page), from the
 * entitlement's reason. Dates in the shop timezone.
 */
export function standingText(
  entitlement: Entitlement,
  timezone: string,
  now: Date = new Date(),
): string {
  const date = (value: string | null) => (value ? formatDate(value, timezone) : null);
  const trialEnd = date(entitlement.trial_ends_at);
  const periodEnd = date(entitlement.current_period_end);
  switch (entitlement.reason) {
    case 'billing_off':
      return 'Billing isn’t enabled, so every part of the app is available to this shop.';
    case 'comped':
      return 'This shop has complimentary access from the platform operator.';
    case 'subscribed':
      if (!periodEnd) return 'The subscription is active.';
      return entitlement.cancel_at_period_end
        ? `The subscription is active until ${periodEnd} and won’t renew.`
        : `The subscription is active and renews on ${periodEnd}.`;
    case 'subscription_trial':
      return trialEnd
        ? `The subscription is in its trial until ${trialEnd}; the first payment is due then.`
        : 'The subscription is in its trial.';
    case 'past_due':
      return PAST_DUE_MESSAGE;
    case 'trial': {
      if (!entitlement.trial_ends_at || !trialEnd) return 'This shop is in its trial.';
      const days = daysLeft(entitlement.trial_ends_at, timezone, now);
      return `This shop’s trial ends ${daysLeftText(days)} (${trialEnd}).`;
    }
    case 'trial_ended':
      return 'This shop’s trial has ended.';
    case 'no_subscription':
      return 'This shop has no subscription.';
    case 'incomplete':
    case 'incomplete_expired':
      return 'The first subscription payment wasn’t completed.';
    case 'period_remaining':
      return periodEnd
        ? `The subscription has stopped; this shop keeps full access until ${periodEnd}.`
        : 'The subscription has stopped.';
    case 'canceled':
      return 'The subscription has ended.';
    case 'unpaid':
      return 'The subscription is unpaid.';
    case 'paused':
      return 'The subscription is paused.';
    default:
      return entitlement.state === 'lapsed'
        ? 'The subscription is inactive.'
        : 'The subscription is active.';
  }
}

/**
 * What stops while a shop is lapsed (0102 / 0103, docs/BILLING.md §8), and
 * what keeps working. Keep in step with the server: public lead forms answer
 * "form not found", online gift card and membership sales are off, staff
 * can't sell memberships or issue gift cards, and enqueue_due_automations
 * skips the shop (no reminders, review requests or follow-ups).
 */
export const LAPSED_PAUSED =
  'Creating new customers, jobs, quotes, invoices and campaigns, selling memberships and issuing gift cards, and sending new messages to customers are paused. Online booking, lead forms, and online gift card and membership sales are off: customers who open them are told they aren’t available.';
export const LAPSED_AUTOMATIONS =
  'Automatic messages have stopped too, including for existing jobs: appointment reminders, review requests and follow-ups aren’t sent.';
export const LAPSED_STILL_WORKS =
  'Everything already in the shop stays available: you can view and export it, finish existing jobs (let those customers know yourself) and collect payments on existing invoices.';

/** The short list the app-shell banner shows under LAPSED_MESSAGE. */
export const LAPSED_BANNER_DETAIL =
  'Online booking, lead forms, online gift card and membership sales, and automatic reminders and follow-ups are paused. You can still view everything.';

/** A page notice for a feature the lapse turned off for customers (lead forms, online sales). */
export function lapsedFeatureNotice(subject: string, { plural = true } = {}): string {
  return `${subject} ${plural ? 'are' : 'is'} off while this shop’s subscription is inactive: customers who open ${plural ? 'them' : 'it'} are told ${plural ? 'they aren’t' : 'it isn’t'} available. ${plural ? 'They come' : 'It comes'} back when the subscription is renewed.`;
}

/** The neutral payment-problem sentence (the server's notification wording). */
export const PAST_DUE_MESSAGE = 'There’s a problem with this shop’s subscription payment.';

/** The neutral lapsed sentence (the server's PT402 wording). */
export const LAPSED_MESSAGE =
  'This shop’s subscription is inactive, so new records can’t be created right now.';

// ---------------------------------------------------------------------------
// Returning from Stripe Checkout
// ---------------------------------------------------------------------------

export type CheckoutReturn = 'success' | 'cancelled';

/**
 * The billing function sends Checkout back to
 * /app/settings/billing?checkout=success|cancelled (also accepted:
 * ?billing=success|cancel).
 */
export function checkoutReturn(params: URLSearchParams): CheckoutReturn | null {
  const value = params.get('checkout') ?? params.get('billing');
  if (value === 'success') return 'success';
  if (value === 'cancelled' || value === 'canceled' || value === 'cancel') return 'cancelled';
  return null;
}

/** How often, and for how long, the page re-reads the subscription after Checkout. */
export const CONFIRM_POLL_MS = 2_000;
export const CONFIRM_TIMEOUT_MS = 60_000;

/** Stripe-hosted pages only (checkout.stripe.com, billing.stripe.com). */
export function isStripeUrl(url: string): boolean {
  try {
    const parsed = new URL(url);
    return parsed.protocol === 'https:' && /(^|\.)stripe\.com$/.test(parsed.hostname);
  } catch {
    return false;
  }
}
