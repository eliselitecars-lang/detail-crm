#!/usr/bin/env node
// Post-deploy smoke checks against the LIVE project (docs/DEPLOY.md). Read-only:
// every request is a denied/unauthenticated/malformed call or a GET, so it is
// safe to run against production at any time.
//
//   node scripts/deploy/verify_live.mjs [--strict] [--json report.json]
//
// Env:
//   APP_BASE_URL             required: the web app origin (Auth, CORS, links)
//   SUPABASE_URL             or SUPABASE_PROJECT_REF (https://<ref>.supabase.co)
//   SUPABASE_ANON_KEY        anon/publishable key; fetched with the access token when unset
//   SUPABASE_SERVICE_ROLE_KEY optional: bucket settings + platform_config checks
//   SUPABASE_ACCESS_TOKEN    optional: Management API checks (Auth config,
//                            deployed verify_jwt, cron jobs, billing config); with
//                            VERIFY_WITH_SERVICE_KEY=1 it also fetches the service key
//   BILLING_ENABLED / BILLING_TRIAL_DAYS  optional: the deploy's billing inputs; when
//                            set, the project's billing config must match, and with
//                            BILLING_ENABLED=true the billing webhook secret must be set
//
// Exit 1 when any check FAILs. KNOWN = a documented open defect
// (scripts/stack/README.md "Known issues"): reported, not a failure unless
// --strict. There is none at present: the defects found earlier are fixed and
// checked as regular (failing) checks, e.g. an unknown public link is 404.
import { randomBytes, randomUUID } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { functionsPlan, normalizeAppBaseUrl, REPO_ROOT, supabaseUrl } from './lib/config.mjs';

const argv = process.argv.slice(2);
const STRICT = argv.includes('--strict') || process.env.VERIFY_STRICT === '1';
const JSON_OUT = argv.includes('--json') ? argv[argv.indexOf('--json') + 1] : undefined;
const env = process.env;
const MGMT = (env.DEPLOY_SUPABASE_API_BASE || 'https://api.supabase.com').replace(/\/+$/, '');
const SUPABASE_DIR = env.VERIFY_SUPABASE_DIR || join(REPO_ROOT, 'supabase');

function die(msg) {
  console.error(`verify_live: ${msg}`);
  process.exit(2);
}

let APP;
let API;
try {
  APP = normalizeAppBaseUrl(env.APP_BASE_URL ?? '', { allowHttp: env.VERIFY_ALLOW_HTTP === '1' });
  API = supabaseUrl(env);
} catch (err) {
  die(err.message);
}
const REF = env.SUPABASE_PROJECT_REF?.trim() || /^https:\/\/([a-z0-9]{20})\.supabase\.co$/.exec(API)?.[1];
const TOKEN = env.SUPABASE_ACCESS_TOKEN?.trim();
const FN = `${API}/functions/v1`;

// ------------------------------------------------------------------ utils
async function http(method, url, { headers = {}, body, raw, redirect = 'manual' } = {}) {
  const res = await fetch(url, {
    method,
    redirect,
    headers: { ...(body !== undefined && !raw ? { 'content-type': 'application/json' } : {}), ...headers },
    body: raw ?? (body !== undefined ? JSON.stringify(body) : undefined),
    signal: AbortSignal.timeout(30_000),
  });
  const text = await res.text();
  let json;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    json = undefined;
  }
  return { status: res.status, headers: res.headers, text, json };
}
const show = (r) => `HTTP ${r.status} ${String(r.text ?? '').slice(0, 300)}`;
function assert(cond, msg) {
  if (!cond) throw new Error(msg);
}

