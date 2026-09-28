import { expect, test } from '@playwright/test';
import type { MockUser } from './support/fixtures';
import { mockSupabase, reply } from './support/mockSupabase';

/** Client portal (/portal) against a mocked backend. */

const CLIENT: MockUser = {
  id: '00000000-0000-4000-8000-0000000000c1',
  email: 'ana@example.com',
  fullName: 'Ana Diaz',
};

const JOB_TOKEN = '61111111-1111-4111-8111-111111111111';
const PAST_TOKEN = '61111111-1111-4111-8111-111111111112';
const QUOTE_TOKEN = '62222222-2222-4222-8222-222222222222';
const INVOICE_TOKEN = '63333333-3333-4333-8333-333333333333';

const OVERVIEW = {
  shops: [
    {
      slug: 'glacier',
      name: 'Glacier Detailing',
      logo_path: null,
      brand_color: '#1F6FEB',
      phone: '+12055550100',
      email: 'hello@glacier.test',
      website: null,
      city: 'Birmingham',
      region: 'AL',
      timezone: 'America/Chicago',
      currency: 'usd',
      booking_enabled: true,
    },
  ],
  customers: [
    {
      shop_slug: 'glacier',
      first_name: 'Ana',
      last_name: 'Diaz',
      company: null,
      email: CLIENT.email,
      phone: null,
      sms_opt_in: false,
      email_opt_in: false,
    },
  ],
  vehicles: [
    {
      id: '64444444-4444-4444-8444-444444444444',
      shop_slug: 'glacier',
      year: 2021,
      make: 'Toyota',
      model: 'Camry',
      trim: null,
      color: 'Blue',
      license_plate: null,
      category_id: null,
      category_name: 'Sedan',
    },
  ],
  upcoming_jobs: [
    {
      token: JOB_TOKEN,
      shop_slug: 'glacier',
      number: 1042,
      status: 'confirmed',
      scheduled_start: '2099-10-01T15:00:00Z',
      scheduled_end: '2099-10-01T17:30:00Z',
      location_type: 'shop',
      vehicle: '2021 Toyota Camry',
      services: 'Full detail, Hand wax',
      total_cents: 19000,
      deposit_required_cents: 3800,
    },
  ],
  past_jobs: [
    {
      token: PAST_TOKEN,
      shop_slug: 'glacier',
      number: 1001,
      status: 'completed',
      scheduled_start: '2026-03-01T15:00:00Z',
      scheduled_end: '2026-03-01T17:00:00Z',
      completed_at: '2026-03-01T17:00:00Z',
      location_type: 'shop',
      vehicle: '2021 Toyota Camry',
      services: 'Full detail',
      total_cents: 15000,
    },
  ],
  quotes: [
    {
      token: QUOTE_TOKEN,
      shop_slug: 'glacier',
      number: 301,
      status: 'sent',
      total_cents: 58000,
      valid_until: '2099-12-31',
      sent_at: '2026-09-20T15:00:00Z',
      vehicle: '2021 Toyota Camry',
    },
  ],
  invoices: [
    {
      token: INVOICE_TOKEN,
      shop_slug: 'glacier',
      number: 2001,
      status: 'partially_paid',
      total_cents: 30000,
      amount_paid_cents: 10000,
      balance_cents: 20000,
      issued_at: '2026-09-20T15:00:00Z',
      due_at: '2099-10-20T15:00:00Z',
    },
  ],
  memberships: [],
};

const EMPTY = {
  shops: [],
  customers: [],
  vehicles: [],
  upcoming_jobs: [],
  past_jobs: [],
  quotes: [],
  invoices: [],
  memberships: [],
};

