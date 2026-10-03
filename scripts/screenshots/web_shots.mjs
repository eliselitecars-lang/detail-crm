#!/usr/bin/env node
/**
 * web_shots.mjs — screenshots of the web app on the LOCAL real stack, filled
 * with the sample shop from seed_demo.mjs (scripts/screenshots/README.md).
 *
 *   scripts/stack/up.sh && node scripts/screenshots/seed_demo.mjs
 *   node scripts/screenshots/web_shots.mjs
 *
 * A production build (no dev-only tooling) is served with `vite preview` on
 * the origin the stack expects (STACK_APP_URL, the GoTrue site URL / function
 * APP_BASE_URL). Staff sign in through the real login page. Every shot waits
 * for the network to go idle, skeletons to disappear and web fonts to load.
 *
 * Env: SHOTS_DIR (default scripts/screenshots/.state/web), SHOTS_SKIP_BUILD=1
 * (reuse the last build), SHOTS_ONLY=<regex on the file name>.
 * Uses Playwright from web/node_modules (Chromium).
 */
import { spawn } from 'node:child_process';
import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

// Behind an HTTPS proxy (the Claude sandbox), Chromium cannot verify the
// proxy's TLS for Google Fonts, so font requests are fetched by Node
// (NODE_USE_ENV_PROXY honours HTTPS_PROXY / NO_PROXY and NODE_EXTRA_CA_CERTS).
const PROXY = process.env.HTTPS_PROXY ?? process.env.https_proxy;
const REEXEC = Boolean(PROXY) && process.env.NODE_USE_ENV_PROXY !== '1';
const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..', '..');
const WEB = join(ROOT, 'web');
const STATE = join(HERE, '.state');
const DIST = join(STATE, 'web-dist');
const OUT = process.env.SHOTS_DIR ?? join(STATE, 'web');
const ONLY = process.env.SHOTS_ONLY ? new RegExp(process.env.SHOTS_ONLY) : null;

const require = createRequire(join(WEB, 'package.json'));
const { chromium } = require('@playwright/test');

// ------------------------------------------------------------------ inputs

function readEnvFile(file) {
  const out = {};
  if (!existsSync(file)) return out;
  for (const line of readFileSync(file, 'utf8').split('\n')) {
    const m = /^([A-Z0-9_]+)=(.*)$/.exec(line.trim());
    if (m) out[m[1]] = m[2];
  }
  return out;
}
const stackFile = readEnvFile(join(ROOT, 'scripts', 'stack', '.state', 'stack.env'));
const envOf = (name, fallback) => process.env[name] ?? stackFile[name] ?? fallback;
const API_URL = envOf('STACK_API_URL');
const ANON_KEY = envOf('STACK_ANON_KEY');
const APP_URL = envOf('STACK_APP_URL', 'http://127.0.0.1:5173');
if (!API_URL || !ANON_KEY) throw new Error('STACK_API_URL / STACK_ANON_KEY missing: run scripts/stack/up.sh');
const demoFile = join(STATE, 'demo.json');
if (!existsSync(demoFile)) throw new Error(`${demoFile} missing: run node scripts/screenshots/seed_demo.mjs`);
const demo = JSON.parse(readFileSync(demoFile, 'utf8'));
const TZ = demo.shop.timeZone;

const log = (msg) => console.log(`[shots] ${msg}`);

// ------------------------------------------------------------------ build + serve

function run(cmd, args, opts = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(cmd, args, { stdio: 'inherit', ...opts });
    child.on('exit', (code) => (code === 0 ? resolve() : reject(new Error(`${cmd} ${args.join(' ')} exited ${code}`))));
  });
}

const VITE = join(WEB, 'node_modules', 'vite', 'bin', 'vite.js');
const viteEnv = { ...process.env, VITE_SUPABASE_URL: API_URL, VITE_SUPABASE_ANON_KEY: ANON_KEY };

async function build() {
  if (process.env.SHOTS_SKIP_BUILD === '1' && existsSync(join(DIST, 'index.html'))) {
    log(`reusing ${DIST}`);
    return;
  }
  log('vite build (production, pointed at the local stack)');
  rmSync(DIST, { recursive: true, force: true });
  await run(process.execPath, [VITE, 'build', '--outDir', DIST, '--emptyOutDir', '--logLevel', 'warn'], {
    cwd: WEB,
    env: viteEnv,
  });
}

