import { screen, waitFor, within } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { membership, renderRoute, shopValue } from '@/test/render';
import { createBuilder, resetSupabaseMock, supabase } from '@/test/supabaseMock';
import ReportsPage from './ReportsPage';

vi.mock('@/lib/supabase', () => import('@/test/supabaseMock'));

const RANGE = 'range=custom&from=2026-03-01&to=2026-03-03';

const revenue = [
  {
    bucket_start: '2026-03-01',
    gross_cents: 50000,
    refunds_cents: 5000,
    net_cents: 45000,
    tips_cents: 2000,
    payments_count: 3,
  },
  {
    bucket_start: '2026-03-02',
    gross_cents: 0,
    refunds_cents: 0,
    net_cents: 0,
    tips_cents: 0,
    payments_count: 0,
  },
  {
    bucket_start: '2026-03-03',
    gross_cents: 12500,
    refunds_cents: 0,
    net_cents: 12500,
    tips_cents: 0,
    payments_count: 1,
  },
];

const teamRow = {
  member_id: 'm-tech',
  display_name: 'Theo Tech',
  role: 'technician',
  active: true,
  worked_seconds: 27000,
  hours: 7.5,
  jobs_completed: 2,
  revenue_cents: 60000,
  pre_tax_revenue_cents: 55000,
  hourly_rate_cents: null,
  commission_bps: null,
  commission_cents: null,
  labor_cost_cents: null,
};

const outstanding = {
  as_of: '2026-03-03T18:00:00Z',
  timezone: 'America/Chicago',
  count: 1,
  balance_cents: 20000,
  overdue_count: 1,
  overdue_balance_cents: 20000,
  buckets: [
    { bucket: '0-30', count: 0, balance_cents: 0 },
    { bucket: '31-60', count: 1, balance_cents: 20000 },
    { bucket: '61-90', count: 0, balance_cents: 0 },
    { bucket: '90+', count: 0, balance_cents: 0 },
  ],
  invoices: [
    {
      invoice_id: 'inv-1',
      number: 1042,
      status: 'partially_paid',
      customer_id: 'cust-1',
      customer_name: 'Dana Driver',
      job_id: null,
      issued_at: '2026-01-10T15:00:00Z',
      due_at: '2026-01-24T15:00:00Z',
      total_cents: 30000,
      amount_paid_cents: 10000,
      balance_cents: 20000,
      days_past_due: 38,
      overdue: true,
      bucket: '31-60',
    },
  ],
};

function rpcResults(results: Record<string, unknown>) {
  supabase.rpc.mockImplementation(((fn: string) =>
    createBuilder({ data: results[fn] ?? null })) as never);
}

function renderAs(role: 'owner' | 'manager' | 'technician', query = RANGE) {
  return renderRoute(<ReportsPage />, {
    path: `/app/reports?${query}`,
    routePath: '/app/reports',
    shop: shopValue({ membership: membership({ role }) }),
  });
}

beforeEach(() => {
  resetSupabaseMock();
  rpcResults({
    report_revenue: revenue,
    report_team: [teamRow],
    report_outstanding: outstanding,
  });
});

describe('ReportsPage', () => {
  it('shows revenue totals and a per-period table', async () => {
    renderAs('manager');
    const tiles = await screen.findByLabelText('Revenue totals');
    expect(within(tiles).getByText('$575.00')).toBeInTheDocument(); // net
    expect(within(tiles).getByText('$625.00')).toBeInTheDocument(); // gross
    expect(within(tiles).getByText('$50.00')).toBeInTheDocument(); // refunds
    expect(within(tiles).getByText('$20.00')).toBeInTheDocument(); // tips
    const table = screen.getByRole('table', { name: 'Revenue by period' });
    expect(within(table).getByRole('row', { name: /Sun, Mar 1, 2026/ })).toHaveTextContent(
      '$450.00',
    );
    expect(screen.getByRole('button', { name: 'Export CSV' })).toBeInTheDocument();
    expect(supabase.rpc).toHaveBeenCalledWith('report_revenue', {
      p_shop_id: 'shop-1',
      p_from: '2026-03-01',
      p_to: '2026-03-03',
      p_bucket: 'day',
    });
  });

  it('shows an empty state when nothing was paid', async () => {
    rpcResults({ report_revenue: [{ ...revenue[1] }] });
    renderAs('owner');
    expect(await screen.findByText('No payments in this period')).toBeInTheDocument();
  });

  it('shows the server error with retry', async () => {
    supabase.rpc.mockImplementation(() =>
      createBuilder({
        error: {
          code: '42501',
          message: 'this report is available to owners, admins and managers',
        },
      }),
    );
    renderAs('manager');
    expect(
      await screen.findByText('This report is available to owners, admins and managers.'),
    ).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Try again' })).toBeInTheDocument();
  });

  it('hides pay columns when the server returns none', async () => {
    const { user } = renderAs('manager');
    await user.click(await screen.findByRole('tab', { name: 'Team' }));
    const table = await screen.findByRole('table', { name: 'Team performance' });
    expect(within(table).getByRole('row', { name: /Theo Tech/ })).toHaveTextContent('7.5 h');
    expect(within(table).queryByText('Commission')).not.toBeInTheDocument();
  });

  it('shows pay columns when the server returns them', async () => {
    rpcResults({
      report_team: [
        {
          ...teamRow,
          hourly_rate_cents: 2000,
          commission_bps: 1000,
          commission_cents: 5500,
          labor_cost_cents: 15000,
        },
      ],
    });
    renderAs('owner', `${RANGE}&tab=team`);
    const table = await screen.findByRole('table', { name: 'Team performance' });
    const row = within(table).getByRole('row', { name: /Theo Tech/ });
    expect(row).toHaveTextContent('10%');
    expect(row).toHaveTextContent('$55.00');
    expect(row).toHaveTextContent('$150.00');
  });

  it('gives technicians only their own team numbers', async () => {
    renderAs('technician');
    expect(await screen.findByRole('heading', { name: 'My numbers' })).toBeInTheDocument();
    expect(screen.queryByRole('tablist')).not.toBeInTheDocument();
    await waitFor(() => expect(supabase.rpc).toHaveBeenCalledTimes(1));
    expect(supabase.rpc).toHaveBeenCalledWith('report_team', {
      p_shop_id: 'shop-1',
      p_from: '2026-03-01',
      p_to: '2026-03-03',
    });
  });

  it('lists outstanding invoices with links', async () => {
    renderAs('manager', 'tab=outstanding');
    const table = await screen.findByRole('table', { name: 'Open invoices' });
    const link = within(table).getByRole('link', { name: '#1042' });
    expect(link).toHaveAttribute('href', '/app/invoices/inv-1');
    expect(within(table).getByText('38 days')).toBeInTheDocument();
    expect(screen.getByText(/no date range needed/)).toBeInTheDocument();
  });

  it('does not query with an invalid custom range', async () => {
    renderAs('manager', 'range=custom&from=2026-03-10&to=2026-03-01');
    expect(await screen.findByText('Choose a valid date range')).toBeInTheDocument();
    expect(supabase.rpc).not.toHaveBeenCalled();
  });

  it('switches presets through the URL', async () => {
    const { user, router } = renderAs('manager');
    await screen.findByLabelText('Revenue totals');
    await user.selectOptions(screen.getByRole('combobox', { name: 'Date range' }), 'ytd');
    expect(router.state.location.search).toContain('range=ytd');
    await user.selectOptions(screen.getByRole('combobox', { name: 'Group by' }), 'month');
    expect(router.state.location.search).toContain('bucket=month');
  });
});
