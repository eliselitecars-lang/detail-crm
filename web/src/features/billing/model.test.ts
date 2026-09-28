import { describe, expect, it } from 'vitest';
import {
  billingBanner,
  checkoutReturn,
  daysLeft,
  daysLeftText,
  entitlementSchema,
  featureLabel,
  formatPlanAmount,
  hasLiveSubscription,
  isStripeUrl,
  planIntervalLabel,
  planMembersLabel,
  planSchema,
  standingText,
  subscriptionConfirmed,
  type Entitlement,
} from './model';

const TZ = 'America/Chicago';
const NOW = new Date('2026-09-28T17:00:00Z'); // noon in Chicago

function entitlement(overrides: Partial<Entitlement> = {}): Entitlement {
  return {
    billing_enabled: true,
    state: 'active',
    reason: 'subscribed',
    plan_name: 'Plan A',
    trial_ends_at: null,
    current_period_end: '2026-10-28T17:00:00Z',
    cancel_at_period_end: false,
    max_members: null,
    members_used: 1,
    can_write: true,
    is_owner: true,
    ...overrides,
  };
}

describe('server shapes', () => {
  it('parses shop_entitlement as 0101 returns it (technician view included)', () => {
    expect(
      entitlementSchema.parse({
        billing_enabled: true,
        state: 'lapsed',
        reason: 'trial_ended',
        plan_name: null,
        trial_ends_at: null,
        current_period_end: null,
        cancel_at_period_end: false,
        max_members: null,
        members_used: null,
        can_write: false,
        is_owner: false,
      }).state,
    ).toBe('lapsed');
    expect(() => entitlementSchema.parse({ state: 'free' })).toThrow();
  });

  it('parses a public plan and refuses Stripe-less nonsense', () => {
    const plan = planSchema.parse({
      id: 'p1',
      name: 'Plan A',
      description: null,
      amount_cents: 4900,
      currency: 'usd',
      interval: 'month',
      interval_count: 1,
      max_members: 3,
      features: ['online_booking'],
    });
    expect(plan.max_members).toBe(3);
    expect(() => planSchema.parse({ ...plan, interval: 'week' })).toThrow();
    expect(() => planSchema.parse({ ...plan, amount_cents: -1 })).toThrow();
  });
});

describe('prices come only from amount, currency and interval', () => {
  it('formats minor units by the currency’s own decimals', () => {
    expect(formatPlanAmount(4900, 'usd')).toBe('$49');
    expect(formatPlanAmount(4950, 'usd')).toBe('$49.50');
    expect(formatPlanAmount(0, 'usd')).toBe('$0');
    expect(formatPlanAmount(5000, 'jpy')).toBe('¥5,000');
    expect(formatPlanAmount(1999, 'eur')).toBe('€19.99');
  });

  it('labels intervals and team sizes', () => {
    expect(planIntervalLabel({ interval: 'month', interval_count: 1 })).toBe('per month');
    expect(planIntervalLabel({ interval: 'year', interval_count: 1 })).toBe('per year');
    expect(planIntervalLabel({ interval: 'month', interval_count: 3 })).toBe('every 3 months');
    expect(planMembersLabel(null)).toBe('Unlimited team members');
    expect(planMembersLabel(1)).toBe('1 team member');
    expect(planMembersLabel(5)).toBe('Up to 5 team members');
    expect(featureLabel('online_booking')).toBe('Online booking');
    expect(featureLabel('two-way-sms')).toBe('Two way sms');
  });
});

describe('days left (shop timezone)', () => {
  it('counts shop-local calendar days', () => {
    // 2026-10-01 03:00Z is Sep 30 22:00 in Chicago: 2 days from Sep 28
    expect(daysLeft('2026-10-01T03:00:00Z', TZ, NOW)).toBe(2);
    expect(daysLeft('2026-09-28T23:00:00Z', TZ, NOW)).toBe(0);
    expect(daysLeft('2026-09-20T00:00:00Z', TZ, NOW)).toBe(0);
    expect(daysLeftText(0)).toBe('today');
    expect(daysLeftText(1)).toBe('tomorrow');
    expect(daysLeftText(4)).toBe('in 4 days');
  });
});