async function up(url) {
  try {
    const r = await fetch(url);
    return r.status < 500;
  } catch {
    return false;
  }
}

async function serve() {
  const { hostname, port } = new URL(APP_URL);
  if (await up(APP_URL)) {
    throw new Error(`${APP_URL} is already serving something (stop the dev server first)`);
  }
  log(`vite preview on ${APP_URL}`);
  const child = spawn(
    process.execPath,
    [VITE, 'preview', '--outDir', DIST, '--host', hostname, '--port', port || '5173', '--strictPort'],
    { cwd: WEB, env: viteEnv, stdio: ['ignore', 'ignore', 'inherit'] },
  );
  for (let i = 0; i < 60; i += 1) {
    if (await up(APP_URL)) return child;
    await new Promise((r) => setTimeout(r, 500));
  }
  child.kill();
  throw new Error('vite preview did not start');
}

// ------------------------------------------------------------------ page helpers

const HIDE_CSS = `
  section[aria-label="Notifications"].fixed { visibility: hidden !important; }
  *, *::before, *::after { caret-color: transparent !important; }
`;

/** Network idle, no skeletons or busy regions, fonts loaded, then a short settle. */
async function settle(page, { heading = true } = {}) {
  await page.waitForLoadState('networkidle', { timeout: 30_000 }).catch(() => undefined);
  if (heading) {
    await page.getByRole('heading', { level: 1 }).first().waitFor({ timeout: 20_000 }).catch(() => undefined);
  }
  await page
    .waitForFunction(
      () => {
        const visible = (el) => {
          const r = el.getBoundingClientRect();
          return r.width > 0 && r.height > 0;
        };
        const skeleton = [...document.querySelectorAll('.animate-pulse.bg-surface-3, [aria-hidden="true"] .animate-pulse')].some(visible);
        const busy = [...document.querySelectorAll('[aria-busy="true"]')].some(
          (el) => visible(el) && el.tagName !== 'BUTTON',
        );
        return !skeleton && !busy;
      },
      undefined,
      { timeout: 20_000, polling: 200 },
    )
    .catch(() => undefined);
  await page.waitForLoadState('networkidle', { timeout: 15_000 }).catch(() => undefined);
  await page.evaluate(() => document.fonts.ready).catch(() => undefined);
  await page.addStyleTag({ content: HIDE_CSS }).catch(() => undefined);
  await page.waitForTimeout(500);
}

/** Error states the app renders for a failed read (same wording the tour spec checks). */
async function problemsOn(page) {
  const texts = await page
    .getByText(/^(Couldn’t (load|count|reach)|Something went wrong|You don’t have access to this page)/)
    .allTextContents()
    .catch(() => []);
  return texts;
}

// ------------------------------------------------------------------ shot list

const ymd = (d) => new Intl.DateTimeFormat('en-CA', { timeZone: TZ, year: 'numeric', month: '2-digit', day: '2-digit' }).format(d);
const today = ymd(new Date());
const from30 = ymd(new Date(Date.now() - 29 * 86400000));
const ids = demo.ids;

/**
 * who: owner | tech | client | anon. device: desktop | phone.
 * before(page): optional interaction after load. full: full-page capture.
 */
const addDaysYmd = (d, n) => {
  const [y, m, dd] = d.split('-').map(Number);
  return new Date(Date.UTC(y, m - 1, dd + n)).toISOString().slice(0, 10);
};

/** Public booking flow: vehicle step filled in, then on to the services step. */
async function bookingToServices(page) {
  await page.getByText('Small SUV', { exact: true }).click();
  await page.getByLabel('Year').fill('2022');
  await page.getByLabel(/^Make/).fill('Toyota');
  await page.getByLabel(/^Model/).fill('RAV4');
  await page.getByLabel(/^Colou?r/).fill('Lunar Rock');
  await page.getByRole('button', { name: 'Continue' }).click();
  await page.getByRole('heading', { name: 'Choose your services' }).waitFor();
  await page.getByRole('checkbox', { name: /Full Detail/ }).first().check();
  await settle(page, { heading: false });
}

async function bookingToTimes(page) {
  await bookingToServices(page);
  await page.getByRole('button', { name: 'Continue' }).click();
  await page.getByRole('heading', { name: 'Pick a date and time' }).waitFor();
  const slots = page.getByRole('button', { name: / on [A-Z][a-z]+day, / });
  await slots.first().or(page.getByText('No open times this week')).waitFor();
  if ((await slots.count()) === 0) await page.getByRole('button', { name: 'Next week' }).first().click();
  await slots.first().waitFor();
  await slots.nth(Math.min(2, (await slots.count()) - 1)).click();
  await settle(page, { heading: false });
}

