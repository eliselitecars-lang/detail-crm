import { expect, test, type Page, type Route } from '@playwright/test';
import { membershipRow, OWNER, SHOP, type MockUser, type Role } from './support/fixtures';
import { mockSupabase, SUPABASE_URL } from './support/mockSupabase';

const MANAGER: MockUser = {
  id: '00000000-0000-4000-8000-000000000003',
  email: 'manager@glacier.test',
  fullName: 'Mara Manager',
};

const SHOP_ROW = {
  ...SHOP,
  email: 'hello@glacier.test',
  phone: '+12055550100',
  website: null,
  address_line1: null,
  address_line2: null,
  city: 'Birmingham',
  region: 'AL',
  postal_code: '35203',
  country: 'US',
  review_url: 'https://g.page/r/glacier',
  quote_terms: null,
  invoice_terms: null,
  invoice_due_days: 0,
  sms_from_number: null,
  updated_at: '2026-01-01T00:00:00Z',
};

const BOOKING_SETTINGS = {
  shop_id: SHOP.id,
  enabled: true,
  auto_confirm: false,
  lead_time_minutes: 120,
  max_days_ahead: 60,
  slot_interval_minutes: 30,
  buffer_minutes: 0,
  max_concurrent_jobs: 1,
  require_deposit: false,
  deposit_type: 'percent',
  deposit_value: 0,
  service_area_postal_codes: [],
  booking_message: null,
  cancellation_policy: null,
  allow_client_cancel_hours: 24,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const TEMPLATES = [
  {
    id: '30000000-0000-4000-8000-000000000001',
    key: 'appointment_reminder',
    channel: 'sms',
    subject: null,
    body: 'Reminder: your appointment with {{shop_name}} is on {{job_date}}.',
    enabled: true,
    offset_minutes: -1440,
    updated_at: '2026-01-01T00:00:00Z',
  },
];

interface Recorded {
  shopPatches: unknown[];
  membershipLoads: number;
}

async function setup(page: Page, user: MockUser, role: Role): Promise<Recorded> {
  const recorded: Recorded = { shopPatches: [], membershipLoads: 0 };
  let shop = { ...SHOP_ROW };
  await mockSupabase(page, {
    user,
    tables: {
      shop_members: () => {
        recorded.membershipLoads += 1;
        return [membershipRow(user, role, { ...SHOP, name: shop.name })];
      },
      notifications: [],
      shops: ({ method, body }) => {
        if (method === 'PATCH') {
          recorded.shopPatches.push(body);
          shop = { ...shop, ...(body as object), updated_at: '2026-01-02T00:00:00Z' };
        }
        return [shop];
      },
      booking_settings: [BOOKING_SETTINGS],
      message_templates: TEMPLATES,
    },
  });
  return recorded;
}

async function stripeConnect(
  page: Page,
  status: Record<string, unknown>,
  calls: Record<string, unknown>[] = [],
) {
  await page.route(`${SUPABASE_URL}/functions/v1/stripe-connect`, async (route: Route) => {
    const headers = {
      'access-control-allow-origin': '*',
      'access-control-allow-headers': '*',
      'access-control-allow-methods': 'POST, OPTIONS',
    };
    if (route.request().method() === 'OPTIONS') {
      await route.fulfill({ status: 204, headers });
      return;
    }
    const body = (route.request().postDataJSON() ?? {}) as Record<string, unknown>;
    calls.push(body);
    const response =
      body.action === 'refresh_status'
        ? status
        : { url: 'https://connect.stripe.test/onboarding/acct_1', expires_at: 0 };
    await route.fulfill({
      status: 200,
      contentType: 'application/json',
      headers,
      body: JSON.stringify(response),
    });
  });
}

test.describe('settings', () => {
  test('owner edits the business profile and the shell reloads the shop', async ({ page }) => {
    const recorded = await setup(page, OWNER, 'owner');
    await page.goto('/app/settings');
    await expect(page).toHaveURL(/\/app\/settings\/business$/);
    await expect(page.getByRole('heading', { name: 'Business profile', level: 2 })).toBeVisible();

    const name = page.getByLabel('Business name');
    await expect(name).toHaveValue('Glacier Detailing');
    await name.fill('Glacier Auto Spa');
    await page.getByLabel('Website').fill('glacier.test');
    const loadsBefore = recorded.membershipLoads;
    await page.getByRole('button', { name: 'Save changes' }).click();

    await expect(page.getByText('Business profile saved')).toBeVisible();
    expect(recorded.shopPatches[0]).toMatchObject({
      name: 'Glacier Auto Spa',
      website: 'https://glacier.test',
      timezone: 'America/Chicago',
    });
    await expect.poll(() => recorded.membershipLoads).toBeGreaterThan(loadsBefore);
    await expect(page.getByText('All changes saved.')).toBeVisible();
  });

  test('booking link and message template preview', async ({ page }) => {
    await setup(page, OWNER, 'owner');
    await page.goto('/app/settings/booking');
    await expect(page.getByLabel('Booking link', { exact: true })).toContainText(
      '/book/glacier-detailing',
    );
    await expect(page.getByText('Taking bookings')).toBeVisible();

    await page
      .getByRole('navigation', { name: 'Settings' })
      .getByRole('link', { name: 'Messages & automations' })
      .click();
    await expect(page.getByText('1 day before the appointment')).toBeVisible();
    await page.getByRole('button', { name: 'Edit Appointment reminder' }).click();
    const dialog = page.getByRole('dialog', { name: 'Appointment reminder' });
    await expect(dialog.getByRole('region', { name: 'Preview' })).toContainText(
      'Reminder: your appointment with Glacier Detailing is on [appointment date].',
    );
    await dialog.getByRole('button', { name: 'Shop phone' }).click();
    await expect(dialog.getByRole('region', { name: 'Preview' })).toContainText('(205) 555-0100');
  });

  test('Stripe Connect onboarding redirect and return', async ({ page }) => {
    await setup(page, OWNER, 'owner');
    const calls: Record<string, unknown>[] = [];
    await stripeConnect(
      page,
      {
        connected: false,
        stripe_account_id: null,
        charges_enabled: false,
        payouts_enabled: false,
        details_submitted: false,
      },
      calls,
    );
    await page.route('https://connect.stripe.test/**', (route) =>
      route.fulfill({ status: 200, contentType: 'text/html', body: '<h1>Stripe onboarding</h1>' }),
    );

    await page.goto('/app/settings/payments');
    await expect(page.getByText('Not connected')).toBeVisible();
    await page.getByRole('button', { name: 'Connect Stripe' }).click();
    await expect(page).toHaveURL('https://connect.stripe.test/onboarding/acct_1');
    expect(calls.map((c) => c.action)).toEqual(['refresh_status', 'create_account_link']);
    expect(calls[1]).toMatchObject({ shop_id: SHOP.id });
  });

  test('returning from Stripe refreshes the status and clears the query', async ({ page }) => {
    await setup(page, OWNER, 'owner');
    await stripeConnect(page, {
      connected: true,
      stripe_account_id: 'acct_1',
      charges_enabled: false,
      payouts_enabled: false,
      details_submitted: true,
    });
    await page.goto('/app/settings/payments?stripe=return');
    await expect(page.getByText('Details submitted — waiting on Stripe')).toBeVisible();
    await expect(page.getByText(/Stripe is reviewing your details/)).toBeVisible();
    await expect(page).toHaveURL(/\/app\/settings\/payments$/);
    await expect(page.getByRole('button', { name: 'Open Stripe dashboard' })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Continue onboarding' })).toBeVisible();
  });

  test('manager sees read-only settings and no Stripe or SMS', async ({ page }) => {
    await setup(page, MANAGER, 'manager');
    await page.goto('/app/settings/business');
    await expect(page.getByText(/Only the owner or an admin can change them/)).toBeVisible();
    await expect(page.getByLabel('Business name')).toBeDisabled();
    const nav = page.getByRole('navigation', { name: 'Settings' });
    await expect(nav.getByRole('link', { name: 'Blocked times' })).toBeVisible();
    await expect(nav.getByRole('link', { name: 'Payments' })).toHaveCount(0);
    await expect(nav.getByRole('link', { name: 'SMS' })).toHaveCount(0);

    await page.goto('/app/settings/sms');
    await expect(page.getByText('You don’t have access to this page')).toBeVisible();
  });

  test('fits a 360px phone without horizontal scrolling', async ({ page }) => {
    await page.setViewportSize({ width: 360, height: 780 });
    await setup(page, OWNER, 'owner');
    for (const path of [
      '/app/settings/business',
      '/app/settings/booking',
      '/app/settings/hours',
      '/app/settings/blocked-times',
      '/app/settings/resources',
      '/app/settings/taxes',
      '/app/settings/vehicle-categories',
      '/app/settings/coupons',
      '/app/settings/templates',
      '/app/settings/forms',
      '/app/settings/sms',
    ]) {
      await page.goto(path);
      await expect(page.getByRole('navigation', { name: 'Settings' })).toBeVisible();
      await expect(page.getByRole('heading', { level: 2 }).first()).toBeVisible();
      const overflow = await page.evaluate(
        () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
      );
      expect(overflow, path).toBeLessThanOrEqual(0);
    }
  });
});
