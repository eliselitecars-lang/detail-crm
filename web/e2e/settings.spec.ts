import { readFileSync } from 'node:fs';
import { expect, test, type Page } from '@playwright/test';
import { membershipRow, OWNER, SHOP, TECH, type MockUser, type Role } from './support/fixtures';
import { mockSupabase, type Json } from './support/mockSupabase';

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
  techs_can_share_reports: false,
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
  max_concurrent_shop: null,
  max_concurrent_mobile: null,
  count_member_availability: false,
  allow_multi_day: false,
  multi_day_max_days: 2,
  quote_self_schedule: false,
  meta_pixel_id: null,
  ga4_measurement_id: null,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const FOLLOWUP_SETTINGS = {
  shop_id: SHOP.id,
  quote_enabled: false,
  quote_first_after_hours: 48,
  quote_repeat_every_hours: 72,
  quote_max_attempts: 2,
  deposit_enabled: false,
  deposit_first_after_hours: 24,
  deposit_repeat_every_hours: 48,
  deposit_max_attempts: 2,
  invoice_enabled: false,
  invoice_first_after_hours: 72,
  invoice_repeat_every_hours: 168,
  invoice_max_attempts: 2,
  overdue_enabled: false,
  overdue_first_after_days: 1,
  overdue_repeat_every_days: 7,
  overdue_max_attempts: 3,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const GIFT_CARD_SETTINGS = {
  shop_id: SHOP.id,
  online_enabled: false,
  offers: [],
  allow_custom_amount: false,
  min_custom_cents: 1000,
  max_custom_cents: 50000,
  expires_months: null,
  terms: null,
  updated_at: '2026-01-01T00:00:00Z',
};

const REFERRAL_SETTINGS = {
  shop_id: SHOP.id,
  enabled: false,
  referee_discount_kind: 'fixed',
  referee_discount_value: 0,
  referrer_reward_cents: 0,
  terms: null,
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
    reminder_offsets_minutes: null,
    updated_at: '2026-01-01T00:00:00Z',
  },
];

interface Recorded {
  shopPatches: unknown[];
  membershipLoads: number;
  feeInserts: unknown[];
  rpcCalls: { name: string; body: unknown }[];
}

interface SetupOptions {
  /** Answers of the stripe-connect function (refresh_status → this status). */
  stripeStatus?: Record<string, Json>;
  /** Bodies the stripe-connect function received. */
  connectCalls?: Record<string, unknown>[];
}

