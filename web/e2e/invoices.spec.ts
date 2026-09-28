import { expect, test, type Page } from '@playwright/test';
import { membershipRow, OWNER, SHOP, TECH } from './support/fixtures';
import { mockSupabase, reply } from './support/mockSupabase';

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

const INVOICE_ID = '90000000-0000-4000-8000-000000000001';

const INVOICE = {
  id: INVOICE_ID,
  shop_id: SHOP.id,
  number: 2001,
  job_id: 'a0000000-0000-4000-8000-000000000001',
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
  tip_cents: 1500,
  public_token: '50000000-0000-4000-8000-000000000001',
  created_by: null,
  created_at: '2026-09-20T15:00:00Z',
  updated_at: '2026-09-20T15:00:00Z',
  customer: CUSTOMER,
};

const LINE = {
  id: 'b0000000-0000-4000-8000-000000000001',
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

const PAYMENT = {
  id: 'c0000000-0000-4000-8000-000000000001',
  shop_id: SHOP.id,
  invoice_id: INVOICE_ID,
  job_id: INVOICE.job_id,
  customer_id: CUSTOMER.id,
  membership_id: null,
  kind: 'deposit',
  method: 'card',
  status: 'succeeded',
  amount_cents: 10000,
  tip_cents: 1500,
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
};

async function setup(page: Page, role: 'owner' | 'technician' = 'owner') {
  const user = role === 'owner' ? OWNER : TECH;
  const rpcCalls: { name: string; body: unknown }[] = [];
  const functionCalls: unknown[] = [];
  await mockSupabase(page, {
    user,
    tables: {
      shop_members: [membershipRow(user, role, { ...SHOP, techs_can_collect_payments: true })],
      notifications: [],
      invoices: [INVOICE],
      invoice_line_items: [LINE],
      payments: [PAYMENT],
      customers: [CUSTOMER],
      vehicles: [],
      customer_payment_methods: [
        {
          id: 'd0000000-0000-4000-8000-000000000001',
          stripe_payment_method_id: 'pm_123',
          brand: 'visa',
          last4: '4242',
          exp_month: 4,
          exp_year: 2030,
          is_default: true,
        },
      ],
    },
    rpc: {
      record_manual_payment: ({ body }) => {
        rpcCalls.push({ name: 'record_manual_payment', body });
        return { ...PAYMENT, id: 'c0000000-0000-4000-8000-000000000002', method: 'cash' };
      },
    },
    functions: {
      payments: ({ body }) => {
        functionCalls.push(body);
        return reply(402, {
          error:
            "The card's bank requires the customer to confirm this payment. Send them a payment link instead.",
          code: 'payment_failed',
          details: { reason: 'authentication_required' },
        });
      },
    },
  });
  return { rpcCalls, functionCalls };
}

test.describe('invoices', () => {
  test('owner records a cash payment against the balance', async ({ page }) => {
    const { rpcCalls } = await setup(page);
    await page.goto(`/app/invoices/${INVOICE_ID}`);
    await expect(page.getByRole('heading', { name: 'Invoice #2001', level: 1 })).toBeVisible();
    await expect(page.getByText('Visa •••• 4242')).toBeVisible();
    await page.getByRole('button', { name: 'Record payment' }).click();
    const dialog = page.getByRole('dialog');
    await expect(dialog.getByLabel(/^Amount/)).toHaveValue('200.00');
    await dialog.getByLabel(/^Amount/).fill('50');
    await dialog.getByRole('button', { name: 'Record payment' }).click();
    await expect(page.getByText('$50.00 payment recorded')).toBeVisible();
    expect(rpcCalls).toEqual([
      {
        name: 'record_manual_payment',
        body: { p_invoice_id: INVOICE_ID, p_amount_cents: 5000, p_method: 'cash', p_tip_cents: 0 },
      },
    ]);
  });

  test('charging a saved card that needs authentication offers the pay link', async ({ page }) => {
    const { functionCalls } = await setup(page);
    await page.goto(`/app/invoices/${INVOICE_ID}`);
    await page.getByRole('button', { name: 'Charge card' }).click();
    const dialog = page.getByRole('dialog');
    await dialog.getByRole('button', { name: 'Charge $200.00' }).click();
    await expect(
      dialog.getByText('The bank wants the customer to confirm this payment.'),
    ).toBeVisible();
    await expect(dialog.getByRole('button', { name: 'Text the pay link' })).toBeVisible();
    expect(functionCalls[0]).toMatchObject({
      action: 'charge_saved_card',
      shop_id: SHOP.id,
      invoice_id: INVOICE_ID,
      payment_method_id: 'pm_123',
      amount_cents: 20000,
    });
  });

  test('technician allowed to collect sees only collection actions', async ({ page }) => {
    await setup(page, 'technician');
    await page.goto(`/app/invoices/${INVOICE_ID}`);
    await expect(page.getByRole('heading', { name: 'Invoice #2001', level: 1 })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Record payment' })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Charge card' })).toHaveCount(0);
    await expect(page.getByRole('button', { name: /Refund/ })).toHaveCount(0);
    // the only extra action is the invoice PDF (collectors may open their job's invoice)
    await page.getByRole('button', { name: 'More invoice actions' }).click();
    await expect(page.getByRole('menuitem')).toHaveText(['Download PDF']);
  });

  test('invoice list fits a 360px phone', async ({ page }) => {
    await page.setViewportSize({ width: 360, height: 740 });
    await setup(page);
    await page.goto('/app/invoices');
    await expect(page.getByRole('link', { name: 'Invoice #2001' }).first()).toBeVisible();
    const overflow = await page.evaluate(
      () => document.documentElement.scrollWidth - window.innerWidth,
    );
    expect(overflow).toBeLessThanOrEqual(0);
  });
});
