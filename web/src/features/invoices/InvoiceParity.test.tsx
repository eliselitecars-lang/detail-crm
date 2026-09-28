import { screen, waitFor, within } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { membership, renderRoute, shopValue } from '@/test/render';
import { mockRpc, resetSupabaseMock, setTableResult, supabase } from '@/test/supabaseMock';
import {
  customerRow,
  invoiceLineRow,
  invoiceRow,
  paymentRow,
} from '@/features/quotes/testFixtures';
import InvoiceDetailPage from './InvoiceDetailPage';

vi.mock('@/lib/supabase', () => import('@/test/supabaseMock'));

function setup(
  options: {
    invoice?: ReturnType<typeof invoiceRow>;
    lines?: ReturnType<typeof invoiceLineRow>[];
    payments?: ReturnType<typeof paymentRow>[];
    jobs?: unknown[];
    credits?: unknown[];
  } = {},
) {
  const invoice = options.invoice ?? invoiceRow();
  setTableResult('invoices', { data: invoice });
  setTableResult('invoice_line_items', { data: options.lines ?? [invoiceLineRow()] });
  setTableResult('payments', { data: options.payments ?? [paymentRow()] });
  setTableResult('invoice_jobs', { data: options.jobs ?? [] });
  setTableResult('gift_cards', { data: options.credits ?? [] });
  setTableResult('customers', { data: customerRow() });
  setTableResult('vehicles', { data: [] });
  setTableResult('customer_payment_methods', { data: [] });
  return renderRoute(<InvoiceDetailPage />, {
    path: `/app/invoices/${invoice.id}`,
    routePath: '/app/invoices/:invoiceId',
    shop: shopValue({ membership: membership({ role: 'owner' }) }),
  });
}

beforeEach(() => {
  resetSupabaseMock();
  supabase.functions.invoke.mockReset();
});

const job = (id: string, number: number) => ({
  job_id: id,
  voided: false,
  job: { id, number, vehicle_id: null, scheduled_start: null, completed_at: null },
});

