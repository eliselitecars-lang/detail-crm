import { expect, test, type Page } from '@playwright/test';
import { membershipRow, TECH } from './support/fixtures';
import { mockSupabase } from './support/mockSupabase';

/**
 * Public /privacy and /terms (no sign-in) and the links to them: under the
 * auth pages, in the public page footer and on /account (every role). The
 * dev server runs with the VITE_LEGAL_* values blank (playwright.config.ts),
 * so the pages must use neutral wording and invent no operator details.
 */

const INVOICE_TOKEN = '52222222-2222-4222-8222-222222222222';

const SHOP = {
  name: 'Glacier Detailing',
  slug: 'glacier',
  logo_path: null,
  brand_color: '#1F6FEB',
  email: 'hello@glacier.test',
  phone: '+12055550100',
  website: null,
  address_line1: '1 Main St',
  address_line2: null,
  city: 'Birmingham',
  region: 'AL',
  postal_code: '35203',
  country: 'US',
  timezone: 'America/Chicago',
  currency: 'usd',
  review_url: null,
};

const INVOICE = {
  shop: SHOP,
  invoice: {
    number: 2001,
    status: 'open',
    issued_at: '2026-09-20T15:00:00Z',
    due_at: '2099-10-20T15:00:00Z',
    paid_at: null,
    voided_at: null,
    notes: null,
    terms: null,
    subtotal_cents: 30000,
    discount_cents: 0,
    tax_rate_bps: 0,
    tax_cents: 0,
    total_cents: 30000,
    amount_paid_cents: 0,
    balance_cents: 30000,
    tip_cents: 0,
    payable: true,
    card_payments_enabled: true,
  },
  customer: { first_name: 'Ana', last_name: 'Diaz', company: null },
  job: { number: 1042, scheduled_start: '2026-09-19T15:00:00Z', scheduled_end: null },
  vehicle: { year: 2021, make: 'Toyota', model: 'Camry', trim: null, color: null },
  line_items: [
    {
      name: 'Full detail',
      description: null,
      vehicle_label: '2021 Toyota Camry',
      quantity: 1,
      unit_price_cents: 30000,
      discount_cents: 0,
      taxable: true,
      total_cents: 30000,
    },
  ],
  payments: [],
};

/** Every request the page makes, by host and path. */
function recordRequests(page: Page): URL[] {
  const seen: URL[] = [];
  page.on('request', (request) => seen.push(new URL(request.url())));
  return seen;
}

async function noHorizontalOverflow(page: Page) {
  const overflow = await page.evaluate(
    () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
  );
  expect(overflow).toBeLessThanOrEqual(0);
}

function legalNav(page: Page, scope: 'footer' | 'page' = 'page') {
  const root = scope === 'footer' ? page.getByRole('contentinfo') : page;
  return root.getByRole('navigation', { name: 'Legal' });
}

