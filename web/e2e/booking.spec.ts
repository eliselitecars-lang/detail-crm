import { expect, test, type Page } from '@playwright/test';
import { mockSupabase, reply } from './support/mockSupabase';

/**
 * Online booking wizard (/book/:slug) against a mocked backend: every
 * price, total and deposit below is what the (mocked) server returns — the
 * page never adds anything up.
 */

const SLUG = 'glacier';
const SEDAN = '11111111-1111-4111-8111-111111111111';
const TRUCK = '22222222-2222-4222-8222-222222222222';
const DETAIL = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1';
const COATING = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2';
const WAX = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1';
const PET_HAIR = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2';
const JOB_TOKEN = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const CHECKOUT_URL = 'https://checkout.stripe.test/c/pay/cs_test_deposit';

function profile(overrides: { enabled?: boolean } = {}) {
  return {
    name: 'Glacier Detailing',
    slug: SLUG,
    logo_path: null,
    brand_color: '#1F6FEB',
    phone: '+12055550100',
    website: null,
    city: 'Birmingham',
    region: 'AL',
    country: 'US',
    timezone: 'America/Chicago',
    currency: 'usd',
    business_type: 'both',
    tax_rate_bps: 0,
    booking: {
      enabled: overrides.enabled ?? true,
      auto_confirm: false,
      lead_time_minutes: 60,
      max_days_ahead: 60,
      slot_interval_minutes: 30,
      require_deposit: true,
      deposit_type: 'percent',
      deposit_value: 2000,
      service_area_limited: false,
      booking_message: null,
      cancellation_policy: 'Cancel at least 24 hours ahead.',
      allow_client_cancel_hours: 24,
    },
  };
}

const price = (vehicle_category_id: string, price_cents: number) => ({
  vehicle_category_id,
  price_cents,
  duration_minutes: null,
});

