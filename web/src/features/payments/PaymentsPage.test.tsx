import { screen, waitFor, within } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { renderRoute } from '@/test/render';
import {
  builders,
  createBuilder,
  resetSupabaseMock,
  setTableResult,
  supabase,
} from '@/test/supabaseMock';
import { customerRow, paymentRow } from '@/features/quotes/testFixtures';
import PaymentsPage from './PaymentsPage';

vi.mock('@/lib/supabase', () => import('@/test/supabaseMock'));

beforeEach(() => resetSupabaseMock());

const reportRow = (method: string, collected: number, tips: number, refunds: number) => ({
  method,
  payments_count: 1,
  gross_cents: collected - tips + refunds,
  refunds_cents: refunds,
  net_cents: collected - tips,
  tips_cents: tips,
  tip_refunds_cents: 0,
  collected_cents: collected,
  deposits_cents: 0,
  memberships_cents: 0,
});

function setup(path = '/app/payments?from=2026-09-01&to=2026-09-30') {
  setTableResult('payments', {
    data: [
      {
        ...paymentRow(),
        customer: customerRow(),
        invoice: { id: 'inv-1', number: 2001 },
        job: null,
      },
    ],
    count: 1,
  });
  supabase.rpc.mockReturnValue(
    createBuilder({ data: [reportRow('card', 11500, 1500, 0), reportRow('cash', 5000, 0, 1000)] }),
  );
  return renderRoute(<PaymentsPage />, { path, routePath: '/app/payments' });
}

describe('PaymentsPage', () => {
  it('shows ledger rows and server totals for the range', async () => {
    setup();
    expect((await screen.findAllByText('Visa •••• 4242')).length).toBeGreaterThan(0);
    expect(screen.getAllByRole('link', { name: 'Invoice #2001' })[0]).toHaveAttribute(
      'href',
      '/app/invoices/inv-1',
    );
    expect(await screen.findByText('$165.00')).toBeInTheDocument(); // collected: 115 + 50
    expect(screen.getByText('$10.00')).toBeInTheDocument(); // refunds
    expect(screen.getByText('$15.00')).toBeInTheDocument(); // tips
    expect(supabase.rpc).toHaveBeenCalledWith('report_payments', {
      p_shop_id: 'shop-1',
      p_from: '2026-09-01',
      p_to: '2026-09-30',
    });
    // shop-local range → UTC bounds (America/Chicago, CDT)
    const orFilter = builders.payments?.[0]?.or.mock.calls[0]?.[0] as string;
    expect(orFilter).toContain('paid_at.gte."2026-09-01T05:00:00.000Z"');
    expect(orFilter).toContain('paid_at.lt."2026-10-01T05:00:00.000Z"');
  });

  it('applies method filters to the list and the totals', async () => {
    setup('/app/payments?from=2026-09-01&to=2026-09-30&method=cash');
    expect(await screen.findByText('$50.00')).toBeInTheDocument();
    await waitFor(() => expect(builders.payments?.[0]?.eq).toHaveBeenCalledWith('method', 'cash'));
  });

  it('rejects an inverted date range', async () => {
    setup('/app/payments?from=2026-09-30&to=2026-09-01');
    expect(await screen.findByText('Fix the date range to see payments')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Export CSV' })).toBeDisabled();
    // totals are not loading (their query is off): each tile says "not available"
    const totals = screen.getByRole('region', { name: 'Totals for these dates' });
    expect(within(totals).getAllByText('Not available')).toHaveLength(4);
    expect(totals.querySelector('.animate-pulse')).toBeNull();
    expect(within(totals).getByText('Fix the date range to see totals.')).toBeInTheDocument();
    expect(supabase.rpc).not.toHaveBeenCalled();
  });

  it('exports the filtered ledger as CSV', async () => {
    const createObjectURL = vi.fn(() => 'blob:x');
    Object.assign(URL, { createObjectURL, revokeObjectURL: vi.fn() });
    const click = vi
      .spyOn(HTMLAnchorElement.prototype, 'click')
      .mockImplementation(() => undefined);
    const { user } = setup();
    await screen.findAllByText('Visa •••• 4242');
    await user.click(screen.getByRole('button', { name: 'Export CSV' }));
    await waitFor(() => expect(click).toHaveBeenCalled());
    expect(createObjectURL).toHaveBeenCalled();
    expect(await screen.findByText('Exported 1 payment')).toBeInTheDocument();
  });

  it('shows an error state with retry', async () => {
    setTableResult('payments', { data: null, error: { message: 'x', code: 'XX000' } });
    supabase.rpc.mockReturnValue(createBuilder({ data: [] }));
    renderRoute(<PaymentsPage />, { path: '/app/payments', routePath: '/app/payments' });
    expect(await screen.findByRole('button', { name: 'Try again' })).toBeInTheDocument();
  });
});
