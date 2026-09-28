import { screen, waitFor, within } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { membership, renderRoute, shopValue } from '@/test/render';
import { createBuilder, resetSupabaseMock, supabase } from '@/test/supabaseMock';
import ReportsPage from './ReportsPage';

vi.mock('@/lib/supabase', () => import('@/test/supabaseMock'));

const RANGE = 'range=custom&from=2026-03-01&to=2026-03-31';

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
  hourly_rate_cents: 2000,
  commission_bps: 1000,
  commission_cents: 5500,
  labor_cost_cents: 15000,
  tips_cents: 1200,
  service_commission_cents: 800,
  sales_commission_cents: 300,
  total_earnings_cents: 22800,
};

function rpcResults(results: Record<string, unknown>) {
  supabase.rpc.mockImplementation(((fn: string) =>
    createBuilder({ data: results[fn] ?? null })) as never);
}

function renderAs(role: 'owner' | 'manager' | 'technician', query: string, memberId = 'm-owner') {
  return renderRoute(<ReportsPage />, {
    path: `/app/reports?${query}`,
    routePath: '/app/reports',
    shop: shopValue({ membership: membership({ role, memberId }) }),
  });
}

beforeEach(() => {
  resetSupabaseMock();
});

describe('team earnings (P-12)', () => {
  it('shows tips and commissions, and the per-job drill-down', async () => {
    rpcResults({
      report_team: [teamRow],
      report_member_earnings: [
        {
          job_id: 'job-1',
          job_number: 1042,
          completed_at: '2026-03-05T20:00:00Z',
          customer_label: 'Dana Driver',
          hours: 3.5,
          revenue_share_cents: 30000,
          commission_cents: 2750,
          service_commission_cents: 800,
          sales_commission_cents: 300,
          tips_cents: 1200,
        },
      ],
    });
    const { user } = renderAs('owner', `${RANGE}&tab=team`);
    const table = await screen.findByRole('table', { name: 'Team performance' });
    const row = within(table).getByRole('row', { name: /Theo Tech/ });
    expect(row).toHaveTextContent('$12.00');
    expect(row).toHaveTextContent('$228.00');
    await user.click(within(row).getByRole('button', { name: 'Theo Tech: earnings by job' }));
    const drawer = await screen.findByRole('dialog', { name: /Theo Tech · earnings by job/ });
    const jobs = await within(drawer).findByRole('table', { name: 'Theo Tech: earnings by job' });
    expect(within(jobs).getByRole('link', { name: '#1042' })).toHaveAttribute(
      'href',
      '/app/jobs/job-1',
    );
    expect(supabase.rpc).toHaveBeenCalledWith('report_member_earnings', {
      p_shop_id: 'shop-1',
      p_member_id: 'm-tech',
      p_from: '2026-03-01',
      p_to: '2026-03-31',
    });
  });

  it('lets a manager open only their own earnings', async () => {
    rpcResults({
      report_team: [
        {
          ...teamRow,
          hourly_rate_cents: null,
          commission_bps: null,
          commission_cents: null,
          labor_cost_cents: null,
          tips_cents: null,
          service_commission_cents: null,
          sales_commission_cents: null,
          total_earnings_cents: null,
        },
        { ...teamRow, member_id: 'm-mgr', display_name: 'Mia Manager', role: 'manager' },
      ],
    });
    renderAs('manager', `${RANGE}&tab=team`, 'm-mgr');
    const table = await screen.findByRole('table', { name: 'Team performance' });
    expect(
      within(table).queryByRole('button', { name: 'Theo Tech: earnings by job' }),
    ).not.toBeInTheDocument();
    expect(
      within(table).getByRole('button', { name: 'Mia Manager: earnings by job' }),
    ).toBeInTheDocument();
  });
});

