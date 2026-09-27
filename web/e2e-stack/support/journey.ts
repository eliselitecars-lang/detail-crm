import { createHash, createHmac, randomUUID } from 'node:crypto';
import { expect, type Page } from '@playwright/test';
import { uniqueSuffix, userHeaders, type StackUser } from './stackApi';
import { stackEnv } from './stackEnv';

/**
 * Journey helpers for the real-stack e2e suite (web/e2e-stack/journeys-*.spec.ts).
 *
 * Rules the helpers follow:
 * - App data is written with the test user's own JWT (RLS applies) or anon.
 * - The service role is used ONLY for harness plumbing that the local stack
 *   cannot do by itself (see `markStripeChargesEnabled`) and for read-only
 *   assertions nobody else can make (e.g. reading `messages` status rows).
 * - No fixed sleeps: `eventually` polls a condition with expect.poll.
 */

export interface HttpResult<T = unknown> {
  status: number;
  json: T;
  text: string;
  headers: Headers;
}

export async function http<T = unknown>(
  method: string,
  url: string,
  options: { headers?: Record<string, string>; json?: unknown; raw?: string } = {},
): Promise<HttpResult<T>> {
  const headers: Record<string, string> = { ...(options.headers ?? {}) };
  let body: string | undefined;
  if (options.json !== undefined) {
    headers['content-type'] ??= 'application/json';
    body = JSON.stringify(options.json);
  } else if (options.raw !== undefined) {
    body = options.raw;
  }
  const res = await fetch(url, { method, headers, body });
  const text = await res.text();
  let json: unknown = null;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    json = null;
  }
  return { status: res.status, json: json as T, text, headers: res.headers };
}

export function anonHeaders(): Record<string, string> {
  const env = stackEnv();
  return { apikey: env.anonKey, authorization: `Bearer ${env.anonKey}` };
}

export function serviceHeaders(): Record<string, string> {
  const env = stackEnv();
  return { apikey: env.serviceRoleKey, authorization: `Bearer ${env.serviceRoleKey}` };
}

/** PostgREST call as a user (RLS applies) — returns status + body, never throws. */
export async function rest<T = unknown>(
  method: string,
  path: string,
  who: StackUser | 'anon' | 'service',
  json?: unknown,
  extraHeaders: Record<string, string> = {},
): Promise<HttpResult<T>> {
  const headers =
    who === 'anon' ? anonHeaders() : who === 'service' ? serviceHeaders() : userHeaders(who);
  return http<T>(method, `${stackEnv().apiUrl}/rest/v1/${path}`, {
    headers: { ...headers, prefer: 'return=representation', ...extraHeaders },
    json,
  });
}

/** PostgREST RPC as a user or anon — returns status + body, never throws. */
export async function rpcAs<T = unknown>(
  name: string,
  args: Record<string, unknown>,
  who: StackUser | 'anon',
): Promise<HttpResult<T>> {
  return rest<T>('POST', `rpc/${name}`, who, args);
}

/** Like rpcAs but asserts 2xx and returns the body. */
export async function rpcOk<T = unknown>(
  name: string,
  args: Record<string, unknown>,
  who: StackUser | 'anon',
): Promise<T> {
  const r = await rpcAs<T>(name, args, who);
  expect(r.status, `${name}: ${r.text}`).toBeLessThan(300);
  return r.json;
}

/** Calls an edge function through Kong (like supabase.functions.invoke). */
export async function fn<T = Record<string, unknown>>(
  name: string,
  body: Record<string, unknown>,
  who: StackUser | 'anon' | { headers: Record<string, string> },
  query = '',
): Promise<HttpResult<T>> {
  const headers =
    who === 'anon'
      ? anonHeaders()
      : 'headers' in who
        ? { ...anonHeaders(), ...who.headers }
        : userHeaders(who);
  return http<T>('POST', `${stackEnv().functionsUrl}/${name}${query}`, { headers, json: body });
}

export function cronHeaders(): { headers: Record<string, string> } {
  return { headers: { 'x-cron-secret': stackEnv().cronSecret } };
}

/** Polls `read` until `check` passes (no fixed sleeps). */
export async function eventually<T>(
  read: () => Promise<T>,
  check: (value: T) => boolean,
  message: string,
  timeout = 20_000,
): Promise<T> {
  let last: T | undefined;
  await expect
    .poll(
      async () => {
        last = await read();
        return check(last);
      },
      { message, timeout },
    )
    .toBe(true);
  return last as T;
}

// ---------------------------------------------------------------- UI auth

