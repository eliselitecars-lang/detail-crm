import { screen, waitFor, within } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { renderRoute } from '@/test/render';
import { builders, resetSupabaseMock, setTableResult, supabase } from '@/test/supabaseMock';
import { customerRow, planRow } from '@/features/quotes/testFixtures';
import { billingLabel } from './api';
import MembershipsPage from './MembershipsPage';

vi.mock('@/lib/supabase', () => import('@/test/supabaseMock'));

const invoke = supabase.functions.invoke;

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
    expect(billingLabel('$25.00', 'week', 2)).toBe('$25.00 every 2 weeks');
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

  it('searches subscribers by customer and keeps the search in the URL', async () => {
    setTableResult('memberships', { data: [subscriber('active')], count: 1 });
    setTableResult('customers', { data: [{ id: customerRow().id }] });
    const { user, router } = renderRoute(<MembershipsPage />, {
      path: '/app/memberships?status=active',
      routePath: '/app/memberships',
    });
    expect((await screen.findAllByText(/Renews Oct 27, 2026/)).length).toBeGreaterThan(0);
    expect(builders.customers).toBeUndefined();

    await user.type(screen.getByRole('searchbox', { name: 'Search memberships' }), 'jane doe');
    await waitFor(() => expect(router.state.location.search).toBe('?status=active&q=jane+doe'));
    await waitFor(() => expect(builders.customers?.length ?? 0).toBeGreaterThan(0));
    const lookup = builders.customers?.at(-1);
    expect(lookup?.eq).toHaveBeenCalledWith('shop_id', 'shop-1');
    expect(lookup?.ilike).toHaveBeenCalledWith('search_text', '%jane%');
    expect(lookup?.ilike).toHaveBeenCalledWith('search_text', '%doe%');
    await waitFor(() =>
      expect(builders.memberships?.at(-1)?.in).toHaveBeenCalledWith('customer_id', [
        customerRow().id,
      ]),
    );
    expect(builders.memberships?.at(-1)?.eq).toHaveBeenCalledWith('status', 'active');
  });

  it('says so when no customer matches the search, without reading memberships', async () => {
    setTableResult('memberships', { data: [subscriber('active')], count: 1 });
    setTableResult('customers', { data: [] });
    renderRoute(<MembershipsPage />, {
      path: '/app/memberships?q=nobody',
      routePath: '/app/memberships',
    });
    expect(await screen.findByText('No memberships match')).toBeVisible();
    expect(screen.getByText('Try another name, phone or email.')).toBeVisible();
    expect(screen.getByRole('searchbox', { name: 'Search memberships' })).toHaveValue('nobody');
    // The list itself is never read.
    for (const b of builders.memberships ?? []) expect(b.range).not.toHaveBeenCalled();
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
    await user.type(within(dialog).getByLabelText(/Included visits per billing period/), '2');
    await user.click(within(dialog).getByRole('switch', { name: 'Sell online' }));
    await user.type(within(dialog).getByLabelText(/^Terms/), 'Cancel any time.');
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
      online_joinable: true,
      included_uses_per_period: 2,
      terms: 'Cancel any time.',
      shop_id: 'shop-1',
    });
  });

  it('offers weekly billing every 1 to 4 weeks only', async () => {
    setTableResult('membership_plans', { data: [] });
    setTableResult('services', { data: [] });
    const { user } = renderRoute(<MembershipsPage />, {
      path: '/app/memberships?tab=plans',
      routePath: '/app/memberships',
    });
    await user.click((await screen.findAllByRole('button', { name: 'New plan' }))[0]!);
    const dialog = await screen.findByRole('dialog', { name: 'New membership plan' });
    await user.selectOptions(within(dialog).getByLabelText(/^Billed/), 'week');
    const frequency = within(dialog).getByLabelText(/Frequency/);
    expect(
      within(frequency)
        .getAllByRole('option')
        .map((o) => o.textContent),
    ).toEqual(['Every week', 'Every 2 weeks', 'Every 3 weeks', 'Every 4 weeks']);
  });

  it('shows the online join page link when a plan is sold online', async () => {
    setTableResult('membership_plans', { data: [planRow({ online_joinable: true })] });
    renderRoute(<MembershipsPage />, {
      path: '/app/memberships?tab=plans',
      routePath: '/app/memberships',
    });
    expect(await screen.findByText('Online join page')).toBeInTheDocument();
    expect(screen.getByText(/\/join\/glacier/)).toBeInTheDocument();
    expect(screen.getAllByText('Online').length).toBeGreaterThan(0);
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
