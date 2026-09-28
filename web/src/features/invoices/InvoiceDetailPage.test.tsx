import { screen, waitFor, within } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { membership, renderRoute, shopValue } from '@/test/render';
import {
  builders,
  createBuilder,
  edgeHttpError,
  resetSupabaseMock,
  setTableResult,
  supabase,
} from '@/test/supabaseMock';
import {
  customerRow,
  invoiceLineRow,
  invoiceRow,
  paymentRow,
} from '@/features/quotes/testFixtures';
import InvoiceDetailPage from './InvoiceDetailPage';

vi.mock('@/lib/supabase', () => import('@/test/supabaseMock'));

const invoke = supabase.functions.invoke;

function setup(
  options: {
    role?: 'owner' | 'manager' | 'technician';
    invoice?: ReturnType<typeof invoiceRow>;
    lines?: ReturnType<typeof invoiceLineRow>[];
    payments?: ReturnType<typeof paymentRow>[];
  } = {},
) {
  const invoice = options.invoice ?? invoiceRow();
  setTableResult('invoices', { data: invoice });
  setTableResult('invoice_line_items', { data: options.lines ?? [invoiceLineRow()] });
  setTableResult('payments', { data: options.payments ?? [paymentRow()] });
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
    expect(supabase.rpc).not.toHaveBeenCalledWith('record_manual_payment', expect.anything());

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

  it('a payment refused while a card payment page is open: cancel the open payments, then it is recorded', async () => {
    const OPEN = {
      code: '55000',
      message:
        'a card payment page for this invoice is still open (until 3:40 PM); cancel the open payments first, or wait until then',
      details: null,
      hint: 'checkout_open',
    };
    let refused = true;
    supabase.rpc.mockImplementation((...args: unknown[]) => {
      if (args[0] !== 'record_manual_payment') return createBuilder({ data: null });
      return createBuilder(
        refused ? { data: null, error: OPEN } : { data: paymentRow({ method: 'cash' }) },
      );
    });
    invoke.mockImplementation(() => {
      refused = false; // the edge expired the page and released the hold
      return Promise.resolve({
        data: {
          invoice_id: 'inv-1',
          cancelled: 0,
          succeeded: 0,
          in_progress: 0,
          sessions_expired: 1,
        },
        error: null,
      });
    });
    const { user } = setup();
    await user.click(await screen.findByRole('button', { name: 'Record payment' }));
    const dialog = await screen.findByRole('dialog');
    const amount = within(dialog).getByLabelText(/^Amount/);
    await user.clear(amount);
    await user.type(amount, '50');
    await user.click(within(dialog).getByRole('button', { name: 'Record payment' }));
    expect(
      await within(dialog).findByText('A card payment page for this invoice is still open'),
    ).toBeInTheDocument();
    // The server's own sentence (with the time) is shown, not a generic error.
    expect(
      within(dialog).getByText(/Cancel the open payments first, or wait until then/i),
    ).toBeInTheDocument();
    await user.click(
      within(dialog).getByRole('button', { name: 'Cancel open payments and try again' }),
    );
    await waitFor(() =>
      expect(invoke).toHaveBeenCalledWith('payments', {
        body: { action: 'cancel_open_payments', shop_id: 'shop-1', invoice_id: 'inv-1' },
      }),
    );
    expect(await screen.findByText('$50.00 payment recorded')).toBeInTheDocument();
    const records = (supabase.rpc.mock.calls as unknown[][]).filter(
      (c) => c[0] === 'record_manual_payment',
    );
    expect(records).toHaveLength(2);
    expect(records[1]?.[1]).toEqual(records[0]?.[1]);
  });

  it('does not record on top of a payment the bank is already processing', async () => {
    supabase.rpc.mockImplementation((...args: unknown[]) =>
      createBuilder(
        args[0] === 'record_manual_payment'
          ? {
              data: null,
              error: {
                code: '55000',
                message:
                  'a card payment page for this invoice is still open (until 3:40 PM); cancel the open payments first, or wait until then',
                details: null,
                hint: 'checkout_open',
              },
            }
          : { data: null },
      ),
    );
    invoke.mockResolvedValue({
      data: {
        invoice_id: 'inv-1',
        cancelled: 0,
        succeeded: 0,
        in_progress: 1,
        sessions_expired: 0,
      },
      error: null,
    });
    const { user } = setup();
    await user.click(await screen.findByRole('button', { name: 'Record payment' }));
    const dialog = await screen.findByRole('dialog');
    await user.click(within(dialog).getByRole('button', { name: 'Record payment' }));
    await user.click(
      await within(dialog).findByRole('button', { name: 'Cancel open payments and try again' }),
    );
    expect(await within(dialog).findByText(/A payment is still processing/)).toBeInTheDocument();
    expect(
      (supabase.rpc.mock.calls as unknown[][]).filter((c) => c[0] === 'record_manual_payment'),
    ).toHaveLength(1);
  });

  it('managers copy the pay link fetched from invoice_link_token', async () => {
    supabase.rpc.mockImplementation((...args: unknown[]) =>
      createBuilder(
        args[0] === 'invoice_link_token'
          ? { data: '50000000-0000-4000-8000-000000000009' }
          : { data: null },
      ),
    );
    const { user } = setup({ role: 'manager' });
    await user.click(await screen.findByRole('button', { name: 'Copy pay link' }));
    expect(supabase.rpc).toHaveBeenCalledWith('invoice_link_token', { p_invoice_id: 'inv-1' });
    expect(await screen.findByText('Pay link copied')).toBeInTheDocument();
    await expect(navigator.clipboard.readText()).resolves.toContain(
      '/i/50000000-0000-4000-8000-000000000009',
    );
  });

  it('offers to text the pay link when the bank requires authentication', async () => {
    invoke.mockResolvedValueOnce({
      data: null,
      error: edgeHttpError(402, {
        error:
          "The card's bank requires the customer to confirm this payment. Send them a payment link instead.",
        code: 'payment_failed',
        details: { reason: 'authentication_required' },
      }),
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

  it('drops a saved card Stripe no longer has and refetches the list', async () => {
    invoke.mockResolvedValueOnce({
      data: null,
      error: edgeHttpError(422, {
        error: 'That saved card is no longer available; it was removed.',
        code: 'unprocessable',
        details: { reason: 'saved_card_removed' },
      }),
    });
    const { user } = setup();
    await user.click(await screen.findByRole('button', { name: 'Charge card' }));
    const dialog = await screen.findByRole('dialog');
    await within(dialog).findByRole('radio', { name: /Visa •••• 4242/ });
    const cardQueries = () => (builders.customer_payment_methods ?? []).length;
    const before = cardQueries();
    setTableResult('customer_payment_methods', { data: [] });
    await user.click(within(dialog).getByRole('button', { name: 'Charge $200.00' }));
    expect(
      await within(dialog).findByText('That saved card is no longer available; it was removed.'),
    ).toBeInTheDocument();
    await waitFor(() => expect(cardQueries()).toBeGreaterThan(before));
    expect(await within(dialog).findByText('No saved card')).toBeInTheDocument();
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
        body: {
          action: 'refund',
          shop_id: 'shop-1',
          payment_id: 'pay-1',
          amount_cents: 11500,
          request_nonce: expect.stringMatching(/^[A-Za-z0-9_-]{8,64}$/) as unknown,
        },
      }),
    );
  });

  it('keeps the refund nonce for a retry after a server error and renews it after a definitive answer', async () => {
    invoke
      .mockResolvedValueOnce({
        data: null,
        error: edgeHttpError(503, { error: 'Stripe is unavailable.', code: 'upstream_error' }),
        response: undefined,
      })
      .mockResolvedValueOnce({
        data: null,
        error: edgeHttpError(422, {
          error: 'The refund is more than the refundable amount.',
          code: 'unprocessable',
          details: { reason: 'amount_exceeds_refundable' },
        }),
        response: undefined,
      })
      .mockResolvedValueOnce({
        data: {
          payment_id: 'pay-1',
          refund_id: 're_2',
          refund_status: 'succeeded',
          amount_cents: 1000,
          refunded_cents_total: 2000,
          payment_status: 'partially_refunded',
        },
        error: null,
        response: undefined,
      });
    const { user } = setup();
    await user.click(await screen.findByRole('button', { name: /Refund Visa •••• 4242 payment/ }));
    const dialog = await screen.findByRole('dialog', { name: 'Refund payment' });
    const amount = within(dialog).getByLabelText(/Refund amount/);
    await user.clear(amount);
    await user.type(amount, '10');
    const refundButton = within(dialog).getByRole('button', { name: 'Refund $10.00' });
    await user.click(refundButton);
    await waitFor(() => expect(invoke).toHaveBeenCalledTimes(1));
    await waitFor(() => expect(refundButton).toBeEnabled());
    await user.click(refundButton);
    await waitFor(() => expect(invoke).toHaveBeenCalledTimes(2));
    await waitFor(() => expect(refundButton).toBeEnabled());
    await user.click(refundButton);
    await waitFor(() => expect(invoke).toHaveBeenCalledTimes(3));
    const nonces = invoke.mock.calls.map(([, options]) => {
      const body: unknown = options?.body;
      return (body as { request_nonce?: string }).request_nonce;
    });
    expect(nonces[0]).toBeTruthy();
    expect(nonces[1]).toBe(nonces[0]); // same attempt retried: Stripe replays, never refunds twice
    expect(nonces[2]).not.toBe(nonces[1]); // a new attempt after a definitive refusal
    expect(await screen.findByText('$10.00 refunded')).toBeInTheDocument();
  });

  it('shows the in-flight payment hold and releases it with cancel_open_payments', async () => {
    invoke.mockResolvedValueOnce({
      data: {
        invoice_id: 'inv-1',
        cancelled: 1,
        succeeded: 0,
        in_progress: 0,
        sessions_expired: 1,
      },
      error: null,
      response: undefined,
    });
    const { user } = setup({
      payments: [
        paymentRow({
          id: 'pay-2',
          status: 'pending',
          paid_at: null,
          created_at: new Date(Date.now() - 5 * 60_000).toISOString(),
        }),
      ],
    });
    const hold = await screen.findByText('A card payment is in progress on this invoice.');
    const banner = hold.closest('[role="status"]');
    expect(banner).not.toBeNull();
    await user.click(
      within(banner as HTMLElement).getByRole('button', { name: 'Cancel open payments' }),
    );
    const dialog = await screen.findByRole('alertdialog', { name: 'Cancel open card payments?' });
    await user.click(within(dialog).getByRole('button', { name: 'Cancel open payments' }));
    await waitFor(() =>
      expect(invoke).toHaveBeenCalledWith('payments', {
        body: { action: 'cancel_open_payments', shop_id: 'shop-1', invoice_id: 'inv-1' },
      }),
    );
    expect(await screen.findByText('1 open payment cancelled')).toBeInTheDocument();
    expect(screen.getByText('1 open pay link was expired.')).toBeInTheDocument();
  });

  it('does not show the hold for an abandoned pending payment older than an hour', async () => {
    setup({
      payments: [
        paymentRow({
          id: 'pay-2',
          status: 'pending',
          paid_at: null,
          created_at: new Date(Date.now() - 2 * 3600_000).toISOString(),
        }),
      ],
    });
    await screen.findByRole('heading', { name: 'Invoice #2001', level: 1 });
    await screen.findByRole('list', { name: 'Payments' });
    expect(
      screen.queryByText('A card payment is in progress on this invoice.'),
    ).not.toBeInTheDocument();
  });

  it('offers to cancel open payments when a void is refused for an in-flight payment', async () => {
    supabase.rpc.mockReturnValue(
      createBuilder({
        data: null,
        error: {
          message: 'a payment is in progress on this invoice; wait for it to finish',
          code: '22023',
        },
      }),
    );
    const { user } = setup();
    await user.click(await screen.findByRole('button', { name: 'More invoice actions' }));
    await user.click(screen.getByRole('menuitem', { name: /Void invoice/ }));
    const dialog = await screen.findByRole('alertdialog');
    await user.click(within(dialog).getByRole('button', { name: 'Void invoice' }));
    const toastTitle = await screen.findByText('A card payment is in progress on this invoice', {
      selector: '[role="status"] *, [role="alert"] *',
    });
    expect(toastTitle).toBeInTheDocument();
    // the hold banner is shown too
    expect(
      await screen.findByText('A card payment is in progress on this invoice.'),
    ).toBeInTheDocument();
    const toastAction = screen.getAllByRole('button', { name: 'Cancel open payments' });
    expect(toastAction.length).toBeGreaterThanOrEqual(2);
  });

  it('managers get a Cancel open payments action on an open invoice', async () => {
    const { user } = setup({ role: 'manager' });
    await user.click(await screen.findByRole('button', { name: 'More invoice actions' }));
    expect(screen.getByRole('menuitem', { name: /Cancel open payments/ })).toBeInTheDocument();
  });

  it('a draft shows "Not issued yet" instead of a paid-in-full balance', async () => {
    setup({
      role: 'manager',
      lines: [],
      invoice: invoiceRow({
        status: 'draft',
        subtotal_cents: 0,
        total_cents: 0,
        amount_paid_cents: 0,
        balance_cents: 0,
        issued_at: null,
        sent_at: null,
        due_at: null,
      }),
      payments: [],
    });
    expect(await screen.findByText('Not issued yet')).toBeInTheDocument();
    expect(screen.queryByText('Paid in full')).not.toBeInTheDocument();
    expect(screen.queryByText('Paid')).not.toBeInTheDocument();
  });

  it('won’t clear the due date of an issued invoice', async () => {
    const { user } = setup({ role: 'manager' });
    const due = await screen.findByLabelText(/Due date/);
    await user.clear(due);
    expect(await screen.findByText('An issued invoice needs a due date.')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Save details' })).toBeDisabled();
  });

  it('technicians (when allowed) can collect but not charge cards, refund, void or send', async () => {
    const { user } = setup({ role: 'technician' });
    await screen.findByRole('heading', { name: 'Invoice #2001', level: 1 });
    expect(screen.getByRole('button', { name: 'Record payment' })).toBeInTheDocument();
    // the pay link is the customer's credential: technicians never fetch it
    expect(screen.queryByRole('button', { name: 'Copy pay link' })).not.toBeInTheDocument();
    expect(supabase.rpc).not.toHaveBeenCalledWith('invoice_link_token', expect.anything());
    expect(screen.queryByRole('button', { name: 'Charge card' })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /Resend|Send invoice/ })).not.toBeInTheDocument();
    // the only extra action is the PDF (collectors may open their job's invoice)
    await user.click(screen.getByRole('button', { name: 'More invoice actions' }));
    expect(screen.getAllByRole('menuitem').map((item) => item.textContent)).toEqual([
      'Download PDF',
    ]);
    await user.keyboard('{Escape}');
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
