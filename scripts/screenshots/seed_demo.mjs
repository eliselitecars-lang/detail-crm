#!/usr/bin/env node
/**
 * seed_demo.mjs — fills the LOCAL real stack (scripts/stack/up.sh) with a
 * believable, clearly fictional SAMPLE detailing shop for screenshots.
 *
 * SAMPLE DATA FOR SCREENSHOTS ONLY. It never ships in the product, never runs
 * against a hosted project (it refuses non-local API URLs unless
 * SEED_ALLOW_REMOTE=1), and every person, phone number (555-01xx) and email
 * (@example.com) is made up.
 *
 * How records are created (same paths the apps use):
 *   - sign-ups through GoTrue; the owner's JWT calls the real RPCs, PostgREST
 *     (RLS applies) and edge functions (invites, messaging, stripe-connect);
 *   - customers book / approve / sign up as anon or as their own portal user;
 *   - card money arrives as correctly signed Stripe Connect webhooks (the
 *     charge's `created` time dates the payment, exactly as Stripe reports it);
 *   - inbound texts are correctly signed Twilio webhooks.
 * The service role is used only for operator plumbing, as the e2e journeys
 * do (Stripe charges_enabled, provisioning the shop's SMS number), plus one
 * clearly separated "history" step: the stack's clock cannot be moved, so the
 * server-stamped times of PAST work (job started/completed, invoice
 * issued/due, customer-since) are shifted back to the day the work happened.
 *
 * Re-runnable: the first run on a fresh database uses the canonical logins
 * (jordan.avery@example.com …, booking link /book/summit-auto). A later run
 * detects that and creates a fresh copy of the shop with a run suffix on the
 * slug and every login email (e.g. jordan.avery+r1a2b@example.com).
 * scripts/screenshots/.state/demo.json always describes the latest run.
 *
 * Usage:  node scripts/screenshots/seed_demo.mjs   (Node 22+, no dependencies)
 * Reads STACK_API_URL, STACK_ANON_KEY, STACK_SERVICE_ROLE_KEY, … from the
 * environment or scripts/stack/.state/stack.env.
 */
import { createHash, createHmac, randomUUID } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..', '..');
const STATE_DIR = join(HERE, '.state');
const OUT_FILE = join(STATE_DIR, 'demo.json');

// ------------------------------------------------------------------ env

function loadEnv() {
  const file = join(ROOT, 'scripts', 'stack', '.state', 'stack.env');
  const fromFile = {};
  if (existsSync(file)) {
    for (const line of readFileSync(file, 'utf8').split('\n')) {
      const m = /^([A-Z0-9_]+)=(.*)$/.exec(line.trim());
      if (m) fromFile[m[1]] = m[2];
    }
  }
  const get = (name, fallback) => {
    const v = process.env[name] ?? fromFile[name] ?? fallback;
    if (v === undefined || v === '') {
      throw new Error(`${name} is not set: start the stack with scripts/stack/up.sh (writes ${file})`);
    }
    return v;
  };
  const apiUrl = get('STACK_API_URL');
  return {
    apiUrl,
    functionsUrl: get('STACK_FUNCTIONS_URL', `${apiUrl}/functions/v1`),
    anonKey: get('STACK_ANON_KEY'),
    serviceRoleKey: get('STACK_SERVICE_ROLE_KEY'),
    providerMockUrl: get('STACK_PROVIDER_MOCK_URL', 'http://127.0.0.1:12120'),
    stripeWebhookSecret: get('STACK_STRIPE_WEBHOOK_SECRET'),
    twilioAuthToken: get('STACK_TWILIO_AUTH_TOKEN'),
    cronSecret: get('STACK_CRON_SECRET'),
    appUrl: get('STACK_APP_URL', 'http://127.0.0.1:5173'),
  };
}

const env = loadEnv();
if (!/^https?:\/\/(127\.0\.0\.1|localhost|host\.docker\.internal)(:\d+)?$/.test(env.apiUrl)) {
  if (process.env.SEED_ALLOW_REMOTE !== '1') {
    throw new Error(`refusing to seed sample data into ${env.apiUrl} (local stack only)`);
  }
}

// ------------------------------------------------------------------ http

let calls = 0;

async function http(method, url, { headers = {}, json, raw } = {}) {
  calls += 1;
  const h = { ...headers };
  let body;
  if (json !== undefined) {
    h['content-type'] ??= 'application/json';
    body = JSON.stringify(json);
  } else if (raw !== undefined) {
    body = raw;
  }
  const res = await fetch(url, { method, headers: h, body });
  const text = await res.text();
  let parsed = null;
  try {
    parsed = text ? JSON.parse(text) : null;
  } catch {
    parsed = null;
  }
  return { status: res.status, json: parsed, text };
}

/** Throws with the failing call's status and body unless the status is expected. */
function must(res, what, ok = (s) => s >= 200 && s < 300) {
  if (!ok(res.status)) {
    throw new Error(`${what} -> HTTP ${res.status}: ${res.text.slice(0, 2000)}`);
  }
  return res.json;
}

const anon = { kind: 'anon' };
const service = { kind: 'service' };

function authHeaders(who) {
  if (who === service) return { apikey: env.serviceRoleKey, authorization: `Bearer ${env.serviceRoleKey}` };
  if (who === anon || !who) return { apikey: env.anonKey, authorization: `Bearer ${env.anonKey}` };
  return { apikey: env.anonKey, authorization: `Bearer ${who.accessToken}` };
}

async function rest(method, path, who, json, extra = {}) {
  const r = await http(method, `${env.apiUrl}/rest/v1/${path}`, {
    headers: { ...authHeaders(who), prefer: 'return=representation', ...extra },
    json,
  });
  return must(r, `${method} /rest/v1/${path}`);
}

async function rpc(name, args, who) {
  const r = await http('POST', `${env.apiUrl}/rest/v1/rpc/${name}`, {
    headers: authHeaders(who),
    json: args,
  });
  return must(r, `rpc ${name}`);
}

async function fn(name, body, who, query = '', extraHeaders = {}) {
  const r = await http('POST', `${env.functionsUrl}/${name}${query}`, {
    headers: { ...authHeaders(who), ...extraHeaders },
    json: body,
  });
  return must(r, `function ${name} ${body.action ?? ''}`.trim());
}

// ------------------------------------------------------------------ auth

async function signUp(email, password, fullName) {
  const r = await http('POST', `${env.apiUrl}/auth/v1/signup`, {
    headers: { apikey: env.anonKey },
    json: { email, password, data: { full_name: fullName } },
  });
  const body = must(r, `GoTrue signup ${email}`);
  if (!body?.access_token) {
    throw new Error(`GoTrue signup ${email}: no session (email confirmations must be off locally): ${r.text}`);
  }
  return { id: body.user.id, email, password, name: fullName, accessToken: body.access_token };
}

/** Whether a GoTrue account exists (admin API, service role: harness check only). */
async function emailTaken(email) {
  const list = await http(
    'GET',
    `${env.apiUrl}/auth/v1/admin/users?per_page=1000&page=1`,
    { headers: authHeaders(service) },
  );
  const users = must(list, 'GoTrue admin list users')?.users ?? [];
  return users.some((u) => String(u.email).toLowerCase() === email.toLowerCase());
}

// ------------------------------------------------------------------ time (shop zone)

const TZ = 'America/Chicago';

