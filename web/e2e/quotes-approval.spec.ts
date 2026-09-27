import { expect, test } from '@playwright/test';
import { membershipRow, OWNER, SHOP } from './support/fixtures';
import { mockSupabase } from './support/mockSupabase';

/** Staff recording a phone approval also record the optional upsells chosen. */

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

const QUOTE_ID = '60000000-0000-4000-8000-000000000021';

const QUOTE = {
  id: QUOTE_ID,
  shop_id: SHOP.id,
  number: 1021,
  customer_id: CUSTOMER.id,
  vehicle_id: null,
  status: 'sent',
  valid_until: null,
  notes: null,
  terms: null,
  internal_notes: null,
  discount_kind: 'none',
  discount_value: 0,
  tax_rate_bps: 0,
  subtotal_cents: 25000,
  discount_cents: 0,
  tax_cents: 0,
  total_cents: 25000,
  public_token: '40000000-0000-4000-8000-000000000021',
  sent_at: '2026-09-21T15:00:00Z',
  viewed_at: null,
  approved_at: null,
  approved_by_name: null,
  declined_at: null,
  declined_reason: null,
  expired_at: null,
  converted_at: null,
  converted_job_id: null,
  created_by: null,
  created_at: '2026-09-20T15:00:00Z',
  updated_at: '2026-09-20T15:00:00Z',
};

function line(overrides: Record<string, unknown>) {
  return {
    id: '70000000-0000-4000-8000-000000000021',
    shop_id: SHOP.id,
    quote_id: QUOTE_ID,
    service_id: null,
    vehicle_id: null,
    name: 'Full detail',
    description: null,
    quantity: 1,
    unit_price_cents: 25000,
    discount_cents: 0,
    taxable: true,
    duration_minutes: 180,
    optional: false,
    selected: true,
    sort: 1,
    total_cents: 25000,
    created_at: '2026-09-20T15:00:00Z',
    updated_at: '2026-09-20T15:00:00Z',
    ...overrides,
  };
}

const TOP_UP = line({
  id: '70000000-0000-4000-8000-000000000022',
  name: 'Ceramic top-up',
  optional: true,
  selected: false,
  unit_price_cents: 5000,
  total_cents: 5000,
  sort: 2,
});

test('recording a phone approval keeps the optional upsell the customer chose', async ({
  page,
}) => {
  const writes: { table: string; url: string; body: unknown }[] = [];
  await mockSupabase(page, {
    user: OWNER,
    tables: {
      shop_members: [membershipRow(OWNER, 'owner')],
      notifications: [],
      quotes: ({ url, method, body }) => {
        if (method === 'PATCH') {
          writes.push({ table: 'quotes', url: url.search, body });
          return [{ ...QUOTE, status: 'approved' }];
        }
        return [QUOTE];
      },
      quote_line_items: ({ url, method, body }) => {
        if (method === 'PATCH') {
          writes.push({ table: 'quote_line_items', url: url.search, body });
          return [];
        }
        return [line({}), TOP_UP];
      },
      customers: [CUSTOMER],
      vehicles: [],
    },
  });
  await page.goto(`/app/quotes/${QUOTE_ID}`);
  await page.getByRole('button', { name: 'More quote actions' }).click();
  await page.getByRole('menuitem', { name: /Mark approved/ }).click();
  const dialog = page.getByRole('dialog', { name: 'Mark quote as approved' });
  await dialog.getByRole('checkbox', { name: 'Ceramic top-up' }).check();
  await dialog.getByLabel(/Approved by/).fill('Jane by phone');
  await dialog.getByRole('button', { name: 'Mark approved' }).click();
  await expect(page.getByText('Quote marked approved')).toBeVisible();

  expect(writes.map((w) => w.table)).toEqual(['quote_line_items', 'quotes']);
  expect(writes[0]?.body).toEqual({ selected: true });
  expect(writes[0]?.url).toContain(`id=eq.${TOP_UP.id}`);
  expect(writes[0]?.url).toContain('optional=eq.true');
  expect(writes[1]?.body).toEqual({ status: 'approved', approved_by_name: 'Jane by phone' });
});
