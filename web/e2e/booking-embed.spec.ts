import { expect, test, type Page } from '@playwright/test';
import { mockSupabase, reply } from './support/mockSupabase';

/**
 * Booking v2 on the public page: private booking links, booking questions,
 * links that preselect services / a referral code, the website embed
 * (/embed.js + ?embed=1) and the rule that only /book/* and /lead/* render
 * inside another site's frame.
 */

const SLUG = 'glacier';
const SEDAN = '11111111-1111-4111-8111-111111111111';
const DETAIL = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1';
const WAX = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1';
const JOB_TOKEN = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const LINK = '99999999-9999-4999-8999-999999999999';

const PROFILE = {
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
    enabled: true,
    auto_confirm: true,
    lead_time_minutes: 60,
    max_days_ahead: 60,
    slot_interval_minutes: 30,
    require_deposit: false,
    deposit_type: null,
    deposit_value: null,
    service_area_limited: false,
    booking_message: null,
    cancellation_policy: null,
    allow_client_cancel_hours: 24,
  },
  tracking: { meta_pixel_id: null, ga4_measurement_id: null },
};

const price = (vehicle_category_id: string, price_cents: number) => ({
  vehicle_category_id,
  price_cents,
  duration_minutes: null,
});

const CATALOG = {
  vehicle_categories: [{ id: SEDAN, name: 'Sedan' }],
  service_categories: [
    { id: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd', name: 'Detailing', bookable_weekdays: [1, 3] },
  ],
  services: [
    {
      id: DETAIL,
      category_id: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
      name: 'Full detail',
      description: null,
      kind: 'service',
      image_path: null,
      duration_minutes: 120,
      base_price_cents: 15000,
      prices: [price(SEDAN, 15000)],
      includes: [],
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
      prices: [price(SEDAN, 4000)],
    },
  ],
};

const QUESTIONS = [
  {
    key: 'gate_code',
    label: 'Gate code',
    type: 'text',
    options: [],
    help_text: 'So we can get in',
    required: true,
    location_scope: 'mobile',
  },
];

function slotsFor(from: string) {
  const day = new Date(`${from}T00:00:00Z`);
  day.setUTCDate(day.getUTCDate() + 1);
  const date = day.toISOString().slice(0, 10);
  return [{ starts_at: `${date}T15:00:00+00:00`, ends_at: `${date}T17:30:00+00:00` }];
}

function preview(code: string) {
  const valid = code === 'ANA-4K7Q';
  return {
    valid,
    message: valid ? null : 'this coupon code is not valid',
    code,
    kind: valid ? 'fixed' : null,
    value: valid ? 2000 : null,
    description: valid ? 'Referral from Ana' : null,
    subtotal_cents: 19000,
    discount_cents: valid ? 2000 : 0,
    tax_cents: 0,
    total_cents: valid ? 17000 : 19000,
  };
}

const LEAD = 'abababab-abab-4bab-8bab-abababababab';

const LEAD_FORM = {
  shop: { name: 'Glacier Detailing', logo_path: null, brand_color: '#1F6FEB' },
  form: {
    name: 'Coating quote',
    headline: 'Get a ceramic coating quote',
    intro: 'Tell us about your car.',
    ask_vehicle: true,
    ask_message: true,
    success_message: 'Thanks! We will reply within a day.',
  },
  fields: [],
};

async function setup(page: Page) {
  const bookings: Record<string, unknown>[] = [];
  const slotRequests: Record<string, unknown>[] = [];
  await mockSupabase(page, {
    rpc: {
      public_get_lead_form: LEAD_FORM,
      public_shop_profile: PROFILE,
      public_booking_catalog: CATALOG,
      public_booking_questions: QUESTIONS,
      public_booking_link: ({ body }) =>
        (body as { p_token: string }).p_token === LINK
          ? {
              slug: SLUG,
              name: 'Fleet wash for Acme',
              note: null,
              expires_at: null,
              catalog: CATALOG,
            }
          : reply(404, { code: 'PT404', message: 'booking link not found' }),
      public_booking_slots: ({ body }) => {
        slotRequests.push(body as Record<string, unknown>);
        return slotsFor((body as { p_from: string }).p_from);
      },
      public_validate_coupon: ({ body }) => preview((body as { p_code: string }).p_code),
      create_online_booking: ({ body }) => {
        bookings.push(body as Record<string, unknown>);
        return {
          job_token: JOB_TOKEN,
          job_number: 1043,
          status: 'scheduled',
          total_cents: 17000,
          deposit_required_cents: 0,
        };
      },
    },
  });
  return { bookings, slotRequests };
}

async function vehicleStep(page: Page) {
  await expect(page.getByRole('heading', { name: 'Tell us about your vehicle' })).toBeVisible();
  await page.getByLabel(/^Make/).fill('Toyota');
  await page.getByLabel(/^Model/).fill('Camry');
  await page.getByRole('button', { name: 'Continue' }).click();
}

/**
 * The app's dev server on a loopback address other than "localhost": a
 * different origin, so an embed on it is really cross-origin. Which address
 * the server listens on follows how the machine resolves localhost (IPv4 in
 * most sandboxes, IPv6 on GitHub's runners), so use whichever one answers.
 */
async function otherLoopbackOrigin(app: string): Promise<string> {
  const { port } = new URL(app);
  for (const host of ['127.0.0.1', '[::1]']) {
    const origin = `http://${host}:${port}`;
    try {
      if ((await fetch(`${origin}/embed.js`)).ok) return origin;
    } catch {
      // Not listening on this address.
    }
  }
  throw new Error(`the dev server answers on no loopback address besides localhost (${app})`);
}

test.describe('booking v2', () => {
  test('a private link books its services at the customer’s location with the questions answered', async ({
    page,
  }) => {
    const { bookings, slotRequests } = await setup(page);
    await page.goto(`/book/${SLUG}?link=${LINK}`);
    await expect(page.getByRole('heading', { name: 'Fleet wash for Acme' })).toBeVisible();
    await page.getByText('Sedan', { exact: true }).click();
    await vehicleStep(page);
    await page.getByRole('checkbox', { name: /Full detail/ }).check();
    await page.getByRole('button', { name: 'Continue' }).click();

    await expect(page.getByRole('heading', { name: 'Pick a date and time' })).toBeVisible();
    await expect(
      page.getByText('Detailing can be booked online on Mondays and Wednesdays.'),
    ).toBeVisible();
    await page.getByText('At my location', { exact: true }).click();
    await expect
      .poll(() =>
        slotRequests.some((r) => r.p_location_type === 'mobile' && r.p_link_token === LINK),
      )
      .toBe(true);
    await page
      .getByRole('button', { name: / on [A-Z][a-z]+day, / })
      .first()
      .click();
    await page.getByRole('button', { name: 'Continue' }).click();

    await expect(page.getByRole('heading', { name: 'Your details' })).toBeVisible();
    await page.getByLabel(/^First name/).fill('Jane');
    await page.getByRole('textbox', { name: 'Email' }).fill('jane@example.com');
    await page.getByLabel(/^Street address/).fill('1 Elm St');
    await page.getByLabel(/^City/).fill('Birmingham');
    await page.getByLabel(/^ZIP/).fill('35203');
    await page.getByRole('button', { name: 'Continue' }).click();
    await expect(page.getByText('Gate code is required')).toBeVisible();
    await page.getByLabel(/^Gate code/).fill('#4521');
    await page.getByRole('button', { name: 'Continue' }).click();
    await expect(page.getByRole('heading', { name: 'Review and book' })).toBeVisible();
    await page.getByRole('button', { name: 'Book appointment' }).click();
    await expect(page.getByRole('heading', { name: 'You’re booked!' })).toBeVisible();

    expect(bookings[0]?.p_payload).toMatchObject({
      link_token: LINK,
      answers: { gate_code: '#4521' },
      location: { type: 'mobile', city: 'Birmingham' },
    });
  });

  test('a referral link preselects the services and applies the code, then cleans the URL', async ({
    page,
  }) => {
    const { bookings } = await setup(page);
    await page.goto(`/book/${SLUG}?services=${DETAIL},${WAX}&category=${SEDAN}&coupon=ANA-4K7Q`);
    await expect(page.getByRole('radio', { name: 'Sedan' })).toBeChecked();
    await expect(page).toHaveURL(`/book/${SLUG}`);
    await vehicleStep(page);
    await expect(page.getByRole('checkbox', { name: /Full detail/ })).toBeChecked();
    await expect(page.getByRole('checkbox', { name: /Hand wax/ })).toBeChecked();
    await page.getByRole('button', { name: 'Continue' }).click();
    await page
      .getByRole('button', { name: / on [A-Z][a-z]+day, / })
      .first()
      .click();
    await page.getByRole('button', { name: 'Continue' }).click();
    await expect(page.getByText(/Code ANA-4K7Q applied — \$20\.00 off/)).toBeVisible();
    await page.getByLabel(/^First name/).fill('Jane');
    await page.getByRole('textbox', { name: 'Email' }).fill('jane@example.com');
    await page.getByRole('button', { name: 'Continue' }).click();
    await page.getByRole('button', { name: 'Book appointment' }).click();
    await expect(page.getByRole('heading', { name: 'You’re booked!' })).toBeVisible();
    expect(bookings[0]?.p_payload).toMatchObject({
      coupon_code: 'ANA-4K7Q',
      service_ids: [DETAIL],
      addon_ids: [WAX],
    });
  });

  test('an expired private link explains itself', async ({ page }) => {
    await setup(page);
    await page.goto(`/book/${SLUG}?link=88888888-8888-4888-8888-888888888888`);
    await expect(page.getByText('This booking link is no longer available')).toBeVisible();
    await expect(page.getByRole('link', { name: 'See all services' })).toHaveAttribute(
      'href',
      `/book/${SLUG}`,
    );
  });

  test('embed.js frames the booking page and sizes it; other pages refuse to be framed', async ({
    page,
    baseURL,
  }) => {
    await setup(page);
    // A shop's website (same test origin) that pastes the embed snippet, and
    // tries to frame a staff page.
    await page.route('**/__shop-site', (route) =>
      route.fulfill({
        status: 200,
        contentType: 'text/html',
        body: `<!doctype html><title>Shop site</title>
<h1>Our shop</h1>
<div data-detailcrm-book="${SLUG}"></div>
<script src="${baseURL}/embed.js" async></script>
<iframe id="staff" src="${baseURL}/app" title="staff" width="600" height="400"></iframe>`,
      }),
    );
    await page.goto('/__shop-site');
    const booking = page.frameLocator('iframe[title="Book an appointment"]');
    await expect(
      booking.getByRole('heading', { name: 'Book with Glacier Detailing' }),
    ).toBeVisible();
    // No page chrome in embed mode; legal links leave the frame.
    await expect(booking.getByRole('banner')).toHaveCount(0);
    await expect(booking.getByRole('link', { name: 'Privacy Policy' })).toHaveAttribute(
      'target',
      '_blank',
    );
    const frame = page.locator('iframe[title="Book an appointment"]');
    await expect(frame).toHaveAttribute('src', `${baseURL}/book/${SLUG}?embed=1`);
    // The frame grows with its content (height messages from the page).
    await expect
      .poll(async () =>
        Number((await frame.getAttribute('style'))?.match(/(?:^|;\s*)height: (\d+)px/)?.[1]),
      )
      .toBeGreaterThan(320);
    const staff = page.frameLocator('#staff');
    await expect(
      staff.getByRole('heading', { name: 'This page can’t be shown here' }),
    ).toBeVisible();
  });

  test('embed.js brings the frame’s top into view when the booking moves to the next step', async ({
    page,
    baseURL,
  }) => {
    await setup(page);
    await page.setViewportSize({ width: 800, height: 600 });
    // A shop's website on its own origin (another loopback address; the app
    // is on localhost): a real cross-origin embed, whose focus changes never
    // scroll the shop's page. The document comes from the dev server so it is
    // on the local network like the app; its content is then replaced.
    await page.goto(`${await otherLoopbackOrigin(baseURL ?? '')}/__shop-site-long`);
    await page.setContent(`<!doctype html><title>Shop site</title>
<h1>Our shop</h1>
<div style="height:900px">About us</div>
<div data-detailcrm-book="${SLUG}"></div>
<div style="height:3000px">Footer</div>
<script src="${baseURL}/embed.js" async></script>`);
    const frame = page.locator('iframe[title="Book an appointment"]');
    const booking = page.frameLocator('iframe[title="Book an appointment"]');
    await expect(
      booking.getByRole('heading', { name: 'Tell us about your vehicle' }),
    ).toBeVisible();
    await booking.getByText('Sedan', { exact: true }).click();
    await booking.getByLabel(/^Make/).fill('Toyota');
    await booking.getByLabel(/^Model/).fill('Camry');
    // The customer scrolled the shop's page past the frame's top to reach Continue.
    const top = await frame.evaluate((el) => el.getBoundingClientRect().top + window.scrollY);
    await page.evaluate((y) => window.scrollTo(0, y + 250), top);
    await expect.poll(() => frame.evaluate((el) => el.getBoundingClientRect().top)).toBeLessThan(0);
    await booking.getByRole('button', { name: 'Continue' }).click();
    await expect(booking.getByRole('heading', { name: 'Choose your services' })).toBeVisible();
    await expect
      .poll(() => frame.evaluate((el) => Math.round(el.getBoundingClientRect().top)))
      .toBeGreaterThanOrEqual(-1);
    expect(await frame.evaluate((el) => el.getBoundingClientRect().top)).toBeLessThan(600);

    // The step-change message itself (browsers whose focus changes do not
    // scroll a cross-origin parent rely on it): only the frame's own message
    // on the app's origin scrolls the shop's page, to the frame's top.
    await page.evaluate((y) => window.scrollTo(0, y + 250), top);
    await page.evaluate(() => window.postMessage({ type: 'detailcrm:scroll-top' }, '*'));
    await page.waitForTimeout(300);
    expect(await frame.evaluate((el) => el.getBoundingClientRect().top)).toBeLessThan(0);
    await booking
      .locator('body')
      .evaluate(() => window.parent.postMessage({ type: 'detailcrm:scroll-top' }, '*'));
    await expect
      .poll(() => frame.evaluate((el) => Math.abs(Math.round(el.getBoundingClientRect().top))))
      .toBeLessThanOrEqual(1);
  });

  test('embed.js on another site frames a private link and a lead form, each sized only by its own messages', async ({
    page,
    baseURL,
  }) => {
    await setup(page);
    const app = baseURL ?? '';
    // The shop's website on its own origin (another loopback address; the app
    // is on localhost), pasting the snippets Settings shows: the booking page
    // (here a private link) and a lead form. A div with a bad slug gets no frame.
    await page.goto(`${await otherLoopbackOrigin(app)}/__shop-site-embeds`);
    await page.setContent(`<!doctype html><title>Shop site</title>
<h1>Our shop</h1>
<div id="book" data-detailcrm-book="${SLUG}" data-link="${LINK}"></div>
<div id="lead" data-detailcrm-book="${SLUG}" data-lead="${LEAD}"></div>
<div id="bad" data-detailcrm-book="not a slug!"></div>
<iframe id="other" src="${app}/privacy" title="Another app page" width="400" height="200"></iframe>
<script src="${app}/embed.js" async></script>`);
    expect(new URL(page.url()).origin).not.toBe(new URL(app).origin);

    const bookFrame = page.locator('#book iframe');
    const leadFrame = page.locator('#lead iframe');
    await expect(bookFrame).toHaveAttribute('src', `${app}/book/${SLUG}?embed=1&link=${LINK}`);
    await expect(bookFrame).toHaveAttribute('title', 'Book an appointment');
    await expect(leadFrame).toHaveAttribute('src', `${app}/lead/${LEAD}?embed=1`);
    await expect(leadFrame).toHaveAttribute('title', 'Contact form');
    await expect(page.locator('#bad iframe')).toHaveCount(0);
    await expect(
      page.frameLocator('#book iframe').getByRole('heading', { name: 'Fleet wash for Acme' }),
    ).toBeVisible();
    await expect(
      page
        .frameLocator('#lead iframe')
        .getByRole('heading', { name: 'Get a ceramic coating quote' }),
    ).toBeVisible();

    const heightOf = async (frame: typeof bookFrame) =>
      Number((await frame.getAttribute('style'))?.match(/(?:^|;\s*)height: (\d+)px/)?.[1]);
    // The frames are cross-origin to the shop's page: measure inside each one.
    const frameAt = (path: RegExp) => {
      const frame = page.frames().find((f) => path.test(new URL(f.url()).pathname));
      if (!frame) throw new Error(`no frame at ${String(path)}`);
      return frame;
    };
    const leadPage = frameAt(/^\/lead\//);
    const bookPage = frameAt(/^\/book\//);
    const contentHeight = (frame: typeof leadPage) =>
      frame.evaluate(() =>
        Math.ceil(
          document.querySelector('main')?.parentElement?.getBoundingClientRect().height ?? 0,
        ),
      );
    // Each frame is exactly as tall as its own content (not the 720px start height).
    await expect
      .poll(async () => (await heightOf(leadFrame)) - (await contentHeight(leadPage)))
      .toBe(0);
    await expect
      .poll(async () => (await heightOf(bookFrame)) - (await contentHeight(bookPage)))
      .toBe(0);
    const book = await heightOf(bookFrame);
    expect(await heightOf(leadFrame)).not.toBe(book);

    // Messages from anywhere else are ignored: the shop's own page (its
    // origin) and another frame on the app's origin that embed.js did not
    // create. A message from the lead frame, posted after them, is applied
    // (clamped to the 320px minimum), so the others were seen and dropped.
    await page.evaluate(() => window.postMessage({ type: 'detailcrm:height', height: 4321 }, '*'));
    await frameAt(/^\/privacy/).evaluate(() =>
      window.parent.postMessage({ type: 'detailcrm:height', height: 4321 }, '*'),
    );
    await leadPage.evaluate(() =>
      window.parent.postMessage({ type: 'detailcrm:height', height: 100 }, '*'),
    );
    await expect.poll(() => heightOf(leadFrame)).toBe(320);
    expect(await heightOf(bookFrame)).toBe(book);
  });
});