describe('billingBanner', () => {
  it('shows nothing while billing is off, active or comped', () => {
    expect(billingBanner(null, 'owner', TZ, NOW)).toBeNull();
    expect(
      billingBanner(entitlement({ billing_enabled: false, state: 'active' }), 'owner', TZ, NOW),
    ).toBeNull();
    expect(billingBanner(entitlement(), 'owner', TZ, NOW)).toBeNull();
    expect(
      billingBanner(entitlement({ state: 'comped', reason: 'comped' }), 'owner', TZ, NOW),
    ).toBeNull();
  });

  it('warns everyone about a lapsed shop', () => {
    const lapsed = entitlement({ state: 'lapsed', reason: 'trial_ended', can_write: false });
    for (const role of ['owner', 'admin', 'manager', 'technician'] as const) {
      expect(billingBanner(lapsed, role, TZ, NOW)).toEqual({ kind: 'lapsed' });
    }
  });

  it('tells only the owner about a payment problem and a trial ending soon', () => {
    const pastDue = entitlement({ state: 'past_due', reason: 'past_due' });
    expect(billingBanner(pastDue, 'owner', TZ, NOW)).toEqual({ kind: 'past_due' });
    expect(billingBanner(pastDue, 'admin', TZ, NOW)).toBeNull();

    const soon = entitlement({
      state: 'trialing',
      reason: 'trial',
      trial_ends_at: '2026-10-01T03:00:00Z',
    });
    expect(billingBanner(soon, 'owner', TZ, NOW)).toEqual({ kind: 'trial_ending', days: 2 });
    expect(billingBanner(soon, 'manager', TZ, NOW)).toBeNull();
    const later = { ...soon, trial_ends_at: '2026-11-15T17:00:00Z' };
    expect(billingBanner(later, 'owner', TZ, NOW)).toBeNull();
    // a Stripe trial (already subscribed) needs no nudge
    expect(billingBanner({ ...soon, reason: 'subscription_trial' }, 'owner', TZ, NOW)).toBeNull();
  });
});

describe('standingText', () => {
  it('explains each standing in plain words with shop-local dates', () => {
    expect(standingText(entitlement(), TZ, NOW)).toBe(
      'The subscription is active and renews on Oct 28, 2026.',
    );
    expect(standingText(entitlement({ cancel_at_period_end: true }), TZ, NOW)).toBe(
      'The subscription is active until Oct 28, 2026 and won’t renew.',
    );
    expect(
      standingText(
        entitlement({ state: 'trialing', reason: 'trial', trial_ends_at: '2026-10-01T03:00:00Z' }),
        TZ,
        NOW,
      ),
    ).toBe('This shop’s trial ends in 2 days (Sep 30, 2026).');
    expect(standingText(entitlement({ state: 'lapsed', reason: 'trial_ended' }), TZ, NOW)).toBe(
      'This shop’s trial has ended.',
    );
    expect(standingText(entitlement({ state: 'past_due', reason: 'past_due' }), TZ, NOW)).toBe(
      'There’s a problem with this shop’s subscription payment.',
    );
    expect(standingText(entitlement({ state: 'comped', reason: 'comped' }), TZ, NOW)).toMatch(
      /complimentary access/,
    );
  });
});

describe('subscription status helpers', () => {
  it('knows live and confirmed subscriptions', () => {
    expect(hasLiveSubscription('none')).toBe(false);
    expect(hasLiveSubscription('canceled')).toBe(false);
    expect(hasLiveSubscription('unpaid')).toBe(true);
    expect(hasLiveSubscription('past_due')).toBe(true);
    expect(subscriptionConfirmed('active')).toBe(true);
    expect(subscriptionConfirmed('trialing')).toBe(true);
    expect(subscriptionConfirmed('none')).toBe(false);
    expect(subscriptionConfirmed('incomplete')).toBe(false);
  });

  it('reads the Checkout return (checkout=, also billing=)', () => {
    expect(checkoutReturn(new URLSearchParams('checkout=success'))).toBe('success');
    expect(checkoutReturn(new URLSearchParams('checkout=cancelled'))).toBe('cancelled');
    expect(checkoutReturn(new URLSearchParams('billing=cancel'))).toBe('cancelled');
    expect(checkoutReturn(new URLSearchParams('billing=success'))).toBe('success');
    expect(checkoutReturn(new URLSearchParams('checkout=maybe'))).toBeNull();
    expect(checkoutReturn(new URLSearchParams(''))).toBeNull();
  });

  it('follows only Stripe-hosted https pages', () => {
    expect(isStripeUrl('https://checkout.stripe.com/c/pay/cs_test_1')).toBe(true);
    expect(isStripeUrl('https://billing.stripe.com/p/session/x')).toBe(true);
    expect(isStripeUrl('http://checkout.stripe.com/x')).toBe(false);
    expect(isStripeUrl('https://stripe.com.evil.example/x')).toBe(false);
    expect(isStripeUrl('javascript:alert(1)')).toBe(false);
  });
});