/**
 * who: owner | tech | client | anon. device: desktop | phone.
 * before(page): optional interaction after load. full: full-page capture.
 */
const SHOTS = [
  { file: 'login', who: 'anon', path: '/login', what: 'Staff sign-in page', login: true },
  { file: 'dashboard', who: 'owner', path: '/app', what: 'Owner dashboard: revenue, today’s schedule by status, booking requests, who is on the clock' },
  { file: 'dashboard-full', who: 'owner', path: '/app', what: 'Owner dashboard (full page)', full: true },
  { file: 'calendar-week', who: 'owner', path: '/app/calendar', what: 'Calendar, week view (today’s jobs at every status)', calendar: 'timeGridWeek' },
  { file: 'calendar-month', who: 'owner', path: '/app/calendar', what: 'Calendar, month view', calendar: 'dayGridMonth' },
  { file: 'calendar-bays', who: 'owner', path: '/app/calendar', what: 'Calendar, bays & vans day view (today)', calendar: 'resourceDay' },
  { file: 'jobs', who: 'owner', path: `/app/jobs?from=${addDaysYmd(today, -4)}&to=${addDaysYmd(today, 4)}&dir=asc`, what: 'Jobs list around today (completed, in progress, on the way, upcoming)' },
  { file: 'job-detail', who: 'owner', path: `/app/jobs/${ids.jobInProgress}`, what: 'Job detail: in-progress full detail (status steps, services, totals)' },
  { file: 'job-detail-full', who: 'owner', path: `/app/jobs/${ids.jobInProgress}`, what: 'Job detail (full page: checklist, team, time, messages, activity)', full: true },
  { file: 'customers', who: 'owner', path: '/app/customers', what: 'Customers list' },
  { file: 'customer-detail', who: 'owner', path: `/app/customers/${ids.customer}`, what: 'Customer detail: lifetime value, jobs, contact, portal link' },
  { file: 'quotes', who: 'owner', path: '/app/quotes', what: 'Quotes list (draft, sent, approved, converted, declined)' },
  { file: 'quote-detail', who: 'owner', path: `/app/quotes/${ids.quoteApproved}`, what: 'Quote approved by the customer online (optional add-on chosen)' },
  { file: 'invoices', who: 'owner', path: '/app/invoices', what: 'Invoices list (paid, partially paid, open, overdue)' },
  { file: 'invoice-detail', who: 'owner', path: `/app/invoices/${ids.invoicePartial}`, what: 'Invoice detail: partially paid by card' },
  { file: 'payments', who: 'owner', path: '/app/payments', what: 'Payments: card (Stripe) and cash, deposits, tips' },
  { file: 'messages', who: 'owner', path: `/app/messages?customer=${ids.customerWithThread}`, what: 'Messages inbox with a two-way SMS conversation open' },
  { file: 'reports', who: 'owner', path: `/app/reports?range=custom&from=${from30}&to=${today}`, what: 'Reports: revenue, last 30 days' },
  { file: 'team', who: 'owner', path: '/app/team', what: 'Team: owner, technician, pending invite' },
  { file: 'timesheets', who: 'owner', path: '/app/timesheets', what: 'Timesheets: this week’s shifts and job time' },
  { file: 'tasks', who: 'owner', path: '/app/tasks', what: 'Tasks' },
  { file: 'catalog', who: 'owner', path: '/app/catalog', what: 'Catalog: services and add-ons' },
  { file: 'catalog-service', who: 'owner', path: `/app/catalog/services/${ids.serviceFullDetail}`, what: 'Catalog item: prices by vehicle size, add-ons' },
  { file: 'memberships', who: 'owner', path: '/app/memberships?tab=plans', what: 'Membership plans' },
  { file: 'campaigns', who: 'owner', path: '/app/campaigns', what: 'Campaigns (one sent, one draft)' },
  { file: 'settings-business', who: 'owner', path: '/app/settings/business', what: 'Settings: business profile' },
  { file: 'settings-booking', who: 'owner', path: '/app/settings/booking', what: 'Settings: online booking (requests, 25% deposit)' },
  { file: 'tech-dashboard', who: 'tech', path: '/app', what: 'Technician dashboard: own jobs today and time clock' },
  { file: 'tech-jobs', who: 'tech', path: `/app/jobs?from=${addDaysYmd(today, -4)}&to=${addDaysYmd(today, 4)}&dir=asc`, what: 'Technician: assigned jobs only (no prices)' },
  { file: 'tech-job-detail', who: 'tech', path: `/app/jobs/${ids.jobEnRoute}`, what: 'Technician: en-route mobile job' },
  { file: 'booking', who: 'anon', path: demo.links.booking, what: 'Public online booking page: vehicle step' },
  { file: 'booking-services', who: 'anon', path: demo.links.booking, what: 'Public booking: services priced for the vehicle size, add-ons', before: bookingToServices },
  { file: 'booking-times', who: 'anon', path: demo.links.booking, what: 'Public booking: open times', before: bookingToTimes },
  { file: 'booking-phone', who: 'anon', device: 'phone', path: demo.links.booking, what: 'Public booking: services step (phone)', before: bookingToServices },
  { file: 'quote-public', who: 'anon', path: demo.links.quote, what: 'Customer quote page (/q): optional add-on, approve or decline', full: true },
  { file: 'invoice-public', who: 'anon', path: demo.links.invoice, what: 'Customer invoice pay page (/i) with a 20% tip chosen', full: true,
    before: async (page) => { await page.getByText('20%', { exact: true }).click(); await settle(page, { heading: false }); } },
  { file: 'portal', who: 'client', path: '/portal', what: 'Client portal: appointments, invoices, vehicles', full: true },
  { file: 'pricing', who: 'anon', path: '/pricing', what: 'Public pricing page (no platform plans are configured on a local stack, so it shows its empty state)' },
  { file: 'phone-dashboard', who: 'owner', device: 'phone', path: '/app', what: 'Owner dashboard (phone)' },
  { file: 'phone-calendar', who: 'owner', device: 'phone', path: '/app/calendar', what: 'Calendar, day view (phone)', calendar: 'timeGridDay' },
  { file: 'phone-job-detail', who: 'owner', device: 'phone', path: `/app/jobs/${ids.jobInProgress}`, what: 'Job detail (phone)' },
  { file: 'phone-messages', who: 'owner', device: 'phone', path: `/app/messages?customer=${ids.customerWithThread}`, what: 'SMS conversation (phone)' },
];