/** Signs in through the real login page and waits for the staff shell or `expectUrl`. */
export async function loginViaUi(
  page: Page,
  user: Pick<StackUser, 'email' | 'password'>,
  expectUrl: RegExp = /\/app(\/.*)?$/,
  next?: string,
): Promise<void> {
  await page.goto(next ? `/login?next=${encodeURIComponent(next)}` : '/login');
  await page.getByLabel('Email').fill(user.email);
  await page.getByLabel(/^Password/).fill(user.password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(expectUrl);
}

/** Records every API response >= 400 from the stack (to assert a flow ran clean). */
export function trackApiFailures(page: Page, ignore: RegExp[] = []): string[] {
  const failures: string[] = [];
  const api = stackEnv().apiUrl;
  page.on('response', (response) => {
    const url = response.url();
    if (!url.startsWith(api) || response.status() < 400) return;
    if (ignore.some((re) => re.test(url))) return;
    failures.push(`${response.request().method()} ${url} -> ${String(response.status())}`);
  });
  return failures;
}

/**
 * Uncaught page errors, console.error output and failed requests (a clean
 * journey has none). Google Fonts (index.html) is the one external resource;
 * a TLS-intercepting sandbox proxy makes it fail with a certificate error that
 * is environment noise, so failures of that host alone are ignored.
 */
const EXTERNAL_FONT_HOSTS = /^https:\/\/fonts\.(googleapis|gstatic)\.com\//;

export function trackPageErrors(page: Page, ignore: RegExp[] = []): string[] {
  const errors: string[] = [];
  let fontFailures = 0;
  page.on('pageerror', (error) => errors.push(`pageerror: ${error.message}`));
  page.on('requestfailed', (request) => {
    const url = request.url();
    if (EXTERNAL_FONT_HOSTS.test(url)) {
      fontFailures += 1;
      return;
    }
    const failure = request.failure()?.errorText ?? '';
    // Navigations away (e.g. to stubbed Stripe pages) abort in-flight requests.
    if (failure === 'net::ERR_ABORTED') return;
    if (ignore.some((re) => re.test(url))) return;
    errors.push(`requestfailed: ${request.method()} ${url} ${failure}`);
  });
  page.on('console', (msg) => {
    if (msg.type() !== 'error') return;
    const text = msg.text();
    if (fontFailures > 0 && /Failed to load resource: net::ERR_CERT_AUTHORITY_INVALID/.test(text))
      return;
    if (ignore.some((re) => re.test(text))) return;
    errors.push(`console.error: ${text}`);
  });
  return errors;
}

/** Intercepts navigation to Stripe-hosted pages (stripe-mock URLs are not real pages). */
export async function stubStripeHostedPages(page: Page): Promise<string[]> {
  const visited: string[] = [];
  await page.route(/^https:\/\/(checkout|connect|dashboard)\.stripe\.com\//, async (route) => {
    visited.push(route.request().url());
    await route.fulfill({
      status: 200,
      contentType: 'text/html',
      body: '<!doctype html><title>Stripe (stubbed)</title><h1>Stripe Checkout (stubbed by e2e)</h1>',
    });
  });
  return visited;
}

// ----------------------------------------------------------------- Stripe

/**
 * Connects the shop to Stripe through the real `stripe-connect` function
 * (create_account_link → stripe-mock creates an Express account and the
 * function stores it in shop_stripe_accounts). stripe-mock is stateless and
 * every account it returns has charges_enabled=false, so the harness then
 * flips the flags the way a finished Stripe onboarding + account.updated
 * would (service role: shop_stripe_accounts is service-role-write only).
 */
export async function connectStripe(owner: StackUser, shopId: string): Promise<string> {
  const link = await fn<{ stripe_account_id: string; url: string }>(
    'stripe-connect',
    { action: 'create_account_link', shop_id: shopId, request_nonce: randomUUID() },
    owner,
  );
  expect(link.status, link.text).toBe(200);
  const account = link.json.stripe_account_id;
  expect(account).toMatch(/^acct_/);
  await markStripeChargesEnabled(shopId);
  return account;
}

/** Harness plumbing: stripe-mock never finishes onboarding (see connectStripe). */
export async function markStripeChargesEnabled(shopId: string): Promise<void> {
  const r = await rest('PATCH', `shop_stripe_accounts?shop_id=eq.${shopId}`, 'service', {
    charges_enabled: true,
    payouts_enabled: true,
    details_submitted: true,
  });
  expect(r.status, r.text).toBe(200);
  expect((r.json as unknown[]).length).toBe(1);
}

export function stripeId(prefix: string): string {
  return `${prefix}_e2e${randomUUID().replace(/-/g, '').slice(0, 20)}`;
}