const results = [];
async function run(kind, name, fn) {
  const started = Date.now();
  try {
    const detail = await fn();
    if (detail && typeof detail === 'object' && detail.skip) {
      results.push({ name, status: 'SKIP', detail: detail.skip });
      console.log(`SKIP  ${name}  — ${detail.skip}`);
      return;
    }
    const status = kind === 'known' ? 'FIXED' : 'PASS';
    results.push({ name, status, ms: Date.now() - started, detail: detail ?? '' });
    console.log(`${status.padEnd(5)} ${name}${detail ? `  — ${detail}` : ''}`);
  } catch (err) {
    const msg = String(err?.message ?? err);
    const status = kind === 'known' && !STRICT ? 'KNOWN' : 'FAIL';
    results.push({ name, status, ms: Date.now() - started, detail: msg });
    console.log(`${status.padEnd(5)} ${name}\n      ${msg.replace(/\n/g, '\n      ')}`);
  }
}
const check = (name, fn) => run('check', name, fn);
// For a documented open defect (none at present): KNOWN while it reproduces,
// FIXED once it no longer does; a FAIL only with --strict.
const known = (name, fn) => run('known', name, fn);
const skip = (why) => ({ skip: why });

async function mgmt(method, path, body) {
  const res = await fetch(`${MGMT}${path}`, {
    method,
    headers: {
      authorization: `Bearer ${TOKEN}`,
      'user-agent': 'detail-crm-verify/1',
      ...(body ? { 'content-type': 'application/json' } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(30_000),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`Management API ${method} ${path}: HTTP ${res.status} ${text.slice(0, 200)}`);
  return text ? JSON.parse(text) : null;
}

// ------------------------------------------------------------------ keys
let ANON = env.SUPABASE_ANON_KEY?.trim();
let SERVICE = env.SUPABASE_SERVICE_ROLE_KEY?.trim();
if ((!ANON || (!SERVICE && env.VERIFY_WITH_SERVICE_KEY === '1')) && TOKEN && REF) {
  try {
    const keys = await mgmt('GET', `/v1/projects/${REF}/api-keys`);
    const pick = (pred) => (Array.isArray(keys) ? keys.find(pred)?.api_key : undefined);
    ANON ||= pick((k) => k.name === 'anon') ?? pick((k) => k.type === 'publishable');
    if (env.VERIFY_WITH_SERVICE_KEY === '1') SERVICE ||= pick((k) => k.name === 'service_role');
  } catch (err) {
    die(`could not fetch API keys: ${err.message}`);
  }
}
if (!ANON) die('SUPABASE_ANON_KEY is required (or SUPABASE_ACCESS_TOKEN + SUPABASE_PROJECT_REF to fetch it)');
const anonH = { apikey: ANON, authorization: `Bearer ${ANON}` };
const serviceH = SERVICE ? { apikey: SERVICE, authorization: `Bearer ${SERVICE}` } : null;

let FUNCTIONS;
try {
  FUNCTIONS = functionsPlan(SUPABASE_DIR).map((f) => ({
    ...f,
    cors: !/cors:\s*false/.test(readFileSync(join(SUPABASE_DIR, 'functions', f.name, 'index.ts'), 'utf8')),
  }));
} catch (err) {
  die(`cannot read the function list from ${SUPABASE_DIR}: ${err.message}`);
}
const CRON_JOBS = [...readFileSync(join(SUPABASE_DIR, 'setup', 'cron.sql'), 'utf8').matchAll(/cron\.schedule\(\s*'([^']+)'/g)].map((m) => m[1]).sort();

console.log(`verify_live: ${API} (app ${APP})${TOKEN ? ' + Management API' : ''}${SERVICE ? ' + service key' : ''}\n`);

// --------------------------------------------------------------- PostgREST
await check('rest: PostgREST answers', async () => {
  const r = await http('GET', `${API}/rest/v1/`, { headers: anonH });
  assert(r.status < 500, show(r));
  return `HTTP ${r.status}`;
});

const TENANT_TABLES = ['shops', 'shop_members', 'customers', 'vehicles', 'jobs', 'quotes', 'invoices', 'payments', 'customer_payment_methods', 'messages', 'stripe_events', 'platform_config', 'profiles'];
await check('rest: anon cannot read tenant tables (RLS / grants)', async () => {
  const bad = [];
  const seen = [];
  for (const t of TENANT_TABLES) {
    const r = await http('GET', `${API}/rest/v1/${t}?select=*&limit=1`, { headers: anonH });
    const denied = r.status === 401 || r.status === 403 || r.json?.code === '42501';
    const empty = r.status === 200 && Array.isArray(r.json) && r.json.length === 0;
    if (!denied && !empty) bad.push(`${t}: ${show(r)}`);
    seen.push(`${t}=${r.status}`);
  }
  assert(bad.length === 0, `anon got data or an unexpected answer:\n${bad.join('\n')}`);
  return seen.join(' ');
});

for (const [fn, args] of [
  ['public_shop_profile', { p_slug: `verify-live-${randomUUID().slice(0, 8)}` }],
  ['public_booking_catalog', { p_slug: `verify-live-${randomUUID().slice(0, 8)}` }],
  ['public_get_quote', { p_token: randomUUID() }],
  ['public_get_invoice', { p_token: randomUUID() }],
  ['public_get_booking', { p_token: randomUUID() }],
  ['public_get_form', { p_token: randomUUID() }],
  ['public_get_invite', { p_token: randomUUID() }],
]) {
  await check(`rest: public rpc ${fn} is exposed to anon`, async () => {
    const r = await http('POST', `${API}/rest/v1/rpc/${fn}`, { headers: anonH, body: args });
    assert(r.json?.code !== '42501' && r.json?.code !== 'PGRST202', `not callable by anon: ${show(r)}`);
    assert(r.status < 500, `${show(r)} — an unknown token, slug or id must be a 4xx (PT404), never a 5xx`);
    return `HTTP ${r.status}${r.json?.code ? ` ${r.json.code}` : ''}`;
  });
}
await check('rest: an unknown public token answers HTTP 404 PT404, not a 5xx', async () => {
  const r = await http('POST', `${API}/rest/v1/rpc/public_get_quote`, { headers: anonH, body: { p_token: randomUUID() } });
  assert(r.status === 404 && r.json?.code === 'PT404', `${show(r)} — public RPCs raise PT404 for an unknown token (scripts/stack/README.md); a migration that is not applied, or a regression to P0002 (HTTP 500)`);
  return `HTTP 404 ${r.json.code}`;
});
await check('rest: a malformed token is a 400, not a 5xx', async () => {
  const r = await http('POST', `${API}/rest/v1/rpc/public_get_invoice`, { headers: anonH, body: { p_token: 'not-a-uuid' } });
  assert(r.status === 400, show(r));
  return `HTTP 400 ${r.json?.code ?? ''}`;
});
await check('rest: anon is denied staff and service RPCs', async () => {
  const a = await http('POST', `${API}/rest/v1/rpc/portal_overview`, { headers: anonH, body: {} });
  const b = await http('POST', `${API}/rest/v1/rpc/create_shop`, { headers: anonH, body: { p_name: 'x', p_slug: `verify-${randomUUID().slice(0, 8)}`, p_timezone: 'UTC' } });
  const c = await http('POST', `${API}/rest/v1/rpc/set_app_base_url`, { headers: anonH, body: { p_url: 'https://verify-live.invalid' } });
  assert(a.status === 401 || a.status === 403 || a.json?.code === '42501', `portal_overview: ${show(a)}`);
  assert(b.status >= 400 && b.status < 500, `create_shop: ${show(b)}`);
  assert(c.status === 401 || c.status === 403 || c.status === 404, `set_app_base_url: ${show(c)}`);
  return `portal_overview ${a.status}, create_shop ${b.status}, set_app_base_url ${c.status}`;
});

// --------------------------------------------------------------- Auth
await check('auth: settings — email sign-up on, confirmations ON, anonymous and phone sign-in off', async () => {
  const r = await http('GET', `${API}/auth/v1/settings`, { headers: { apikey: ANON } });
  assert(r.status === 200 && r.json, show(r));
  const s = r.json;
  const problems = [];
  if (s.external?.email !== true) problems.push('email provider disabled');
  if (s.disable_signup === true) problems.push('sign-ups disabled (shops cannot register)');
  if (s.mailer_autoconfirm !== false) problems.push('email confirmations are OFF (mailer_autoconfirm true): portal customer linking trusts confirmed emails');
  if (s.external?.anonymous_users === true) problems.push('anonymous sign-ins enabled');
  if (s.external?.phone === true) problems.push('phone sign-in enabled');
  assert(problems.length === 0, problems.join('; '));
  return 'email on, autoconfirm off';
});

await check('auth: site_url / redirect allow-list use APP_BASE_URL', async () => {
  if (TOKEN && REF) {
    const cfg = await mgmt('GET', `/v1/projects/${REF}/config/auth`);
    const allow = String(cfg.uri_allow_list ?? '').split(',').map((s) => s.trim());
    assert(cfg.site_url?.replace(/\/+$/, '') === APP, `site_url is ${cfg.site_url}, expected ${APP}`);
    assert(allow.includes(`${APP}/**`), `uri_allow_list lacks ${APP}/** (has ${allow.length} entries)`);
    assert(cfg.mailer_autoconfirm === false, 'mailer_autoconfirm is true (confirmations off)');
    assert(cfg.smtp_host, 'custom SMTP is not configured (Supabase\'s built-in mailer is rate-limited and not for production)');
    return `site_url=${cfg.site_url}, smtp=${cfg.smtp_host} (Management API)`;
  }
  // Without the Management API: an invalid email link sends the browser to
  // redirect_to when it is allowed, else to site_url (GoTrue /verify).
  const token = randomBytes(12).toString('hex');
  const ok = await http('GET', `${API}/auth/v1/verify?type=recovery&token=${token}&redirect_to=${encodeURIComponent(`${APP}/reset-password`)}`, { headers: { apikey: ANON } });
  const evil = await http('GET', `${API}/auth/v1/verify?type=recovery&token=${token}&redirect_to=${encodeURIComponent('https://verify-live.invalid/steal')}`, { headers: { apikey: ANON } });
  const okLoc = ok.headers.get('location');
  const evilLoc = evil.headers.get('location');
  if (!okLoc || !evilLoc) return skip(`GoTrue /verify answered ${ok.status}/${evil.status} without a redirect; set SUPABASE_ACCESS_TOKEN to check site_url`);
  assert(okLoc.startsWith(`${APP}/reset-password`), `redirect to ${APP}/reset-password is not allowed (went to ${okLoc.split('#')[0]})`);
  assert(!evilLoc.startsWith('https://verify-live.invalid'), 'an arbitrary redirect_to is accepted (open redirect): tighten the allow-list');
  assert(evilLoc.startsWith(APP), `site_url is not APP_BASE_URL (fallback went to ${evilLoc.split('#')[0]})`);
  return 'redirect_to allowed for the app, foreign redirect falls back to APP_BASE_URL';
});

// --------------------------------------------------------- Edge functions
function envelope(r, status, code) {
  const hint =
    r.json?.code === 'server_misconfigured'
      ? ' (a function secret is missing/invalid: the function logs name it)'
      : r.json?.code === 'BOOT_ERROR'
        ? ' (the function failed to boot)'
        : r.status === 404 && !r.json?.request_id
          ? ' (function not deployed?)'
          : '';
  assert(r.status === status && r.json?.code === code, `expected ${status} ${code}, got ${show(r)}${hint}`);
  assert(typeof r.json.error === 'string' && typeof r.json.request_id === 'string', `not the documented envelope {error, code, request_id}: ${show(r)}`);
}

for (const f of FUNCTIONS) {
  if (f.verifyJwt) {
    await check(`fn ${f.name}: verify_jwt=true — the gateway rejects a call without a JWT`, async () => {
      const r = await http('POST', `${FN}/${f.name}`, { body: {} });
      assert(r.status === 401, `${show(r)} — config.toml says verify_jwt = true; redeploy it without --no-verify-jwt`);
      assert(r.status < 500, show(r));
      return 'HTTP 401 (gateway)';
    });
  } else if (f.name === 'calendar-feed') {
    // GET-only (calendar apps): a request without a token is the function's own 400.
    await check('fn calendar-feed: verify_jwt=false — a GET without a token is 400 validation_failed', async () => {
      const r = await http('GET', `${FN}/calendar-feed`);
      if (r.status === 401 && !r.json?.request_id) {
        throw new Error(`${show(r)} — the gateway demands a JWT: deployed with verify_jwt=true, so calendar apps cannot subscribe. Redeploy with --no-verify-jwt.`);
      }
      envelope(r, 400, 'validation_failed');
      return `validation_failed (${r.json.request_id.slice(0, 8)}…)`;
    });
  } else {
    const expected = f.name === 'stripe-webhook' || f.name === 'billing-webhook' ? 'invalid_signature' : 'unknown_action';
    await check(`fn ${f.name}: verify_jwt=false — answers callers without a JWT with its envelope (400 ${expected})`, async () => {
      const r = await http('POST', `${FN}/${f.name}`, { body: {} });
      if (r.status === 401 && !r.json?.request_id) {
        throw new Error(`${show(r)} — the gateway demands a JWT: deployed with verify_jwt=true, so Stripe/Twilio/pg_cron cannot reach it. Redeploy with --no-verify-jwt.`);
      }
      envelope(r, 400, expected);
      return `${expected} (${r.json.request_id.slice(0, 8)}…)`;
    });
  }
}

const has = (name) => FUNCTIONS.some((f) => f.name === name);
if (has('payments')) {
  await check('fn payments: public invoice_checkout with an unknown token is 404 not_found (secrets + DB reachable)', async () => {
    const r = await http('POST', `${FN}/payments`, { headers: anonH, body: { action: 'invoice_checkout', token: randomUUID() } });
    envelope(r, 404, 'not_found');
    return 'not_found';
  });
  await check('fn payments: a client-sent total is 400 validation_failed', async () => {
    const r = await http('POST', `${FN}/payments`, { headers: anonH, body: { action: 'invoice_checkout', token: 'nope', total: 1 } });
    envelope(r, 400, 'validation_failed');
    return 'validation_failed';
  });
  await check('fn payments: a staff action without a session is 401 unauthorized', async () => {
    const r = await http('POST', `${FN}/payments`, { headers: anonH, body: { action: 'refund', shop_id: randomUUID(), payment_id: randomUUID(), request_nonce: randomUUID() } });
    envelope(r, 401, 'unauthorized');
    return 'unauthorized';
  });
  await check('fn payments: cron action without x-cron-secret is 401 (CRON_SECRET configured)', async () => {
    const r = await http('POST', `${FN}/payments`, { headers: anonH, body: { action: 'sweep_payment_sheets' } });
    envelope(r, 401, 'unauthorized');
    return 'unauthorized';
  });
}
if (has('stripe-webhook')) {
  await check('fn stripe-webhook: a forged signature is 400 invalid_signature (Stripe keys + webhook secret configured)', async () => {
    const r = await http('POST', `${FN}/stripe-webhook`, {
      raw: JSON.stringify({ id: `evt_verify${randomUUID().replace(/-/g, '')}`, object: 'event', type: 'account.updated' }),
      headers: { 'content-type': 'application/json', 'stripe-signature': `t=${Math.floor(Date.now() / 1000)},v1=${'0'.repeat(64)}` },
    });
    envelope(r, 400, 'invalid_signature');
    return 'invalid_signature';
  });
}
const BILLING_ON = env.BILLING_ENABLED?.trim().toLowerCase() === 'true';
if (has('billing')) {
  await check('fn billing: plans without a user session is 401 unauthorized (checked in the function)', async () => {
    const r = await http('POST', `${FN}/billing`, { headers: anonH, body: { action: 'plans' } });
    envelope(r, 401, 'unauthorized');
    return 'unauthorized';
  });
  await check('fn billing: a client-sent price on checkout is 400 validation_failed', async () => {
    const r = await http('POST', `${FN}/billing`, {
      headers: anonH,
      body: { action: 'checkout', shop_id: randomUUID(), plan_id: randomUUID(), price: 'price_verify_live' },
    });
    envelope(r, 400, 'validation_failed');
    return 'validation_failed';
  });
  await check('fn billing: sync_plans without x-cron-secret is 401 (CRON_SECRET configured)', async () => {
    const r = await http('POST', `${FN}/billing`, { headers: anonH, body: { action: 'sync_plans' } });
    envelope(r, 401, 'unauthorized');
    return 'unauthorized';
  });
}
if (has('billing-webhook')) {
  const fakeEvent = () => JSON.stringify({ id: `evt_verify${randomUUID().replace(/-/g, '')}`, object: 'event', type: 'invoice.paid', data: { object: {} } });
  await check('fn billing-webhook: an unsigned request is 400 invalid_signature', async () => {
    const r = await http('POST', `${FN}/billing-webhook`, { raw: fakeEvent(), headers: { 'content-type': 'application/json' } });
    envelope(r, 400, 'invalid_signature');
    return 'invalid_signature';
  });
  await check('fn billing-webhook: a forged signature is 400 invalid_signature (STRIPE_BILLING_WEBHOOK_SECRET configured)', async () => {
    const r = await http('POST', `${FN}/billing-webhook`, {
      raw: fakeEvent(),
      headers: { 'content-type': 'application/json', 'stripe-signature': `t=${Math.floor(Date.now() / 1000)},v1=${'0'.repeat(64)}` },
    });
    if (r.status === 500 && r.json?.code === 'server_misconfigured' && !BILLING_ON) {
      return skip('STRIPE_BILLING_WEBHOOK_SECRET is not set (fine while BILLING_ENABLED is not true)');
    }
    envelope(r, 400, 'invalid_signature');
    return 'invalid_signature';
  });
}
if (has('messaging')) {
  await check('fn messaging: process_queue without x-cron-secret is 401 (CRON_SECRET configured)', async () => {
    const r = await http('POST', `${FN}/messaging`, { headers: anonH, body: { action: 'process_queue' } });
    envelope(r, 401, 'unauthorized');
    return 'unauthorized';
  });
  await check('fn messaging: twilio_inbound with a forged X-Twilio-Signature is 400 invalid_signature (Twilio secrets configured)', async () => {
    const r = await http('POST', `${FN}/messaging?action=twilio_inbound&shop_id=${randomUUID()}`, {
      raw: new URLSearchParams({ From: '+12055550199', To: '+12055550100', Body: 'verify', MessageSid: `SM${'0'.repeat(32)}` }).toString(),
      headers: { 'content-type': 'application/x-www-form-urlencoded', 'x-twilio-signature': 'forged' },
    });
    envelope(r, 400, 'invalid_signature');
    return 'invalid_signature';
  });
  await check('fn messaging: unsubscribe GET redirects to APP_BASE_URL/u/<token> (APP_BASE_URL secret matches)', async () => {
    const token = randomUUID();
    const r = await http('GET', `${FN}/messaging?action=unsubscribe&token=${token}`);
    const loc = r.headers.get('location');
    assert(r.status === 303 && loc === `${APP}/u/${token}`, `expected 303 -> ${APP}/u/${token}, got HTTP ${r.status} location=${loc}`);
    return `303 -> ${APP}/u/…`;
  });
}
if (has('storage-purge')) {
  await check('fn storage-purge: purge without x-cron-secret is 401 (CRON_SECRET configured)', async () => {
    const r = await http('POST', `${FN}/storage-purge`, { headers: anonH, body: { action: 'purge' } });
    envelope(r, 401, 'unauthorized');
    return 'unauthorized';
  });
}
for (const [name, action] of [['push', 'process_queue'], ['webhooks', 'deliver'], ['sms-provisioning', 'refresh_status']]) {
  if (!has(name)) continue;
  await check(`fn ${name}: ${action} without x-cron-secret is 401 (CRON_SECRET configured)`, async () => {
    const r = await http('POST', `${FN}/${name}`, { headers: anonH, body: { action } });
    envelope(r, 401, 'unauthorized');
    return 'unauthorized';
  });
}
for (const f of FUNCTIONS.filter((x) => x.cors)) {
  await check(`fn ${f.name}: CORS allows exactly APP_BASE_URL's origin and refuses others`, async () => {
    const origin = new URL(APP).origin;
    const pre = (o) =>
      http('OPTIONS', `${FN}/${f.name}`, {
        headers: { origin: o, 'access-control-request-method': 'POST', 'access-control-request-headers': 'authorization,content-type,apikey,x-client-info' },
      });
    const ok = await pre(origin);
    const allow = ok.headers.get('access-control-allow-origin');
    assert(ok.status < 300 && allow === origin, `app origin: HTTP ${ok.status} allow-origin=${allow}`);
    const bad = await pre('https://verify-live.invalid');
    const badAllow = bad.headers.get('access-control-allow-origin');
    assert(bad.status === 403 && !badAllow, `foreign origin: HTTP ${bad.status} allow-origin=${badAllow}`);
    return `${ok.status}/${bad.status}`;
  });
}

// --------------------------------------------------------------- Storage
await check('storage: job-photos and signatures are not public; shop-assets is public (migration 0025)', async () => {
  const probe = (bucket) => http('GET', `${API}/storage/v1/object/public/${bucket}/verify-live-${randomUUID()}.png`, { headers: { apikey: ANON } });
  const none = await probe(`no-such-bucket-${randomUUID().slice(0, 8)}`);
  const sig = (r) => `${r.status}|${r.json?.error ?? r.json?.message ?? r.text.slice(0, 60)}`;
  const out = [];
  for (const b of ['job-photos', 'signatures']) {
    const r = await probe(b);
    assert(r.status >= 400 && r.status < 500, `${b}: ${show(r)}`);
    assert(sig(r) === sig(none), `${b} answers a public-URL request like a public bucket (${sig(r)} vs no-such-bucket ${sig(none)})`);
    out.push(`${b}=private`);
  }
  const pub = await probe('shop-assets');
  assert(sig(pub) !== sig(none), `shop-assets is not a public bucket (or does not exist): ${show(pub)}`);
  out.push('shop-assets=public');
  return out.join(' ');
});
await check('storage: bucket settings via the service key', async () => {
  if (!serviceH) return skip('no SUPABASE_SERVICE_ROLE_KEY (or VERIFY_WITH_SERVICE_KEY=1 with an access token)');
  const r = await http('GET', `${API}/storage/v1/bucket`, { headers: serviceH });
  assert(r.status === 200 && Array.isArray(r.json), show(r));
  const by = new Map(r.json.map((b) => [b.id, b]));
  const want = { 'job-photos': false, signatures: false, 'shop-assets': true };
  for (const [id, pub] of Object.entries(want)) {
    assert(by.has(id), `bucket ${id} missing (migration 0025 not applied?)`);
    assert(by.get(id).public === pub, `bucket ${id} public=${by.get(id).public}, expected ${pub}`);
  }
  return Object.entries(want).map(([id, p]) => `${id}:${p ? 'public' : 'private'}`).join(' ');
});

// --------------------------------------------------------------- Realtime
await check('realtime: websocket accepts the anon key and joins a channel', async () => {
  if (typeof WebSocket !== 'function') return skip('global WebSocket missing (Node 22+)');
  const wsUrl = `${API.replace(/^http/, 'ws')}/realtime/v1/websocket?apikey=${encodeURIComponent(ANON)}&vsn=1.0.0`;
  return await new Promise((resolve, reject) => {
    const ws = new WebSocket(wsUrl);
    const timer = setTimeout(() => {
      ws.close();
      reject(new Error('no phx_reply within 10 s'));
    }, 10_000);
    ws.onerror = () => {
      clearTimeout(timer);
      reject(new Error('websocket error'));
    };
    ws.onopen = () =>
      ws.send(JSON.stringify({ topic: 'realtime:verify-live', event: 'phx_join', ref: '1', payload: { config: { broadcast: { self: false }, presence: { key: '' }, postgres_changes: [] }, access_token: ANON } }));
    ws.onmessage = (ev) => {
      let msg;
      try {
        msg = JSON.parse(String(ev.data));
      } catch {
        return;
      }
      if (msg.event !== 'phx_reply' || msg.ref !== '1') return;
      clearTimeout(timer);
      ws.close();
      if (msg.payload?.status === 'ok') resolve('joined');
      else reject(new Error(`join refused: ${JSON.stringify(msg.payload).slice(0, 200)}`));
    };
  });
});

// ------------------------------------------------------- Management API
await check('management: deployed functions carry config.toml verify_jwt', async () => {
  if (!TOKEN || !REF) return skip('no SUPABASE_ACCESS_TOKEN');
  const list = await mgmt('GET', `/v1/projects/${REF}/functions`);
  const by = new Map(list.map((f) => [f.slug, f]));
  const bad = FUNCTIONS.filter((f) => !by.has(f.name) || by.get(f.name).verify_jwt !== f.verifyJwt).map((f) => `${f.name}: want ${f.verifyJwt}, deployed ${by.get(f.name)?.verify_jwt ?? 'missing'}`);
  assert(bad.length === 0, bad.join('; '));
  return FUNCTIONS.map((f) => `${f.name}=${f.verifyJwt}`).join(' ');
});
await check('management: platform setup — app_base_url and cron jobs', async () => {
  if (!TOKEN || !REF) {
    if (serviceH) {
      const r = await http('GET', `${API}/rest/v1/platform_config?key=eq.app_base_url&select=value`, { headers: serviceH });
      assert(r.status === 200 && r.json?.[0]?.value === APP, `platform_config.app_base_url: ${show(r)}`);
      return 'app_base_url matches (cron jobs need SUPABASE_ACCESS_TOKEN)';
    }
    return skip('no SUPABASE_ACCESS_TOKEN or service key');
  }
  const cfg = await mgmt('POST', `/v1/projects/${REF}/database/query`, { query: "select value from public.platform_config where key = 'app_base_url'" });
  assert(cfg?.[0]?.value === APP, `platform_config.app_base_url is ${JSON.stringify(cfg?.[0]?.value)}, expected ${APP} (run the deploy's platform setup)`);
  const jobs = await mgmt('POST', `/v1/projects/${REF}/database/query`, { query: "select jobname, active from cron.job where jobname like 'detail-crm-%' order by jobname" });
  const active = (jobs ?? []).filter((j) => j.active !== false).map((j) => j.jobname);
  const missing = CRON_JOBS.filter((j) => !active.includes(j));
  assert(missing.length === 0, `cron jobs missing/inactive: ${missing.join(', ')}`);
  return `app_base_url ok, ${CRON_JOBS.length} jobs active`;
});

await check('management: billing config (set_billing_config) matches BILLING_ENABLED / BILLING_TRIAL_DAYS', async () => {
  if (!TOKEN || !REF) return skip('no SUPABASE_ACCESS_TOKEN');
  const rows = await mgmt('POST', `/v1/projects/${REF}/database/query`, {
    query: "select key, value from public.platform_config where key in ('billing_enabled', 'billing_trial_days') order by key",
  });
  const by = Object.fromEntries((Array.isArray(rows) ? rows : []).map((r) => [r.key, r.value]));
  const enabled = String(by.billing_enabled ?? '').toLowerCase() === 'true';
  const days = Number(by.billing_trial_days ?? 0);
  if (env.BILLING_ENABLED?.trim()) {
    assert(enabled === BILLING_ON, `billing is ${enabled ? 'ON' : 'off'} in the project but BILLING_ENABLED=${env.BILLING_ENABLED.trim()} (run the deploy's platform setup)`);
  }
  if (env.BILLING_TRIAL_DAYS?.trim()) {
    assert(days === Number(env.BILLING_TRIAL_DAYS.trim()), `the project's trial is ${days} day(s) but BILLING_TRIAL_DAYS=${env.BILLING_TRIAL_DAYS.trim()}`);
  }
  return `billing ${enabled ? 'ON' : 'off'}, trial ${days} day(s)`;
});

// ---------------------------------------------------------------- report
const count = (s) => results.filter((r) => r.status === s).length;
console.log(`\n${count('PASS')} passed, ${count('FAIL')} failed, ${count('KNOWN')} known, ${count('SKIP')} skipped, ${count('FIXED')} fixed`);
if (JSON_OUT) writeFileSync(JSON_OUT, `${JSON.stringify({ api: API, app: APP, at: new Date().toISOString(), results }, null, 2)}\n`);
process.exit(count('FAIL') ? 1 : 0);
