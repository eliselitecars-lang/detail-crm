import { screen } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { renderRoute } from '@/test/render';
import { mockRpc, resetSupabaseMock } from '@/test/supabaseMock';
import PricingPage from './PricingPage';
import { billingOfferSchema, firstShopTrialLabel, type BillingPlan } from './model';

vi.mock('@/lib/supabase', () => import('@/test/supabaseMock'));

/** Test data, not real pricing. */
const PLAN: BillingPlan = {
  id: '30000000-0000-4000-8000-000000000001',
  name: 'Plan A',
  description: null,
  amount_cents: 4900,
  currency: 'usd',
  interval: 'month',
  interval_count: 1,
  max_members: 3,
  features: [],
};

function render() {
  return renderRoute(<PricingPage />, { path: '/pricing', routePath: '/pricing', shop: null });
}

beforeEach(() => resetSupabaseMock());

describe('PricingPage', () => {
  it('states the first shop’s trial length from public_billing_offer', async () => {
    const calls = mockRpc({
      public_billing_offer: { data: { plans: [PLAN], trial_days: 21, trial_available: null } },
    });
    render();
    expect(await screen.findByRole('article', { name: 'Plan A' })).toBeInTheDocument();
    expect(screen.getByText('21-day free trial for your first shop.')).toBeInTheDocument();
    expect(screen.getByText(/starts when you create the shop/)).toBeInTheDocument();
    expect(calls.map((c) => c.fn)).toEqual(['public_billing_offer']);
  });

  it('states no trial when none is configured', async () => {
    mockRpc({
      public_billing_offer: { data: { plans: [PLAN], trial_days: 0, trial_available: null } },
    });
    render();
    expect(await screen.findByRole('article', { name: 'Plan A' })).toBeInTheDocument();
    expect(screen.queryByText(/free trial/)).not.toBeInTheDocument();
  });

  it('shows neither plans nor a trial while billing is off', async () => {
    mockRpc({
      public_billing_offer: { data: { plans: [], trial_days: 0, trial_available: null } },
    });
    render();
    expect(await screen.findByText('Pricing coming soon')).toBeInTheDocument();
    expect(screen.queryByText(/free trial/)).not.toBeInTheDocument();
    expect(screen.queryByRole('article')).not.toBeInTheDocument();
  });

  it('offers a retry when the offer cannot be read', async () => {
    mockRpc({
      public_billing_offer: { data: { plans: 'nope', trial_days: 14 } },
    });
    render();
    expect(await screen.findByText('Couldn’t load the plans')).toBeInTheDocument();
  });
});

describe('firstShopTrialLabel', () => {
  const offer = (value: unknown) => billingOfferSchema.parse(value);

  it('words the trial as the first shop’s, and only with plans and days', () => {
    expect(firstShopTrialLabel(offer({ plans: [PLAN], trial_days: 14 }))).toBe(
      '14-day free trial for your first shop',
    );
    expect(firstShopTrialLabel(offer({ plans: [PLAN], trial_days: 0 }))).toBeNull();
    expect(firstShopTrialLabel(offer({ plans: [], trial_days: 14 }))).toBeNull();
    expect(firstShopTrialLabel(null)).toBeNull();
  });

  it('reads a missing trial as none and an unknown availability as null', () => {
    expect(offer({ plans: [PLAN] })).toEqual({
      plans: [PLAN],
      trial_days: 0,
      trial_available: null,
    });
    expect(() => offer({ plans: [PLAN], trial_days: -1 })).toThrow();
  });
});