/** POSTs a correctly signed Stripe Connect event to the local stripe-webhook function. */
export async function postStripeEvent(
  type: string,
  account: string,
  object: Record<string, unknown>,
): Promise<HttpResult<{ received?: boolean; handled?: boolean; result?: string | null }>> {
  const env = stackEnv();
  const event = {
    id: stripeId('evt'),
    object: 'event',
    api_version: '2026-08-26.dahlia',
    created: Math.floor(Date.now() / 1000),
    livemode: false,
    pending_webhooks: 1,
    request: { id: null, idempotency_key: null },
    type,
    account,
    data: { object },
  };
  const payload = JSON.stringify(event);
  const t = Math.floor(Date.now() / 1000);
  const sig = createHmac('sha256', env.stripeWebhookSecret).update(`${t}.${payload}`).digest('hex');
  return http('POST', `${env.functionsUrl}/stripe-webhook`, {
    headers: { 'content-type': 'application/json', 'stripe-signature': `t=${t},v1=${sig}` },
    raw: payload,
  });
}

/**
 * A card Charge object as Stripe embeds it (expanded `latest_charge`), so the
 * webhook needs no stripe-mock round trip to read brand/last4.
 */
export function stripeCharge(opts: {
  chargeId: string;
  paymentIntentId: string;
  amount: number;
  amountRefunded?: number;
  last4?: string;
}): Record<string, unknown> {
  return {
    id: opts.chargeId,
    object: 'charge',
    amount: opts.amount,
    amount_captured: opts.amount,
    amount_refunded: opts.amountRefunded ?? 0,
    refunded: (opts.amountRefunded ?? 0) >= opts.amount,
    captured: true,
    paid: true,
    status: 'succeeded',
    currency: 'usd',
    created: Math.floor(Date.now() / 1000),
    payment_intent: opts.paymentIntentId,
    payment_method: stripeId('pm'),
    payment_method_details: {
      type: 'card',
      card: { brand: 'visa', last4: opts.last4 ?? '4242', exp_month: 12, exp_year: 2030 },
    },
  };
}

/** A succeeded PaymentIntent (expanded, with its latest charge) carrying our metadata. */
export function stripePaymentIntent(opts: {
  paymentIntentId: string;
  chargeId: string;
  amount: number;
  metadata: Record<string, string>;
}): Record<string, unknown> {
  return {
    id: opts.paymentIntentId,
    object: 'payment_intent',
    amount: opts.amount,
    amount_received: opts.amount,
    currency: 'usd',
    status: 'succeeded',
    customer: null,
    payment_method: null,
    payment_method_types: ['card'],
    setup_future_usage: null,
    metadata: opts.metadata,
    latest_charge: stripeCharge({
      chargeId: opts.chargeId,
      paymentIntentId: opts.paymentIntentId,
      amount: opts.amount,
    }),
  };
}

// ----------------------------------------------------------------- Twilio

/**
 * Operator step (supabase/setup/twilio.md): the platform provisions a Twilio
 * number for the shop — `shop_sms_numbers` is service-role-only by design —
 * and the number's inbound webhook in Twilio (here: the Twilio mock) names
 * the shop. Only then may an owner put it in Settings → SMS.
 */
export async function provisionSmsNumber(shopId: string, phone: string): Promise<void> {
  const r = await rest('POST', 'shop_sms_numbers', 'service', {
    phone_number: phone,
    shop_id: shopId,
  });
  expect(r.status, r.text).toBe(201);
  await registerTwilioNumber(shopId, phone);
}

/** Registers the shop's number with the Twilio mock (SmsUrl bound to the shop). */
export async function registerTwilioNumber(shopId: string, phone: string): Promise<void> {
  const env = stackEnv();
  const smsUrl = `${env.functionsUrl}/messaging?action=twilio_inbound&shop_id=${shopId}`;
  const r = await http('POST', `${env.providerMockUrl}/__control/twilio/numbers`, {
    json: { phone_number: phone, sms_url: smsUrl },
  });
  expect(r.status, r.text).toBe(200);
}

/** POSTs a correctly signed Twilio inbound SMS webhook for the shop. */
export async function postTwilioInbound(
  shopId: string,
  params: { From: string; To: string; Body: string },
): Promise<HttpResult> {
  const env = stackEnv();
  const query = `?action=twilio_inbound&shop_id=${shopId}`;
  const url = `${env.functionsUrl}/messaging${query}`;
  const all: Record<string, string> = {
    AccountSid: 'AC00000000000000000000000000000000',
    MessageSid: `SM${createHash('md5').update(randomUUID()).digest('hex')}`,
    NumMedia: '0',
    ...params,
  };
  const data =
    url +
    Object.keys(all)
      .sort()
      .map((k) => k + (all[k] ?? ''))
      .join('');
  const sig = createHmac('sha1', env.twilioAuthToken).update(data).digest('base64');
  return http('POST', url, {
    headers: { 'content-type': 'application/x-www-form-urlencoded', 'x-twilio-signature': sig },
    raw: new URLSearchParams(all).toString(),
  });
}