const DEVICES = {
  desktop: { viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2 },
  phone: {
    viewport: { width: 390, height: 844 },
    deviceScaleFactor: 3,
    isMobile: true,
    hasTouch: true,
    userAgent:
      'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1',
  },
};

// ------------------------------------------------------------------ main

const fontCache = new Map();

/** A browser context; behind a proxy, Google Fonts are fetched by Node (see top). */
async function newContext(browser, options) {
  const context = await browser.newContext({ ...common, ...options });
  if (PROXY) {
    await context.route(/^https:\/\/fonts\.(googleapis|gstatic)\.com\//, async (route) => {
      const url = route.request().url();
      try {
        if (!fontCache.has(url)) {
          const res = await fetch(url, { headers: { 'user-agent': route.request().headers()['user-agent'] ?? '' } });
          fontCache.set(url, {
            status: res.status,
            contentType: res.headers.get('content-type') ?? 'application/octet-stream',
            body: Buffer.from(await res.arrayBuffer()),
          });
        }
        const hit = fontCache.get(url);
        await route.fulfill({
          status: hit.status,
          contentType: hit.contentType,
          body: hit.body,
          headers: { 'access-control-allow-origin': '*' },
        });
      } catch {
        await route.abort();
      }
    });
  }
  return context;
}

