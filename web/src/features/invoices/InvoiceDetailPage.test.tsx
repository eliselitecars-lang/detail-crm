import { FunctionsHttpError } from '@supabase/supabase-js';
import { screen, waitFor, within } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { supabase as appSupabase } from '@/lib/supabase';
import { membership, renderRoute, shopValue } from '@/test/render';
import { createBuilder, resetSupabaseMock, setTableResult, supabase } from '@/test/supabaseMock';
import {
  customerRow,
  invoiceLineRow,
  invoiceRow,
  paymentRow,
} from '@/features/quotes/testFixtures';
import InvoiceDetailPage from './InvoiceDetailPage';

vi.mock('@/lib/supabase', async () => {
  const mod = await import('@/test/supabaseMock');
  return { ...mod, supabase: Object.assign(mod.supabase, { functions: { invoke: vi.fn() } }) };
});

const invoke = vi.mocked(appSupabase.functions.invoke);

function setup(
  options: {
    role?: 'owner' | 'manager' | 'technician';
    invoice?: ReturnType<typeof invoiceRow>;
  } = {},
) {
  const invoice = options.invoice ?? invoiceRow();
  setTableResult('invoices', { data: invoice });
  setTableResult('invoice_line_items', { data: [invoiceLineRow()] });
  setTableResult('payments', { data: [paymentRow()] });
  setTableResult('customers', { data: customerRow() });
  setTableResult('vehicles', { data: [] });
  setTableResult('customer_payment_methods', {
    data: [
      {
        id: 'cpm-1',
        stripe_payment_method_id: 'pm_123',
        brand: 'visa',
        last4: '4242',
        exp_month: 4,
        exp_year: 2030,
        is_default: true,
      },
    ],
  });
  const role = options.role ?? 'owner';
  const current = membership({
    role,
    shop: { ...membership().shop, techs_can_collect_payments: true },
  });
  return renderRoute(<InvoiceDetailPage />, {
    path: `/app/invoices/${invoice.id}`,
    routePath: '/app/invoices/:invoiceId',
    shop: shopValue({ membership: current }),
  });
}

beforeEach(() => {
  resetSupabaseMock();
  invoke.mockReset();
});