test.describe('client portal', () => {
  test('signed-out visitors are sent to sign in and come back to the portal', async ({ page }) => {
    await mockSupabase(page, {
      accounts: [CLIENT],
      rpc: { portal_claim_customers: 0, portal_overview: OVERVIEW },
    });
    await page.goto('/portal');
    await expect(page).toHaveURL(/\/login\?next=%2Fportal$/);
    await page.getByLabel('Email').fill(CLIENT.email);
    await page.getByLabel(/^Password/).fill('correct-horse');
    await page.getByRole('button', { name: 'Sign in' }).click();
    await expect(page.getByRole('heading', { name: 'My account', level: 1 })).toBeVisible();
  });

  test('claims records, then lists appointments, quotes, invoices and vehicles', async ({
    page,
  }) => {
    const order: string[] = [];
    await mockSupabase(page, {
      user: CLIENT,
      rpc: {
        portal_claim_customers: () => {
          order.push('claim');
          return 1;
        },
        portal_overview: () => {
          order.push('overview');
          return OVERVIEW;
        },
      },
    });
    await page.goto('/portal');
    await expect(page.getByRole('heading', { name: 'My account', level: 1 })).toBeVisible();
    await expect(page.getByText(`Signed in as ${CLIENT.email}`)).toBeVisible();

    const upcoming = page.getByRole('list', { name: 'Upcoming appointments' });
    await expect(upcoming.getByRole('link')).toHaveAttribute('href', `/booking/${JOB_TOKEN}`);
    await expect(upcoming).toContainText('Full detail, Hand wax');
    await expect(
      page.getByRole('list', { name: 'Past appointments' }).getByRole('link'),
    ).toHaveAttribute('href', `/booking/${PAST_TOKEN}`);
    const invoices = page.getByRole('list', { name: 'Invoices' });
    await expect(invoices.getByRole('link')).toHaveAttribute('href', `/i/${INVOICE_TOKEN}`);
    await expect(invoices).toContainText('$200.00 due');
    await expect(page.getByRole('list', { name: 'Quotes' }).getByRole('link')).toHaveAttribute(
      'href',
      `/q/${QUOTE_TOKEN}`,
    );
    await expect(page.getByRole('list', { name: 'Vehicles' })).toContainText('2021 Toyota Camry');
    const book = page.getByRole('link', { name: /Book\s+with Glacier Detailing/ });
    await expect(book).toHaveAttribute('href', '/book/glacier');
    // A new document without a referrer (the booking page may load the shop's tags).
    await expect(book).toHaveAttribute('rel', 'noreferrer');
    expect(order).toEqual(['claim', 'overview']);
  });

  test('explains how bookings appear when nothing is linked yet', async ({ page }) => {
    await mockSupabase(page, {
      user: CLIENT,
      rpc: { portal_claim_customers: 0, portal_overview: EMPTY },
    });
    await page.goto('/portal');
    await expect(page.getByText('No bookings linked yet')).toBeVisible();
    await expect(page.getByText(/same email as this account \(ana@example\.com\)/)).toBeVisible();
  });

  test('an unconfirmed email is told to confirm it', async ({ page }) => {
    await mockSupabase(page, {
      user: CLIENT,
      rpc: {
        portal_overview: EMPTY,
        portal_claim_customers: reply(403, {
          code: '42501',
          message: 'confirm your email address before linking your records',
          details: null,
          hint: null,
        }),
      },
    });
    await page.goto('/portal');
    await expect(page.getByText('Confirm your email to see your bookings')).toBeVisible();
    await expect(page.getByText('No bookings linked yet')).toBeVisible();
  });

  test('returning from Stripe with ?card=saved confirms it once', async ({ page }) => {
    await mockSupabase(page, {
      user: CLIENT,
      rpc: { portal_claim_customers: 1, portal_overview: OVERVIEW },
    });
    await page.goto('/portal?card=saved');
    await expect(
      page.getByText('Your card was saved. Glacier Detailing can now charge it for future visits.'),
    ).toBeVisible();
    // The parameter is removed so a refresh doesn't repeat the banner.
    await expect(page).toHaveURL(/\/portal$/);
    await page.reload();
    await expect(page.getByRole('list', { name: 'Upcoming appointments' })).toBeVisible();
    await expect(page.getByText(/Your card was saved/)).toHaveCount(0);
  });

  test('a membership sign-up re-reads the overview once it is being activated', async ({
    page,
  }) => {
    let overviews = 0;
    await mockSupabase(page, {
      user: CLIENT,
      rpc: {
        portal_claim_customers: 1,
        portal_overview: () => {
          overviews += 1;
          return OVERVIEW;
        },
      },
    });
    await page.goto('/portal?membership=active');
    await expect(
      page.getByText(
        'Thanks! Your membership is being activated — it can take a minute to show as active.',
      ),
    ).toBeVisible();
    await expect(page).toHaveURL(/\/portal$/);
    await expect.poll(() => overviews, { timeout: 10_000 }).toBeGreaterThanOrEqual(2);
  });

  test('a cancelled card link says nothing was saved', async ({ page }) => {
    await mockSupabase(page, {
      user: CLIENT,
      rpc: { portal_claim_customers: 1, portal_overview: OVERVIEW },
    });
    await page.goto('/portal?card=canceled');
    await expect(page.getByText('No card was saved.')).toBeVisible();
    await expect(page.getByRole('link', { name: 'Account settings' })).toHaveAttribute(
      'href',
      '/account',
    );
  });
});