function ymdIn(date, timeZone = TZ) {
  return new Intl.DateTimeFormat('en-CA', {
    timeZone,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).format(date);
}

function offsetMinutes(date, timeZone = TZ) {
  const parts = Object.fromEntries(
    new Intl.DateTimeFormat('en-US', {
      timeZone,
      hourCycle: 'h23',
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit',
    })
      .formatToParts(date)
      .map((p) => [p.type, p.value]),
  );
  const asUtc = Date.UTC(
    Number(parts.year),
    Number(parts.month) - 1,
    Number(parts.day),
    Number(parts.hour),
    Number(parts.minute),
    Number(parts.second),
  );
  return Math.round((asUtc - date.getTime()) / 60000);
}

/** The instant of a local wall-clock time ('YYYY-MM-DD', 'HH:MM') in the shop zone. */
function at(ymd, hm) {
  const [y, m, d] = ymd.split('-').map(Number);
  const [hh, mm] = hm.split(':').map(Number);
  const guess = Date.UTC(y, m - 1, d, hh, mm);
  let t = guess - offsetMinutes(new Date(guess)) * 60000;
  t = guess - offsetMinutes(new Date(t)) * 60000; // DST edge
  return new Date(t);
}

function addDays(ymd, n) {
  const [y, m, d] = ymd.split('-').map(Number);
  return new Date(Date.UTC(y, m - 1, d + n)).toISOString().slice(0, 10);
}

function weekday(ymd) {
  const [y, m, d] = ymd.split('-').map(Number);
  return new Date(Date.UTC(y, m - 1, d)).getUTCDay(); // 0 = Sunday
}

const NOW = new Date();
const TODAY = ymdIn(NOW);

/** The date `n` work days (Mon–Sat; Sundays are closed) before or after today. */
function workday(n) {
  let day = TODAY;
  for (let left = Math.abs(n); left > 0; ) {
    day = addDays(day, n < 0 ? -1 : 1);
    if (weekday(day) !== 0) left -= 1;
  }
  return day;
}

const minutes = (ms) => ms * 60000;
const unix = (date) => Math.floor(date.getTime() / 1000);

// ------------------------------------------------------------------ provider helpers

function stripeId(prefix) {
  return `${prefix}_demo${randomUUID().replace(/-/g, '').slice(0, 20)}`;
}

async function postStripeEvent(type, account, object, created) {
  const event = {
    id: stripeId('evt'),
    object: 'event',
    api_version: '2026-08-26.dahlia',
    created: created ?? unix(new Date()),
    livemode: false,
    pending_webhooks: 1,
    request: { id: null, idempotency_key: null },
    type,
    account,
    data: { object },
  };
  const payload = JSON.stringify(event);
  const t = unix(new Date());
  const sig = createHmac('sha256', env.stripeWebhookSecret).update(`${t}.${payload}`).digest('hex');
  const r = await http('POST', `${env.functionsUrl}/stripe-webhook`, {
    headers: { 'content-type': 'application/json', 'stripe-signature': `t=${t},v1=${sig}` },
    raw: payload,
  });
  const body = must(r, `stripe-webhook ${type}`);
  if (body?.handled === false || (body?.result && body.result !== 'applied')) {
    throw new Error(`stripe-webhook ${type} not applied: ${r.text}`);
  }
  return body;
}

const CARDS = {
  visa: { brand: 'visa', last4: '4242' },
  mastercard: { brand: 'mastercard', last4: '4444' },
  amex: { brand: 'amex', last4: '0005' },
  discover: { brand: 'discover', last4: '1117' },
};

function stripePaymentIntent({ amount, metadata, card, created }) {
  const pi = stripeId('pi');
  const ch = stripeId('ch');
  return {
    id: pi,
    object: 'payment_intent',
    amount,
    amount_received: amount,
    currency: 'usd',
    status: 'succeeded',
    customer: null,
    payment_method: null,
    payment_method_types: ['card'],
    setup_future_usage: null,
    metadata,
    latest_charge: {
      id: ch,
      object: 'charge',
      amount,
      amount_captured: amount,
      amount_refunded: 0,
      refunded: false,
      captured: true,
      paid: true,
      status: 'succeeded',
      currency: 'usd',
      created,
      payment_intent: pi,
      payment_method: stripeId('pm'),
      payment_method_details: {
        type: 'card',
        card: { brand: card.brand, last4: card.last4, exp_month: 11, exp_year: 2029 },
      },
    },
  };
}

/** A paid Stripe Checkout Session (invoice pay link / deposit link), as Stripe reports it. */
async function payByCheckout({ account, amount, metadata, card, paidAt }) {
  const created = unix(paidAt);
  return postStripeEvent(
    'checkout.session.completed',
    account,
    {
      id: stripeId('cs'),
      object: 'checkout.session',
      mode: 'payment',
      status: 'complete',
      payment_status: 'paid',
      amount_total: amount,
      currency: 'usd',
      customer: null,
      client_reference_id: metadata.invoice_id ?? metadata.job_id ?? null,
      metadata,
      payment_intent: stripePaymentIntent({ amount, metadata, card, created }),
    },
    created,
  );
}

async function registerTwilioNumber(shopId, phone) {
  const smsUrl = `${env.functionsUrl}/messaging?action=twilio_inbound&shop_id=${shopId}`;
  const r = await http('POST', `${env.providerMockUrl}/__control/twilio/numbers`, {
    json: { phone_number: phone, sms_url: smsUrl },
  });
  must(r, 'provider mock: register Twilio number');
}

async function postTwilioInbound(shopId, params) {
  const query = `?action=twilio_inbound&shop_id=${shopId}`;
  const url = `${env.functionsUrl}/messaging${query}`;
  const all = {
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
  const r = await http('POST', url, {
    headers: { 'content-type': 'application/x-www-form-urlencoded', 'x-twilio-signature': sig },
    raw: new URLSearchParams(all).toString(),
  });
  must(r, 'Twilio inbound webhook');
}

// ------------------------------------------------------------------ sample content

const PASSWORDS = {
  owner: 'Summit-Demo-Owner-2026!',
  technician: 'Summit-Demo-Tech-2026!',
  client: 'Summit-Demo-Client-2026!',
};

const SHOP = {
  name: 'Summit Auto Detailing',
  slugBase: 'summit-auto',
  phone: '+16155550100',
  email: 'hello@summitautodetailing.example.com',
  website: 'https://summitautodetailing.example.com',
  address_line1: '2417 Charlotte Ave',
  city: 'Nashville',
  region: 'TN',
  postal_code: '37203',
  lat: 36.1531,
  lng: -86.8137,
  tax_rate_bps: 925,
  brand_color: '#2563EB',
};

// [Car, Small SUV, Large SUV / Truck, Van] in dollars
const SERVICES = [
  { key: 'full', cat: 'Detailing', name: 'Full Detail', minutes: 240, online: true,
    description: 'Hand wash, clay decontamination, one-step sealant, full interior shampoo and steam, leather care and glass.',
    prices: [249, 279, 319, 349] },
  { key: 'interior', cat: 'Detailing', name: 'Interior Detail', minutes: 180, online: true,
    description: 'Deep vacuum, carpet and upholstery shampoo, steam-cleaned vents and cupholders, leather clean and condition.',
    prices: [159, 179, 209, 229] },
  { key: 'exterior', cat: 'Detailing', name: 'Exterior Wash & Wax', minutes: 120, online: true,
    description: 'Foam pre-wash, two-bucket hand wash, wheels and tires, spray wax and streak-free glass.',
    prices: [99, 115, 135, 149] },
  { key: 'maint', cat: 'Detailing', name: 'Maintenance Wash', minutes: 90, online: true,
    description: 'Upkeep wash for coated or regularly detailed vehicles, quick interior wipe-down and vacuum.',
    prices: [59, 69, 79, 89] },
  { key: 'correction', cat: 'Paint & Protection', name: 'Paint Correction (1-Step)', minutes: 360, online: true,
    description: 'Machine polish that removes light swirls and restores gloss; includes full decontamination.',
    prices: [449, 529, 619, 679] },
  { key: 'ceramic', cat: 'Paint & Protection', name: 'Ceramic Coating (3-Year)', minutes: 480, online: false,
    description: 'Paint prep and a 3-year ceramic coating on paint, wheels faces and glass. Quoted after an inspection.',
    prices: [899, 1049, 1199, 1299] },
  { key: 'ppf', cat: 'Paint & Protection', name: 'PPF Front End', minutes: 480, online: false,
    description: 'Self-healing paint protection film on bumper, full hood, fenders and mirrors.',
    prices: [1495, 1595, 1795, 1895] },
  { key: 'tint', cat: 'Window Tint', name: 'Window Tint (Ceramic Film)', minutes: 180, online: true,
    description: 'Ceramic window film on side and rear windows. Lifetime warranty on the film.',
    prices: [349, 379, 429, 449] },
];

const ADDONS = [
  { key: 'engine', name: 'Engine Bay Detail', minutes: 45, price: 49, for: ['full', 'exterior', 'correction'] },
  { key: 'headlights', name: 'Headlight Restoration', minutes: 45, price: 79, for: ['full', 'exterior', 'maint', 'correction'] },
  { key: 'pethair', name: 'Pet Hair Removal', minutes: 45, price: 45, for: ['full', 'interior'] },
  { key: 'odor', name: 'Odor Elimination', minutes: 60, price: 65, for: ['full', 'interior'] },
  { key: 'clay', name: 'Clay Bar & Iron Decon', minutes: 45, price: 59, for: ['exterior', 'maint'] },
];

// size: 0 Car, 1 Small SUV, 2 Large SUV / Truck, 3 Van
const CUSTOMERS = [
  { key: 'emily', first: 'Emily', last: 'Carter', phone: '0101', city: 'Nashville', zip: '37212', street: '1814 Belmont Blvd',
    source: 'google', tags: ['VIP'], notes: 'Prefers texts. Two dogs, expect pet hair in the third row.',
    vehicles: [{ year: 2023, make: 'Tesla', model: 'Model Y', trim: 'Long Range', color: 'Pearl White', size: 1, plate: 'BKX-4821' }] },
  { key: 'michael', first: 'Michael', last: 'Thompson', phone: '0102', city: 'Franklin', zip: '37064', street: '412 Lewisburg Pike',
    source: 'referral', tags: [], notes: null,
    vehicles: [{ year: 2021, make: 'Ford', model: 'F-150', trim: 'Lariat', color: 'Agate Black', size: 2, plate: 'TNF-2290' }] },
  { key: 'sarah', first: 'Sarah', last: 'Nguyen', phone: '0103', city: 'Nashville', zip: '37209', street: '5310 Charlotte Pike',
    source: 'instagram', tags: [], notes: null,
    vehicles: [{ year: 2023, make: 'Honda', model: 'Civic', trim: 'Sport', color: 'Rallye Red', size: 0, plate: 'CVC-7714' }] },
  { key: 'david', first: 'David', last: 'Martinez', phone: '0104', city: 'Brentwood', zip: '37027', street: '9 Wildwood Ct',
    source: 'google', tags: ['Mobile'], notes: 'Gate code 4512. Park on the left side of the driveway.',
    vehicles: [{ year: 2020, make: 'Chevrolet', model: 'Tahoe', trim: 'LT', color: 'Summit White', size: 2, plate: 'DMT-0520' }] },
  { key: 'jessica', first: 'Jessica', last: 'Patel', phone: '0105', city: 'Nashville', zip: '37215', street: '3604 Hillsboro Pike',
    source: 'referral', tags: ['VIP', 'Ceramic'], notes: null,
    vehicles: [{ year: 2024, make: 'BMW', model: 'X5', trim: 'xDrive40i', color: 'Phytonic Blue', size: 1, plate: 'JPX-5550' }] },
  { key: 'chris', first: 'Christopher', last: 'Lee', phone: '0106', city: 'Nashville', zip: '37205', street: '118 Westview Ave',
    source: 'instagram', tags: ['Ceramic'], notes: 'Garage-kept. Hand dry only, no forced air on the wheels.',
    vehicles: [{ year: 2019, make: 'Porsche', model: '911', trim: 'Carrera S', color: 'GT Silver', size: 0, plate: '911-CLS' }] },
  { key: 'ashley', first: 'Ashley', last: 'Robinson', phone: '0107', city: 'Nashville', zip: '37206', street: '1020 Fatherland St',
    source: 'facebook', tags: [], notes: null,
    vehicles: [{ year: 2022, make: 'Toyota', model: 'RAV4', trim: 'XLE', color: 'Lunar Rock', size: 1, plate: 'RAV-3307' }] },
  { key: 'daniel', first: 'Daniel', last: 'Walker', phone: '0108', city: 'Mt. Juliet', zip: '37122', street: '77 Providence Pkwy',
    source: 'walk_in', tags: [], notes: null,
    vehicles: [{ year: 2023, make: 'Ram', model: '1500', trim: 'Big Horn', color: 'Granite Crystal', size: 2, plate: 'RMW-1500' }] },
  { key: 'megan', first: 'Megan', last: 'Brooks', phone: '0109', city: 'Nashville', zip: '37204', street: '2905 12th Ave S',
    source: 'google', tags: [], notes: null,
    vehicles: [{ year: 2021, make: 'Audi', model: 'Q5', trim: 'Premium Plus', color: 'Navarra Blue', size: 1, plate: 'AQ5-6612' }] },
  { key: 'ryan', first: 'Ryan', last: 'Mitchell', phone: '0110', city: 'Hendersonville', zip: '37075', street: '48 Saundersville Rd',
    source: 'referral', tags: [], notes: null,
    vehicles: [{ year: 2024, make: 'Toyota', model: 'Tacoma', trim: 'TRD Off-Road', color: 'Ice Cap', size: 2, plate: 'TRD-2404' }] },
  { key: 'lauren', first: 'Lauren', last: 'Hayes', phone: '0111', city: 'Nashville', zip: '37203', street: '600 Church St, Apt 1204',
    source: 'google', tags: ['Mobile'], notes: 'Condo garage, level P2. Text on arrival.',
    vehicles: [{ year: 2020, make: 'Mercedes-Benz', model: 'C 300', trim: 'Sedan', color: 'Obsidian Black', size: 0, plate: 'LHC-3000' }] },
  { key: 'kevin', first: 'Kevin', last: 'Sullivan', phone: '0112', city: 'Franklin', zip: '37069', street: '1601 Westhaven Blvd',
    source: 'facebook', tags: [], notes: null,
    vehicles: [{ year: 2023, make: 'Jeep', model: 'Grand Cherokee', trim: 'Limited', color: 'Velvet Red', size: 1, plate: 'JGC-8810' }] },
  { key: 'olivia', first: 'Olivia', last: 'Bennett', phone: '0113', city: 'Nashville', zip: '37211', street: '4720 Nolensville Pike',
    source: 'google', tags: ['Mobile'], notes: null,
    vehicles: [{ year: 2022, make: 'Kia', model: 'Telluride', trim: 'SX', color: 'Gravity Gray', size: 2, plate: 'KTS-2201' }] },
  { key: 'brandon', first: 'Brandon', last: 'Foster', phone: '0114', city: 'Nashville', zip: '37220', street: '1236 Otter Creek Rd',
    source: 'referral', tags: ['VIP'], notes: 'Two vehicles. Corvette is a weekend car; Sierra is the daily driver.',
    vehicles: [
      { year: 2021, make: 'Chevrolet', model: 'Corvette', trim: 'Stingray 2LT', color: 'Torch Red', size: 0, plate: 'C8-FOSTR' },
      { year: 2023, make: 'GMC', model: 'Sierra 1500', trim: 'Denali', color: 'Onyx Black', size: 2, plate: 'GMC-1923' },
    ] },
];

/**
 * Jobs relative to today in the shop zone. pay: card | cash | partial | open
 * | overdue | deposit. who: tech | owner | both.
 */
const JOBS = [
  // ---- past, completed
  { day: -15, at: '09:00', c: 'david', svc: ['full'], add: ['pethair'], loc: 'mobile', who: 'tech', pay: 'card', card: 'visa', tip: 4000 },
  { day: -13, at: '08:30', c: 'chris', svc: ['correction'], add: [], loc: 'shop', who: 'both', pay: 'card', card: 'amex',
    internal: 'Swirls on driver door and roof. 80% correction achieved, customer happy.' },
  { day: -12, at: '10:00', c: 'ashley', svc: ['interior'], add: ['odor'], loc: 'mobile', who: 'tech', pay: 'card', card: 'mastercard' },
  { day: -11, at: '09:00', c: 'megan', svc: ['tint'], add: [], loc: 'shop', who: 'owner', pay: 'card', card: 'visa', tip: 2000 },
  { day: -9, at: '08:00', c: 'daniel', svc: ['full'], add: ['engine'], loc: 'shop', who: 'tech', pay: 'overdue' },
  { day: -8, at: '09:30', c: 'lauren', svc: ['exterior'], add: ['clay'], loc: 'mobile', who: 'tech', pay: 'card', card: 'visa', tip: 1500 },
  { day: -7, at: '08:00', c: 'ryan', svc: ['ppf'], add: [], loc: 'shop', who: 'both', pay: 'card', card: 'discover' },
  { day: -6, at: '10:00', c: 'kevin', svc: ['interior'], add: [], loc: 'mobile', who: 'tech', pay: 'partial', card: 'visa', partial: 10000 },
  { day: -4, at: '09:00', c: 'olivia', svc: ['full'], add: [], loc: 'mobile', who: 'tech', pay: 'card', card: 'mastercard', tip: 3000 },
  { day: -3, at: '08:30', c: 'jessica', svc: ['ceramic'], add: [], loc: 'shop', who: 'both', pay: 'card', card: 'amex',
    internal: 'Coated paint, wheel faces and glass. Cure 24h before washing; follow-up maintenance wash in 2 weeks.' },
  { day: -2, at: '09:00', c: 'sarah', svc: ['maint'], add: ['headlights'], loc: 'mobile', who: 'tech', pay: 'card', card: 'visa', tip: 1000 },
  { day: -1, at: '10:00', c: 'brandon', v: 0, svc: ['correction'], add: [], loc: 'shop', who: 'owner', pay: 'open' },
  // ---- today
  { day: 0, at: '08:00', c: 'michael', svc: ['exterior'], add: [], loc: 'shop', who: 'tech', status: 'completed', pay: 'cash', tip: 1500 },
  { day: 0, at: '09:30', c: 'emily', svc: ['full'], add: ['pethair'], loc: 'shop', who: 'tech', status: 'in_progress', checklist: true,
    notes: 'Customer will pick up after work. Spare key in the lockbox.' },
  { day: 0, at: '13:00', c: 'david', svc: ['maint'], add: [], loc: 'mobile', who: 'tech', status: 'en_route', onMyWay: true },
  { day: 0, at: '15:30', c: 'ryan', svc: ['interior'], add: [], loc: 'mobile', who: 'owner', status: 'confirmed' },
  // ---- upcoming
  { day: 1, at: '09:00', c: 'brandon', v: 1, svc: ['full'], add: [], loc: 'shop', who: 'tech', status: 'confirmed' },
  { day: 2, at: '08:00', c: 'megan', svc: ['ceramic'], add: [], loc: 'shop', who: 'both', status: 'confirmed', pay: 'deposit', deposit: 25000, card: 'visa' },
  { day: 2, at: '13:30', c: 'kevin', svc: ['exterior'], add: ['clay'], loc: 'mobile', who: 'tech' },
  { day: 3, at: '09:00', c: 'lauren', svc: ['correction'], add: [], loc: 'shop', who: 'owner' },
  { day: 4, at: '10:00', c: 'sarah', svc: ['tint'], add: [], loc: 'shop', who: 'tech' },
  { day: 5, at: '09:00', c: 'chris', svc: ['maint'], add: [], loc: 'mobile', who: 'tech' },
  { day: 7, at: '08:00', c: 'jessica', svc: ['maint'], add: [], loc: 'mobile', who: 'tech',
    notes: 'Two-week ceramic follow-up wash (pH-neutral soap only).' },
  { day: 8, at: '10:00', c: 'emily', svc: ['interior'], add: [], loc: 'mobile', who: 'tech' },
  { day: 9, at: '09:00', c: 'olivia', svc: ['exterior'], add: [], loc: 'mobile', who: 'tech' },
];

const RESOURCES = [
  { key: 'bay1', name: 'Bay 1', kind: 'bay' },
  { key: 'bay2', name: 'Bay 2', kind: 'bay' },
  { key: 'van', name: 'Mobile Van', kind: 'van' },
];

// ------------------------------------------------------------------ main

const log = (msg) => console.log(`[seed] ${msg}`);

async function main() {
  const started = Date.now();
  log(`API ${env.apiUrl} · shop day ${TODAY} (${TZ})`);

  // --- run identity (canonical first, suffixed copy on re-runs)
  let sfx = process.env.SEED_SUFFIX ?? '';
  if (!sfx && (await emailTaken('jordan.avery@example.com'))) {
    sfx = `r${Date.now().toString(36).slice(-5)}`;
    log(`canonical demo shop already exists: creating a fresh copy (suffix ${sfx})`);
  }
  const login = (local) => (sfx ? `${local}+${sfx}@example.com` : `${local}@example.com`);
  const slug = sfx ? `${SHOP.slugBase}-${sfx}` : SHOP.slugBase;

  // --- 1. owner signs up and onboards the shop (create_shop + details + hours)
  const owner = await signUp(login('jordan.avery'), PASSWORDS.owner, 'Jordan Avery');
  log(`owner ${owner.email}`);
  const created = await rpc(
    'create_shop',
    {
      p_name: SHOP.name,
      p_slug: slug,
      p_timezone: TZ,
      p_business_type: 'both',
      p_email: SHOP.email,
      p_phone: SHOP.phone,
    },
    owner,
  );
  const shopId = created.id;
  await rest('PATCH', `shops?id=eq.${shopId}&select=id`, owner, {
    website: SHOP.website,
    address_line1: SHOP.address_line1,
    city: SHOP.city,
    region: SHOP.region,
    postal_code: SHOP.postal_code,
    lat: SHOP.lat,
    lng: SHOP.lng,
    tax_rate_bps: SHOP.tax_rate_bps,
    brand_color: SHOP.brand_color,
    invoice_due_days: 7,
    review_url: 'https://g.page/r/summit-auto-detailing-example/review',
    quote_terms:
      'Quotes are valid for 30 days. Ceramic coating and PPF prices assume paint in good condition; heavy defects are quoted separately after inspection.',
    invoice_terms: 'Payment due within 7 days. Thank you for choosing Summit Auto Detailing!',
  });
  await rpc(
    'replace_business_hours',
    {
      p_shop_id: shopId,
      p_rows: [
        ...[1, 2, 3, 4, 5].map((weekday) => ({ weekday, opens_at: '08:00', closes_at: '18:00' })),
        { weekday: 6, opens_at: '09:00', closes_at: '15:00' },
      ],
    },
    owner,
  );
  log(`shop ${SHOP.name} (${shopId}) /book/${slug}`);

  // owner's own membership row (the owner works jobs too)
  const ownerMember = (
    await rest('GET', `shop_members?shop_id=eq.${shopId}&user_id=eq.${owner.id}&select=id`, owner)
  )[0];
  await rest('PATCH', `shop_members?id=eq.${ownerMember.id}&select=id`, owner, {
    calendar_color: '#2563EB',
    phone: SHOP.phone,
  });

  // --- 2. vehicle sizes (seeded by create_shop), resources, catalog
  const cats = await rest(
    'GET',
    `vehicle_categories?shop_id=eq.${shopId}&select=id,name,sort&order=sort`,
    owner,
  );
  if (cats.length < 4) throw new Error(`expected 4 default vehicle sizes, got ${JSON.stringify(cats)}`);
  const sizeIds = cats.slice(0, 4).map((c) => c.id);

  const resources = {};
  for (const [i, r] of RESOURCES.entries()) {
    const row = (
      await rest('POST', 'resources?select=id', owner, { shop_id: shopId, name: r.name, kind: r.kind, sort: i + 1 })
    )[0];
    resources[r.key] = row.id;
  }

  const catIds = {};
  for (const [i, name] of ['Detailing', 'Paint & Protection', 'Window Tint', 'Add-ons'].entries()) {
    catIds[name] = (
      await rest('POST', 'service_categories?select=id', owner, { shop_id: shopId, name, sort: i + 1 })
    )[0].id;
  }
  const services = {};
  for (const [i, s] of SERVICES.entries()) {
    const row = (
      await rest('POST', 'services?select=id', owner, {
        shop_id: shopId,
        category_id: catIds[s.cat],
        name: s.name,
        description: s.description,
        kind: 'service',
        duration_minutes: s.minutes,
        online_bookable: s.online,
        sort: i + 1,
      })
    )[0];
    services[s.key] = row.id;
    await rest('POST', 'service_prices', owner, [
      { shop_id: shopId, service_id: row.id, vehicle_category_id: null, price_cents: s.prices[0] * 100 },
      ...s.prices.map((p, k) => ({
        shop_id: shopId,
        service_id: row.id,
        vehicle_category_id: sizeIds[k],
        price_cents: p * 100,
      })),
    ]);
  }
  for (const [i, a] of ADDONS.entries()) {
    const row = (
      await rest('POST', 'services?select=id', owner, {
        shop_id: shopId,
        category_id: catIds['Add-ons'],
        name: a.name,
        kind: 'addon',
        duration_minutes: a.minutes,
        online_bookable: true,
        sort: i + 1,
      })
    )[0];
    services[a.key] = row.id;
    await rest('POST', 'service_prices', owner, {
      shop_id: shopId,
      service_id: row.id,
      vehicle_category_id: null,
      price_cents: a.price * 100,
    });
    await rest(
      'POST',
      'service_addons',
      owner,
      a.for.map((k) => ({ shop_id: shopId, service_id: services[k], addon_id: row.id })),
    );
  }
  log(`catalog: ${SERVICES.length} services, ${ADDONS.length} add-ons, 4 vehicle sizes`);

  // membership plans (owner setup; subscribers need a live Stripe subscription)
  await rest('POST', 'membership_plans', owner, [
    {
      shop_id: shopId,
      name: 'Maintenance Club',
      description: 'One Maintenance Wash every month plus 10% off any other service.',
      price_cents: 7900,
      interval: 'month',
      interval_count: 1,
      included_service_ids: [services.maint],
      included_uses_per_period: 1,
      discount_bps: 1000,
      online_joinable: true,
      sort: 1,
    },
    {
      shop_id: shopId,
      name: 'Ceramic Care Plan',
      description: 'Quarterly decon wash and coating topper for ceramic-coated vehicles.',
      price_cents: 14900,
      interval: 'month',
      interval_count: 3,
      included_service_ids: [services.maint],
      included_uses_per_period: 1,
      discount_bps: 1500,
      online_joinable: true,
      sort: 2,
    },
  ]);
  await rest('POST', 'coupons', owner, {
    shop_id: shopId,
    code: 'FALLSHINE',
    description: 'Fall promo: $25 off a Full Detail',
    kind: 'fixed',
    value: 2500,
    service_ids: [services.full],
    active: true,
  });

  // checklist template for full details
  const checklist = (
    await rest('POST', 'checklist_templates?select=id', owner, {
      shop_id: shopId,
      name: 'Full Detail checklist',
      service_id: services.full,
      items: [
        { id: 'walkaround', label: 'Walk-around photos and damage notes' },
        { id: 'vacuum', label: 'Vacuum and air-purge interior' },
        { id: 'shampoo', label: 'Shampoo carpets and mats' },
        { id: 'leather', label: 'Clean and condition leather' },
        { id: 'wash', label: 'Foam pre-wash and hand wash' },
        { id: 'clay', label: 'Clay bar and iron decontamination' },
        { id: 'sealant', label: 'Apply paint sealant' },
        { id: 'glass', label: 'Glass inside and out' },
        { id: 'final', label: 'Final inspection with customer' },
      ],
    })
  )[0];

  // --- 3. online booking: requests with a 25% deposit
  await rest('PATCH', `booking_settings?shop_id=eq.${shopId}&select=shop_id`, owner, {
    enabled: true,
    auto_confirm: false,
    lead_time_minutes: 720,
    max_days_ahead: 60,
    slot_interval_minutes: 30,
    buffer_minutes: 30,
    max_concurrent_jobs: 2,
    require_deposit: true,
    deposit_type: 'percent',
    deposit_value: 2500,
    booking_message:
      'Book in under a minute. We confirm every request by text within a few hours. Mobile service available within 25 miles of downtown Nashville.',
    cancellation_policy:
      'Free rescheduling or cancellation up to 24 hours before your appointment. Deposits for later cancellations are kept as credit for a future visit.',
    allow_client_cancel_hours: 24,
  });

  // --- 4. Stripe Connect (real stripe-connect -> stripe-mock; operator flips charges_enabled)
  const link = await fn(
    'stripe-connect',
    { action: 'create_account_link', shop_id: shopId, request_nonce: randomUUID() },
    owner,
  );
  const account = link.stripe_account_id;
  await rest('PATCH', `shop_stripe_accounts?shop_id=eq.${shopId}`, service, {
    charges_enabled: true,
    payouts_enabled: true,
    details_submitted: true,
  });
  log(`Stripe account ${account} (charges enabled)`);

  // --- 5. SMS: operator provisions the number (service role + Twilio mock), owner saves it
  let smsNumber = null;
  for (const candidate of ['+16155550100', ...Array.from({ length: 40 }, (_, i) => `+1615555${String(150 + i).padStart(4, '0')}`)]) {
    const r = await http('POST', `${env.apiUrl}/rest/v1/shop_sms_numbers`, {
      headers: { ...authHeaders(service), prefer: 'return=minimal' },
      json: { phone_number: candidate, shop_id: shopId },
    });
    if (r.status === 201) {
      smsNumber = candidate;
      break;
    }
    if (r.status !== 409) must(r, 'provision shop_sms_numbers');
  }
  if (!smsNumber) throw new Error('no free sample SMS number');
  await registerTwilioNumber(shopId, smsNumber);
  await rest('PATCH', `shops?id=eq.${shopId}&select=id`, owner, { sms_from_number: smsNumber });
  log(`SMS from ${smsNumber}`);

  // --- 6. team: technician invited through the real invites function, then accepts
  const techEmail = login('marcus.reed');
  const invite = await fn(
    'invites',
    { action: 'send_invite', shop_id: shopId, email: techEmail, role: 'technician' },
    owner,
  );
  const inviteToken = /\/invite\/([0-9a-f-]{36})/.exec(invite.invite_url)?.[1];
  if (!inviteToken) throw new Error(`no invite token in ${JSON.stringify(invite)}`);
  const tech = await signUp(techEmail, PASSWORDS.technician, 'Marcus Reed');
  const techMember = await rpc('accept_invite', { p_token: inviteToken }, tech);
  await rest('PATCH', `shop_members?id=eq.${techMember.id}&select=id`, owner, {
    display_name: 'Marcus Reed',
    calendar_color: '#16A34A',
    phone: '+16155550120',
  });
  // a second invite still pending (shows on the Team page)
  await fn('invites', { action: 'send_invite', shop_id: shopId, email: login('tyler.grant'), role: 'technician' }, owner);
  log(`technician ${tech.email} joined; 1 invite pending`);

  // --- 7. customers + vehicles (owner, PostgREST/RLS)
  const customers = {};
  for (const c of CUSTOMERS) {
    const row = (
      await rest('POST', 'customers?select=id', owner, {
        shop_id: shopId,
        first_name: c.first,
        last_name: c.last,
        email: c.key === 'emily' ? login('emily.carter') : `${c.first}.${c.last}`.toLowerCase() + '@example.com',
        phone: `+1615555${c.phone}`,
        address_line1: c.street,
        city: c.city,
        region: 'TN',
        postal_code: c.zip,
        country: 'US',
        notes: c.notes,
        tags: c.tags,
        source: c.source,
        sms_opt_in: true,
        email_opt_in: true,
      })
    )[0];
    const vehicles = [];
    for (const v of c.vehicles) {
      const vr = (
        await rest('POST', 'vehicles?select=id', owner, {
          shop_id: shopId,
          customer_id: row.id,
          year: v.year,
          make: v.make,
          model: v.model,
          trim: v.trim,
          color: v.color,
          license_plate: v.plate,
          category_id: sizeIds[v.size],
        })
      )[0];
      vehicles.push({ ...v, id: vr.id });
    }
    customers[c.key] = { ...c, id: row.id, vehicles, email: c.key === 'emily' ? login('emily.carter') : `${c.first}.${c.last}`.toLowerCase() + '@example.com' };
  }
  log(`${CUSTOMERS.length} customers`);

  // --- 8. jobs, invoices, payments
  const memberFor = { tech: [techMember.id], owner: [ownerMember.id], both: [ownerMember.id, techMember.id] };
  const history = { jobs: [], invoices: [] };
  const jobIds = {};
  const invoiceLinks = {};
  let completedToday = null;

  const priceLines = async (cust, vehicle, keys) => {
    const pricing = await rpc(
      'price_services',
      {
        p_shop: shopId,
        p_customer_id: cust.id,
        p_service_ids: keys.map((k) => services[k]),
        p_vehicle_category_id: sizeIds[vehicle.size],
        p_vehicle_id: vehicle.id,
      },
      owner,
    );
    return (pricing.lines ?? []).map((l) => ({
      service_id: l.service_id,
      vehicle_id: vehicle.id,
      name: l.name,
      quantity: 1,
      unit_price_cents: l.unit_price_cents ?? l.catalog_price_cents ?? 0,
      taxable: l.taxable,
      duration_minutes: l.duration_minutes ?? 0,
    }));
  };

  const setStatus = async (jobId, path) => {
    for (const status of path) {
      await rest('PATCH', `jobs?id=eq.${jobId}&select=id,status`, owner, { status });
    }
  };

  for (const [i, j] of JOBS.entries()) {
    const cust = customers[j.c];
    const vehicle = cust.vehicles[j.v ?? 0];
    const day = workday(j.day);
    const lines = await priceLines(cust, vehicle, [...j.svc, ...j.add]);
    const total = lines.reduce((m, l) => m + l.duration_minutes, 0) || 120;
    const start = at(day, j.at);
    const end = new Date(start.getTime() + minutes(total));
    const mobile = j.loc === 'mobile';
    const job = (
      await rest('POST', 'jobs?select=id,number', owner, {
        shop_id: shopId,
        number: 0,
        customer_id: cust.id,
        vehicle_id: vehicle.id,
        scheduled_start: start.toISOString(),
        scheduled_end: end.toISOString(),
        location_type: j.loc,
        ...(mobile
          ? {
              service_address_line1: cust.street,
              service_city: cust.city,
              service_region: 'TN',
              service_postal_code: cust.zip,
            }
          : {}),
        resource_id: mobile ? resources.van : i % 2 === 0 ? resources.bay1 : resources.bay2,
        notes: j.notes ?? null,
        internal_notes: j.internal ?? null,
        tax_rate_bps: SHOP.tax_rate_bps,
        source: 'staff',
        deposit_required_cents: j.deposit ?? 0,
      })
    )[0];
    jobIds[`${j.c}:${j.day}`] = job.id;
    await rest('POST', 'job_line_items', owner, lines.map((l, k) => ({ ...l, shop_id: shopId, job_id: job.id, sort: k + 1 })));
    await rest(
      'POST',
      'job_assignments',
      owner,
      memberFor[j.who].map((member_id) => ({ shop_id: shopId, job_id: job.id, member_id })),
    );

    const past = j.day < 0;
    const status = past ? 'completed' : j.status ?? 'scheduled';
    const path = {
      scheduled: [],
      confirmed: ['confirmed'],
      en_route: ['confirmed', 'en_route'],
      in_progress: ['confirmed', 'en_route', 'in_progress'],
      completed: ['confirmed', 'en_route', 'in_progress', 'completed'],
    }[status];
    if (j.checklist) {
      await rpc('apply_checklist_template', { p_job_id: job.id, p_template_id: checklist.id }, owner);
    }
    await setStatus(job.id, path);
    if (past) history.jobs.push({ id: job.id, start, end });

    const md = (extra) => ({
      shop_id: shopId,
      job_id: job.id,
      customer_id: cust.id,
      ...extra,
    });

    if (j.pay === 'deposit') {
      await payByCheckout({
        account,
        amount: j.deposit,
        card: CARDS[j.card],
        paidAt: new Date(NOW.getTime() - 3 * 86400000),
        metadata: md({ kind: 'deposit', tip_cents: '0', source: 'booking_deposit_checkout' }),
      });
    }
    if (status === 'completed' && j.pay) {
      const invoice = await rpc('create_invoice_from_job', { p_job_id: job.id }, owner);
      const paidAt = new Date(end.getTime() + minutes(20));
      if (past) history.invoices.push({ id: invoice.id, issuedAt: new Date(end.getTime() + minutes(10)) });
      if (j.pay === 'card') {
        await payByCheckout({
          account,
          amount: invoice.total_cents + (j.tip ?? 0),
          card: CARDS[j.card],
          paidAt,
          metadata: md({
            invoice_id: invoice.id,
            kind: 'payment',
            tip_cents: String(j.tip ?? 0),
            source: 'invoice_checkout',
          }),
        });
      } else if (j.pay === 'partial') {
        await payByCheckout({
          account,
          amount: j.partial,
          card: CARDS[j.card],
          paidAt,
          metadata: md({ invoice_id: invoice.id, kind: 'payment', tip_cents: '0', source: 'invoice_checkout' }),
        });
        invoiceLinks.partial = invoice.id;
      } else if (j.pay === 'cash') {
        await rpc(
          'record_manual_payment',
          {
            p_invoice_id: invoice.id,
            p_amount_cents: invoice.total_cents,
            p_method: 'cash',
            p_tip_cents: j.tip ?? 0,
            p_note: 'Paid at pickup',
          },
          owner,
        );
        completedToday = invoice.id;
      } else if (j.pay === 'open') {
        invoiceLinks.open = invoice.id;
      } else if (j.pay === 'overdue') {
        invoiceLinks.overdue = invoice.id;
      }
      if (j.pay === 'open' || j.pay === 'overdue' || j.pay === 'partial') {
        // the invoice email (messaging.send renders invoice_sent server-side)
        await fn(
          'messaging',
          {
            action: 'send',
            shop_id: shopId,
            channel: 'email',
            template_key: 'invoice_sent',
            invoice_id: invoice.id,
            request_nonce: randomUUID().replace(/-/g, ''),
          },
          owner,
        );
      }
    }
  }
  log(`${JOBS.length} jobs (${history.jobs.length} past, ${JOBS.filter((j) => j.day === 0).length} today)`);

  // checklist progress on today's in-progress job
  const emilyJob = jobIds['emily:0'];
  const items = await rest(
    'GET',
    `job_checklist_items?job_id=eq.${emilyJob}&select=id,sort&order=sort`,
    owner,
  );
  for (const item of items.slice(0, 5)) {
    await rest('PATCH', `job_checklist_items?id=eq.${item.id}&select=id`, tech, { done_at: new Date().toISOString() });
  }

  // "On my way" text from the technician for the en-route mobile job
  await fn(
    'messaging',
    { action: 'send', shop_id: shopId, job_id: jobIds['david:0'], channel: 'sms', template_key: 'on_the_way' },
    tech,
  );

  // --- 9. quotes: draft, sent, approved (by the customer), converted, declined
  const quote = async (custKey, keys, optionalKeys, notes) => {
    const cust = customers[custKey];
    const vehicle = cust.vehicles[0];
    const q = (
      await rest('POST', 'quotes?select=id,number,public_token', owner, {
        shop_id: shopId,
        customer_id: cust.id,
        vehicle_id: vehicle.id,
        notes,
        valid_until: addDays(TODAY, 30),
      })
    )[0];
    const lines = await priceLines(cust, vehicle, keys);
    const opt = optionalKeys.length ? await priceLines(cust, vehicle, optionalKeys) : [];
    await rest(
      'POST',
      'quote_line_items',
      owner,
      [...lines.map((l) => ({ ...l, optional: false })), ...opt.map((l) => ({ ...l, optional: true }))].map(
        (l, k) => ({ ...l, shop_id: shopId, quote_id: q.id, sort: k + 1 }),
      ),
    );
    return { ...q, cust };
  };
  // The send dialog marks the quote sent (mark_quote_sent), then messaging.send
  // renders quote_sent with the /q link server-side.
  const sendQuote = async (q) => {
    await rpc('mark_quote_sent', { p_quote_id: q.id }, owner);
    return fn(
      'messaging',
      {
        action: 'send',
        shop_id: shopId,
        channel: 'email',
        template_key: 'quote_sent',
        quote_id: q.id,
        request_nonce: randomUUID().replace(/-/g, ''),
      },
      owner,
    );
  };

  await quote('michael', ['ppf', 'ceramic'], ['tint'], 'Full front PPF plus ceramic coating over the film and remaining paint.');
  const sentQuote = await quote(
    'ashley',
    ['ceramic'],
    ['correction'],
    'Ceramic coating for your RAV4. We recommend a one-step correction first to remove light swirls before the coating locks them in.',
  );
  await sendQuote(sentQuote);
  const approvedQuote = await quote('daniel', ['ceramic'], ['engine'], 'Ceramic coating for the Ram 1500, including wheel faces.');
  await sendQuote(approvedQuote);
  const approvedQuoteView = await rpc('public_get_quote', { p_token: approvedQuote.public_token }, anon);
  const engineLine = (approvedQuoteView?.quote?.line_items ?? approvedQuoteView?.line_items ?? []).find(
    (l) => l.optional,
  );
  await rpc(
    'public_respond_quote',
    {
      p_token: approvedQuote.public_token,
      p_action: 'approve',
      p_signer_name: 'Daniel Walker',
      ...(engineLine ? { p_selected_optional_line_ids: [engineLine.id] } : {}),
    },
    anon,
  );
  const convertQuote = await quote('kevin', ['correction', 'ceramic'], [], 'Correction and ceramic coating package for the Grand Cherokee.');
  await sendQuote(convertQuote);
  await rpc('public_get_quote', { p_token: convertQuote.public_token }, anon);
  await rpc('public_respond_quote', { p_token: convertQuote.public_token, p_action: 'approve', p_signer_name: 'Kevin Sullivan' }, anon);
  const convDay = workday(10);
  const convStart = at(convDay, '08:00');
  const convertedJob = await rpc(
    'convert_quote_to_job',
    {
      p_quote_id: convertQuote.id,
      p_start: convStart.toISOString(),
      p_end: new Date(convStart.getTime() + minutes(9 * 60)).toISOString(),
    },
    owner,
  );
  const convertedJobId = convertedJob?.id ?? convertedJob;
  if (typeof convertedJobId === 'string') {
    await rest('POST', 'job_assignments', owner, [
      { shop_id: shopId, job_id: convertedJobId, member_id: ownerMember.id },
      { shop_id: shopId, job_id: convertedJobId, member_id: techMember.id },
    ]);
  }
  const declinedQuote = await quote('ryan', ['tint'], [], 'Ceramic tint on all side and rear windows.');
  await sendQuote(declinedQuote);
  await rpc('public_get_quote', { p_token: declinedQuote.public_token }, anon);
  await rpc(
    'public_respond_quote',
    { p_token: declinedQuote.public_token, p_action: 'decline', p_declined_reason: 'Going to wait until spring.' },
    anon,
  );
  log('5 quotes (draft, sent, approved, converted, declined)');

  // --- 10. a customer books online (anon: real slots + create_online_booking)
  const fullId = services.full;
  const smallSuv = sizeIds[1];
  const slots = await rpc(
    'get_available_slots',
    {
      p_shop_slug: slug,
      p_service_ids: [fullId],
      p_vehicle_category_id: smallSuv,
      p_from: addDays(TODAY, 2),
      p_to: addDays(TODAY, 12),
    },
    anon,
  );
  if (!Array.isArray(slots) || slots.length === 0) throw new Error('no online booking slots available');
  const slot = slots.find((s) => new Date(s.starts_at).getUTCHours() >= 14) ?? slots[0];
  const booking = await rpc(
    'create_online_booking',
    {
      p_slug: slug,
      p_payload: {
        customer: {
          first_name: 'Natalie',
          last_name: 'Russo',
          email: 'natalie.russo@example.com',
          phone: '+16155550115',
          sms_opt_in: true,
          email_opt_in: true,
        },
        vehicle: { year: 2021, make: 'Subaru', model: 'Outback', color: 'Autumn Green', category_id: smallSuv },
        service_ids: [fullId],
        addon_ids: [services.pethair],
        starts_at: slot.starts_at,
        location: { type: 'shop' },
        notes: 'First time customer. Found you on Google. Lots of dog hair in the cargo area!',
        coupon_code: null,
      },
    },
    anon,
  );
  log(`online booking request #${booking.job_number} (${booking.status})`);

  // --- 11. client portal user (Emily signs up with her customer email; portal claims it)
  const client = await signUp(customers.emily.email, PASSWORDS.client, 'Emily Carter');
  await rpc('portal_claim_customers', {}, client);
  log(`portal client ${client.email}`);

  // --- 12. two-way SMS (messaging.send -> Twilio mock; signed inbound replies)
  const sendText = (cust, body, jobId) =>
    fn(
      'messaging',
      {
        action: 'send',
        shop_id: shopId,
        customer_id: cust.id,
        channel: 'sms',
        body,
        ...(jobId ? { job_id: jobId } : {}),
        request_nonce: randomUUID().replace(/-/g, ''),
      },
      owner,
    );
  const inbound = (cust, body) =>
    postTwilioInbound(shopId, { From: `+1615555${cust.phone}`, To: smsNumber, Body: body });
  const emily = customers.emily;
  await sendText(
    emily,
    'Hi Emily, Marcus started on your Model Y. The pet hair in the third row is heavier than usual, so we added Pet Hair Removal ($45) as discussed. Everything else looks great!',
    emilyJob,
  );
  await inbound(emily, 'Perfect, thank you! Any idea what time it will be ready?');
  await sendText(emily, 'Should be wrapped up around 1:30. We will text you as soon as it is ready for pickup.', emilyJob);
  await inbound(emily, 'Sounds great 👍');
  const ashley = customers.ashley;
  await sendText(
    ashley,
    'Hi Ashley, this is Jordan from Summit Auto Detailing. I just emailed your ceramic coating quote for the RAV4. Happy to answer any questions!',
  );
  await inbound(ashley, 'Thanks Jordan! Does the 3-year coating cover the wheels too?');
  const lauren = customers.lauren;
  await sendText(lauren, 'Hi Lauren, confirming your paint correction appointment. Same condo garage, level P2?');
  await inbound(lauren, 'Yes, P2 near the elevators. Thanks!');
  log('SMS threads: Emily, Ashley, Lauren');

  // --- 13. time: past shifts entered on the timesheet by the owner; today live clock-ins
  const entries = [];
  for (let n = -12; n <= -1; n += 1) {
    const day = workday(n);
    const wd = weekday(day);
    const shiftStart = at(day, wd === 6 ? '08:50' : n % 2 ? '07:52' : '08:05');
    const shiftEnd = at(day, wd === 6 ? '14:40' : n % 3 ? '17:10' : '16:45');
    entries.push({
      shop_id: shopId,
      member_id: techMember.id,
      kind: 'shift',
      job_id: null,
      clock_in: shiftStart.toISOString(),
      clock_out: shiftEnd.toISOString(),
    });
  }
  for (const [i, j] of JOBS.entries()) {
    if (j.day >= 0 || j.who === 'owner' || j.day < -12) continue;
    const h = history.jobs.find((x) => x.id === jobIds[`${j.c}:${j.day}`]);
    if (!h) continue;
    entries.push({
      shop_id: shopId,
      member_id: techMember.id,
      kind: 'job',
      job_id: h.id,
      clock_in: new Date(h.start.getTime() + minutes(5 + (i % 3) * 4)).toISOString(),
      clock_out: new Date(h.end.getTime() - minutes(10 - (i % 4) * 5)).toISOString(),
    });
  }
  await rest('POST', 'time_entries', owner, entries);
  // Today: Marcus clocks in for his shift and to the job he is working (his own JWT).
  await rpc('clock_in', { p_shop_id: shopId, p_kind: 'shift' }, tech);
  await rpc('clock_in', { p_shop_id: shopId, p_job_id: emilyJob, p_kind: 'job' }, tech);
  log(`${entries.length} timesheet entries + live clock-ins`);

  // --- 14. tasks
  const task = (t) => ({ shop_id: shopId, notes: null, customer_id: null, ...t });
  await rest('POST', 'tasks', owner, [
    task({
      title: 'Call Daniel Walker about the overdue invoice',
      assignee_member_id: ownerMember.id,
      customer_id: customers.daniel.id,
      due_at: at(TODAY, '17:00').toISOString(),
    }),
    task({
      title: 'Follow up on Ashley’s ceramic coating quote',
      notes: 'She asked whether the coating covers the wheels — yes, wheel faces are included.',
      assignee_member_id: ownerMember.id,
      customer_id: customers.ashley.id,
      due_at: at(workday(1), '10:00').toISOString(),
    }),
    task({
      title: 'Restock microfiber towels and pH-neutral soap in the van',
      assignee_member_id: techMember.id,
      due_at: at(workday(2), '08:00').toISOString(),
    }),
    task({
      title: 'Order ceramic coating kits for next week',
      assignee_member_id: ownerMember.id,
      due_at: at(workday(3), '12:00').toISOString(),
    }),
  ]);

  // --- 15. a draft email campaign
  await rest('POST', 'campaigns', owner, {
    shop_id: shopId,
    name: 'Fall protection special',
    channel: 'email',
    subject: 'Get your paint ready for winter',
    body:
      'Hi {{first_name}},\n\nWinter road salt is hard on paint. Book a Full Detail before November 30 and use code FALLSHINE for $25 off.\n\nSee you soon,\nSummit Auto Detailing',
    audience: {},
  });

  // --- 16. history: the stack's clock cannot move, so shift PAST work back to
  // when it happened (service role; see the header). Card payments are
  // already dated by their Stripe charge time.
  for (const h of history.jobs) {
    await rest('PATCH', `jobs?id=eq.${h.id}&select=id`, service, {
      confirmed_at: new Date(h.start.getTime() - 2 * 86400000).toISOString(),
      en_route_at: new Date(h.start.getTime() - minutes(30)).toISOString(),
      started_at: new Date(h.start.getTime() + minutes(5)).toISOString(),
      completed_at: new Date(h.end.getTime() - minutes(5)).toISOString(),
      appointment_set_at: new Date(h.start.getTime() - 6 * 86400000).toISOString(),
      created_at: new Date(h.start.getTime() - 6 * 86400000).toISOString(),
    });
  }
  for (const inv of history.invoices) {
    const due = at(addDays(ymdIn(inv.issuedAt), 7), '23:59');
    await rest('PATCH', `invoices?id=eq.${inv.id}&select=id`, service, {
      issued_at: inv.issuedAt.toISOString(),
      sent_at: inv.issuedAt.toISOString(),
      due_at: due.toISOString(),
      created_at: inv.issuedAt.toISOString(),
    });
  }
  for (const [i, c] of Object.values(customers).entries()) {
    const since = new Date(NOW.getTime() - (40 + i * 23) * 86400000);
    await rest('PATCH', `customers?id=eq.${c.id}&select=id`, service, { created_at: since.toISOString() });
  }

  // --- links + output
  const invoiceToken = async (id) => (id ? await rpc('invoice_link_token', { p_invoice_id: id }, owner) : null);
  const openInvoiceToken = await invoiceToken(invoiceLinks.open);
  const overdueInvoiceToken = await invoiceToken(invoiceLinks.overdue);
  const ids = {
    jobInProgress: emilyJob,
    jobEnRoute: jobIds['david:0'],
    jobCompletedToday: jobIds['michael:0'],
    customer: emily.id,
    customerWithThread: emily.id,
    quoteSent: sentQuote.id,
    quoteApproved: approvedQuote.id,
    invoiceOpen: invoiceLinks.open ?? null,
    invoiceOverdue: invoiceLinks.overdue ?? null,
    invoicePartial: invoiceLinks.partial ?? null,
    invoicePaidToday: completedToday,
    onlineBookingJobToken: booking.job_token,
  };
  const demo = {
    sample: true,
    note: 'SAMPLE data for screenshots only (scripts/screenshots/seed_demo.mjs). Fictional people, 555-01xx phones, @example.com emails.',
    generatedAt: new Date().toISOString(),
    shopToday: TODAY,
    apiUrl: env.apiUrl,
    anonKey: env.anonKey,
    appUrl: env.appUrl,
    shop: { id: shopId, slug, name: SHOP.name, timeZone: TZ, smsNumber },
    owner: { email: owner.email, password: PASSWORDS.owner, name: owner.name, userId: owner.id },
    technician: { email: tech.email, password: PASSWORDS.technician, name: 'Marcus Reed', userId: tech.id },
    client: { email: client.email, password: PASSWORDS.client, name: 'Emily Carter', userId: client.id },
    links: {
      booking: `/book/${slug}`,
      quote: `/q/${sentQuote.public_token}`,
      invoice: openInvoiceToken ? `/i/${openInvoiceToken}` : null,
      invoiceOverdue: overdueInvoiceToken ? `/i/${overdueInvoiceToken}` : null,
      manageBooking: `/booking/${booking.job_token}`,
      join: `/join/${slug}`,
      portal: '/portal',
      login: '/login',
    },
    ids,
  };
  mkdirSync(STATE_DIR, { recursive: true });
  writeFileSync(OUT_FILE, `${JSON.stringify(demo, null, 2)}\n`);

  const secs = ((Date.now() - started) / 1000).toFixed(1);
  console.log(`
  Sample shop ready (${calls} API calls, ${secs}s) — SAMPLE DATA FOR SCREENSHOTS
    ${SHOP.name}   ${env.appUrl}/book/${slug}
    owner       ${owner.email} / ${PASSWORDS.owner}
    technician  ${tech.email} / ${PASSWORDS.technician}
    client      ${client.email} / ${PASSWORDS.client}   (${env.appUrl}/portal)
    quote       ${env.appUrl}${demo.links.quote}
    invoice     ${env.appUrl}${demo.links.invoice}
    wrote       ${OUT_FILE}
`);
}

main().catch((error) => {
  console.error(`[seed] FAILED: ${error instanceof Error ? error.stack ?? error.message : String(error)}`);
  process.exit(1);
});
