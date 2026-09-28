#!/usr/bin/env node
// Verifies the REAL local Supabase stack started by scripts/stack/up.sh:
// database platform pieces (extensions, realtime publication, buckets,
// grants, pg_net -> functions), PostgREST RPC exposure and grants, GoTrue
// signup/login, Storage buckets + RLS policies through the Storage API,
// Realtime postgres_changes under RLS, and every edge function's boot,
// auth errors and provider wiring (stripe-mock, Twilio/Resend mock).
//
// Usage: node scripts/stack/verify_stack.mjs [--json out.json]
// Reads scripts/stack/.state/stack.env (written by up.sh). Creates its own
// uniquely named users/shops, so it can run repeatedly against one stack.
// Exit code 1 if any check fails; every failure prints the evidence.
import { createHash, createHmac, randomUUID } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { existsSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..', '..');

function loadEnvFile(path) {
  const out = {};
  if (!existsSync(path)) return out;
  for (const line of readFileSync(path, 'utf8').split('\n')) {
    const m = /^([A-Z0-9_]+)=(.*)$/.exec(line.trim());
    if (m) out[m[1]] = m[2].replace(/^"(.*)"$/, '$1');
  }
  return out;
}
const E = { ...loadEnvFile(join(HERE, '.state', 'stack.env')), ...process.env };
for (const k of ['STACK_API_URL', 'STACK_ANON_KEY', 'STACK_SERVICE_ROLE_KEY', 'STACK_DB_URL']) {
  if (!E[k]) {
    console.error(`missing ${k}: run scripts/stack/up.sh first`);
    process.exit(2);
  }
}
const API = E.STACK_API_URL;
const FN = `${API}/functions/v1`;
const ANON = E.STACK_ANON_KEY;
const SERVICE = E.STACK_SERVICE_ROLE_KEY;
const APP_ORIGIN = E.STACK_APP_URL ?? 'http://127.0.0.1:5173';
const PROVIDER = E.STACK_PROVIDER_MOCK_URL ?? 'http://127.0.0.1:12120';
const WHSEC = E.STACK_STRIPE_WEBHOOK_SECRET;
const TWILIO_TOKEN = E.STACK_TWILIO_AUTH_TOKEN;
const CRON = E.STACK_CRON_SECRET;
const SFX = randomUUID().slice(0, 8);

// ------------------------------------------------------------------ utils
const results = [];
async function check(name, fn) {
  const started = Date.now();
  try {
    const detail = await fn();
    results.push({ name, ok: true, ms: Date.now() - started, detail: detail ?? '' });
    console.log(`PASS  ${name}${detail ? `  — ${detail}` : ''}`);
  } catch (err) {
    results.push({ name, ok: false, ms: Date.now() - started, detail: String(err?.message ?? err) });
    console.log(`FAIL  ${name}\n      ${String(err?.message ?? err).replace(/\n/g, '\n      ')}`);
  }
}
/**
 * A check that documents a KNOWN defect / platform difference (recorded in
 * scripts/stack/README.md "Known issues"). It is reported as KNOWN (not a
 * failure) unless STACK_STRICT=1; once it passes it is reported as FIXED so
 * the entry can be turned into a normal check.
 */
async function known(name, fn) {
  const strict = process.env.STACK_STRICT === '1';
  const started = Date.now();
  try {
    const detail = await fn();
    results.push({ name, ok: true, known: 'fixed', ms: Date.now() - started, detail: detail ?? '' });
    console.log(`FIXED ${name}${detail ? `  — ${detail}` : ''} (known issue no longer reproduces)`);
  } catch (err) {
    results.push({ name, ok: !strict, known: 'open', ms: Date.now() - started, detail: String(err?.message ?? err) });
    console.log(`${strict ? 'FAIL ' : 'KNOWN'} ${name}\n      ${String(err?.message ?? err).replace(/\n/g, '\n      ')}`);
  }
}
function assert(cond, msg) {
  if (!cond) throw new Error(msg);
}
async function http(method, url, { headers = {}, body, raw } = {}) {
  const res = await fetch(url, {
    method,
    headers: {
      ...(body !== undefined && !raw ? { 'content-type': 'application/json' } : {}),
      ...headers,
    },
    body: raw ?? (body !== undefined ? JSON.stringify(body) : undefined),
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
const show = (r) => `HTTP ${r.status} ${r.text.slice(0, 400)}`;
const anonH = { apikey: ANON, authorization: `Bearer ${ANON}` };
const userH = (jwt) => ({ apikey: ANON, authorization: `Bearer ${jwt}` });
const serviceH = { apikey: SERVICE, authorization: `Bearer ${SERVICE}` };

function findPsql() {
  try {
    execFileSync('psql', ['--version'], { stdio: 'ignore' });
    return 'psql';
  } catch {
    /* not on PATH */
  }
  const base = '/usr/lib/postgresql';
  if (existsSync(base)) {
    const versions = readdirSync(base).sort((a, b) => Number(b) - Number(a));
    for (const v of versions) if (existsSync(`${base}/${v}/bin/psql`)) return `${base}/${v}/bin/psql`;
  }
  return null;
}
const PSQL = findPsql();
/** Runs SQL as postgres, returns trimmed unaligned output. */
function sql(query) {
  const args = ['-X', '-q', '-A', '-t', '-v', 'ON_ERROR_STOP=1', '-c', query];
  if (PSQL) return execFileSync(PSQL, [E.STACK_DB_URL, ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
  return execFileSync('docker', ['exec', '-i', 'supabase_db_detail-crm', 'psql', '-U', 'postgres', '-d', 'postgres', ...args], {
    encoding: 'utf8',
    stdio: ['pipe', 'pipe', 'pipe'],
  }).trim();
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ------------------------------------------------------------ database
await check('db: pg_cron and pg_net are installed (real image)', () => {
  const got = sql(`select string_agg(extname || '@' || extnamespace::regnamespace, ',' order by extname)
                     from pg_extension where extname in ('pg_cron','pg_net','supabase_vault')`);
  assert(got.includes('pg_cron@pg_catalog') && got.includes('pg_net@extensions') && got.includes('supabase_vault'), got);
  return got;
});
await check('db: app extensions live in schema extensions', () => {
  const got = sql(`select string_agg(extname, ',' order by extname) from pg_extension
                    where extname in ('citext','pg_trgm','btree_gist','pgcrypto') and extnamespace = 'extensions'::regnamespace`);
  assert(got === 'btree_gist,citext,pg_trgm,pgcrypto', got);
  return got;
});
// 0044_integration_realtime.sql adds jobs, messages, notifications, payments
// and time_entries; 0081_comms_schema.sql adds tasks. Exactly the tables the
// web subscribes to (useRealtime callers; web/README.md "Realtime").
await check('db: supabase_realtime publication carries exactly the 0044 + 0081 tables', () => {
  const got = sql(`select string_agg(tablename, ',' order by tablename) from pg_publication_tables
                    where pubname = 'supabase_realtime' and schemaname = 'public'`);
  assert(got === 'jobs,messages,notifications,payments,tasks,time_entries', got);
  return got;
});
await check('db: storage buckets from migration 0025 exist with limits', () => {
  const got = sql(`select string_agg(id || ':' || public || ':' || coalesce(file_size_limit::text,'-'), ',' order by id) from storage.buckets`);
  assert(/job-photos:false:\d+/.test(got) && /signatures:false:\d+/.test(got) && /shop-assets:true:\d+/.test(got), got);
  return got;
});
await check('db: every public table has RLS enabled', () => {
  const got = sql(`select coalesce(string_agg(c.relname, ','), '') from pg_class c
                    where c.relnamespace = 'public'::regnamespace and c.relkind in ('r','p') and not c.relrowsecurity`);
  assert(got === '', `tables without RLS: ${got}`);
  return 'none missing';
});
await check('db: anon has no direct table privileges in public', () => {
  const got = sql(`select coalesce(string_agg(distinct table_name, ','), '') from information_schema.role_table_grants
                    where grantee = 'anon' and table_schema = 'public'`);
  assert(got === '', `anon can touch: ${got}`);
  return 'none';
});
await check('db: platform_config.app_base_url is set for local links', () => {
  const got = sql(`select value from public.platform_config where key = 'app_base_url'`);
  assert(got === APP_ORIGIN, got);
  return got;
});

// ---------------------------------------------------------- PostgREST
await check('rest: anon cannot read tenant tables (shops)', async () => {
  const r = await http('GET', `${API}/rest/v1/shops?select=id&limit=1`, { headers: anonH });
  assert(r.status === 401 || r.status === 403 || (r.status === 200 && Array.isArray(r.json) && r.json.length === 0), show(r));
  return `HTTP ${r.status}`;
});
for (const [fn, args] of [
  ['public_shop_profile', { p_slug: `no-such-shop-${SFX}` }],
  ['public_booking_catalog', { p_slug: `no-such-shop-${SFX}` }],
  ['public_get_quote', { p_token: randomUUID() }],
  ['public_get_invoice', { p_token: randomUUID() }],
  ['public_get_booking', { p_token: randomUUID() }],
  ['public_get_form', { p_token: randomUUID() }],
  ['public_get_invite', { p_token: randomUUID() }],
  ['public_unsubscribe', { p_token: randomUUID() }],
  // /pricing (anon): [] while billing is off
  ['public_billing_plans', {}],
]) {
  await check(`rest: anon can call rpc ${fn} (exposed + granted)`, async () => {
    const r = await http('POST', `${API}/rest/v1/rpc/${fn}`, { headers: anonH, body: args });
    // Exposed and executable: anything but "function not found" (PGRST202)
    // or "permission denied" (42501). An unknown token/slug may answer null,
    // {} or raise PT404 (HTTP 404: the function ran), all fine here; never 5xx.
    assert(r.json?.code !== '42501' && r.json?.code !== 'PGRST202', show(r));
    assert(r.status < 500, show(r));
    return `HTTP ${r.status}${r.json?.code ? ` ${r.json.code}` : ''}`;
  });
}
// Public RPCs raise PT404 for an unknown token/slug (PostgREST: HTTP 404);
// P0002 would be HTTP 500 (only P0001 is 400, PT4xx sets the status).
await check('rest: a not-found public RPC answers HTTP 404 PT404 (not P0002 -> 500)', async () => {
  const r = await http('POST', `${API}/rest/v1/rpc/public_get_quote`, { headers: anonH, body: { p_token: randomUUID() } });
  assert(r.status === 404 && r.json?.code === 'PT404', `${show(r)} — expected 404 PT404; PostgREST maps SQLSTATE P0002 to HTTP 500`);
  return `HTTP ${r.status} ${r.json.code}`;
});
await check('rest: anon can call get_available_slots with an unknown shop', async () => {
  const r = await http('POST', `${API}/rest/v1/rpc/get_available_slots`, {
    headers: anonH,
    body: { p_shop_slug: `no-such-shop-${SFX}`, p_service_ids: [randomUUID()], p_vehicle_category_id: null, p_from: '2030-01-01', p_to: '2030-01-02' },
  });
  assert(r.json?.code !== '42501' && r.json?.code !== 'PGRST202', show(r));
  assert(r.status < 500, show(r));
  return `HTTP ${r.status}${r.json?.code ? ` ${r.json.code}` : ''}`;
});
await check('rest: anon is denied portal_overview and create_shop', async () => {
  const a = await http('POST', `${API}/rest/v1/rpc/portal_overview`, { headers: anonH, body: {} });
  const b = await http('POST', `${API}/rest/v1/rpc/create_shop`, {
    headers: anonH,
    body: { p_name: 'x', p_slug: `x-${SFX}`, p_timezone: 'America/Chicago' },
  });
  assert(a.status === 401 || a.status === 403 || a.json?.code === '42501', `portal_overview: ${show(a)}`);
  assert(b.status >= 400 && b.status < 500, `create_shop: ${show(b)}`);
  return `portal_overview HTTP ${a.status}, create_shop HTTP ${b.status} ${b.json?.code ?? ''}`;
});
await check('rest: service-only set_app_base_url is not callable by anon', async () => {
  const r = await http('POST', `${API}/rest/v1/rpc/set_app_base_url`, { headers: anonH, body: { p_url: 'https://evil.example' } });
  assert(r.status === 401 || r.status === 403 || r.status === 404, show(r));
  return `HTTP ${r.status} ${r.json?.code ?? ''}`;
});

// --------------------------------------------------------------- GoTrue
const owner = { email: `owner-${SFX}@stack.test`, password: `Pw-${SFX}-stack!` };
const tech = { email: `tech-${SFX}@stack.test`, password: `Pw-${SFX}-tech!` };
await check('auth: email signup returns a session (confirmations off locally)', async () => {
  for (const u of [owner, tech]) {
    const r = await http('POST', `${API}/auth/v1/signup`, { headers: { apikey: ANON }, body: { email: u.email, password: u.password, data: { full_name: 'Stack Owner' } } });
    assert(r.status === 200 && r.json?.access_token, show(r));
    u.id = r.json.user.id;
    assert(r.json.user.email_confirmed_at, 'email_confirmed_at is null (autoconfirm expected)');
  }
  return `owner ${owner.id}`;
});
await check('auth: password login + /user', async () => {
  for (const u of [owner, tech]) {
    const r = await http('POST', `${API}/auth/v1/token?grant_type=password`, { headers: { apikey: ANON }, body: { email: u.email, password: u.password } });
    assert(r.status === 200 && r.json?.access_token && r.json?.refresh_token, show(r));
    u.jwt = r.json.access_token;
    u.refresh = r.json.refresh_token;
  }
  const me = await http('GET', `${API}/auth/v1/user`, { headers: userH(owner.jwt) });
  assert(me.status === 200 && me.json?.email === owner.email, show(me));
  return 'ok';
});
await check('auth: wrong password is rejected', async () => {
  const r = await http('POST', `${API}/auth/v1/token?grant_type=password`, { headers: { apikey: ANON }, body: { email: owner.email, password: 'wrong-password' } });
  assert(r.status === 400, show(r));
  return `HTTP ${r.status} ${r.json?.error_code ?? ''}`;
});
await check('auth: refresh token rotation works', async () => {
  const r = await http('POST', `${API}/auth/v1/token?grant_type=refresh_token`, { headers: { apikey: ANON }, body: { refresh_token: owner.refresh } });
  assert(r.status === 200 && r.json?.access_token, show(r));
  owner.jwt = r.json.access_token;
  return 'ok';
});
await check('auth: signup trigger created the profile row', () => {
  const got = sql(`select count(*) from public.profiles where id = '${owner.id}'`);
  assert(got === '1', `profiles rows: ${got}`);
  return 'profiles row present';
});

// ------------------------------------------------ tenant data as owner
const shop = { slug: `stack-${SFX}` };
await check('rest: owner creates a shop via rpc create_shop (seed triggers run)', async () => {
  const r = await http('POST', `${API}/rest/v1/rpc/create_shop`, {
    headers: userH(owner.jwt),
    body: { p_name: `Stack Shop ${SFX}`, p_slug: shop.slug, p_timezone: 'America/Chicago' },
  });
  assert(r.status === 200 && r.json?.id, show(r));
  shop.id = r.json.id;
  return shop.id;
});
await check('rest: owner inserts a customer and a job (RLS insert path)', async () => {
  const c = await http('POST', `${API}/rest/v1/customers`, {
    headers: { ...userH(owner.jwt), prefer: 'return=representation' },
    body: { shop_id: shop.id, first_name: 'Stack', last_name: 'Customer', email: `cust-${SFX}@stack.test` },
  });
  assert(c.status === 201 && c.json?.[0]?.id, `customer: ${show(c)}`);
  shop.customerId = c.json[0].id;
  // jobs.public_token is not SELECT-able by authenticated (column grants), so
  // return=representation must name columns (select=*) would be 42501.
  const j = await http('POST', `${API}/rest/v1/jobs?select=id,number`, {
    headers: { ...userH(owner.jwt), prefer: 'return=representation' },
    body: { shop_id: shop.id, customer_id: shop.customerId, scheduled_start: '2030-03-04T15:00:00Z', scheduled_end: '2030-03-04T17:00:00Z' },
  });
  assert(j.status === 201 && j.json?.[0]?.id, `job: ${show(j)}`);
  shop.jobId = j.json[0].id;
  return `job #${j.json[0].number}`;
});
await check('rest: another user cannot see the shop (tenant isolation)', async () => {
  const r = await http('GET', `${API}/rest/v1/shops?id=eq.${shop.id}&select=id`, { headers: userH(tech.jwt) });
  assert(r.status === 200 && Array.isArray(r.json) && r.json.length === 0, show(r));
  const j = await http('GET', `${API}/rest/v1/jobs?shop_id=eq.${shop.id}&select=id`, { headers: userH(tech.jwt) });
  assert(j.status === 200 && Array.isArray(j.json) && j.json.length === 0, show(j));
  return 'no rows';
});
await check('rest: anon sees the new shop through public_shop_profile', async () => {
  const r = await http('POST', `${API}/rest/v1/rpc/public_shop_profile`, { headers: anonH, body: { p_slug: shop.slug } });
  assert(r.status === 200 && r.json && JSON.stringify(r.json).includes(shop.slug), show(r));
  return 'ok';
});

// --------------------------------------------------------------- Storage
const photoPath = () => `${shop.id}/${shop.jobId}/before-${SFX}.jpg`;
const JPEG = Buffer.from('/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDA==', 'base64');
await check('storage: member uploads to job-photos/<shop>/<job>/… (policy allows)', async () => {
  const r = await http('POST', `${API}/storage/v1/object/job-photos/${photoPath()}`, {
    headers: { ...userH(owner.jwt), 'content-type': 'image/jpeg' },
    raw: JPEG,
  });
  assert(r.status === 200, show(r));
  return r.json?.Key ?? 'ok';
});
await check('storage: member downloads the photo; outsider and anon cannot', async () => {
  const own = await http('GET', `${API}/storage/v1/object/authenticated/job-photos/${photoPath()}`, { headers: userH(owner.jwt) });
  assert(own.status === 200, `owner: ${show(own)}`);
  const other = await http('GET', `${API}/storage/v1/object/authenticated/job-photos/${photoPath()}`, { headers: userH(tech.jwt) });
  assert(other.status === 400 || other.status === 403 || other.status === 404, `outsider: ${show(other)}`);
  const anon = await http('GET', `${API}/storage/v1/object/authenticated/job-photos/${photoPath()}`, { headers: anonH });
  assert(anon.status >= 400, `anon: ${show(anon)}`);
  return `owner 200, outsider ${other.status}, anon ${anon.status}`;
});
await check('storage: upload outside the member’s shop / job is refused', async () => {
  const r = await http('POST', `${API}/storage/v1/object/job-photos/${randomUUID()}/${randomUUID()}/x.jpg`, {
    headers: { ...userH(owner.jwt), 'content-type': 'image/jpeg' },
    raw: JPEG,
  });
  assert(r.status === 400 || r.status === 403, show(r));
  const t = await http('POST', `${API}/storage/v1/object/job-photos/${shop.id}/${shop.jobId}/tech.jpg`, {
    headers: { ...userH(tech.jwt), 'content-type': 'image/jpeg' },
    raw: JPEG,
  });
  assert(t.status === 400 || t.status === 403, `non-member: ${show(t)}`);
  return `HTTP ${r.status} / ${t.status}`;
});
await check('storage: bucket MIME allow-list rejects a non-image', async () => {
  const r = await http('POST', `${API}/storage/v1/object/job-photos/${shop.id}/${shop.jobId}/evil.html`, {
    headers: { ...userH(owner.jwt), 'content-type': 'text/html' },
    raw: '<script>alert(1)</script>',
  });
  assert(r.status === 400 || r.status === 415 || r.status === 422, show(r));
  return `HTTP ${r.status}`;
});
await check('storage: shop-assets is public-readable after an admin upload', async () => {
  const path = `${shop.id}/logo-${SFX}.png`;
  const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==', 'base64');
  const up = await http('POST', `${API}/storage/v1/object/shop-assets/${path}`, { headers: { ...userH(owner.jwt), 'content-type': 'image/png' }, raw: PNG });
  assert(up.status === 200, `upload: ${show(up)}`);
  const pub = await fetch(`${API}/storage/v1/object/public/shop-assets/${path}`);
  assert(pub.status === 200, `public GET: HTTP ${pub.status}`);
  return 'ok';
});
await check('storage: member deletes through the Storage API (protect_delete path)', async () => {
  const r = await http('DELETE', `${API}/storage/v1/object/job-photos`, { headers: userH(owner.jwt), body: { prefixes: [photoPath()] } });
  assert(r.status === 200 && Array.isArray(r.json) && r.json.length === 1, show(r));
  return 'deleted';
});
await check('storage: direct SQL DELETE on storage.objects is blocked by the platform', () => {
  let msg = '';
  try {
    sql(`delete from storage.objects where bucket_id = 'shop-assets' and false`);
  } catch (e) {
    msg = String(e.stderr ?? e.message);
  }
  assert(/Direct deletion from storage tables is not allowed/.test(msg), `expected protect_delete error, got: ${msg || 'no error'}`);
  return 'storage.protect_delete() active (app code must use the Storage API)';
});

// -------------------------------------------------------------- Realtime
await check('realtime: owner receives postgres_changes for its shop jobs', async () => {
  assert(typeof WebSocket === 'function', 'global WebSocket missing (Node 22+ required)');
  const wsUrl = `${API.replace(/^http/, 'ws')}/realtime/v1/websocket?apikey=${ANON}&vsn=1.0.0`;
  const ws = new WebSocket(wsUrl);
  const events = [];
  let subscribed = false;
  ws.onmessage = (m) => {
    const msg = JSON.parse(m.data);
    events.push(msg);
    if (msg.event === 'system' && msg.payload?.status === 'ok' && /Subscribed/i.test(msg.payload?.message ?? '')) subscribed = true;
  };
  await new Promise((resolve, reject) => {
    ws.onopen = resolve;
    ws.onerror = () => reject(new Error('websocket error'));
  });
  ws.send(JSON.stringify({
    topic: `realtime:stack-${SFX}`,
    event: 'phx_join',
    ref: '1',
    payload: {
      config: { postgres_changes: [{ event: '*', schema: 'public', table: 'jobs', filter: `shop_id=eq.${shop.id}` }] },
      access_token: owner.jwt,
    },
  }));
  for (let i = 0; i < 100 && !subscribed; i++) await sleep(100);
  assert(subscribed, `not subscribed: ${JSON.stringify(events).slice(0, 600)}`);
  const u = await http('PATCH', `${API}/rest/v1/jobs?id=eq.${shop.jobId}`, { headers: userH(owner.jwt), body: { notes: `realtime ${SFX}` } });
  assert(u.status === 204 || u.status === 200, `update: ${show(u)}`);
  let change;
  for (let i = 0; i < 100 && !change; i++) {
    change = events.find((e) => e.event === 'postgres_changes' && e.payload?.data?.type === 'UPDATE' &&
      e.payload?.data?.record?.notes === `realtime ${SFX}`);
    if (!change) await sleep(100);
  }
  ws.close();
  assert(change, `no postgres_changes UPDATE event: ${JSON.stringify(events).slice(0, 600)}`);
  const leaked = Object.keys(change.payload.data.record).filter((k) => k === 'public_token');
  assert(leaked.length === 0, 'realtime payload exposes jobs.public_token (column not SELECT-able by authenticated)');
  return 'UPDATE received, public_token not in payload';
});

// -------------------------------------------------------- Edge functions
const FUNCTIONS = ['payments', 'stripe-webhook', 'messaging', 'invites', 'stripe-connect', 'storage-purge'];
for (const f of FUNCTIONS) {
  await check(`fn ${f}: boots and answers with the JSON error envelope`, async () => {
    const headers = ['invites', 'stripe-connect'].includes(f) ? userH(owner.jwt) : anonH;
    const r = await http('POST', `${FN}/${f}`, { headers, body: {} });
    assert(r.json?.code !== 'BOOT_ERROR', `boot error: ${show(r)}`);
    // stripe-webhook has no actions: it verifies the signature first.
    const expected = f === 'stripe-webhook' ? 'invalid_signature' : 'unknown_action';
    assert(r.status === 400 && r.json?.code === expected && r.json?.request_id, show(r));
    return expected;
  });
}
await check('fn cors: browser preflight from the app origin succeeds', async () => {
  const out = [];
  for (const f of ['payments', 'messaging', 'invites', 'stripe-connect']) {
    const r = await fetch(`${FN}/${f}`, {
      method: 'OPTIONS',
      headers: { origin: APP_ORIGIN, 'access-control-request-method': 'POST', 'access-control-request-headers': 'authorization,content-type,apikey,x-client-info' },
    });
    const allow = r.headers.get('access-control-allow-origin');
    assert(r.status < 300 && (allow === APP_ORIGIN || allow === '*'), `${f}: HTTP ${r.status} allow-origin=${allow}`);
    out.push(`${f}=${allow}`);
  }
  return out.join(',');
});
await known('fn cors: a foreign origin is not allowed (function exact-origin CORS)', async () => {
  const bad = await fetch(`${FN}/payments`, { method: 'OPTIONS', headers: { origin: 'https://evil.example', 'access-control-request-method': 'POST' } });
  const allow = bad.headers.get('access-control-allow-origin');
  assert(allow !== '*' && allow !== 'https://evil.example',
    `allow-origin=${allow} (server: ${bad.headers.get('server')}) — the LOCAL Kong gateway's global CORS plugin answers every preflight and overwrites Access-Control-Allow-Origin with *, so the functions' exact-origin CORS (_shared/cors.ts) is not observable through the local gateway (the next check proves it directly against the edge runtime)`);
  return allow ?? 'none';
});
// The local Kong masks the functions' own CORS (known issue above), so the
// exact-origin policy (_shared/cors.ts: APP_BASE_URL's origin +
// CORS_ALLOWED_ORIGINS, never *) is checked by calling the edge runtime
// directly on the Docker network (edge_runtime:8081), bypassing Kong — from
// the db container, which ships curl. That is the policy hosted Supabase serves.
function preflightDirect(fnName, origin) {
  const out = execFileSync('docker', ['exec', 'supabase_db_detail-crm', 'curl', '-s', '-D', '-', '-o', '/dev/null',
    '-X', 'OPTIONS', `http://edge_runtime:8081/${fnName}`,
    '-H', `origin: ${origin}`, '-H', 'access-control-request-method: POST',
    '-H', 'access-control-request-headers: authorization,content-type,apikey,x-client-info'], { encoding: 'utf8' });
  const status = Number(/^HTTP\/\S+ (\d{3})/m.exec(out)?.[1] ?? 0);
  const allow = /^access-control-allow-origin:\s*(.+?)\s*$/im.exec(out)?.[1] ?? null;
  return { status, allow };
}
await check('fn cors (direct to the edge runtime, no Kong): exact app origins allowed, foreign origin refused', () => {
  const out = [];
  for (const f of ['payments', 'messaging', 'invites', 'stripe-connect']) {
    for (const origin of [APP_ORIGIN, 'http://localhost:5173']) {
      const ok = preflightDirect(f, origin);
      assert(ok.status === 204 && ok.allow === origin, `${f} ${origin}: HTTP ${ok.status} allow-origin=${ok.allow}`);
    }
    const bad = preflightDirect(f, 'https://evil.example');
    assert(bad.status === 403 && bad.allow === null, `${f} foreign origin: HTTP ${bad.status} allow-origin=${bad.allow}`);
    out.push(`${f} 204/403`);
  }
  return out.join(', ');
});
await check('fn gateway: verify_jwt functions reject calls without a JWT', async () => {
  for (const f of ['invites', 'stripe-connect']) {
    const r = await http('POST', `${FN}/${f}`, { body: { action: 'refresh_status' } });
    assert(r.status === 401, `${f}: ${show(r)}`);
  }
  return '401';
});
await check('fn payments: staff action without a session is 401 unauthorized', async () => {
  const r = await http('POST', `${FN}/payments`, { headers: anonH, body: { action: 'refund', shop_id: randomUUID(), payment_id: randomUUID(), request_nonce: randomUUID() } });
  assert(r.status === 401 && r.json?.code === 'unauthorized', show(r));
  return 'unauthorized';
});
await check('fn payments: public invoice_checkout with an unknown token is 404 (DB reached via service role)', async () => {
  const r = await http('POST', `${FN}/payments`, { headers: anonH, body: { action: 'invoice_checkout', token: randomUUID() } });
  assert(r.status === 404 && r.json?.code === 'not_found', show(r));
  return 'not_found';
});
await check('fn payments: malformed input is 400 validation_failed', async () => {
  const r = await http('POST', `${FN}/payments`, { headers: anonH, body: { action: 'invoice_checkout', token: 'nope', total: 1 } });
  assert(r.status === 400 && r.json?.code === 'validation_failed', show(r));
  return 'validation_failed';
});
await check('fn stripe-connect: technician/non-member is 403; owner reaches stripe-mock', async () => {
  const denied = await http('POST', `${FN}/stripe-connect`, { headers: userH(tech.jwt), body: { action: 'refresh_status', shop_id: shop.id } });
  assert(denied.status === 403 && denied.json?.code === 'forbidden', `non-member: ${show(denied)}`);
  const link = await http('POST', `${FN}/stripe-connect`, { headers: userH(owner.jwt), body: { action: 'create_account_link', shop_id: shop.id, request_nonce: randomUUID() } });
  assert(link.status === 200 && /^acct_/.test(link.json?.stripe_account_id ?? '') && link.json?.url, `create_account_link via stripe-mock: ${show(link)}`);
  const status = await http('POST', `${FN}/stripe-connect`, { headers: userH(owner.jwt), body: { action: 'refresh_status', shop_id: shop.id } });
  assert(status.status === 200 && status.json?.connected === true, `refresh_status: ${show(status)}`);
  return link.json.stripe_account_id;
});
await check('fn stripe-webhook: missing/invalid signature is 400 invalid_signature', async () => {
  const body = JSON.stringify({ id: `evt_${SFX}`, object: 'event', type: 'account.updated' });
  const a = await http('POST', `${FN}/stripe-webhook`, { raw: body, headers: { 'content-type': 'application/json' } });
  const b = await http('POST', `${FN}/stripe-webhook`, { raw: body, headers: { 'content-type': 'application/json', 'stripe-signature': 't=1,v1=deadbeef' } });
  assert(a.status === 400 && a.json?.code === 'invalid_signature', `no signature: ${show(a)}`);
  assert(b.status === 400 && b.json?.code === 'invalid_signature', `bad signature: ${show(b)}`);
  return 'invalid_signature';
});
await check('fn stripe-webhook: a correctly signed event is verified and acknowledged', async () => {
  assert(WHSEC, 'STACK_STRIPE_WEBHOOK_SECRET missing');
  const acct = `acct_stack${SFX.replace(/-/g, '')}`;
  const event = {
    id: `evt_stack${SFX.replace(/-/g, '')}`,
    object: 'event',
    api_version: '2026-08-26.dahlia',
    created: Math.floor(Date.now() / 1000),
    livemode: false,
    pending_webhooks: 1,
    request: { id: null, idempotency_key: null },
    type: 'account.updated',
    account: acct,
    data: { object: { id: acct, object: 'account', charges_enabled: false, payouts_enabled: false, details_submitted: false } },
  };
  const payload = JSON.stringify(event);
  const t = Math.floor(Date.now() / 1000);
  const sig = createHmac('sha256', WHSEC).update(`${t}.${payload}`).digest('hex');
  const r = await http('POST', `${FN}/stripe-webhook`, { raw: payload, headers: { 'content-type': 'application/json', 'stripe-signature': `t=${t},v1=${sig}` } });
  assert(r.status === 200, show(r));
  return `HTTP ${r.status} ${r.text.slice(0, 80)}`;
});
await check('fn messaging: process_queue needs the cron secret; with it the queue drains', async () => {
  const no = await http('POST', `${FN}/messaging`, { headers: anonH, body: { action: 'process_queue' } });
  assert(no.status === 401 && no.json?.code === 'unauthorized', `no secret: ${show(no)}`);
  const bad = await http('POST', `${FN}/messaging`, { headers: { ...anonH, 'x-cron-secret': 'x'.repeat(40) }, body: { action: 'process_queue' } });
  assert(bad.status === 401, `wrong secret: ${show(bad)}`);
  const ok = await http('POST', `${FN}/messaging`, { headers: { ...anonH, 'x-cron-secret': CRON }, body: { action: 'process_queue' } });
  assert(ok.status === 200, `with secret: ${show(ok)}`);
  return ok.text.slice(0, 120);
});
await check('fn messaging: twilio_inbound rejects a bad X-Twilio-Signature and accepts a valid one', async () => {
  const query = `?action=twilio_inbound&shop_id=${shop.id}`;
  const params = { AccountSid: 'AC00000000000000000000000000000000', From: '+12055550199', To: '+12055550100', Body: 'hello', MessageSid: `SM${createHash('md5').update(SFX).digest('hex')}` };
  const form = new URLSearchParams(params).toString();
  const bad = await http('POST', `${FN}/messaging${query}`, { raw: form, headers: { 'content-type': 'application/x-www-form-urlencoded', 'x-twilio-signature': 'bad' } });
  assert(bad.status >= 400 && bad.status < 500, `bad signature: ${show(bad)}`);
  const publicUrl = `${FN}/messaging${query}`;
  const data = publicUrl + Object.keys(params).sort().map((k) => k + params[k]).join('');
  const sig = createHmac('sha1', TWILIO_TOKEN).update(data).digest('base64');
  const good = await http('POST', `${FN}/messaging${query}`, { raw: form, headers: { 'content-type': 'application/x-www-form-urlencoded', 'x-twilio-signature': sig } });
  assert(good.status === 200, `valid signature: ${show(good)}`);
  return `bad ${bad.status}, valid ${good.status}`;
});
await check('fn storage-purge: needs the cron secret; with it purge runs', async () => {
  const no = await http('POST', `${FN}/storage-purge`, { headers: anonH, body: { action: 'purge' } });
  assert(no.status === 401, `no secret: ${show(no)}`);
  const ok = await http('POST', `${FN}/storage-purge`, { headers: { ...anonH, 'x-cron-secret': CRON }, body: { action: 'purge', limit: 10 } });
  assert(ok.status === 200, `with secret: ${show(ok)}`);
  return ok.text.slice(0, 120);
});
await check('fn invites: owner sends an invite; email goes to the Resend mock', async () => {
  // The provider log is never cleared (the Playwright journeys may run at the
  // same time and read it); the unique address below identifies this call.
  const email = `invitee-${SFX}@stack.test`;
  const r = await http('POST', `${FN}/invites`, { headers: userH(owner.jwt), body: { action: 'send_invite', shop_id: shop.id, email, role: 'technician' } });
  assert(r.status === 200, show(r));
  const reqs = await (await fetch(`${PROVIDER}/__control/requests?service=resend`)).json();
  const hit = reqs.find((q) => JSON.stringify(q.body ?? '').includes(email));
  assert(hit, `no Resend request recorded for ${email}: ${JSON.stringify(reqs).slice(0, 400)}`);
  assert(JSON.stringify(hit.body).includes(`${APP_ORIGIN}/invite/`), 'invite link does not use APP_BASE_URL');
  return 'resend mock received the invite';
});
await check('fn invites: a technician of another shop is forbidden', async () => {
  const r = await http('POST', `${FN}/invites`, { headers: userH(tech.jwt), body: { action: 'send_invite', shop_id: shop.id, email: `x-${SFX}@stack.test`, role: 'technician' } });
  assert(r.status === 403 && r.json?.code === 'forbidden', show(r));
  return 'forbidden';
});

// ------------------------------------------- account deletion (GoTrue admin)
await check('auth: GoTrue admin delete of a manager who authored a job succeeds (FK SET NULL as supabase_auth_admin)', async () => {
  const mgr = { email: `mgr-${SFX}@stack.test`, password: `Pw-${SFX}-mgr!` };
  const su = await http('POST', `${API}/auth/v1/signup`, { headers: { apikey: ANON }, body: mgr });
  assert(su.status === 200 && su.json?.access_token, show(su));
  mgr.id = su.json.user.id;
  mgr.jwt = su.json.access_token;
  // Harness plumbing: add the membership directly (the invite flow is covered elsewhere).
  sql(`insert into public.shop_members (shop_id, user_id, role, display_name) values ('${shop.id}', '${mgr.id}', 'manager', 'Stack Manager')`);
  const j = await http('POST', `${API}/rest/v1/jobs?select=id,created_by`, {
    headers: { ...userH(mgr.jwt), prefer: 'return=representation' },
    body: { shop_id: shop.id, customer_id: shop.customerId, scheduled_start: '2030-03-05T15:00:00Z', scheduled_end: '2030-03-05T16:00:00Z' },
  });
  assert(j.status === 201 && j.json?.[0]?.created_by === mgr.id, `job by manager: ${show(j)}`);
  const del = await http('DELETE', `${API}/auth/v1/admin/users/${mgr.id}`, { headers: serviceH });
  assert(del.status === 200, `admin delete: ${show(del)}`);
  const after = sql(`select coalesce(created_by::text, 'null') from public.jobs where id = '${j.json[0].id}'`);
  assert(after === 'null', `jobs.created_by after delete: ${after}`);
  return 'deleted; jobs.created_by -> null';
});
await check('auth: deleting a shop owner is refused (owner membership rule)', async () => {
  const del = await http('DELETE', `${API}/auth/v1/admin/users/${owner.id}`, { headers: serviceH });
  assert(del.status >= 400 && /owner membership cannot be removed/.test(del.text), show(del));
  return `HTTP ${del.status} (GoTrue reports the trigger error as unexpected_failure)`;
});

// ------------------------------------------- pg_net -> functions (cron path)
await check('db: pg_net reaches the functions through Kong with the cron secret (pg_cron job path)', async () => {
  const id = sql(`select net.http_post(url := 'http://kong:8000/functions/v1/messaging',
                    headers := jsonb_build_object('Content-Type','application/json','x-cron-secret', '${CRON}'),
                    body := '{"action":"process_queue"}'::jsonb, timeout_milliseconds := 30000)`);
  let row = '';
  for (let i = 0; i < 60 && !row; i++) {
    await sleep(500);
    row = sql(`select status_code || '|' || coalesce(error_msg,'') from net._http_response where id = ${Number(id)}`);
  }
  assert(row.startsWith('200|'), `pg_net response: ${row || 'none after 30 s'}`);
  return `request ${id} -> ${row}`;
});
await check('db: pg_cron can schedule and unschedule a job', () => {
  const got = sql(`select cron.schedule('stack-verify-${SFX}', '0 0 1 1 *', 'select 1')::text || '|' ||
                          cron.unschedule('stack-verify-${SFX}')::text`);
  assert(/^\d+\|true$/.test(got), got);
  return got;
});

// ------------------------------------------------------------------ done
const failed = results.filter((r) => !r.ok);
const knownOpen = results.filter((r) => r.known === 'open' && r.ok).length;
console.log(`----\n${results.length - failed.length - knownOpen} passed, ${failed.length} failed, ${knownOpen} known issues`);
const jsonOut = process.argv.indexOf('--json');
if (jsonOut > 0 && process.argv[jsonOut + 1]) writeFileSync(process.argv[jsonOut + 1], JSON.stringify(results, null, 2));
process.exit(failed.length ? 1 : 0);
