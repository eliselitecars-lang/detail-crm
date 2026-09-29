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
import { CUSTOMER_ID, customerRow, paymentRow } from '@/features/quotes/testFixtures';
import { membership, shopValue } from '@/test/render';
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

  describe('export past PostgREST max_rows (1,000 per response)', () => {
    /** payments answers each .range() like PostgREST: at most 1,000 rows, exact count. */
    function pagedPayments(total: number) {
      const rows = Array.from({ length: total }, (_, i) => ({
        ...paymentRow({ id: `pay-${i}` }),
        customer: customerRow(),
        invoice: null,
        job: null,
      }));
      const original = supabase.from.getMockImplementation();
      const ranges: [number, number][] = [];
      supabase.from.mockImplementation((table: string) => {
        const builder = original!(table);
        if (table !== 'payments') return builder;
        builder.range.mockImplementation((from: number, to: number) => {
          ranges.push([from, to]);
          const paged = createBuilder({
            data: rows.slice(from, Math.min(to + 1, from + 1000)),
            count: total,
          });
          return paged;
        });
        return builder;
      });
      return { ranges, restore: () => supabase.from.mockImplementation(original!) };
    }

    async function exportAll() {
      const createObjectURL = vi.fn((_blob: Blob) => 'blob:x');
      Object.assign(URL, { createObjectURL, revokeObjectURL: vi.fn() });
      vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(() => undefined);
      const { user } = setup();
      await screen.findAllByText('Visa •••• 4242');
      return { user, createObjectURL };
    }

    it('reads every payment in pages instead of stopping at 1,000', async () => {
      const { user, createObjectURL } = await exportAll();
      const paged = pagedPayments(2300);
      try {
        await user.click(screen.getByRole('button', { name: 'Export CSV' }));
        expect(await screen.findByText('Exported 2300 payments')).toBeInTheDocument();
        expect(paged.ranges.slice(-3)).toEqual([
          [0, 999],
          [1000, 1999],
          [2000, 2299],
        ]);
        const blob = createObjectURL.mock.calls.at(-1)?.[0];
        const text = await new Promise<string>((resolve) => {
          const reader = new FileReader();
          reader.onload = () => resolve(reader.result as string);
          reader.readAsText(blob!);
        });
        const lines = text.trim().split(/\r?\n/);
        expect(lines).toHaveLength(2301); // header + every payment
      } finally {
        paged.restore();
      }
    });

    it('says the export was limited only when more than 5,000 match', async () => {
      const { user } = await exportAll();
      const paged = pagedPayments(6200);
      try {
        await user.click(screen.getByRole('button', { name: 'Export CSV' }));
        expect(await screen.findByText('Export limited')).toBeInTheDocument();
        expect(
          screen.getByText('Only the newest 5,000 payments were exported. Narrow the dates.'),
        ).toBeInTheDocument();
        expect(paged.ranges.at(-1)).toEqual([4000, 4999]);
      } finally {
        paged.restore();
      }
    });
  });

  it('shows an error state with retry', async () => {
    setTableResult('payments', { data: null, error: { message: 'x', code: 'XX000' } });
    supabase.rpc.mockReturnValue(createBuilder({ data: [] }));
    renderRoute(<PaymentsPage />, { path: '/app/payments', routePath: '/app/payments' });
    expect(await screen.findByRole('button', { name: 'Try again' })).toBeInTheDocument();
  });

  describe('money that pays nothing (unapplied) and membership charges', () => {
    const note = 'Received for a deleted job: apply it to an invoice or refund it';
    function setupUnapplied(
      role: 'owner' | 'manager' = 'owner',
      path = '/app/payments?from=2026-09-01&to=2026-09-30',
    ) {
      setTableResult('payments', {
        data: [
          {
            ...paymentRow({ id: 'pay-u', invoice_id: null, kind: 'deposit', tip_cents: 0, note }),
            customer: customerRow(),
            invoice: null,
            job: null,
          },
          {
            ...paymentRow({
              id: 'pay-m',
              invoice_id: null,
              membership_id: 'mem-1',
              kind: 'membership',
              tip_cents: 0,
              amount_cents: 4900,
              card_last4: '1111',
            }),
            customer: customerRow(),
            invoice: null,
            job: null,
          },
        ],
        count: 2,
      });
      setTableResult('invoices', {
        data: [
          {
            id: 'inv-9',
            number: 2009,
            status: 'open',
            total_cents: 20000,
            balance_cents: 20000,
            due_at: null,
            issued_at: '2026-09-20T15:00:00Z',
          },
          {
            id: 'inv-8',
            number: 2008,
            status: 'partially_paid',
            total_cents: 9000,
            balance_cents: 5000,
            due_at: null,
            issued_at: '2026-09-19T15:00:00Z',
          },
        ],
      });
      supabase.rpc.mockImplementation((...args: unknown[]) =>
        args[0] === 'report_payments'
          ? createBuilder({ data: [reportRow('card', 11500, 1500, 0)] })
          : createBuilder({ data: paymentRow({ id: 'pay-u', invoice_id: 'inv-9' }) }),
      );
      return renderRoute(<PaymentsPage />, {
        path,
        routePath: '/app/payments',
        shop: shopValue({ membership: membership({ role }) }),
      });
    }

    it('labels an unapplied payment, shows the server note and applies it to an open invoice', async () => {
      const { user } = setupUnapplied();
      expect((await screen.findAllByText('Unapplied')).length).toBeGreaterThan(0);
      expect(screen.getAllByText(note).length).toBeGreaterThan(0);
      // a membership charge is not "unapplied" and cannot be applied
      expect(screen.getAllByText('Membership').length).toBeGreaterThan(0);
      // (the table renders a desktop row and a stacked mobile card per payment)
      expect(screen.getAllByRole('button', { name: /^Apply / })).toHaveLength(2);

      await user.click(
        screen.getAllByRole('button', { name: /^Apply \$100\.00 from Jane Doe/ })[0]!,
      );
      const dialog = await screen.findByRole('dialog', { name: 'Apply to an invoice' });
      const select = await within(dialog).findByLabelText(/Invoice/);
      expect(builders.invoices?.[0]?.eq).toHaveBeenCalledWith('customer_id', CUSTOMER_ID);
      expect(builders.invoices?.[0]?.in).toHaveBeenCalledWith('status', ['open', 'partially_paid']);
      // $100 does not fit invoice #2008's $50 balance
      await user.selectOptions(select, 'inv-8');
      expect(within(dialog).getByText(/Invoice #2008 has \$50\.00 due/)).toBeInTheDocument();
      expect(within(dialog).getByRole('button', { name: 'Apply $100.00' })).toBeDisabled();
      await user.selectOptions(select, 'inv-9');
      await user.click(within(dialog).getByRole('button', { name: 'Apply $100.00' }));
      await waitFor(() =>
        expect(supabase.rpc).toHaveBeenCalledWith('apply_payment_to_invoice', {
          p_payment_id: 'pay-u',
          p_invoice_id: 'inv-9',
        }),
      );
      expect(await screen.findByText('$100.00 applied to invoice #2009')).toBeInTheDocument();
    });

    it('offers to cancel an open card page when applying is refused (checkout_open), then applies', async () => {
      const { user } = setupUnapplied();
      let held = true;
      supabase.rpc.mockImplementation((...args: unknown[]) => {
        if (args[0] === 'report_payments') {
          return createBuilder({ data: [reportRow('card', 11500, 1500, 0)] });
        }
        if (args[0] === 'apply_payment_to_invoice' && held) {
          return createBuilder({
            data: null,
            error: {
              code: '55000',
              message:
                'a card payment page for this invoice is still open (until 3:40 PM); cancel the open payments first, or wait until then',
              details: null,
              hint: 'checkout_open',
            },
          });
        }
        return createBuilder({ data: paymentRow({ id: 'pay-u', invoice_id: 'inv-9' }) });
      });
      supabase.functions.invoke.mockImplementation(() => {
        held = false;
        return Promise.resolve({
          data: {
            invoice_id: 'inv-9',
            job_id: null,
            cancelled: 0,
            succeeded: 0,
            in_progress: 0,
            sessions_expired: 1,
          },
          error: null,
        });
      });
      await user.click(
        (await screen.findAllByRole('button', { name: /^Apply \$100\.00 from Jane Doe/ }))[0]!,
      );
      const dialog = await screen.findByRole('dialog', { name: 'Apply to an invoice' });
      await user.selectOptions(await within(dialog).findByLabelText(/Invoice/), 'inv-9');
      await user.click(within(dialog).getByRole('button', { name: 'Apply $100.00' }));
      const notice = await within(dialog).findByRole('alert');
      expect(notice).toHaveTextContent('A card payment page for this invoice is still open');
      expect(supabase.functions.invoke).not.toHaveBeenCalled();

      await user.click(
        within(notice).getByRole('button', { name: 'Cancel open payments and try again' }),
      );
      expect(await screen.findByText('$100.00 applied to invoice #2009')).toBeInTheDocument();
      expect(supabase.functions.invoke).toHaveBeenCalledWith('payments', {
        body: { action: 'cancel_open_payments', shop_id: 'shop-1', invoice_id: 'inv-9' },
      });
      expect(
        (supabase.rpc.mock.calls as unknown[][]).filter(
          (call) => call[0] === 'apply_payment_to_invoice',
        ),
      ).toHaveLength(2);
    });

    it('lets an owner refund a membership charge from the ledger', async () => {
      const invoke = supabase.functions.invoke;
      invoke.mockResolvedValueOnce({
        data: {
          payment_id: 'pay-m',
          refund_id: 're_1',
          refund_status: 'succeeded',
          amount_cents: 4900,
          refunded_cents_total: 4900,
          payment_status: 'refunded',
        },
        error: null,
        response: undefined,
      });
      const { user } = setupUnapplied();
      await user.click(
        (
          await screen.findAllByRole('button', {
            name: /Refund Visa •••• 1111 payment of \$49\.00/,
          })
        )[0]!,
      );
      const dialog = await screen.findByRole('dialog', { name: 'Refund payment' });
      await user.click(within(dialog).getByRole('button', { name: 'Refund $49.00' }));
      await waitFor(() =>
        expect(invoke).toHaveBeenCalledWith('payments', {
          body: expect.objectContaining({
            action: 'refund',
            payment_id: 'pay-m',
            amount_cents: 4900,
          }) as unknown,
        }),
      );
    });

    it('managers can apply but not refund', async () => {
      setupUnapplied('manager');
      expect((await screen.findAllByRole('button', { name: /^Apply / })).length).toBeGreaterThan(0);
      expect(screen.queryByRole('button', { name: /^Refund/ })).toBeNull();
    });

    it('filters the ledger to unapplied money', async () => {
      const { user } = setupUnapplied();
      await screen.findAllByText('Unapplied');
      await user.click(screen.getByRole('checkbox', { name: 'Only unapplied money' }));
      await waitFor(() => {
        const last = builders.payments?.at(-1);
        expect(last?.is).toHaveBeenCalledWith('invoice_id', null);
        expect(last?.is).toHaveBeenCalledWith('job_id', null);
        expect(last?.is).toHaveBeenCalledWith('membership_id', null);
      });
    });
  });
});