test.describe('legal pages', () => {
  test('privacy policy: public, phone-width, neutral wording, nothing external', async ({
    page,
  }) => {
    const requests = recordRequests(page);
    await mockSupabase(page);
    await page.setViewportSize({ width: 360, height: 740 });
    await page.goto('/privacy');

    await expect(page.getByRole('heading', { level: 1, name: 'Privacy Policy' })).toBeVisible();
    await expect(page).toHaveTitle('Privacy Policy · Detail CRM');
    await expect(page.getByText('Last updated')).toBeVisible();
    await expect(
      page.getByText('The operator of this service (“we”, “us”) runs the Service'),
    ).toBeVisible();
    const contact = page.getByRole('region', { name: /Contact us/ });
    await expect(contact).toContainText(
      'For privacy questions and requests, contact the operator of this service.',
    );
    await expect(page.locator('a[href^="mailto:"]')).toHaveCount(0);
    // 0126: the unsubscribe link ends marketing email only.
    const choices = page.getByRole('region', { name: /Texts, emails and your choices/ });
    await expect(choices).toContainText(
      'Unsubscribing stops that shop’s marketing emails to your address; booking confirmations, appointment reminders, quotes, invoices and receipts from the shop still arrive.',
    );
    await expect(page.getByText(/stops all emails/i)).toHaveCount(0);
    await noHorizontalOverflow(page);

    // The table of contents jumps to its section.
    await page
      .getByRole('navigation', { name: 'On this page' })
      .getByRole('link', { name: 'Contact us' })
      .click();
    await expect(page).toHaveURL(/\/privacy#contact$/);
    await expect(contact.getByRole('heading', { name: /Contact us/ })).toBeInViewport();

    // Only this app (and the Inter font every page loads) — no data requests.
    const external = requests.filter(
      (url) =>
        url.hostname !== 'localhost' &&
        url.hostname !== 'fonts.googleapis.com' &&
        url.hostname !== 'fonts.gstatic.com' &&
        !url.hostname.endsWith('.supabase.co'),
    );
    expect(external.map((url) => url.href)).toEqual([]);
    const data = requests.filter((url) => /\/(rest|functions|storage)\/v1\//.test(url.pathname));
    expect(data.map((url) => url.href)).toEqual([]);
  });

  test('terms of service: public, phone-width, neutral governing law', async ({ page }) => {
    await mockSupabase(page);
    await page.setViewportSize({ width: 360, height: 740 });
    await page.goto('/terms');

    await expect(page.getByRole('heading', { level: 1, name: 'Terms of Service' })).toBeVisible();
    await expect(page).toHaveTitle('Terms of Service · Detail CRM');
    await expect(page.getByRole('region', { name: /Governing law/ })).toContainText(
      'governed by the laws of the place where the operator of this service is established',
    );
    await expect(page.getByRole('region', { name: /Payments through Stripe/ })).toContainText(
      'you are the merchant of record',
    );
    await noHorizontalOverflow(page);

    // Across to the privacy policy and back through the footer.
    await page
      .getByRole('article', { name: 'Terms of Service' })
      .getByRole('link', { name: 'Privacy Policy' })
      .click();
    await expect(page).toHaveURL(/\/privacy$/);
    await legalNav(page, 'footer').getByRole('link', { name: 'Terms of Service' }).click();
    await expect(page).toHaveURL(/\/terms$/);
    await expect(page.getByRole('heading', { level: 1, name: 'Terms of Service' })).toBeVisible();
  });
});

test.describe('links to the legal pages', () => {
  test('sign-in and sign-up pages', async ({ page }) => {
    await mockSupabase(page);
    await page.goto('/login');
    await legalNav(page).getByRole('link', { name: 'Privacy Policy' }).click();
    await expect(page).toHaveURL(/\/privacy$/);
    await expect(page.getByRole('heading', { level: 1, name: 'Privacy Policy' })).toBeVisible();

    await page.goto('/signup');
    await expect(page.getByRole('heading', { name: 'Create your account' })).toBeVisible();
    await legalNav(page).getByRole('link', { name: 'Terms of Service' }).click();
    await expect(page).toHaveURL(/\/terms$/);
    await expect(page.getByRole('heading', { level: 1, name: 'Terms of Service' })).toBeVisible();
  });

  test('the footer of a public invoice page', async ({ page }) => {
    await mockSupabase(page, { rpc: { public_get_invoice: INVOICE } });
    await page.setViewportSize({ width: 360, height: 740 });
    await page.goto(`/i/${INVOICE_TOKEN}`);
    await expect(page.getByRole('heading', { name: 'Invoice #2001', level: 1 })).toBeVisible();
    const footer = page.getByRole('contentinfo');
    await expect(footer).toContainText('Powered by Detail CRM');
    await noHorizontalOverflow(page);
    await legalNav(page, 'footer').getByRole('link', { name: 'Terms of Service' }).click();
    await expect(page).toHaveURL(/\/terms$/);
    await expect(page.getByRole('heading', { level: 1, name: 'Terms of Service' })).toBeVisible();
  });

  test('a technician reaches them from Your account', async ({ page }) => {
    await mockSupabase(page, {
      user: TECH,
      tables: { shop_members: [membershipRow(TECH, 'technician')], notifications: [] },
    });
    await page.goto('/app');
    await page.getByRole('button', { name: /Account menu/ }).click();
    await page.getByRole('menuitem', { name: 'Your account' }).click();
    await expect(page).toHaveURL(/\/account$/);
    const card = page.getByRole('region', { name: 'Privacy and terms' });
    await expect(card.getByRole('link', { name: 'Terms of Service' })).toHaveAttribute(
      'href',
      '/terms',
    );
    await card.getByRole('link', { name: 'Privacy Policy' }).click();
    await expect(page).toHaveURL(/\/privacy$/);
    await expect(page.getByRole('heading', { level: 1, name: 'Privacy Policy' })).toBeVisible();
  });
});
