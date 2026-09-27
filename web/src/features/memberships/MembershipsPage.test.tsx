import { screen, waitFor, within } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { supabase as appSupabase } from '@/lib/supabase';
import { renderRoute } from '@/test/render';
import { builders, resetSupabaseMock, setTableResult } from '@/test/supabaseMock';
import { customerRow, planRow } from '@/features/quotes/testFixtures';
import { billingLabel } from './api';
import MembershipsPage from './MembershipsPage';

vi.mock('@/lib/supabase', async () => {
  const mod = await import('@/test/supabaseMock');
  return { ...mod, supabase: Object.assign(mod.supabase, { functions: { invoke: vi.fn() } }) };
});

const invoke = vi.mocked(appSupabase.functions.invoke);

beforeEach(() => {
  resetSupabaseMock();
  invoke.mockReset();
});

const subscriber = (status: 'incomplete' | 'active', extra: Record<string, unknown> = {}) => ({
  id: `m-${status}`,
  status,
  plan_id: 'plan-1',
  customer_id: customerRow().id,
  vehicle_id: null,
  stripe_subscription_id: status === 'active' ? 'sub_1' : null,
  current_period_end: status === 'active' ? '2026-10-27T15:00:00Z' : null,
  cancel_at_period_end: false,
  started_at: status === 'active' ? '2026-09-27T15:00:00Z' : null,
  cancelled_at: null,
  created_at: '2026-09-27T15:00:00Z',
  plan: {
    id: 'plan-1',
    name: 'Maintenance Club',
    price_cents: 4900,
    interval: 'month',
    interval_count: 1,
  },
  customer: customerRow(),
  vehicle: null,
  ...extra,
});

describe('billingLabel', () => {
  it('describes the billing period', () => {
    expect(billingLabel('$49.00', 'month', 1)).toBe('$49.00 / month');
    expect(billingLabel('$120.00', 'month', 3)).toBe('$120.00 every 3 months');
    expect(billingLabel('$499.00', 'year', 1)).toBe('$499.00 / year');
  });
});

describe('MembershipsPage', () => {
  it('lists subscribers and sends a checkout link for an incomplete one', async () => {
    setTableResult('memberships', {
      data: [subscriber('incomplete'), subscriber('active')],
      count: 2,
    });
    invoke.mockResolvedValueOnce({
      data: {
        url: 'https://checkout.stripe.com/c/pay/cs_test_1',
        expires_at: 1790000000,
        amount_cents: 4900,
        interval: 'month',
        interval_count: 1,
        currency: 'usd',
      },
      error: null,
      response: undefined,
    });
    const { user } = renderRoute(<MembershipsPage />, {
      path: '/app/memberships',
      routePath: '/app/memberships',
    });
    expect((await screen.findAllByText(/Renews Oct 27, 2026/)).length).toBeGreaterThan(0);
    expect(screen.getAllByText('$49.00 / month').length).toBeGreaterThan(0);

    const [incompleteMenu] = screen.getAllByRole('button', { name: /Actions for Jane Doe/ });
    await user.click(incompleteMenu!);
    await user.click(screen.getByRole('menuitem', { name: 'Send checkout link' }));
    const dialog = await screen.findByRole('dialog', { name: 'Membership checkout link' });
    await user.click(within(dialog).getByRole('button', { name: 'Create checkout link' }));
    expect(
      await within(dialog).findByDisplayValue('https://checkout.stripe.com/c/pay/cs_test_1'),
    ).toBeInTheDocument();
    const [fn, options] = invoke.mock.calls[0] ?? [];
    expect(fn).toBe('payments');
    expect(options?.body).toMatchObject({
      action: 'membership_checkout',
      shop_id: 'shop-1',
      membership_id: 'm-incomplete',
    });
    expect(within(dialog).getByRole('textbox', { name: 'Message' })).toHaveValue(
      'Hi Jane, here is your secure link to start your Maintenance Club membership with Glacier Detailing: https://checkout.stripe.com/c/pay/cs_test_1',
    );
  });

  it('cancels an active membership at the end of the period', async () => {
    setTableResult('memberships', { data: [subscriber('active')], count: 1 });
    invoke.mockResolvedValueOnce({
      data: {
        membership_id: 'm-active',
        status: 'active',
        cancel_at_period_end: true,
        current_period_end: '2026-10-27T15:00:00Z',
      },
      error: null,
      response: undefined,
    });
    const { user } = renderRoute(<MembershipsPage />, {
      path: '/app/memberships',
      routePath: '/app/memberships',
    });
    await user.click((await screen.findAllByRole('button', { name: /Actions for Jane Doe/ }))[0]!);
    await user.click(screen.getByRole('menuitem', { name: 'Cancel…' }));
    const dialog = await screen.findByRole('alertdialog');
    expect(within(dialog).getByRole('radio', { name: /end of the paid period/ })).toBeChecked();
    await user.click(within(dialog).getByRole('button', { name: 'Cancel membership' }));
    await waitFor(() =>
      expect(invoke).toHaveBeenCalledWith('payments', {
        body: {
          action: 'membership_cancel',
          shop_id: 'shop-1',
          membership_id: 'm-active',
          at_period_end: true,
        },
      }),
    );
  });

  it('creates a plan with included services and a member discount', async () => {
    setTableResult('membership_plans', { data: [] });
    setTableResult('services', {
      data: [
        {
          id: 'svc-1',
          name: 'Maintenance wash',
          kind: 'service',
          description: null,
          taxable: true,
          duration_minutes: 60,
          sort: 0,
        },
      ],
    });
    const { user } = renderRoute(<MembershipsPage />, {
      path: '/app/memberships?tab=plans',
      routePath: '/app/memberships',
    });
    expect(await screen.findByText('No membership plans yet')).toBeInTheDocument();
    await user.click(screen.getAllByRole('button', { name: 'New plan' })[0]!);
    const dialog = await screen.findByRole('dialog', { name: 'New membership plan' });
    await user.type(within(dialog).getByLabelText(/^Name/), 'Wash Club');
    await user.type(within(dialog).getByLabelText(/^Price/), '39');
    await user.selectOptions(within(dialog).getByLabelText(/Frequency/), '3');
    const discount = within(dialog).getByLabelText(/Member discount/);
    await user.clear(discount);
    await user.type(discount, '10');
    await user.click(await within(dialog).findByRole('checkbox', { name: 'Maintenance wash' }));
    await user.click(within(dialog).getByRole('button', { name: 'Create plan' }));
    await waitFor(() =>
      expect(builders.membership_plans?.some((b) => b.insert.mock.calls.length > 0)).toBe(true),
    );
    const insert = builders.membership_plans?.find((b) => b.insert.mock.calls.length > 0);
    expect(insert?.insert).toHaveBeenCalledWith({
      name: 'Wash Club',
      description: null,
      price_cents: 3900,
      interval: 'month',
      interval_count: 3,
      included_service_ids: ['svc-1'],
      discount_bps: 1000,
      active: true,
      shop_id: 'shop-1',
    });
  });

  it('lists plans with billing and discount', async () => {
    setTableResult('membership_plans', { data: [planRow()] });
    renderRoute(<MembershipsPage />, {
      path: '/app/memberships?tab=plans',
      routePath: '/app/memberships',
    });
    expect((await screen.findAllByText('Maintenance Club')).length).toBeGreaterThan(0);
    expect(screen.getAllByText('$49.00 / month').length).toBeGreaterThan(0);
    expect(screen.getAllByText('10% off').length).toBeGreaterThan(0);
  });
});