export interface ProviderRequest {
  at: string;
  service: string;
  method: string;
  path: string;
  body: Record<string, unknown> | string | null;
}

/** Recorded provider-mock requests (never cleared: tests filter by their own unique data). */
export async function providerLog(service: 'twilio' | 'resend'): Promise<ProviderRequest[]> {
  const r = await http<ProviderRequest[]>(
    'GET',
    `${stackEnv().providerMockUrl}/__control/requests?service=${service}`,
  );
  expect(r.status).toBe(200);
  return r.json;
}

/** A unique valid NANP number (+1 205 NXX XXXX: exchange 200–999). */
export function uniquePhone(): string {
  const n = Number.parseInt(uniqueSuffix().slice(0, 8), 16);
  const exchange = 200 + (n % 800);
  const line = Math.floor(n / 800) % 10_000;
  return `+1205${String(exchange)}${String(line).padStart(4, '0')}`;
}

// --------------------------------------------------------------- dates

/** YYYY-MM-DD of `date` in the given IANA zone. */
export function ymdIn(date: Date, timeZone: string): string {
  return new Intl.DateTimeFormat('en-CA', {
    timeZone,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).format(date);
}

// ------------------------------------------------------- online booking

export interface BookableShop {
  serviceId: string;
  categoryId: string;
}

/**
 * Arranges a shop for online booking as its owner (PostgREST + RLS): open
 * every day 08:00–18:00, no lead time, one online-bookable service with a
 * base price, booking enabled (requests, no deposit).
 */
export async function arrangeBookableShop(
  owner: StackUser,
  shopId: string,
  service: { name: string; cents: number; minutes?: number },
): Promise<BookableShop> {
  const hours = await rest(
    'POST',
    'business_hours',
    owner,
    [0, 1, 2, 3, 4, 5, 6].map((weekday) => ({
      shop_id: shopId,
      weekday,
      opens_at: '08:00',
      closes_at: '18:00',
    })),
  );
  expect(hours.status, hours.text).toBe(201);
  const svc = await rest<Array<{ id: string }>>('POST', 'services?select=id', owner, {
    shop_id: shopId,
    name: service.name,
    duration_minutes: service.minutes ?? 60,
    online_bookable: true,
  });
  expect(svc.status, svc.text).toBe(201);
  const serviceId = svc.json[0]?.id ?? '';
  const price = await rest('POST', 'service_prices', owner, {
    shop_id: shopId,
    service_id: serviceId,
    vehicle_category_id: null,
    price_cents: service.cents,
  });
  expect(price.status, price.text).toBe(201);
  const settings = await rest(
    'PATCH',
    `booking_settings?shop_id=eq.${shopId}&select=shop_id`,
    owner,
    {
      enabled: true,
      lead_time_minutes: 0,
    },
  );
  expect(settings.status, settings.text).toBe(200);
  const cats = await rest<Array<{ id: string }>>(
    'GET',
    `vehicle_categories?shop_id=eq.${shopId}&select=id&order=sort&limit=1`,
    owner,
  );
  return { serviceId, categoryId: cats.json[0]?.id ?? '' };
}

export interface CreatedBooking {
  job_token: string;
  job_number: number;
  status: string;
  total_cents: number;
}

/** Books the first open slot anonymously (real get_available_slots + create_online_booking). */
export async function bookOnline(
  slug: string,
  shop: BookableShop,
  customer: { first_name: string; last_name: string; email: string; phone?: string },
  vehicle = { year: 2021, make: 'Toyota', model: 'Camry', color: 'Blue' },
): Promise<CreatedBooking & { starts_at: string }> {
  const from = new Date(Date.now() + 24 * 3600 * 1000);
  const to = new Date(Date.now() + 8 * 24 * 3600 * 1000);
  const slots = await rpcOk<Array<{ starts_at: string }>>(
    'get_available_slots',
    {
      p_shop_slug: slug,
      p_service_ids: [shop.serviceId],
      p_vehicle_category_id: shop.categoryId,
      p_from: from.toISOString().slice(0, 10),
      p_to: to.toISOString().slice(0, 10),
    },
    'anon',
  );
  expect(slots.length).toBeGreaterThan(0);
  const startsAt = slots[0]?.starts_at ?? '';
  const booking = await rpcOk<CreatedBooking>(
    'create_online_booking',
    {
      p_slug: slug,
      p_payload: {
        customer: {
          ...customer,
          phone: customer.phone ?? null,
          sms_opt_in: Boolean(customer.phone),
          email_opt_in: false,
        },
        vehicle: { ...vehicle, category_id: shop.categoryId },
        service_ids: [shop.serviceId],
        addon_ids: [],
        starts_at: startsAt,
        location: { type: 'shop' },
        notes: null,
        coupon_code: null,
      },
    },
    'anon',
  );
  return { ...booking, starts_at: startsAt };
}
