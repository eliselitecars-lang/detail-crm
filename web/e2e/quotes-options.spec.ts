import { expect, test } from '@playwright/test';
import { mockSupabase } from './support/mockSupabase';

/** Public /q: proposal options (P-15) and self-scheduling an approved quote (P-16). */

const TOKEN = '61111111-1111-4111-8111-111111111111';
const JOB_TOKEN = '62222222-2222-4222-8222-222222222222';
const CHECKOUT_URL = 'https://checkout.stripe.test/c/pay/cs_test_quote_deposit';

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

const line = (id: string, name: string, optionId: string | null, cents: number) => ({
  id,
  option_id: optionId,
  name,
  description: null,
  vehicle_label: null,
  quantity: 1,
  unit_price_cents: cents,
  discount_cents: 0,
  taxable: true,
  total_cents: cents,
  optional: false,
  selected: true,
});

const option = (id: string, name: string, sort: number, total: number) => ({
  id,
  name,
  description: null,
  sort,
  subtotal_cents: total,
  discount_cents: 0,
  tax_cents: 0,
  total_cents: total,
});

function quoteDoc(quote: Record<string, unknown> = {}, selfSchedule: Record<string, unknown> = {}) {
  return {
    shop: SHOP,
    quote: {
      number: 310,
      status: 'viewed',
      valid_until: null,
      expires_at: null,
      notes: null,
      terms: null,
      subtotal_cents: 20000,
      discount_cents: 0,
      tax_rate_bps: 0,
      tax_cents: 0,
      total_cents: 20000,
      sent_at: '2026-09-20T15:00:00Z',
      viewed_at: '2026-09-21T15:00:00Z',
      approved_at: null,
      approved_by_name: null,
      declined_at: null,
      declined_reason: null,
      expired_at: null,
      can_respond: true,
      has_options: true,
      selected_option_id: 'o-basic',
      ...quote,
    },
    customer: { first_name: 'Ana', last_name: 'Diaz', company: null },
    vehicle: null,
    options: [option('o-basic', 'Basic', 1, 20000), option('o-premium', 'Premium', 2, 45000)],
    line_items: [
      line('l-wash', 'Hand wash', null, 5000),
      line('l-seal', 'Spray sealant', 'o-basic', 15000),
      line('l-coat', 'Ceramic coating', 'o-premium', 40000),
    ],
    self_schedule: {
      available: false,
      converted: false,
      job_token: null,
      deposit_due_cents: null,
      payment_pending: false,
      ...selfSchedule,
    },
  };
}

/** Tomorrow in the shop's zone, and a start at 15:00 UTC on it (morning in Chicago). */
function tomorrowSlot() {
  const today = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Chicago' }).format(
    new Date(),
  );
  const date = new Date(`${today}T15:00:00Z`);
  date.setUTCDate(date.getUTCDate() + 1);
  return {
    starts_at: date.toISOString(),
    ends_at: new Date(date.getTime() + 3 * 3600_000).toISOString(),
  };
}

test('the customer compares options and approves the one they want', async ({ page }) => {
  let body: unknown = null;
  await mockSupabase(page, {
    rpc: {
      public_get_quote: quoteDoc(),
      public_respond_quote: ({ body: sent }) => {
        body = sent;
        return quoteDoc({
          status: 'approved',
          can_respond: false,
          selected_option_id: 'o-premium',
        });
      },
    },
  });
  await page.goto(`/q/${TOKEN}`);
  const options = page.getByRole('region', { name: 'Options' });
  await expect(options.getByText('$450.00')).toBeVisible();
  await expect(page.getByRole('list', { name: 'Included in every option' })).toContainText(
    'Hand wash',
  );
  await options.getByRole('button', { name: 'Choose Premium' }).click();
  await page.getByLabel(/^Your full name/).fill('Ana Diaz');
  await page.getByRole('button', { name: 'Approve quote' }).click();
  await expect(page.getByText('Your choice')).toBeVisible();
  expect(body).toEqual({
    p_token: TOKEN,
    p_action: 'approve',
    p_signer_name: 'Ana Diaz',
    p_selected_optional_line_ids: [],
    p_option_id: 'o-premium',
  });
});

test('the customer picks a time for the approved quote and pays the deposit', async ({ page }) => {
  const slot = tomorrowSlot();
  let scheduled = false;
  const scheduleBodies: unknown[] = [];
  const payBodies: unknown[] = [];
  await mockSupabase(page, {
    rpc: {
      public_get_quote: () =>
        scheduled
          ? quoteDoc(
              { status: 'converted', can_respond: false },
              { converted: true, job_token: JOB_TOKEN, deposit_due_cents: 5000 },
            )
          : quoteDoc(
              { status: 'approved', can_respond: false, approved_by_name: 'Ana Diaz' },
              { available: true },
            ),
      public_shop_profile: {
        business_type: 'fixed',
        booking: { max_days_ahead: 30, booking_message: null, cancellation_policy: null },
      },
      public_quote_slots: [slot],
      public_schedule_quote: ({ body }) => {
        scheduleBodies.push(body);
        scheduled = true;
        return {
          job_token: JOB_TOKEN,
          job_number: 1050,
          status: 'scheduled',
          total_cents: 20000,
          deposit_required_cents: 5000,
          deposit_due_cents: 5000,
        };
      },
    },
    functions: {
      payments: ({ body }) => {
        payBodies.push(body);
        return {
          url: CHECKOUT_URL,
          expires_at: 1790000000,
          amount_cents: 5000,
          tip_cents: 0,
          currency: 'usd',
        };
      },
    },
  });
  await page.route(`${CHECKOUT_URL}**`, (route) =>
    route.fulfill({ status: 200, contentType: 'text/html', body: '<h1>Stripe checkout</h1>' }),
  );
  await page.goto(`/q/${TOKEN}`);
  await expect(page.getByText(/Pick a time for the work below/)).toBeVisible();
  await page
    .getByRole('radiogroup', { name: 'Days' })
    .getByRole('radio', { name: /1 times/ })
    .click();
  await page.getByRole('radiogroup', { name: 'Start times' }).getByRole('radio').first().click();
  await page.getByRole('button', { name: /^Book / }).click();
  await expect(page.getByText('You’re booked')).toBeVisible();
  expect(scheduleBodies[0]).toEqual({
    p_token: TOKEN,
    p_starts_at: slot.starts_at,
    p_location: { type: 'shop' },
  });
  await page.getByRole('button', { name: 'Pay $50.00 deposit' }).click();
  await expect(page.getByRole('heading', { name: 'Stripe checkout' })).toBeVisible();
  expect(payBodies[0]).toEqual({
    action: 'quote_deposit_checkout',
    token: TOKEN,
    request_nonce: expect.stringMatching(/^[A-Za-z0-9_-]{8,64}$/),
  });
});

test('options stack on a 360px phone without horizontal scrolling', async ({ page }) => {
  await page.setViewportSize({ width: 360, height: 740 });
  await mockSupabase(page, { rpc: { public_get_quote: quoteDoc() } });
  await page.goto(`/q/${TOKEN}`);
  await expect(page.getByRole('region', { name: 'Options' })).toBeVisible();
  const overflow = await page.evaluate(
    () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
  );
  expect(overflow).toBeLessThanOrEqual(0);
});