describe('new report tabs', () => {
  it('lead sources: table with conversion and CSV', async () => {
    rpcResults({
      report_lead_sources: [
        {
          source: 'google',
          customers_count: 4,
          leads_count: 1,
          converted_count: 3,
          revenue_cents: 90000,
          first_job_revenue_cents: 60000,
        },
        {
          source: 'facebook',
          customers_count: 0,
          leads_count: 0,
          converted_count: 0,
          revenue_cents: 0,
          first_job_revenue_cents: 0,
        },
      ],
    });
    renderAs('manager', `${RANGE}&tab=lead_sources`);
    const table = await screen.findByRole('table', { name: 'Lead sources' });
    const row = within(table).getByRole('row', { name: /Google/ });
    expect(row).toHaveTextContent('75%');
    expect(row).toHaveTextContent('$900.00');
    expect(within(table).queryByText('Facebook')).not.toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Export CSV' })).toBeInTheDocument();
  });

  it('quote conversion: funnel, rate and months', async () => {
    rpcResults({
      report_quote_conversion: {
        sent: 10,
        viewed: 8,
        approved: 4,
        declined: 2,
        expired: 1,
        converted: 3,
        conversion_rate_bps: 4000,
        average_quote_cents: 50000,
        average_approved_cents: 65000,
        median_hours_to_approve: 30.5,
        by_month: [{ month: '2026-03', sent: 10, approved: 4, approved_cents: 260000 }],
      },
    });
    renderAs('owner', `${RANGE}&tab=quotes`);
    expect(await screen.findByText('40%')).toBeInTheDocument();
    expect(screen.getByText('30.5 h')).toBeInTheDocument();
    const funnel = screen.getByRole('list', { name: 'Quote funnel' });
    expect(within(funnel).getByText('Turned into jobs')).toBeInTheDocument();
    const months = screen.getByRole('table', { name: 'Quotes by month' });
    expect(within(months).getByRole('row', { name: /Mar 2026/ })).toHaveTextContent('$2,600.00');
  });

  it('job profit hides labor for managers (the server sends null)', async () => {
    rpcResults({
      report_job_profit: [
        {
          job_id: 'job-1',
          job_number: 1042,
          completed_at: '2026-03-05T20:00:00Z',
          customer_label: 'Dana Driver',
          revenue_cents: 50000,
          materials_cents: 4200,
          labor_cents: null,
          profit_cents: null,
          margin_bps: null,
        },
      ],
    });
    renderAs('manager', `${RANGE}&tab=job_profit`);
    const table = await screen.findByRole('table', { name: 'Job profit' });
    expect(within(table).getByRole('row', { name: /1042/ })).toHaveTextContent('$42.00');
    expect(within(table).queryByText('Labor')).not.toBeInTheDocument();
    expect(screen.getByText('After materials')).toBeInTheDocument();
  });

  it('service profit and gift cards', async () => {
    rpcResults({
      report_service_profit: [
        {
          service_id: 'svc-1',
          service_name: 'Ceramic coating',
          jobs_count: 2,
          revenue_cents: 180000,
          materials_cents: 30000,
          gross_profit_cents: 150000,
          margin_bps: 8333,
        },
      ],
      report_gift_cards: {
        sold_count: 3,
        sold_value_cents: 30000,
        sold_price_cents: 27000,
        redeemed_cents: 5000,
        outstanding_liability_cents: 25000,
        expired_cents: 0,
        credit_issued_cents: 2000,
      },
    });
    const { user } = renderAs('owner', `${RANGE}&tab=service_profit`);
    const table = await screen.findByRole('table', { name: 'Service profit' });
    expect(within(table).getByRole('row', { name: /Ceramic coating/ })).toHaveTextContent('83.33%');
    await user.click(screen.getByRole('tab', { name: 'Gift cards' }));
    expect(await screen.findByText('$250.00')).toBeInTheDocument();
    expect(screen.getByText(/3 cards · \$270\.00 paid/)).toBeInTheDocument();
    await waitFor(() =>
      expect(supabase.rpc).toHaveBeenCalledWith('report_gift_cards', {
        p_shop_id: 'shop-1',
        p_from: '2026-03-01',
        p_to: '2026-03-31',
      }),
    );
  });
});
