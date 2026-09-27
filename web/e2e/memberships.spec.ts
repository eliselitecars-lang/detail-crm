import { expect, test } from '@playwright/test';
import { membershipRow, OWNER, SHOP } from './support/fixtures';
import { mockSupabase } from './support/mockSupabase';

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

const PLAN = {
  id: 'e0000000-0000-4000-8000-000000000001',
  shop_id: SHOP.id,
  name: 'Maintenance Club',
  description: null,
  price_cents: 4900,
  interval: 'month',
  interval_count: 1,
  included_service_ids: [],
  discount_bps: 1000,
  active: true,
  sort: 0,
  stripe_product_id: null,
  stripe_price_id: null,
  archived_at: null,
  created_at: '2026-09-01T15:00:00Z',
  updated_at: '2026-09-01T15:00:00Z',
};

test('owner signs a customer up and gets a checkout link', async ({ page }) => {
  let created: unknown = null;
  const functionCalls: unknown[] = [];
  await mockSupabase(page, {
    user: OWNER,
    tables: {
      shop_members: [membershipRow(OWNER, 'owner', SHOP)],
      notifications: [],
      memberships: [],
      membership_plans: [PLAN],
      customers: [CUSTOMER],
      vehicles: [],
    },
    rpc: {
      create_membership: ({ body }) => {
        created = body;
        return {
          id: 'f0000000-0000-4000-8000-000000000001',
          shop_id: SHOP.id,
          plan_id: PLAN.id,
          customer_id: CUSTOMER.id,
          vehicle_id: null,
          status: 'incomplete',
        };
      },
    },
    functions: {
      payments: ({ body }) => {
        functionCalls.push(body);
        return {
          url: 'https://checkout.stripe.com/c/pay/cs_test_1',
          expires_at: 1790000000,
          amount_cents: 4900,
          interval: 'month',
          interval_count: 1,
          currency: 'usd',
        };
      },
    },
  });

  await page.goto('/app/memberships');
  await expect(page.getByText('No memberships yet')).toBeVisible();
  await page.getByRole('button', { name: 'New membership' }).first().click();
  const dialog = page.getByRole('dialog', { name: 'New membership' });
  await dialog.getByRole('combobox', { name: /Customer/ }).click();
  await page.getByRole('option', { name: /Jane Doe/ }).click();
  await dialog.getByLabel(/^Plan/).selectOption(PLAN.id);
  await dialog.getByRole('button', { name: 'Create membership' }).click();

  const checkout = page.getByRole('dialog', { name: 'Membership checkout link' });
  await checkout.getByRole('button', { name: 'Create checkout link' }).click();
  await expect(checkout.getByRole('textbox', { name: 'Checkout link' })).toHaveValue(
    'https://checkout.stripe.com/c/pay/cs_test_1',
  );
  expect(created).toEqual({ p_plan_id: PLAN.id, p_customer_id: CUSTOMER.id });
  expect(functionCalls[0]).toMatchObject({
    action: 'membership_checkout',
    shop_id: SHOP.id,
    membership_id: 'f0000000-0000-4000-8000-000000000001',
  });
});

test('plans tab lists plans', async ({ page }) => {
  await mockSupabase(page, {
    user: OWNER,
    tables: {
      shop_members: [membershipRow(OWNER, 'owner', SHOP)],
      notifications: [],
      membership_plans: [PLAN],
    },
  });
  await page.goto('/app/memberships?tab=plans');
  await expect(page.getByText('Maintenance Club').first()).toBeVisible();
  await expect(page.getByText('$49.00 / month').first()).toBeVisible();
});
