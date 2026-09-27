import { expect, test, type Page } from '@playwright/test';
import { membershipRow, OWNER, SHOP } from './support/fixtures';
import { mockSupabase, type Json } from './support/mockSupabase';

/**
 * Card-money safety on the invoice page: a hold left by an unconfirmed
 * payment can be released (payments.cancel_open_payments), and every card
 * refund attempt carries its own request_nonce so a second partial refund of
 * the same amount is never mistaken for a replay of the first.
 */

const CUSTOMER = {
  id: '30000000-0000-4000-8000-000000000001',
  first_name: 'Jane',
  last_name: 'Doe',
  company: null,
  email: 'jane@example.com',
  phone: '+12055550123',
  archived_at: null,
  sms_opted_out_at: null,
  email_opted_out_at: null,
};

const INVOICE_ID = '90000000-0000-4000-8000-000000000011';

const INVOICE = {
  id: INVOICE_ID,
  shop_id: SHOP.id,
  number: 2011,
  job_id: null,
  customer_id: CUSTOMER.id,
  status: 'partially_paid',
  issued_at: '2026-09-20T15:00:00Z',
  due_at: '2099-10-20T15:00:00Z',
  sent_at: '2026-09-20T15:00:00Z',
  paid_at: null,
  voided_at: null,
  void_reason: null,
  notes: null,
  terms: null,
  internal_notes: null,
  discount_kind: 'none',
  discount_value: 0,
  tax_rate_bps: 0,
  subtotal_cents: 30000,
  discount_cents: 0,
  tax_cents: 0,
  total_cents: 30000,
  amount_paid_cents: 10000,
  balance_cents: 20000,
  tip_cents: 0,
  public_token: '50000000-0000-4000-8000-000000000011',
  created_by: null,
  created_at: '2026-09-20T15:00:00Z',
  updated_at: '2026-09-20T15:00:00Z',
};

const LINE = {
  id: 'b0000000-0000-4000-8000-000000000011',
  shop_id: SHOP.id,
  invoice_id: INVOICE_ID,
  service_id: null,
  vehicle_id: null,
  name: 'Ceramic coating',
  description: null,
  quantity: 1,
  unit_price_cents: 30000,
  discount_cents: 0,
  taxable: true,
  sort: 1,
  total_cents: 30000,
  created_at: '2026-09-20T15:00:00Z',
  updated_at: '2026-09-20T15:00:00Z',
};

function payment(overrides: Record<string, unknown> = {}) {
  return {
    id: 'c0000000-0000-4000-8000-000000000011',
    shop_id: SHOP.id,
    invoice_id: INVOICE_ID,
    job_id: null,
    customer_id: CUSTOMER.id,
    membership_id: null,
    kind: 'payment',
    method: 'card',
    status: 'succeeded',
    amount_cents: 10000,
    tip_cents: 0,
    refunded_cents: 0,
    stripe_payment_intent_id: 'pi_123',
    stripe_charge_id: 'ch_123',
    stripe_checkout_session_id: null,
    card_brand: 'visa',
    card_last4: '4242',
    note: null,
    recorded_by: null,
    paid_at: '2026-09-21T15:00:00Z',
    created_at: '2026-09-21T15:00:00Z',
    updated_at: '2026-09-21T15:00:00Z',
    ...overrides,
  };
}

type Body = Record<string, unknown>;

async function setup(page: Page, payments: ReturnType<typeof payment>[]) {
  const calls: Body[] = [];
  await mockSupabase(page, {
    user: OWNER,
    tables: {
      shop_members: [membershipRow(OWNER, 'owner')],
      notifications: [],
      invoices: [INVOICE],
      invoice_line_items: [LINE],
      payments,
      customers: [CUSTOMER],
      vehicles: [],
      customer_payment_methods: [],
    },
    functions: {
      payments: ({ body }): Json => {
        const call = body as Body;
        calls.push(call);
        return call.action === 'cancel_open_payments'
          ? {
              invoice_id: INVOICE_ID,
              cancelled: 1,
              succeeded: 0,
              in_progress: 0,
              sessions_expired: 0,
            }
          : {
              payment_id: payment().id,
              refund_id: `re_${calls.length}`,
              refund_status: 'succeeded',
              amount_cents: call.amount_cents as Json,
              refunded_cents_total: 1000 * calls.length,
              payment_status: 'partially_refunded',
            };
      },
    },
  });
  return calls;
}

test.describe('invoice card-money safety', () => {
  test('an unconfirmed card payment holds the invoice until the owner cancels it', async ({
    page,
  }) => {
    const calls = await setup(page, [
      payment(),
      payment({
        id: 'c0000000-0000-4000-8000-000000000012',
        status: 'pending',
        paid_at: null,
        created_at: new Date(Date.now() - 10 * 60_000).toISOString(),
      }),
    ]);
    await page.goto(`/app/invoices/${INVOICE_ID}`);
    const hold = page.getByRole('status').filter({
      hasText: 'A card payment is in progress on this invoice.',
    });
    await expect(hold).toBeVisible();
    await hold.getByRole('button', { name: 'Cancel open payments' }).click();
    const dialog = page.getByRole('alertdialog', { name: 'Cancel open card payments?' });
    await dialog.getByRole('button', { name: 'Cancel open payments' }).click();
    await expect(page.getByText('1 open payment cancelled')).toBeVisible();
    expect(calls).toEqual([
      { action: 'cancel_open_payments', shop_id: SHOP.id, invoice_id: INVOICE_ID },
    ]);
  });

  test('two partial refunds of the same amount are two refund attempts', async ({ page }) => {
    const calls = await setup(page, [payment()]);
    await page.goto(`/app/invoices/${INVOICE_ID}`);
    for (let attempt = 0; attempt < 2; attempt += 1) {
      await page.getByRole('button', { name: /Refund Visa •••• 4242 payment/ }).click();
      const dialog = page.getByRole('dialog', { name: 'Refund payment' });
      await dialog.getByLabel(/Refund amount/).fill('10');
      await dialog.getByRole('button', { name: 'Refund $10.00' }).click();
      await expect(dialog).toBeHidden();
    }
    expect(calls).toHaveLength(2);
    const [first, second] = calls;
    expect(first).toMatchObject({ action: 'refund', payment_id: payment().id, amount_cents: 1000 });
    expect(first?.request_nonce).toEqual(expect.stringMatching(/^[A-Za-z0-9_-]{8,64}$/));
    expect(second?.request_nonce).toEqual(expect.stringMatching(/^[A-Za-z0-9_-]{8,64}$/));
    expect(second?.request_nonce).not.toBe(first?.request_nonce);
  });
});