describe('InvoiceDetailPage', () => {
  it('shows server totals, balance and payments with card details and tips', async () => {
    setup();
    expect(
      await screen.findByRole('heading', { name: 'Invoice #2001', level: 1 }),
    ).toBeInTheDocument();
    expect(screen.getByText('$200.00')).toBeInTheDocument(); // balance badge
    const payments = await screen.findByRole('list', { name: 'Payments' });
    expect(within(payments).getByText('Visa •••• 4242')).toBeInTheDocument();
    expect(within(payments).getByText('+ $15.00 tip')).toBeInTheDocument();
    // money on the invoice: lines are locked
    expect(screen.queryByRole('button', { name: 'Edit Ceramic coating' })).not.toBeInTheDocument();
  });

  it('records a manual payment up to the balance', async () => {
    supabase.rpc.mockReturnValue(createBuilder({ data: paymentRow({ method: 'check' }) }));
    const { user } = setup();
    await user.click(await screen.findByRole('button', { name: 'Record payment' }));
    const dialog = await screen.findByRole('dialog');
    await user.selectOptions(within(dialog).getByLabelText(/Method/), 'check');
    const amount = within(dialog).getByLabelText(/^Amount/);
    await user.clear(amount);
    await user.type(amount, '250');
    await user.click(within(dialog).getByRole('button', { name: 'Record payment' }));
    expect(
      await within(dialog).findByText(/can’t be more than the balance due/),
    ).toBeInTheDocument();
    expect(supabase.rpc).not.toHaveBeenCalled();

    await user.clear(amount);
    await user.type(amount, '120.50');
    const tip = within(dialog).getByLabelText(/Tip/);
    await user.clear(tip);
    await user.type(tip, '10');
    await user.click(within(dialog).getByRole('button', { name: 'Record payment' }));
    await waitFor(() =>
      expect(supabase.rpc).toHaveBeenCalledWith('record_manual_payment', {
        p_invoice_id: 'inv-1',
        p_amount_cents: 12050,
        p_method: 'check',
        p_tip_cents: 1000,
      }),
    );
  });

  it('offers to text the pay link when the bank requires authentication', async () => {
    invoke.mockResolvedValueOnce({
      data: null,
      error: new FunctionsHttpError(
        new Response(
          JSON.stringify({
            error:
              "The card's bank requires the customer to confirm this payment. Send them a payment link instead.",
            code: 'payment_failed',
            details: { reason: 'authentication_required' },
          }),
          { status: 402 },
        ),
      ),
      response: undefined,
    });
    const { user } = setup();
    await user.click(await screen.findByRole('button', { name: 'Charge card' }));
    const dialog = await screen.findByRole('dialog');
    expect(await within(dialog).findByRole('radio', { name: /Visa •••• 4242/ })).toBeChecked();
    await user.click(within(dialog).getByRole('button', { name: 'Charge $200.00' }));
    expect(
      await within(dialog).findByRole('button', { name: 'Text the pay link' }),
    ).toBeInTheDocument();
    const [fn, options] = invoke.mock.calls[0] ?? [];
    expect(fn).toBe('payments');
    expect(options?.body).toMatchObject({
      action: 'charge_saved_card',
      shop_id: 'shop-1',
      invoice_id: 'inv-1',
      payment_method_id: 'pm_123',
      amount_cents: 20000,
    });
  });

  it('refunds a card payment through the payments function (owner)', async () => {
    invoke.mockResolvedValueOnce({
      data: {
        payment_id: 'pay-1',
        refund_id: 're_1',
        refund_status: 'succeeded',
        amount_cents: 11500,
        refunded_cents_total: 11500,
        payment_status: 'refunded',
      },
      error: null,
      response: undefined,
    });
    const { user } = setup();
    await user.click(await screen.findByRole('button', { name: /Refund Visa •••• 4242 payment/ }));
    const dialog = await screen.findByRole('dialog', { name: 'Refund payment' });
    expect(within(dialog).getByLabelText(/Refund amount/)).toHaveValue('115.00');
    await user.click(within(dialog).getByRole('button', { name: 'Refund $115.00' }));
    await waitFor(() =>
      expect(invoke).toHaveBeenCalledWith('payments', {
        body: { action: 'refund', shop_id: 'shop-1', payment_id: 'pay-1', amount_cents: 11500 },
      }),
    );
  });

  it('technicians (when allowed) can collect but not charge cards, refund, void or send', async () => {
    setup({ role: 'technician' });
    await screen.findByRole('heading', { name: 'Invoice #2001', level: 1 });
    expect(screen.getByRole('button', { name: 'Record payment' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Copy pay link' })).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Charge card' })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /Resend|Send invoice/ })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'More invoice actions' })).not.toBeInTheDocument();
    await screen.findByRole('list', { name: 'Payments' });
    expect(screen.queryByRole('button', { name: /^Refund/ })).not.toBeInTheDocument();
  });

  it('lets managers edit lines on a draft and hides payment actions', async () => {
    const { user } = setup({
      role: 'manager',
      invoice: invoiceRow({
        status: 'draft',
        amount_paid_cents: 0,
        balance_cents: 30000,
        issued_at: null,
        sent_at: null,
        due_at: null,
      }),
    });
    await screen.findByRole('heading', { name: 'Invoice #2001', level: 1 });
    expect(screen.getByRole('button', { name: 'Edit Ceramic coating' })).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Record payment' })).not.toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Send invoice' })).toBeInTheDocument();
    // managers cannot void
    await user.click(screen.getByRole('button', { name: 'More invoice actions' }));
    expect(screen.queryByRole('menuitem', { name: /Void/ })).not.toBeInTheDocument();
    expect(screen.getByRole('menuitem', { name: /Delete draft/ })).toBeInTheDocument();
  });

  it('voids an invoice (owner) with a reason', async () => {
    supabase.rpc.mockReturnValue(createBuilder({ data: invoiceRow({ status: 'void' }) }));
    const { user } = setup();
    await user.click(await screen.findByRole('button', { name: 'More invoice actions' }));
    await user.click(screen.getByRole('menuitem', { name: /Void invoice/ }));
    const dialog = await screen.findByRole('alertdialog');
    await user.type(within(dialog).getByLabelText(/Reason/), 'Duplicate');
    await user.click(within(dialog).getByRole('button', { name: 'Void invoice' }));
    await waitFor(() =>
      expect(supabase.rpc).toHaveBeenCalledWith('void_invoice', {
        p_invoice_id: 'inv-1',
        p_reason: 'Duplicate',
      }),
    );
  });
});
