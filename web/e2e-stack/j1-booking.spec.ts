import { expect, test } from '@playwright/test';
import { uniqueSuffix } from './support/stackApi';
import {
  connectStripe,
  postStripeEvent,
  rest,
  stripeId,
  stripePaymentIntent,
  stubStripeHostedPages,
  trackApiFailures,
  trackPageErrors,
} from './support/journey';

/**
 * J1 — owner onboarding → catalog → booking settings → anonymous online
 * booking → approval → job line edit, all on the REAL stack (GoTrue,
 * PostgREST/RLS, triggers, get_available_slots, create_online_booking).
 */

test.use({ actionTimeout: 15_000, navigationTimeout: 30_000 });

interface SlotRow {
  starts_at: string;
  ends_at: string;
}

test('J1: owner sets up a shop, a customer books online, the owner approves and edits the job', async ({
  page,
  browser,
}) => {
  test.setTimeout(240_000);
  const sfx = uniqueSuffix();
  const owner = {
    name: 'Olivia Owner',
    email: `j1-owner-${sfx}@stack.test`,
    password: `Pw-${sfx}-owner!`,
  };
  const shopName = `J1 Detail ${sfx}`;
  const slug = `j1-${sfx}`;
  const serviceName = `Signature Detail ${sfx}`;
  const customer = {
    first: 'Casey',
    last: `Booker${sfx.slice(0, 4)}`,
    email: `j1-cust-${sfx}@stack.test`,
  };
  const apiFailures = trackApiFailures(page);
  const pageErrors = trackPageErrors(page);

  // --- 1. Real sign-up (email confirmations are off locally) → onboarding
  await page.goto('/signup');
  await page.getByLabel('Your name').fill(owner.name);
  await page.getByLabel('Email').fill(owner.email);
  await page.getByLabel(/^Password/).fill(owner.password);
  await page.getByLabel('Confirm password').fill(owner.password);
  await page.getByRole('button', { name: 'Create account' }).click();
  await expect(page).toHaveURL(/\/app\/onboarding$/);

  // --- 2. Onboarding: business → contact & location → taxes & hours
  await page.getByLabel('Shop name').fill(shopName);
  await page.getByLabel('Booking link').fill(slug);
  await page.getByRole('button', { name: 'Continue' }).click();
  await page.getByLabel('Time zone').selectOption('America/Chicago');
  await page.getByLabel('City').fill('Birmingham');
  await page.getByLabel('State').fill('AL');
  await page.getByRole('button', { name: 'Continue' }).click();
  await page.getByLabel('Sales tax rate').fill('8.25');
  await page.getByRole('button', { name: 'Create shop' }).click();
  await expect(page).toHaveURL(/\/app$/);
  await expect(page.getByRole('heading', { name: 'Dashboard', level: 1 })).toBeVisible();

  // The server stored exactly what onboarding sent (read back with the owner's own session).
  const session = await page.evaluate(() => {
    const key = Object.keys(localStorage).find((k) => k.endsWith('-auth-token'));
    return key
      ? (JSON.parse(localStorage.getItem(key) ?? '{}') as {
          access_token?: string;
          user?: { id: string };
        })
      : {};
  });
  expect(session.access_token).toBeTruthy();
  const ownerUser = {
    id: session.user?.id ?? '',
    email: owner.email,
    password: owner.password,
    accessToken: session.access_token ?? '',
  };
  const shopRows = await rest<Array<{ id: string; tax_rate_bps: number; timezone: string }>>(
    'GET',
    `shops?slug=eq.${slug}&select=id,tax_rate_bps,timezone`,
    ownerUser,
  );
  expect(shopRows.json).toEqual([
    expect.objectContaining({ tax_rate_bps: 825, timezone: 'America/Chicago' }),
  ]);
  const shopId = shopRows.json[0]?.id ?? '';
  const hours = await rest<Array<{ weekday: number }>>(
    'GET',
    `business_hours?shop_id=eq.${shopId}&select=weekday`,
    ownerUser,
  );
  expect(hours.json.map((h) => h.weekday).sort()).toEqual([1, 2, 3, 4, 5]);

  // --- 3. Catalog: a service priced per vehicle size
  await page.goto('/app/catalog');
  await page.getByRole('button', { name: 'New item' }).first().click();
  const dialog = page.getByRole('dialog', { name: 'New catalog item' });
  await dialog.getByLabel('Name').fill(serviceName);
  await dialog.getByLabel('Duration (minutes)').fill('120');
  await dialog.getByRole('switch', { name: 'Bookable online' }).click();
  await expect(dialog.getByRole('switch', { name: 'Bookable online' })).toHaveAttribute(
    'aria-checked',
    'true',
  );
  await dialog.getByRole('button', { name: 'Create' }).click();
  await expect(page).toHaveURL(/\/app\/catalog\/services\/[0-9a-f-]{36}$/);
  await expect(page.getByRole('heading', { name: serviceName })).toBeVisible();
  const grid = page.getByRole('table', { name: 'Prices by vehicle size' });
  await grid.getByRole('textbox', { name: 'Base price' }).fill('150');
  await grid.getByRole('textbox', { name: 'Large SUV / Truck price' }).fill('220');
  await page.getByRole('button', { name: 'Save prices' }).click();
  await expect(page.getByText('Prices saved')).toBeVisible();
  const serviceId = page.url().split('/').pop() ?? '';
  const prices = await rest<Array<{ price_cents: number; vehicle_category_id: string | null }>>(
    'GET',
    `service_prices?service_id=eq.${serviceId}&select=price_cents,vehicle_category_id`,
    ownerUser,
  );
  expect(prices.json.map((p) => p.price_cents).sort()).toEqual([15000, 22000]);

  // --- 4. Settings: accept online bookings (as requests) with a 20% deposit
  await page.goto('/app/settings/booking');
  const accept = page.getByRole('switch', { name: 'Accept online bookings' });
  await accept.click();
  await expect(accept).toHaveAttribute('aria-checked', 'true');
  await expect(
    page.getByRole('switch', { name: 'Confirm bookings automatically' }),
  ).toHaveAttribute('aria-checked', 'false');
  await page.getByLabel('Minimum notice', { exact: true }).fill('0');
  await page.getByRole('switch', { name: 'Require a deposit to book' }).click();
  await page.getByText('Percent of the booking total').click();
  await page.getByLabel('Deposit percent').fill('20');
  await page.getByRole('button', { name: 'Save changes' }).click();
  await expect(page.getByText('Booking settings saved')).toBeVisible();
  const settings = await rest<Array<Record<string, unknown>>>(
    'GET',
    `booking_settings?shop_id=eq.${shopId}&select=enabled,auto_confirm,require_deposit,deposit_type,deposit_value`,
    ownerUser,
  );
  expect(settings.json[0]).toMatchObject({
    enabled: true,
    auto_confirm: false,
    require_deposit: true,
    deposit_type: 'percent',
  });

  // Deposits are collected with Stripe Checkout on the shop's connected account.
  const account = await connectStripe(ownerUser, shopId);

  // --- 5. An anonymous customer books on /book/<slug> in a fresh browser context
  const anon = await browser.newContext();
  const book = await anon.newPage();
  // The anonymous customer page must run clean too (no API >= 400, no page errors).
  const publicApiFailures = trackApiFailures(book);
  const publicPageErrors = trackPageErrors(book);
  const stripePages = await stubStripeHostedPages(book);
  const slotResponses: SlotRow[][] = [];
  book.on('response', (response) => {
    // The booking page reads availability v2 (public_booking_slots, 0053).
    if (response.url().includes('/rest/v1/rpc/public_booking_slots') && response.ok()) {
      void response
        .json()
        .then((rows: SlotRow[]) => slotResponses.push(rows))
        .catch(() => undefined);
    }
  });
  await book.goto(`/book/${slug}`);
  await expect(book.getByRole('heading', { name: `Book with ${shopName}` })).toBeVisible();
  await book.getByText('Large SUV / Truck', { exact: true }).click();
  await book.getByLabel('Year').fill('2022');
  await book.getByLabel(/^Make/).fill('Ford');
  await book.getByLabel(/^Model/).fill('F-150');
  await book.getByRole('button', { name: 'Continue' }).click();
  await expect(book.getByRole('heading', { name: 'Choose your services' })).toBeVisible();
  const serviceBox = book.getByRole('checkbox', { name: new RegExp(serviceName) });
  await expect(book.getByText('$220.00').first()).toBeVisible();
  await serviceBox.check();
  await book.getByRole('button', { name: 'Continue' }).click();
  await expect(book.getByRole('heading', { name: 'Pick a date and time' })).toBeVisible();

  // Real slots from public_booking_slots; weekends are closed, so move on a week if needed.
  const slots = book.getByRole('button', { name: / on [A-Z][a-z]+day, / });
  await expect(slots.first().or(book.getByText('No open times this week'))).toBeVisible();
  if ((await slots.count()) === 0) {
    await book.getByRole('button', { name: 'Next week' }).first().click();
  }
  await expect(slots.first()).toBeVisible();
  const lastSlots = slotResponses.at(-1) ?? [];
  expect(lastSlots.length).toBeGreaterThan(0);
  await slots.first().click();
  await book.getByRole('button', { name: 'Continue' }).click();

  await expect(book.getByRole('heading', { name: 'Your details' })).toBeVisible();
  await book.getByLabel(/^First name/).fill(customer.first);
  await book.getByLabel('Last name').fill(customer.last);
  await book.getByRole('textbox', { name: 'Email' }).fill(customer.email);
  await book.getByRole('button', { name: 'Continue' }).click();
  await expect(book.getByRole('heading', { name: 'Review and book' })).toBeVisible();
  // 220.00 + 8.25% tax (18.15) = 238.15 — computed by the server.
  await expect(book.getByText('$238.15').first()).toBeVisible();
  await expect(book.getByText(/deposit of 20%/i)).toBeVisible();
  await book.getByRole('button', { name: 'Request appointment' }).click();
  await expect(book.getByRole('heading', { name: 'Request received' })).toBeVisible();
  await expect(book.getByText('$238.15').first()).toBeVisible();
  const manage = book.getByRole('link', { name: 'View or manage booking' });
  const bookingToken = ((await manage.getAttribute('href')) ?? '').split('/').pop() ?? '';
  expect(bookingToken).toMatch(/^[0-9a-f-]{36}$/);
  // The deposit is 20% of the server total: 47.63.
  // Pass the real function response through, keeping a copy of its body.
  const depositBodies: Array<{ status: number; body: Record<string, unknown> }> = [];
  await book.route('**/functions/v1/payments', async (route) => {
    const response = await route.fetch();
    depositBodies.push({
      status: response.status(),
      body: (await response.json()) as Record<string, unknown>,
    });
    await route.fulfill({ response });
  });
  await book.getByRole('button', { name: 'Pay $47.63 deposit' }).click();
  await expect.poll(() => depositBodies.length).toBe(1);
  expect(depositBodies[0]?.status).toBe(200);
  expect(depositBodies[0]?.body).toMatchObject({
    amount_cents: 4763,
    tip_cents: 0,
    currency: 'usd',
  });
  expect(String(depositBodies[0]?.body.url)).toMatch(/^https:\/\/checkout\.stripe\.com\//);
  await expect.poll(() => stripePages.length).toBe(1);

  // Stripe reports the deposit Checkout paid (signed Connect webhook, metadata
  // contract of booking_deposit_checkout); the booking page confirms it.
  const booked = await rest<Array<{ id: string; customer_id: string }>>(
    'GET',
    `jobs?shop_id=eq.${shopId}&select=id,customer_id`,
    ownerUser,
  );
  expect(booked.json).toHaveLength(1);
  const depositMeta = {
    shop_id: shopId,
    job_id: booked.json[0]?.id ?? '',
    customer_id: booked.json[0]?.customer_id ?? '',
    kind: 'deposit',
    tip_cents: '0',
    source: 'booking_deposit_checkout',
  };
  const paid = await postStripeEvent('checkout.session.completed', account, {
    id: stripeId('cs'),
    object: 'checkout.session',
    mode: 'payment',
    status: 'complete',
    payment_status: 'paid',
    amount_total: 4763,
    currency: 'usd',
    customer: null,
    metadata: depositMeta,
    payment_intent: stripePaymentIntent({
      paymentIntentId: stripeId('pi'),
      chargeId: stripeId('ch'),
      amount: 4763,
      metadata: depositMeta,
    }),
  });
  expect(paid.status, paid.text).toBe(200);
  expect(paid.json).toMatchObject({ handled: true, result: 'applied' });
  await book.goto(`/booking/${bookingToken}?paid=1`);
  await expect(book.getByText('Deposit received — thank you!')).toBeVisible();
  expect(publicApiFailures, 'anonymous page API failures').toEqual([]);
  expect(publicPageErrors, 'anonymous page errors').toEqual([]);
  await anon.close();

  // --- 6. Owner sees the request on the dashboard and approves it
  await page.goto('/app');
  const requests = page.getByRole('region', { name: 'Booking requests' });
  const requestLink = requests.getByRole('link', {
    name: new RegExp(`${customer.first} ${customer.last}`),
  });
  await expect(requestLink).toBeVisible();
  const jobPath = (await requestLink.getAttribute('href')) ?? '';
  expect(jobPath).toMatch(/^\/app\/jobs\/[0-9a-f-]{36}$/);
  await requests
    .getByRole('button', { name: `Approve booking from ${customer.first} ${customer.last}` })
    .click();
  await expect(page.getByText('Booking approved')).toBeVisible();
  await expect(requests.getByText('No requests waiting')).toBeVisible();

  // --- 7. Job detail: add a custom line; totals are recomputed by the server
  await page.goto(jobPath);
  await expect(page.getByRole('heading', { name: /^Job #\d+$/, level: 1 })).toBeVisible();
  const services = page.getByRole('region', { name: 'Services & items' });
  await expect(services.getByText(serviceName)).toBeVisible();
  await expect(services.getByText('$238.15')).toBeVisible();
  await services.getByRole('button', { name: 'Custom item' }).click();
  const lineDialog = page.getByRole('dialog', { name: 'Add custom item' });
  await lineDialog.getByLabel('Name').fill('Headlight restoration');
  await lineDialog.getByLabel('Unit price').fill('40');
  await lineDialog.getByRole('button', { name: 'Add item' }).click();
  await expect(lineDialog).toBeHidden();
  // subtotal 260.00, tax round(26000 × 8.25%) = 21.45, total 281.45
  await expect(services.getByText('$260.00')).toBeVisible();
  await expect(services.getByText('$21.45')).toBeVisible();
  await expect(services.getByText('$281.45')).toBeVisible();
  // The deposit received through Stripe counts against the new total.
  const money = page.getByRole('region', { name: 'Payments' });
  await expect(money).toContainText('$47.63');
  await expect(money).toContainText('$233.82');
  const jobId = jobPath.split('/').pop() ?? '';
  const job = await rest<Array<Record<string, unknown>>>(
    'GET',
    `jobs?id=eq.${jobId}&select=status,subtotal_cents,tax_cents,total_cents,source,scheduled_start`,
    ownerUser,
  );
  expect(job.json[0]).toMatchObject({
    status: 'scheduled',
    source: 'online_booking',
    subtotal_cents: 26000,
    tax_cents: 2145,
    total_cents: 28145,
  });
  // The booked start is one of the slots the real public_booking_slots offered.
  const bookedAt = new Date(String(job.json[0]?.scheduled_start)).getTime();
  expect(lastSlots.map((s) => new Date(s.starts_at).getTime())).toContain(bookedAt);
  expect(apiFailures).toEqual([]);
  expect(pageErrors).toEqual([]);
});
