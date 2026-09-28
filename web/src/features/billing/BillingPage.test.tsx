import { act, screen, waitFor, within } from '@testing-library/react';
import { beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import { renderSettings } from '@/features/settings/testing/renderSettings';
import { redirectTo } from '@/features/settings/externalRedirect';
import {
  builders,
  edgeHttpError,
  mockRpc,
  resetSupabaseMock,
  setTableResult,
  supabase,
} from '@/test/supabaseMock';
import { membership, renderRoute, shopValue } from '@/test/render';
import { BillingErrorLink } from './BillingErrorLink';
import type { BillingPlan, Entitlement, ShopBilling } from './model';

vi.mock('@/lib/supabase', () => import('@/test/supabaseMock'));
vi.mock('@/features/settings/externalRedirect', () => ({ redirectTo: vi.fn() }));

const PLAN: BillingPlan = {
  id: '30000000-0000-4000-8000-000000000001',
  name: 'Plan A',
  description: 'For a small team',
  amount_cents: 4900,
  currency: 'usd',
  interval: 'month',
  interval_count: 1,
  max_members: 3,
  features: ['online_booking'],
};

function entitlement(overrides: Partial<Entitlement> = {}): Entitlement {
  return {
    billing_enabled: true,
    state: 'trialing',
    reason: 'trial',
    plan_name: null,
    trial_ends_at: '2099-01-15T18:00:00Z',
    current_period_end: null,
    cancel_at_period_end: false,
    max_members: null,
    members_used: 2,
    can_write: true,
    is_owner: true,
    ...overrides,
  };
}

function billingRow(overrides: Partial<ShopBilling> = {}): ShopBilling {
  return {
    plan_id: null,
    status: 'none',
    trial_ends_at: '2099-01-15T18:00:00Z',
    current_period_end: null,
    cancel_at_period_end: false,
    ...overrides,
  };
}

function backend(ent: Entitlement | null, plans: BillingPlan[] = [PLAN]) {
  return mockRpc({
    shop_entitlement: { data: ent },
    public_billing_plans: { data: plans },
  });
}

beforeAll(async () => {
  await Promise.all([import('./BillingPage'), import('@/features/settings/SettingsPage')]);
}, 60_000);

beforeEach(() => {
  resetSupabaseMock();
  vi.mocked(redirectTo).mockClear();
  setTableResult('shop_billing', { data: [billingRow()] });
});

describe('Settings > Billing', () => {
  it('says billing is not enabled, offers nothing to buy and hides the nav item', async () => {
    backend(entitlement({ billing_enabled: false, state: 'active', reason: 'billing_off' }), []);
    renderSettings('/app/settings/billing');
    expect(await screen.findByText('Billing isn’t enabled')).toBeVisible();
    expect(screen.queryByRole('button', { name: /Choose/ })).not.toBeInTheDocument();
    const nav = screen.getByRole('navigation', { name: 'Settings' });
    expect(within(nav).queryByRole('link', { name: 'Billing' })).not.toBeInTheDocument();
    expect(supabase.functions.invoke).not.toHaveBeenCalled();
  });

  it('shows the owner’s trial and plans from the server, and checks out through the billing function', async () => {
    const calls = backend(entitlement());
    supabase.functions.invoke.mockResolvedValueOnce({
      data: { url: 'https://checkout.stripe.com/c/pay/cs_test_1' },
      error: null,
    });
    const { user } = renderSettings('/app/settings/billing');
    expect(await screen.findByRole('heading', { name: 'Billing', level: 2 })).toBeVisible();
    expect(await screen.findByText('Trial')).toBeVisible();
    const nav = screen.getByRole('navigation', { name: 'Settings' });
    expect(within(nav).getByRole('link', { name: 'Billing' })).toBeInTheDocument();
    expect(screen.getByText('2 (no limit)')).toBeVisible();

    const card = await screen.findByRole('article', { name: 'Plan A' });
    expect(within(card).getByText('$49')).toBeVisible();
    expect(within(card).getByText('per month')).toBeVisible();
    expect(within(card).getByText('Up to 3 team members')).toBeVisible();
    expect(within(card).getByText('Online booking')).toBeVisible();

    await user.click(within(card).getByRole('button', { name: /Choose Plan A/ }));
    await waitFor(() =>
      expect(redirectTo).toHaveBeenCalledWith('https://checkout.stripe.com/c/pay/cs_test_1'),
    );
    expect(supabase.functions.invoke).toHaveBeenCalledWith('billing', {
      body: {
        action: 'checkout',
        shop_id: 'shop-1',
        plan_id: PLAN.id,
        request_nonce: expect.stringMatching(/^[A-Za-z0-9_-]{8,64}$/) as unknown,
      },
    });
    expect(calls.some((c) => c.fn === 'shop_entitlement')).toBe(true);
  });

  it('refuses a non-Stripe checkout URL and shows the server’s refusal verbatim', async () => {
    backend(entitlement());
    supabase.functions.invoke.mockResolvedValueOnce({
      data: null,
      error: edgeHttpError(409, {
        error: 'This shop already has a subscription. Use Manage billing to change or cancel it.',
        code: 'conflict',
        details: { reason: 'already_subscribed' },
      }),
    });
    const { user } = renderSettings('/app/settings/billing');
    const card = await screen.findByRole('article', { name: 'Plan A' });
    await user.click(within(card).getByRole('button', { name: /Choose Plan A/ }));
    expect(
      await screen.findByText(
        'This shop already has a subscription. Use Manage billing to change or cancel it.',
      ),
    ).toBeVisible();
    expect(redirectTo).not.toHaveBeenCalled();

    supabase.functions.invoke.mockResolvedValueOnce({
      data: { url: 'https://evil.example/pay' },
      error: null,
    });
    await user.click(within(card).getByRole('button', { name: /Choose Plan A/ }));
    expect(
      await screen.findByText('Stripe returned an unexpected link. Please try again.'),
    ).toBeVisible();
    expect(redirectTo).not.toHaveBeenCalled();
  });

  it('opens the billing portal for a live subscription and offers no second checkout', async () => {
    backend(
      entitlement({
        state: 'active',
        reason: 'subscribed',
        plan_name: 'Plan A',
        trial_ends_at: null,
        current_period_end: '2099-02-01T18:00:00Z',
      }),
    );
    setTableResult('shop_billing', {
      data: [billingRow({ status: 'active', plan_id: PLAN.id, trial_ends_at: null })],
    });
    supabase.functions.invoke.mockResolvedValueOnce({
      data: { url: 'https://billing.stripe.com/p/session/x' },
      error: null,
    });
    const { user } = renderSettings('/app/settings/billing');
    expect(await screen.findByText('Renews')).toBeVisible();
    expect(screen.getByText('Plan A')).toBeVisible();
    await user.click(await screen.findByRole('button', { name: 'Manage billing' }));
    await waitFor(() =>
      expect(redirectTo).toHaveBeenCalledWith('https://billing.stripe.com/p/session/x'),
    );
    expect(supabase.functions.invoke).toHaveBeenCalledWith('billing', {
      body: { action: 'portal', shop_id: 'shop-1' },
    });
    expect(screen.queryByRole('button', { name: /Choose/ })).not.toBeInTheDocument();
  });

  it('shows managers the standing read-only', async () => {
    backend(entitlement({ state: 'lapsed', reason: 'trial_ended', can_write: false }));
    renderSettings('/app/settings/billing', { role: 'manager' });
    expect(await screen.findByText('Inactive')).toBeVisible();
    expect(screen.getByText(/Creating new customers, jobs, quotes, invoices/)).toBeVisible();
    expect(
      screen.getByText('Only the shop owner can choose a plan or change the subscription.'),
    ).toBeVisible();
    expect(screen.queryByRole('button', { name: /Choose|Manage billing/ })).not.toBeInTheDocument();
  });

  it('keeps technicians out', async () => {
    backend(entitlement());
    renderSettings('/app/settings/billing', { role: 'technician' });
    expect(await screen.findByText('You don’t have access to this page')).toBeVisible();
    const nav = screen.getByRole('navigation', { name: 'Settings' });
    expect(within(nav).queryByRole('link', { name: 'Billing' })).not.toBeInTheDocument();
  });

  it('back from Checkout: waits for Stripe’s confirmation, then says so', async () => {
    backend(entitlement());
    const { router } = renderSettings('/app/settings/billing?checkout=success');
    expect(await screen.findByText('Confirming your subscription with Stripe…')).toBeVisible();
    await waitFor(() => expect(router.state.location.search).toBe(''));
    const reads = builders.shop_billing?.length ?? 0;
    // Stripe's webhook lands: the next poll sees the subscription.
    setTableResult('shop_billing', {
      data: [billingRow({ status: 'active', plan_id: PLAN.id })],
    });
    expect(
      await screen.findByText('Thanks! Stripe confirmed your subscription.', {}, { timeout: 6000 }),
    ).toBeVisible();
    expect(builders.shop_billing?.length ?? 0).toBeGreaterThan(reads);
  });

  it('back from Checkout: stops waiting after a bounded time with a clear message', async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    try {
      backend(entitlement());
      const { user } = renderSettings('/app/settings/billing?checkout=success');
      expect(await screen.findByText('Confirming your subscription with Stripe…')).toBeVisible();
      await act(async () => {
        await vi.advanceTimersByTimeAsync(61_000);
      });
      expect(await screen.findByText(/Stripe hasn’t confirmed the subscription yet/)).toBeVisible();
      await user.click(screen.getByRole('button', { name: 'Check again' }));
      expect(await screen.findByText('Confirming your subscription with Stripe…')).toBeVisible();
    } finally {
      vi.useRealTimers();
    }
  });

  it('notes a cancelled checkout', async () => {
    backend(entitlement());
    renderSettings('/app/settings/billing?checkout=cancelled');
    expect(
      await screen.findByText('Checkout was cancelled. No subscription was started.'),
    ).toBeVisible();
  });
});

describe('BillingErrorLink', () => {
  const refused = { code: 'PT402', message: "This shop's plan allows 3 team members." };

  it('links owners to Billing next to a subscription refusal only', () => {
    renderRoute(<BillingErrorLink error={refused} />);
    expect(screen.getByRole('link', { name: 'Go to Billing' })).toHaveAttribute(
      'href',
      '/app/settings/billing',
    );
  });

  it('renders nothing for other roles or other errors', () => {
    const { unmount } = renderRoute(<BillingErrorLink error={{ code: '22023', message: 'x' }} />);
    expect(screen.queryByRole('link')).not.toBeInTheDocument();
    unmount();
    renderRoute(<BillingErrorLink error={refused} />, {
      shop: shopValue({ membership: membership({ role: 'admin' }) }),
    });
    expect(screen.queryByRole('link')).not.toBeInTheDocument();
  });
});