async function signIn(browser, user, deviceOptions) {
  const context = await newContext(browser, deviceOptions);
  const page = await context.newPage();
  await page.goto(`${APP_URL}/login`);
  await page.getByLabel('Email').fill(user.email);
  await page.getByLabel(/^Password/).fill(user.password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL(/\/(app|portal)(\/.*)?$/, { timeout: 30_000 });
  await settle(page);
  const state = await context.storageState();
  await context.close();
  return state;
}

const common = { locale: 'en-US', timezoneId: TZ, colorScheme: 'light', baseURL: APP_URL };

async function main() {
  mkdirSync(OUT, { recursive: true });
  if (!ONLY) {
    for (const f of readdirSync(OUT)) if (/^\d+-.*\.png$/.test(f)) rmSync(join(OUT, f));
  }
  await build();
  const server = await serve();
  let browser;
  try {
    browser = await chromium.launch(
      process.env.PW_CHROMIUM_EXECUTABLE ? { executablePath: process.env.PW_CHROMIUM_EXECUTABLE } : {},
    );
  } catch (error) {
    server.kill();
    throw error;
  }
  const manifest = [];
  const issues = [];
  try {
    const states = {};
    const stateFor = async (who, device) => {
      if (who === 'anon') return undefined;
      const key = `${who}:${device}`;
      if (!states[key]) {
        const user = { owner: demo.owner, tech: demo.technician, client: demo.client }[who];
        states[key] = await signIn(browser, user, DEVICES[device]);
      }
      return states[key];
    };
    let n = 0;
    for (const shot of SHOTS) {
      n += 1;
      const device = shot.device ?? 'desktop';
      const name = `${String(n).padStart(2, '0')}-${shot.file}.png`;
      if (ONLY && !ONLY.test(name)) continue;
      const context = await newContext(browser, {
        ...DEVICES[device],
        storageState: await stateFor(shot.who, device),
      });
      if (shot.calendar) {
        await context.addInitScript((view) => {
          try {
            localStorage.setItem('detailcrm:calendarView', view);
          } catch {
            /* ignore */
          }
        }, shot.calendar);
      }
      const page = await context.newPage();
      const failed = [];
      page.on('response', (r) => {
        if (r.url().startsWith(API_URL) && r.status() >= 400) failed.push(`${r.status()} ${r.url().replace(API_URL, '')}`);
      });
      page.on('pageerror', (e) => failed.push(`pageerror: ${e.message}`));
      await page.goto(shot.path);
      await settle(page);
      if (shot.login) {
        await page.getByLabel('Email').fill(demo.owner.email);
        await page.getByLabel(/^Password/).fill(demo.owner.password);
        await page.evaluate(() => document.activeElement?.blur());
      }
      if (shot.before) {
        try {
          await shot.before(page);
        } catch (error) {
          failed.push(`interaction failed: ${error instanceof Error ? error.message.split('\n')[0] : String(error)}`);
        }
      }
      const file = join(OUT, name);
      if (shot.full) {
        // Grow the viewport to the page instead of fullPage, so the
        // full-height sidebar and sticky bars render as on a tall screen.
        const vp = page.viewportSize();
        const height = await page.evaluate(() => document.documentElement.scrollHeight);
        if (vp && height > vp.height) {
          await page.setViewportSize({ width: vp.width, height: Math.min(height, 8000) });
          await settle(page, { heading: false });
        }
      }
      await page.screenshot({ path: file, animations: 'disabled' });
      const problems = await problemsOn(page);
      if (problems.length || failed.length) issues.push(`${name}: ${[...problems, ...failed].join(' | ')}`);
      manifest.push(`- \`${name}\` — ${shot.what}${device === 'phone' ? ' — 390×844 @3x' : ' — 1440×900 @2x'}${shot.full ? ' (full page)' : ''}`);
      log(`${name}${problems.length || failed.length ? `  (!) ${[...problems, ...failed].join(' | ')}` : ''}`);
      await context.close();
    }
  } finally {
    await browser.close();
    server.kill();
  }
  const md = [
    '# Web screenshots — Summit Auto Detailing (SAMPLE data)',
    '',
    `Captured ${new Date().toISOString()} from a production build on the local real stack, shop day ${demo.shopToday} (${TZ}).`,
    'Sample data from `scripts/screenshots/seed_demo.mjs`; every person, phone number and email is fictional.',
    '',
    ...manifest,
    '',
    '## Issues seen',
    '',
    ...(issues.length ? issues.map((i) => `- ${i}`) : ['- None detected automatically (API errors, page errors, error states).']),
    '',
  ].join('\n');
  if (!ONLY) writeFileSync(join(OUT, 'MANIFEST.md'), md);
  log(`${manifest.length} screenshots in ${OUT}`);
}

if (REEXEC) {
  const child = spawn(process.execPath, process.argv.slice(1), {
    stdio: 'inherit',
    env: { ...process.env, NODE_USE_ENV_PROXY: '1', NODE_NO_WARNINGS: '1' },
  });
  child.on('exit', (code) => process.exit(code ?? 1));
} else main().catch((error) => {
  console.error(`[shots] FAILED: ${error instanceof Error ? error.stack ?? error.message : String(error)}`);
  process.exit(1);
});