describe('InvoiceDetailPage — parity', () => {
  it('groups a fleet invoice’s lines under each job it bills', async () => {
    setup({
      invoice: invoiceRow({ job_id: null }),
      jobs: [job('job-2', 1043), job('job-1', 1042)],
      lines: [
        invoiceLineRow({ id: 'l1', name: 'Wash A', job_id: 'job-1' }),
        invoiceLineRow({ id: 'l2', name: 'Wash B', job_id: 'job-2' }),
        invoiceLineRow({ id: 'l3', name: 'Travel', job_id: null, fee_id: 'fee-1' }),
      ],
    });
    const first = await screen.findByRole('list', { name: 'Job #1042 lines' });
    expect(first).toHaveTextContent('Wash A');
    expect(screen.getByRole('list', { name: 'Job #1043 lines' })).toHaveTextContent('Wash B');
    expect(screen.getByRole('list', { name: 'Other lines lines' })).toHaveTextContent('Travel');
    // the details card links every billed job
    expect(screen.getByRole('link', { name: '#1042' })).toHaveAttribute('href', '/app/jobs/job-1');
  });

  it('pays with a gift card: checks the code, then applies it', async () => {
    const calls = mockRpc({
      lookup_gift_card: {
        data: {
          gift_card_id: 'gc-1',
          kind: 'gift',
          last4: 'Q7ZK',
          balance_cents: 5000,
          status: 'active',
          expires_at: null,
        },
      },
      redeem_gift_card: { data: paymentRow({ method: 'gift_card', amount_cents: 5000 }) },
    });
    const { user } = setup();
    await user.click(await screen.findByRole('button', { name: 'Record payment' }));
    const dialog = await screen.findByRole('dialog', { name: /Record a payment/ });
    await user.click(within(dialog).getByRole('tab', { name: 'Gift card / credit' }));
    await user.type(within(dialog).getByLabelText(/Gift card code/), 'abcd-efgh-jkmn-q7zk');
    await user.click(within(dialog).getByRole('button', { name: 'Check' }));
    expect(await within(dialog).findByText('Gift card …Q7ZK')).toBeInTheDocument();
    await user.click(within(dialog).getByRole('button', { name: 'Apply $50.00' }));
    await waitFor(() =>
      expect(calls.find((c) => c.fn === 'redeem_gift_card')?.args).toEqual({
        p_invoice_id: 'inv-1',
        p_code: 'abcd-efgh-jkmn-q7zk',
        p_amount_cents: 5000,
      }),
    );
    expect(calls.find((c) => c.fn === 'lookup_gift_card')?.args).toEqual({
      p_shop_id: 'shop-1',
      p_code: 'abcd-efgh-jkmn-q7zk',
    });
  });

  it('says so when no gift card has the code', async () => {
    mockRpc({ lookup_gift_card: { data: null } });
    const { user } = setup();
    await user.click(await screen.findByRole('button', { name: 'Record payment' }));
    const dialog = await screen.findByRole('dialog', { name: /Record a payment/ });
    await user.click(within(dialog).getByRole('tab', { name: 'Gift card / credit' }));
    await user.type(within(dialog).getByLabelText(/Gift card code/), 'ZZZZ');
    await user.click(within(dialog).getByRole('button', { name: 'Check' }));
    expect(await within(dialog).findByText(/No gift card has that code/)).toBeInTheDocument();
  });

  it('applies the customer’s store credit without a code', async () => {
    const calls = mockRpc({
      redeem_customer_credit: { data: paymentRow({ method: 'gift_card', amount_cents: 2000 }) },
    });
    const { user } = setup({
      credits: [
        {
          id: 'credit-1',
          code_last4: 'CR42',
          balance_cents: 2000,
          expires_at: null,
          created_at: '2026-09-01T15:00:00Z',
        },
      ],
    });
    await user.click(await screen.findByRole('button', { name: 'Record payment' }));
    const dialog = await screen.findByRole('dialog', { name: /Record a payment/ });
    await user.click(within(dialog).getByRole('tab', { name: 'Gift card / credit' }));
    await user.click(await within(dialog).findByRole('radio', { name: 'Customer’s store credit' }));
    await user.click(within(dialog).getByRole('button', { name: 'Apply credit' }));
    await waitFor(() =>
      expect(calls.find((c) => c.fn === 'redeem_customer_credit')?.args).toEqual({
        p_invoice_id: 'inv-1',
        p_gift_card_id: 'credit-1',
        p_amount_cents: 2000,
      }),
    );
  });

  it('does not collect again while a bank payment covers the balance', async () => {
    setup({
      payments: [
        paymentRow(),
        paymentRow({
          id: 'pay-ach',
          method: 'ach_debit',
          status: 'processing',
          amount_cents: 20000,
          tip_cents: 0,
          card_brand: null,
          card_last4: null,
          paid_at: null,
          stripe_method_type: 'us_bank_account',
        }),
      ],
    });
    expect(await screen.findByText(/is still clearing/)).toBeInTheDocument();
    expect(screen.getByText(/nothing more needs to be collected/)).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Record payment' })).not.toBeInTheDocument();
    expect(screen.getByText(/Still clearing with the bank/)).toBeInTheDocument();
  });

  it('records at most the balance less a bank payment still clearing', async () => {
    const calls = mockRpc({ record_manual_payment: { data: paymentRow({ amount_cents: 12000 }) } });
    const { user } = setup({
      payments: [
        paymentRow(),
        paymentRow({
          id: 'pay-ach',
          method: 'ach_debit',
          status: 'processing',
          amount_cents: 8000,
          tip_cents: 0,
          card_brand: null,
          card_last4: null,
          paid_at: null,
          stripe_method_type: 'us_bank_account',
        }),
      ],
    });
    await user.click(await screen.findByRole('button', { name: 'Record payment' }));
    const dialog = await screen.findByRole('dialog', { name: /Record a payment/ });
    expect(
      within(dialog).getByText('Up to $120.00 — $80.00 is still clearing or in progress'),
    ).toBeInTheDocument();
    const amount = within(dialog).getByLabelText(/^Amount/);
    expect(amount).toHaveValue('120.00');
    await user.clear(amount);
    await user.type(amount, '150');
    await user.click(within(dialog).getByRole('button', { name: 'Record payment' }));
    expect(await within(dialog).findByText(/can’t be more than \$120\.00/)).toBeInTheDocument();
    expect(calls.find((c) => c.fn === 'record_manual_payment')).toBeUndefined();
    await user.clear(amount);
    await user.type(amount, '120');
    await user.click(within(dialog).getByRole('button', { name: 'Record payment' }));
    await waitFor(() =>
      expect(calls.find((c) => c.fn === 'record_manual_payment')?.args).toMatchObject({
        p_amount_cents: 12000,
      }),
    );
  });

  it('refunds a bank debit through Stripe, not by hand', async () => {
    supabase.functions.invoke.mockResolvedValue({
      data: {
        payment_id: 'pay-ach',
        refund_id: 're_1',
        refund_status: 'pending',
        amount_cents: 5000,
        refunded_cents_total: 5000,
        payment_status: 'partially_refunded',
      },
      error: null,
    });
    const { user } = setup({
      payments: [
        paymentRow({
          id: 'pay-ach',
          method: 'ach_debit',
          amount_cents: 5000,
          tip_cents: 0,
          card_brand: null,
          card_last4: null,
        }),
      ],
    });
    await user.click(await screen.findByRole('button', { name: /^Refund Bank debit/ }));
    const dialog = await screen.findByRole('dialog', { name: 'Refund payment' });
    expect(within(dialog).getByText(/through Stripe/)).toBeInTheDocument();
    await user.click(within(dialog).getByRole('button', { name: /^Refund/ }));
    await waitFor(() =>
      expect(supabase.functions.invoke).toHaveBeenCalledWith(
        'payments',
        expect.objectContaining({
          body: expect.objectContaining({ action: 'refund', payment_id: 'pay-ach' }),
        }),
      ),
    );
  });
});