const CATALOG = {
  vehicle_categories: [
    { id: SEDAN, name: 'Sedan' },
    { id: TRUCK, name: 'Truck' },
  ],
  service_categories: [{ id: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd', name: 'Detailing' }],
  services: [
    {
      id: DETAIL,
      category_id: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
      name: 'Full detail',
      description: 'Inside and out',
      kind: 'service',
      image_path: null,
      duration_minutes: 120,
      base_price_cents: 15000,
      prices: [price(SEDAN, 15000), price(TRUCK, 20000)],
      includes: [],
      addon_ids: [WAX, PET_HAIR],
    },
    {
      id: COATING,
      category_id: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
      name: 'Ceramic coating',
      description: null,
      kind: 'package',
      image_path: null,
      duration_minutes: 480,
      base_price_cents: null,
      prices: [price(SEDAN, 90000)],
      includes: ['Paint correction'],
      addon_ids: [WAX],
    },
  ],
  addons: [
    {
      id: WAX,
      category_id: null,
      name: 'Hand wax',
      description: null,
      kind: 'addon',
      image_path: null,
      duration_minutes: 30,
      base_price_cents: 4000,
      prices: [price(SEDAN, 4000), price(TRUCK, 5000)],
    },
    {
      id: PET_HAIR,
      category_id: null,
      name: 'Pet hair removal',
      description: null,
      kind: 'addon',
      image_path: null,
      duration_minutes: 30,
      base_price_cents: 3000,
      prices: [price(SEDAN, 3000)],
    },
  ],
};

function preview(code: string) {
  const valid = code === 'SPRING10';
  return {
    valid,
    message: valid ? null : 'this coupon code is not valid',
    code,
    kind: valid ? 'percent' : null,
    value: valid ? 1000 : null,
    description: valid ? 'Spring special' : null,
    subtotal_cents: 19000,
    discount_cents: valid ? 1900 : 0,
    tax_cents: 0,
    total_cents: valid ? 17100 : 19000,
  };
}

/** Two slots on the day after the requested window starts (UTC instants). */
function slotsFor(from: string) {
  const day = new Date(`${from}T00:00:00Z`);
  day.setUTCDate(day.getUTCDate() + 1);
  const date = day.toISOString().slice(0, 10);
  return [
    { starts_at: `${date}T15:00:00+00:00`, ends_at: `${date}T17:30:00+00:00` },
    { starts_at: `${date}T18:00:00+00:00`, ends_at: `${date}T20:30:00+00:00` },
  ];
}

async function setup(page: Page, options: { enabled?: boolean; catalog?: typeof CATALOG } = {}) {
  const bookings: unknown[] = [];
  const slotRequests: unknown[] = [];
  const couponRequests: unknown[] = [];
  const functionCalls: unknown[] = [];
  await mockSupabase(page, {
    rpc: {
      public_shop_profile: profile(options),
      public_booking_catalog: options.catalog ?? CATALOG,
      get_available_slots: ({ body }) => {
        slotRequests.push(body);
        return slotsFor((body as { p_from: string }).p_from);
      },
      public_validate_coupon: ({ body }) => {
        couponRequests.push(body);
        return preview((body as { p_code: string }).p_code);
      },
      // The first booking attempt loses the race for its slot (23P01 → HTTP
      // 409); the retry succeeds.
      create_online_booking: ({ body }) => {
        bookings.push(body);
        if (bookings.length === 1 && !options.catalog) {
          return reply(409, {
            code: '23P01',
            message: 'that time is no longer available; please choose another time',
            details: null,
            hint: null,
          });
        }
        return {
          job_token: JOB_TOKEN,
          job_number: 1042,
          status: 'requested',
          total_cents: 17100,
          deposit_required_cents: 3420,
        };
      },
    },
    functions: {
      payments: ({ body }) => {
        functionCalls.push(body);
        return {
          url: CHECKOUT_URL,
          expires_at: 1_900_000_000,
          amount_cents: 3420,
          tip_cents: 0,
          currency: 'usd',
        };
      },
    },
  });
  await page.route('https://checkout.stripe.test/**', (route) =>
    route.fulfill({
      status: 200,
      contentType: 'text/html',
      body: '<!doctype html><title>Stripe Checkout</title><h1>Stripe Checkout</h1>',
    }),
  );
  return { bookings, slotRequests, couponRequests, functionCalls };
}

test.describe('online booking', () => {
  test('books with a coupon, recovers from a taken slot and pays the deposit', async ({ page }) => {
    const { bookings, slotRequests, functionCalls } = await setup(page);
    await page.goto(`/book/${SLUG}`);
    await expect(page.getByRole('heading', { name: 'Book with Glacier Detailing' })).toBeVisible();

    // 1. Vehicle
    // The radio input is visually hidden inside its card: click the card label.
    await page.getByText('Sedan', { exact: true }).click();
    await expect(page.getByRole('radio', { name: 'Sedan' })).toBeChecked();
    await page.getByLabel('Year').fill('2021');
    await page.getByLabel(/^Make/).fill('Toyota');
    await page.getByLabel(/^Model/).fill('Camry');
    await page.getByLabel('Color').fill('Blue');
    await page.getByRole('button', { name: 'Continue' }).click();

    // 2. Services + an allowed add-on, priced for Sedan by the server catalog
    await expect(page.getByRole('heading', { name: 'Choose your services' })).toBeVisible();
    await expect(page.getByText('Prices shown for: Sedan', { exact: false })).toBeVisible();
    await page.getByRole('checkbox', { name: /Full detail/ }).check();
    await expect(page.getByRole('checkbox', { name: /Pet hair removal/ })).toBeVisible();
    await page.getByRole('checkbox', { name: /Hand wax/ }).check();
    await page.getByRole('button', { name: 'Continue' }).click();

    // 3. Time (shop time zone)
    await expect(page.getByRole('heading', { name: 'Pick a date and time' })).toBeVisible();
    await expect(page.getByText(/Times are shown in the shop’s time zone/)).toBeVisible();
    await expect(page.getByText('(America/Chicago)', { exact: false })).toBeVisible();
    const slots = page.getByRole('button', { name: / on [A-Z][a-z]+day, / });
    await expect(slots).toHaveCount(2);
    await slots.first().click();
    await expect(slots.first()).toHaveAttribute('aria-pressed', 'true');
    expect(slotRequests[0]).toMatchObject({
      p_shop_slug: SLUG,
      p_service_ids: [DETAIL, WAX],
      p_vehicle_category_id: SEDAN,
    });
    await page.getByRole('button', { name: 'Continue' }).click();

    // 4. Details + coupon preview from the server
    await expect(page.getByRole('heading', { name: 'Your details' })).toBeVisible();
    await page.getByLabel(/^First name/).fill('Jane');
    await page.getByLabel('Last name').fill('Doe');
    await page.getByRole('textbox', { name: 'Email' }).fill('jane@example.com');
    await page.getByLabel('Coupon code').fill('NOPE');
    await page.getByRole('button', { name: 'Apply' }).click();
    await expect(page.getByText('This coupon code is not valid')).toBeVisible();
    await page.getByLabel('Coupon code').fill('SPRING10');
    await page.getByRole('button', { name: 'Apply' }).click();
    await expect(page.getByText(/applied — \$19\.00 off/)).toBeVisible();
    await page.getByRole('button', { name: 'Continue' }).click();

    // 5. Review → the slot was just taken → back on the time step
    await expect(page.getByRole('heading', { name: 'Review and book' })).toBeVisible();
    await expect(page.getByText('$171.00')).toBeVisible();
    await expect(page.getByText(/deposit of 20%/i)).toBeVisible();
    await page.getByRole('button', { name: 'Request appointment' }).click();
    await expect(page.getByRole('heading', { name: 'Pick a date and time' })).toBeVisible();
    await expect(page.getByText(/that time was just booked/)).toBeVisible();
    await expect(page.getByRole('button', { name: 'Continue' })).toBeDisabled();
    await slots.last().click();
    await page.getByRole('button', { name: 'Continue' }).click();
    await page.getByRole('button', { name: 'Continue' }).click();
    await page.getByRole('button', { name: 'Request appointment' }).click();

    // Confirmation with the server's total and deposit
    await expect(page.getByRole('heading', { name: 'Request received' })).toBeVisible();
    await expect(page.getByText('#1042')).toBeVisible();
    await expect(page.getByText('$171.00')).toBeVisible();
    await expect(page.getByRole('link', { name: 'View or manage booking' })).toHaveAttribute(
      'href',
      `/booking/${JOB_TOKEN}`,
    );

    expect(bookings).toHaveLength(2);
    const payload = bookings[1] as { p_slug: string; p_payload: Record<string, unknown> };
    expect(payload.p_slug).toBe(SLUG);
    expect(payload.p_payload).toMatchObject({
      customer: { first_name: 'Jane', last_name: 'Doe', email: 'jane@example.com' },
      vehicle: { year: 2021, make: 'Toyota', model: 'Camry', color: 'Blue', category_id: SEDAN },
      service_ids: [DETAIL],
      addon_ids: [WAX],
      location: { type: 'shop' },
      coupon_code: 'SPRING10',
    });
    expect(payload.p_payload.starts_at).toBe(
      slotsFor((slotRequests[0] as { p_from: string }).p_from)[1]?.starts_at,
    );
    // No price-like keys ever leave the browser.
    expect(JSON.stringify(payload)).not.toMatch(/price|total|_cents/);

    await page.getByRole('button', { name: 'Pay $34.20 deposit' }).click();
    await page.waitForURL(CHECKOUT_URL);
    expect(functionCalls).toHaveLength(1);
    expect(functionCalls[0]).toMatchObject({
      action: 'booking_deposit_checkout',
      token: JOB_TOKEN,
    });
    expect((functionCalls[0] as { request_nonce: string }).request_nonce).toMatch(
      /^[A-Za-z0-9_-]{8,64}$/,
    );
  });

  test('a shop without vehicle sizes books at base prices and sends no category', async ({
    page,
  }) => {
    const { bookings, slotRequests, couponRequests } = await setup(page, {
      catalog: { ...CATALOG, vehicle_categories: [] },
    });
    await page.goto(`/book/${SLUG}`);
    await expect(page.getByRole('heading', { name: 'Tell us about your vehicle' })).toBeVisible();
    await expect(page.getByRole('radio')).toHaveCount(0);
    await page.getByLabel(/^Make/).fill('Toyota');
    await page.getByLabel(/^Model/).fill('Camry');
    await page.getByRole('button', { name: 'Continue' }).click();

    await page.getByRole('checkbox', { name: /Full detail/ }).check();
    await page.getByRole('button', { name: 'Continue' }).click();
    const slots = page.getByRole('button', { name: / on [A-Z][a-z]+day, / });
    await slots.first().click();
    await page.getByRole('button', { name: 'Continue' }).click();
    await page.getByLabel(/^First name/).fill('Jane');
    await page.getByRole('textbox', { name: 'Email' }).fill('jane@example.com');
    await page.getByRole('button', { name: 'Continue' }).click();
    await page.getByRole('button', { name: 'Request appointment' }).click();
    await expect(page.getByRole('heading', { name: 'Request received' })).toBeVisible();

    expect(slotRequests[0]).not.toHaveProperty('p_vehicle_category_id');
    expect(couponRequests.length).toBeGreaterThan(0);
    for (const request of couponRequests) {
      expect(request).not.toHaveProperty('p_vehicle_category_id');
    }
    const payload = (bookings[0] as { p_payload: { vehicle: Record<string, unknown> } }).p_payload;
    expect(payload.vehicle).not.toHaveProperty('category_id');
  });

  test('a shop with online booking turned off shows a friendly closed page', async ({ page }) => {
    await setup(page, { enabled: false });
    await page.goto(`/book/${SLUG}`);
    await expect(page.getByText('Online booking is closed right now')).toBeVisible();
    await expect(page.getByRole('link', { name: /Call \(205\) 555-0100/ })).toHaveAttribute(
      'href',
      'tel:+12055550100',
    );
    await expect(page.getByRole('button', { name: 'Continue' })).toHaveCount(0);
  });

  test('works at phone width', async ({ page }) => {
    await page.setViewportSize({ width: 360, height: 740 });
    await setup(page);
    await page.goto(`/book/${SLUG}`);
    await expect(page.getByRole('heading', { name: 'Tell us about your vehicle' })).toBeVisible();
    const overflow = await page.evaluate(
      () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
    );
    expect(overflow).toBeLessThanOrEqual(0);
  });
});