async function setup(
  page: Page,
  user: MockUser,
  role: Role,
  { stripeStatus, connectCalls = [] }: SetupOptions = {},
): Promise<Recorded> {
  const recorded: Recorded = { shopPatches: [], membershipLoads: 0, feeInserts: [], rpcCalls: [] };
  let feed: Record<string, Json> | null = null;
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
      followup_settings: [FOLLOWUP_SETTINGS],
      gift_card_settings: [GIFT_CARD_SETTINGS],
      referral_settings: [REFERRAL_SETTINGS],
      calendar_feed_tokens: () => (feed ? [feed] : []),
      shop_fees: ({ method, body }) => {
        if (method === 'POST') recorded.feeInserts.push(body);
        return [];
      },
    },
    rpc: {
      create_calendar_feed: ({ body }) => {
        recorded.rpcCalls.push({ name: 'create_calendar_feed', body });
        feed = {
          id: 'feed-1',
          token: '44444444-4444-4444-8444-444444444444',
          include_all: false,
          created_at: '2026-01-01T00:00:00Z',
          last_accessed_at: null,
        };
        return {
          token: '44444444-4444-4444-8444-444444444444',
          path: '/functions/v1/calendar-feed?token=44444444-4444-4444-8444-444444444444',
        };
      },
    },
    functions: stripeStatus
      ? {
          'stripe-connect': ({ body }) => {
            const call = (body ?? {}) as Record<string, unknown>;
            connectCalls.push(call);
            return call.action === 'refresh_status'
              ? stripeStatus
              : { url: 'https://connect.stripe.com/onboarding/acct_1', expires_at: 0 };
          },
        }
      : {},
  });
  return recorded;
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
    const calls: Record<string, unknown>[] = [];
    await setup(page, OWNER, 'owner', {
      stripeStatus: {
        connected: false,
        stripe_account_id: null,
        charges_enabled: false,
        payouts_enabled: false,
        details_submitted: false,
      },
      connectCalls: calls,
    });
    await page.route('https://connect.stripe.com/**', (route) =>
      route.fulfill({ status: 200, contentType: 'text/html', body: '<h1>Stripe onboarding</h1>' }),
    );

    await page.goto('/app/settings/payments');
    await expect(page.getByText('Not connected')).toBeVisible();
    await page.getByRole('button', { name: 'Connect Stripe' }).click();
    await expect(page).toHaveURL('https://connect.stripe.com/onboarding/acct_1');
    expect(calls.map((c) => c.action)).toEqual(['refresh_status', 'create_account_link']);
    expect(calls[1]).toMatchObject({ shop_id: SHOP.id });
  });

  test('returning from Stripe refreshes the status and clears the query', async ({ page }) => {
    await setup(page, OWNER, 'owner', {
      stripeStatus: {
        connected: true,
        stripe_account_id: 'acct_1',
        charges_enabled: false,
        payouts_enabled: false,
        details_submitted: true,
      },
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
    await expect(nav.getByRole('link', { name: 'Closures & time off' })).toBeVisible();
    await expect(nav.getByRole('link', { name: 'Webhooks' })).toHaveCount(0);
    await expect(nav.getByRole('link', { name: 'Payments' })).toHaveCount(0);
    await expect(nav.getByRole('link', { name: 'SMS' })).toHaveCount(0);

    await page.goto('/app/settings/sms');
    await expect(page.getByText('You don’t have access to this page')).toBeVisible();
  });

  test('technician makes a personal calendar feed', async ({ page }) => {
    const recorded = await setup(page, TECH, 'technician');
    await page.goto('/app/settings');
    await expect(page).toHaveURL(/\/app\/settings\/calendar-feed$/);
    const nav = page.getByRole('navigation', { name: 'Settings' });
    await expect(nav.getByRole('link')).toHaveText(['Calendar feed']);
    await page.getByRole('button', { name: 'Create my calendar link' }).click();
    await expect(page.getByLabel('Calendar link', { exact: true })).toContainText(
      'https://e2e-mock.supabase.co/functions/v1/calendar-feed?token=44444444-4444-4444-8444-444444444444',
    );
    expect(recorded.rpcCalls).toEqual([
      { name: 'create_calendar_feed', body: { p_shop_id: SHOP.id, p_include_all: false } },
    ]);
  });

  test('owner adds a travel fee', async ({ page }) => {
    const recorded = await setup(page, OWNER, 'owner');
    await page.goto('/app/settings/fees');
    await expect(page.getByText('No fees yet')).toBeVisible();
    await page.getByRole('button', { name: 'Add fee' }).first().click();
    const dialog = page.getByRole('dialog', { name: 'New fee' });
    await dialog.getByLabel('Name').fill('Travel fee');
    await dialog.getByLabel('Amount').fill('35');
    await dialog.getByLabel('When to add it').selectOption('mobile');
    await dialog.getByRole('button', { name: 'Add fee' }).click();
    await expect(page.getByText('Fee added')).toBeVisible();
    expect(recorded.feeInserts.flat()).toEqual([
      {
        name: 'Travel fee',
        amount_cents: 3500,
        taxable: false,
        auto_apply: 'mobile',
        active: true,
        sort: 1,
        shop_id: SHOP.id,
      },
    ]);
  });

  // One test per page (each is a full app load): every test stays far inside
  // the timeout with several workers, and a failure names its page. The pages
  // are read from the settings registry, so a new section is covered too.
  const PHONE_ROUTES = [
    ...readFileSync(
      new URL('../src/features/settings/sections.ts', import.meta.url),
      'utf8',
    ).matchAll(/^\s+path: '([a-z-]+)',$/gm),
  ].map((m) => m[1] ?? '');
  test('covers every settings section at phone width', () => {
    expect(PHONE_ROUTES.length).toBeGreaterThanOrEqual(23);
    expect(PHONE_ROUTES).toEqual(expect.arrayContaining(['business', 'delete-shop']));
  });
  for (const section of PHONE_ROUTES) {
    test(`fits a 360px phone without horizontal scrolling: ${section}`, async ({ page }) => {
      await page.setViewportSize({ width: 360, height: 780 });
      await setup(page, OWNER, 'owner');
      await page.goto(`/app/settings/${section}`);
      await expect(page.getByRole('navigation', { name: 'Settings' })).toBeVisible();
      await expect(page.getByRole('heading', { level: 2 }).first()).toBeVisible();
      const overflow = await page.evaluate(
        () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
      );
      expect(overflow).toBeLessThanOrEqual(0);
    });
  }
});
