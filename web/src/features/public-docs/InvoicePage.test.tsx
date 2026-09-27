import { screen, waitFor } from '@testing-library/react';
import { FunctionsHttpError } from '@supabase/supabase-js';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { renderRoute } from '@/test/render';
import InvoicePage from './InvoicePage';
import { navigation } from './shared/checkout';
import { edge, mockRpc, resetPublicMocks } from './shared/testing';
import { DOC_TOKEN, invoiceFixture } from './testFixtures';

vi.mock('@/lib/supabase', () => import('@/features/public-docs/shared/testSupabase'));

function render(path = `/i/${DOC_TOKEN}`) {
  return renderRoute(<InvoicePage />, { path, routePath: '/i/:token', shop: null });
}

function checkoutOk() {
  edge.invoke.mockResolvedValue({
    data: {
      url: 'https://checkout.stripe.com/c/pay/cs_inv',
      expires_at: 1,
      amount_cents: 20000,
      tip_cents: 3000,
      currency: 'usd',
    },
    error: null,
  });
}

beforeEach(() => {
  resetPublicMocks();
});

describe('InvoicePage', () => {
  it('shows lines, payments and the server balance', async () => {
    mockRpc({ public_get_invoice: { data: invoiceFixture() } });
    render();
    expect(
      await screen.findByRole('heading', { name: 'Invoice #2001', level: 1 }),
    ).toBeInTheDocument();
    expect(screen.getByText('Balance due')).toBeInTheDocument();
    expect(screen.getByText('Visa •••• 4242')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Print' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Pay $200.00' })).toBeInTheDocument();
  });

  it('pays the balance with a 15% tip via Stripe Checkout', async () => {
    mockRpc({ public_get_invoice: { data: invoiceFixture() } });
    checkoutOk();
    const assign = vi.spyOn(navigation, 'assign').mockImplementation(() => undefined);
    const { user } = render();
    await user.click(await screen.findByRole('radio', { name: /15%/ }));
    await user.click(screen.getByRole('button', { name: 'Pay $200.00 + $30.00 tip' }));
    await waitFor(() =>
      expect(assign).toHaveBeenCalledWith('https://checkout.stripe.com/c/pay/cs_inv'),
    );
    const body = (edge.invoke.mock.calls[0]?.[1] as { body: Record<string, unknown> }).body;
    expect(edge.invoke.mock.calls[0]?.[0]).toBe('payments');
    expect(body).toMatchObject({ action: 'invoice_checkout', token: DOC_TOKEN, tip_cents: 3000 });
    expect(Object.keys(body).sort()).toEqual(['action', 'request_nonce', 'tip_cents', 'token']);
  });

  it('bounds a custom tip to the balance', async () => {
    mockRpc({ public_get_invoice: { data: invoiceFixture() } });
    const { user } = render();
    await user.click(await screen.findByRole('radio', { name: /Custom/ }));
    await user.click(screen.getByRole('button', { name: /^Pay \$200\.00/ }));
    expect(screen.getByText('Enter a tip between $0.00 and $200.00.')).toBeInTheDocument();
    expect(edge.invoke).not.toHaveBeenCalled();
  });

  it('shows the edge function’s message when checkout is refused', async () => {
    mockRpc({ public_get_invoice: { data: invoiceFixture() } });
    edge.invoke.mockResolvedValue({
      data: null,
      error: new FunctionsHttpError(
        new Response(
          JSON.stringify({
            error: 'This shop cannot take card payments yet.',
            code: 'unprocessable',
          }),
          {
            status: 422,
            headers: { 'content-type': 'application/json' },
          },
        ),
      ),
    });
    const { user } = render();
    await user.click(await screen.findByRole('button', { name: 'Pay $200.00' }));
    expect(await screen.findByText('This shop cannot take card payments yet.')).toBeInTheDocument();
  });

  it('confirms the payment after returning from Stripe', async () => {
    let n = 0;
    mockRpc({
      public_get_invoice: () => {
        n += 1;
        return {
          data:
            n === 1
              ? invoiceFixture()
              : invoiceFixture({
                  status: 'paid',
                  amount_paid_cents: 30000,
                  balance_cents: 0,
                  payable: false,
                  paid_at: '2026-09-27T15:00:00Z',
                }),
        };
      },
    });
    render(`/i/${DOC_TOKEN}?paid=1`);
    expect(await screen.findByText('Confirming your payment…')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /^Pay/ })).not.toBeInTheDocument();
    expect(
      await screen.findByText('Payment received — thank you!', {}, { timeout: 5000 }),
    ).toBeInTheDocument();
  });

  it('shows the void state without a pay button', async () => {
    mockRpc({
      public_get_invoice: {
        data: invoiceFixture({ status: 'void', payable: false, voided_at: '2026-09-25T15:00:00Z' }),
      },
    });
    render();
    expect(await screen.findByText('This invoice was voided')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /^Pay/ })).not.toBeInTheDocument();
  });

  it('tells the customer to contact the shop when card payments are off', async () => {
    mockRpc({ public_get_invoice: { data: invoiceFixture({ card_payments_enabled: false }) } });
    render();
    expect(await screen.findByText('Online payment isn’t available')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /^Pay/ })).not.toBeInTheDocument();
  });
});
