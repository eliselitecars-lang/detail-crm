import { expect, test } from '@playwright/test';
import { membershipRow, OWNER, SHOP } from './support/fixtures';
import { mockSupabase } from './support/mockSupabase';

const PAYMENT = {
  id: 'c0000000-0000-4000-8000-000000000001',
  kind: 'payment',
  method: 'cash',
  status: 'succeeded',
  amount_cents: 12500,
  tip_cents: 1000,
  refunded_cents: 0,
  card_brand: null,
  card_last4: null,
  stripe_method_type: null,
  note: 'Paid at pickup',
  paid_at: '2026-09-21T15:00:00Z',
  created_at: '2026-09-21T15:00:00Z',
  invoice_id: '90000000-0000-4000-8000-000000000001',
  job_id: null,
  membership_id: null,
  customer_id: '30000000-0000-4000-8000-000000000001',
  customer: {
    id: '30000000-0000-4000-8000-000000000001',
    first_name: 'Jane',
    last_name: 'Doe',
    company: null,
  },
  invoice: { id: '90000000-0000-4000-8000-000000000001', number: 2001 },
  job: null,
};

const METHODS = ['card', 'card_present', 'cash', 'check', 'bank_transfer', 'other'];

test('payments ledger shows server totals and exports CSV', async ({ page }) => {
  let reportArgs: unknown = null;
  await mockSupabase(page, {
    user: OWNER,
    tables: {
      shop_members: [membershipRow(OWNER, 'owner', SHOP)],
      notifications: [],
      payments: [PAYMENT],
    },
    rpc: {
      report_payments: ({ body }) => {
        reportArgs = body;
        return METHODS.map((method) => ({
          method,
          payments_count: method === 'cash' ? 1 : 0,
          gross_cents: method === 'cash' ? 12500 : 0,
          refunds_cents: 0,
          net_cents: method === 'cash' ? 12500 : 0,
          tips_cents: method === 'cash' ? 1000 : 0,
          tip_refunds_cents: 0,
          collected_cents: method === 'cash' ? 13500 : 0,
          deposits_cents: 0,
          memberships_cents: 0,
        }));
      },
    },
  });
  await page.goto('/app/payments?from=2026-09-01&to=2026-09-30');
  await expect(page.getByRole('heading', { name: 'Payments', level: 1 })).toBeVisible();
  await expect(page.getByRole('link', { name: 'Invoice #2001' }).first()).toBeVisible();
  await expect(page.getByText('$135.00')).toBeVisible();
  expect(reportArgs).toEqual({ p_shop_id: SHOP.id, p_from: '2026-09-01', p_to: '2026-09-30' });

  const download = page.waitForEvent('download');
  await page.getByRole('button', { name: 'Export CSV' }).click();
  const file = await download;
  expect(file.suggestedFilename()).toBe('payments-2026-09-01-to-2026-09-30.csv');
  const stream = await file.createReadStream();
  const chunks: Buffer[] = [];
  for await (const chunk of stream) chunks.push(chunk as Buffer);
  const text = Buffer.concat(chunks)
    .toString('utf8')
    .replace(/^\uFEFF/, '');
  expect(text.split('\r\n')[1]).toBe(
    '2026-09-21 10:00,Jane Doe,2001,,Payment,Cash,,,succeeded,125.00,10.00,0.00,Paid at pickup',
  );
});

test('payments filters fit a 360px phone', async ({ page }) => {
  await page.setViewportSize({ width: 360, height: 740 });
  await mockSupabase(page, {
    user: OWNER,
    tables: {
      shop_members: [membershipRow(OWNER, 'owner', SHOP)],
      notifications: [],
      payments: [PAYMENT],
    },
    rpc: { report_payments: [] },
  });
  await page.goto('/app/payments');
  await expect(page.getByRole('button', { name: 'Export CSV' })).toBeVisible();
  const overflow = await page.evaluate(
    () => document.documentElement.scrollWidth - window.innerWidth,
  );
  expect(overflow).toBeLessThanOrEqual(0);
});
