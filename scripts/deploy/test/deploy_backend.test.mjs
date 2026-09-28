// End-to-end test of scripts/deploy/deploy_backend.sh against a fake Supabase
// CLI (fakes/fake_supabase.sh) and a fake Management + Stripe API
// (fakes/fake_api.mjs): command sequence, dry run, missing/invalid inputs,
// secret handling (no value is ever printed or put on a command line),
// idempotent re-runs, and that `supabase config push` is never invoked.
//   node --test scripts/deploy/test/
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtempSync, readdirSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { after, before, describe, test } from 'node:test';
import { parseHandledStripeEvents, parseStripeApiVersion, REPO_ROOT } from '../lib/config.mjs';
import { startFakeApi } from './fakes/fake_api.mjs';

const SCRIPT = join(REPO_ROOT, 'scripts', 'deploy', 'deploy_backend.sh');
const FAKE_CLI = join(REPO_ROOT, 'scripts', 'deploy', 'test', 'fakes', 'fake_supabase.sh');
const REF = 'abcdefghijklmnopqrst';
const MIGRATIONS = readdirSync(join(REPO_ROOT, 'supabase', 'migrations')).filter((f) => f.endsWith('.sql'));
const EVENTS = parseHandledStripeEvents(readFileSync(join(REPO_ROOT, 'supabase/functions/stripe-webhook/handlers.ts'), 'utf8'));
const BILLING_EVENTS = parseHandledStripeEvents(readFileSync(join(REPO_ROOT, 'supabase/functions/billing-webhook/handlers.ts'), 'utf8'));
const STRIPE_VERSION = parseStripeApiVersion(readFileSync(join(REPO_ROOT, 'supabase/functions/_shared/stripe.ts'), 'utf8'));
const NO_JWT = ['billing', 'billing-webhook', 'calendar-feed', 'messaging', 'payments', 'pdf', 'public-media', 'push', 'sms-provisioning', 'storage-purge', 'stripe-webhook', 'webhooks'];
const FUNCTIONS = ['account', 'billing', 'billing-webhook', 'calendar-feed', 'invites', 'messaging', 'payments', 'pdf', 'public-media', 'push', 'sms-provisioning', 'storage-purge', 'stripe-connect', 'stripe-webhook', 'webhooks'];
const CRON_JOBS = [...readFileSync(join(REPO_ROOT, 'supabase/setup/cron.sql'), 'utf8').matchAll(/cron\.schedule\(\s*'([^']+)'/g)].map((m) => m[1]);

const SECRETS = {
  SUPABASE_ACCESS_TOKEN: 'sbp_fake_token_SECRET_0123456789',
  SUPABASE_DB_PASSWORD: 'db-password-SECRET-0123',
  STRIPE_SECRET_KEY: 'sk_live_FAKEsecretKEY0123456789',
  STRIPE_WEBHOOK_SECRET: 'whsec_FAKEenvWEBHOOKsecret0123',
  TWILIO_AUTH_TOKEN: 'twilio-auth-token-SECRET-0123456789',
  RESEND_API_KEY: 're_FAKE_resend_SECRET_0123',
  CRON_SECRET: 'cron-secret-SECRET-0123456789abcdef',
};
const PUBLIC = {
  SUPABASE_PROJECT_REF: REF,
  STRIPE_PUBLISHABLE_KEY: 'pk_live_FAKEpublishable0123456789',
  TWILIO_ACCOUNT_SID: `AC${'0123456789abcdef'.repeat(2)}`,
  EMAIL_FROM: 'Detail CRM <notifications@example.com>',
  APP_BASE_URL: 'https://app.example.com',
};

let work;
let api;
function freshState() {
  work = mkdtempSync(join(tmpdir(), 'deploy-test-'));
}
async function freshApi() {
  if (api) await api.close();
  freshState();
  api = await startFakeApi({ ref: REF, deployedFile: join(work, 'deployed.jsonl'), token: SECRETS.SUPABASE_ACCESS_TOKEN, stripeKey: SECRETS.STRIPE_SECRET_KEY, cronSecret: SECRETS.CRON_SECRET });
}

function run(args = [], { omit = [], extra = {} } = {}) {
  const env = {
    PATH: process.env.PATH,
    HOME: process.env.HOME ?? work,
    TMPDIR: work,
    FAKE_CLI_LOG: join(work, 'cli.log'),
    FAKE_STATE_DIR: work,
    SUPABASE_CLI: FAKE_CLI,
    DEPLOY_SUPABASE_API_BASE: api.url,
    DEPLOY_STRIPE_API_BASE: api.url,
    DEPLOY_FUNCTIONS_API_BASE: `${api.url}/functions/v1`,
    ...SECRETS,
    ...PUBLIC,
    ...extra,
  };
  for (const k of omit) delete env[k];
  const started = api.state.requests.length;
  // Async on purpose: the fake API runs in this process, so a sync spawn
  // would block the event loop that answers the script's requests.
  return new Promise((resolve, reject) => {
    const child = spawn('bash', [SCRIPT, ...args], { env });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (d) => (stdout += d));
    child.stderr.on('data', (d) => (stderr += d));
    const timer = setTimeout(() => child.kill('SIGKILL'), 120_000);
    child.on('error', reject);
    child.on('close', (code) => {
      clearTimeout(timer);
      resolve({ code, out: `${stdout}\n${stderr}`, requests: api.state.requests.slice(started) });
    });
  });
}
function cliLog() {
  try {
    return readFileSync(join(work, 'cli.log'), 'utf8').split('\n').filter(Boolean);
  } catch {
    return [];
  }
}
function assertNoSecretLeak(text, what) {
  const values = [...Object.values(SECRETS), ...[...api.state.endpoints.values()].map((e) => e.secret)];
  for (const v of values) assert.ok(!text.includes(v), `${what} contains a secret value (${v.slice(0, 6)}…)`);
}
const mutations = (reqs) => reqs.filter((r) => r.method !== 'GET');

before(freshApi);
after(async () => {
  await api?.close();
  if (work) rmSync(work, { recursive: true, force: true });
});

describe('deploy_backend.sh', () => {
  test('missing inputs: every missing name is listed and nothing is contacted', async () => {
    await freshApi();
    const r = await run([], { omit: ['STRIPE_SECRET_KEY', 'TWILIO_AUTH_TOKEN', 'CRON_SECRET', 'SUPABASE_DB_PASSWORD', 'STRIPE_WEBHOOK_SECRET'] });
    assert.equal(r.code, 1, r.out);
    for (const name of ['STRIPE_SECRET_KEY', 'TWILIO_AUTH_TOKEN', 'CRON_SECRET', 'SUPABASE_DB_PASSWORD', 'STRIPE_WEBHOOK_SECRET']) {
      assert.match(r.out, new RegExp(`- ${name}: `), `missing ${name} not listed:\n${r.out}`);
    }
    assert.equal(r.requests.length, 0, 'no API request before inputs are valid');
    assert.deepEqual(cliLog(), [], 'no CLI call before inputs are valid');
    assertNoSecretLeak(r.out, 'output');
  });

  test('--stripe-webhooks makes STRIPE_WEBHOOK_SECRET optional', async () => {
    await freshApi();
    const r = await run(['--dry-run', '--stripe-webhooks'], { omit: ['STRIPE_WEBHOOK_SECRET'] });
    assert.equal(r.code, 0, r.out);
    assert.doesNotMatch(r.out, /- STRIPE_WEBHOOK_SECRET:/);
  });

  test('invalid inputs: the problem is named, the value never printed', async () => {
    await freshApi();
    const r = await run([], { extra: { STRIPE_PUBLISHABLE_KEY: 'pk_test_FAKEpublishable0123456789', CRON_SECRET: 'short-SECRET', APP_BASE_URL: 'http://app.example.com' } });
    assert.equal(r.code, 1, r.out);
    assert.match(r.out, /STRIPE_PUBLISHABLE_KEY: publishable key is test but secret key is live/);
    assert.match(r.out, /CRON_SECRET: must be at least 24 characters/);
    assert.match(r.out, /APP_BASE_URL: APP_BASE_URL must be an https:\/\/ URL/);
    assert.ok(!r.out.includes('short-SECRET'));
    assert.equal(r.requests.length, 0);
  });

  test('--dry-run: links, lists pending migrations and the plan, changes nothing', async () => {
    await freshApi();
    const r = await run(['--dry-run', '--stripe-webhooks']);
    assert.equal(r.code, 0, r.out);
    assert.match(r.out, /DRY RUN/);
    assert.match(r.out, /Would push these migrations:/);
    for (const m of MIGRATIONS) assert.ok(r.out.includes(m), `pending migration ${m} not listed`);
    for (const fn of FUNCTIONS) {
      assert.ok(r.out.includes(`would deploy ${fn} (verify_jwt=${!NO_JWT.includes(fn)})`), `plan for ${fn} missing:\n${r.out}`);
    }
    assert.match(r.out, /would create the Connect endpoint/);
    assert.match(r.out, /Platform billing endpoint: not managed \(BILLING_ENABLED is not true\)/);
    assert.match(r.out, /dry run: Auth config not changed/);
    assert.match(r.out, /dry run: cron\.sql not executed/);
    assert.match(r.out, /dry run: would call set_billing_config\(false, 0\)/);
    assert.match(r.out, /billing: off \(BILLING_ENABLED unset\)/);
    assert.deepEqual(mutations(r.requests), [], `dry run sent mutations: ${JSON.stringify(mutations(r.requests).map((q) => `${q.method} ${q.path}`))}`);
    const cli = cliLog();
    assert.ok(cli.some((l) => l.startsWith(`link --project-ref ${REF} --workdir `)), cli.join('\n'));
    assert.ok(cli.some((l) => /^db push --linked --yes --skip-vault --dry-run --workdir /.test(l)), cli.join('\n'));
    assert.ok(!cli.some((l) => /^db push/.test(l) && !l.includes('--dry-run')), 'dry run must not push');
    assert.ok(!cli.some((l) => l.startsWith('functions deploy')), 'dry run must not deploy functions');
    assert.ok(!cli.some((l) => l.startsWith('config')), 'config push must never be invoked');
    assertNoSecretLeak(r.out, 'output');
    assertNoSecretLeak(cli.join('\n'), 'CLI argv');
  });

  test('full deploy: exact sequence, verify_jwt flags, secrets, webhook, Auth, cron.sql', async () => {
    await freshApi();
    const r = await run(['--stripe-webhooks', '--allow-dirty'], { omit: ['STRIPE_WEBHOOK_SECRET'] });
    assert.equal(r.code, 0, r.out);
    const s = api.state;

    // CLI: link -> push dry-run -> push -> one deploy per function with the right JWT flag.
    const cli = cliLog();
    const idx = (re) => cli.findIndex((l) => re.test(l));
    assert.ok(idx(/^link /) >= 0 && idx(/^link /) < idx(/^db push .*--dry-run/), cli.join('\n'));
    const push = cli.findIndex((l) => /^db push/.test(l) && !l.includes('--dry-run'));
    assert.ok(push > idx(/^db push .*--dry-run/), cli.join('\n'));
    const deploys = cli.filter((l) => l.startsWith('functions deploy'));
    assert.equal(deploys.length, FUNCTIONS.length, deploys.join('\n'));
    for (const l of deploys) {
      const fn = l.split(' ')[2];
      assert.equal(l.includes('--no-verify-jwt'), NO_JWT.includes(fn), `wrong JWT flag: ${l}`);
      assert.ok(l.includes(`--project-ref ${REF}`) && l.includes('--use-api'), l);
    }
    assert.ok(!cli.some((l) => l.startsWith('config')), 'config push must never be invoked');
    assert.equal(readFileSync(join(work, 'applied'), 'utf8').trim().split('\n').length, MIGRATIONS.length);

    // Mutations happen in the documented order.
    const order = mutations(r.requests).map((q) => `${q.method} ${q.path.replace(REF, '<ref>')}`);
    const at = (x) => order.indexOf(x);
    assert.ok(at('POST /v1/projects/<ref>/secrets') >= 0, order.join('\n'));
    assert.ok(at('POST /v1/projects/<ref>/secrets') < at('POST /v1/webhook_endpoints'), order.join('\n'));
    assert.ok(at('POST /v1/webhook_endpoints') < at('PATCH /v1/projects/<ref>/config/auth'), order.join('\n'));
    assert.ok(at('PATCH /v1/projects/<ref>/config/auth') < at('POST /v1/projects/<ref>/database/query'), order.join('\n'));
    for (const q of r.requests.filter((x) => x.path.startsWith('/v1/projects'))) assert.match(q.ua ?? '', /detail-crm-deploy/);

    // Secrets: exact values, no reserved/harness names.
    for (const name of ['STRIPE_SECRET_KEY', 'TWILIO_AUTH_TOKEN', 'RESEND_API_KEY', 'CRON_SECRET']) assert.equal(s.secrets.get(name), SECRETS[name]);
    for (const name of ['STRIPE_PUBLISHABLE_KEY', 'TWILIO_ACCOUNT_SID', 'EMAIL_FROM', 'APP_BASE_URL']) assert.equal(s.secrets.get(name), PUBLIC[name]);
    assert.ok(![...s.secrets.keys()].some((k) => k.startsWith('SUPABASE_')));
    assert.ok(!s.secrets.has('SUPABASE_DB_PASSWORD') && !s.secrets.has('SUPABASE_ACCESS_TOKEN'));

    // Stripe: one Connect endpoint with exactly the handled events; its secret stored.
    assert.equal(s.endpoints.size, 1);
    const ep = [...s.endpoints.values()][0];
    assert.equal(ep.connect, true);
    assert.equal(ep.url, `https://${REF}.supabase.co/functions/v1/stripe-webhook`);
    assert.equal(ep.api_version, STRIPE_VERSION);
    assert.deepEqual([...ep.enabled_events].sort(), [...EVENTS].sort());
    assert.equal(ep.metadata.detail_crm_role, 'connect');
    assert.equal(s.secrets.get('STRIPE_WEBHOOK_SECRET'), ep.secret);

    // Auth: production values, confirmations ON, Resend SMTP.
    const auth = s.authPatches.at(-1);
    assert.equal(auth.site_url, PUBLIC.APP_BASE_URL);
    assert.equal(auth.mailer_autoconfirm, false);
    assert.equal(auth.external_anonymous_users_enabled, false);
    assert.equal(auth.smtp_host, 'smtp.resend.com');
    assert.equal(auth.smtp_user, 'resend');
    assert.equal(auth.smtp_pass, SECRETS.RESEND_API_KEY);
    assert.equal(auth.smtp_admin_email, 'notifications@example.com');
    assert.equal(auth.smtp_sender_name, 'Detail CRM');
    assert.ok(auth.uri_allow_list.split(',').includes(`${PUBLIC.APP_BASE_URL}/**`));
    assert.ok(!auth.uri_allow_list.includes('127.0.0.1') && !auth.uri_allow_list.includes('localhost'));

    // cron.sql: rendered in memory with the real values (the fake enforces the guard).
    const cron = s.sql.find((q) => q.includes('cron.schedule'));
    assert.ok(cron && !cron.includes("v_cron_secret   constant text := '<CRON_SECRET>'"));
    assert.equal(s.platformConfig, PUBLIC.APP_BASE_URL);
    assert.equal(s.vaultValues.cronSecret, SECRETS.CRON_SECRET);
    assert.equal(s.vaultValues.functionsUrl, `https://${REF}.supabase.co/functions/v1`);
    assert.equal(s.cronJobs.length, CRON_JOBS.length);
    assert.ok(s.cronJobs.some((j) => j.jobname === 'detail-crm-billing-sync-plans'));
    assert.match(r.out, /deployed functions match config\.toml/);
    assert.match(r.out, /platform setup applied/);

    // Billing off (no BILLING_* inputs): the default is stored, no billing endpoint, no sync.
    assert.deepEqual(s.billingConfigCalls, [{ enabled: false, trialDays: 0 }]);
    assert.equal(s.syncCalls.length, 0);
    assert.ok(![...s.endpoints.values()].some((e) => e.url.endsWith('/billing-webhook')));
    assert.ok(!s.secrets.has('STRIPE_BILLING_WEBHOOK_SECRET'));

    // Nothing secret in the output or on any command line; no rendered SQL on disk.
    assertNoSecretLeak(r.out, 'output');
    assertNoSecretLeak(cli.join('\n'), 'CLI argv');
    assert.deepEqual(readdirSync(work).filter((f) => f.startsWith('detail-crm-deploy')), [], 'temp workdir was not removed');
  });

  test('re-run is idempotent: no new endpoint, no secret writes, nothing to migrate', async () => {
    const creates = api.state.endpointCreates;
    const r = await run(['--stripe-webhooks', '--allow-dirty'], { omit: ['STRIPE_WEBHOOK_SECRET'] });
    assert.equal(r.code, 0, r.out);
    assert.equal(api.state.endpointCreates, creates);
    assert.equal(api.state.endpoints.size, 1);
    assert.match(r.out, /is up to date \(\d+ events/);
    assert.match(r.out, /Remote database is up to date\./);
    assert.deepEqual(
      r.requests.filter((q) => q.method === 'POST' && q.path.endsWith('/secrets')),
      [],
      'unchanged secrets must not be re-sent',
    );
    assert.match(r.out, /secrets: 0 set, 0 removed/);
    assert.ok(!cliLog().some((l) => l.startsWith('config')));
    assertNoSecretLeak(r.out, 'output');
  });

  test('a harness-only secret in the project is removed', async () => {
    api.state.secrets.set('STRIPE_API_BASE', 'http://host.docker.internal:12111');
    const r = await run(['--allow-dirty']);
    assert.equal(r.code, 0, r.out);
    const del = r.requests.find((q) => q.method === 'DELETE' && q.path.endsWith('/secrets'));
    assert.ok(del && JSON.parse(del.raw).includes('STRIPE_API_BASE'), r.out);
    assert.ok(!api.state.secrets.has('STRIPE_API_BASE'));
  });

  test('an endpoint at the webhook URL that the script did not create is never touched', async () => {
    await freshApi();
    api.state.endpoints.set('we_handmade', {
      id: 'we_handmade',
      url: `https://${REF}.supabase.co/functions/v1/stripe-webhook`,
      enabled_events: ['*'],
      metadata: {},
      status: 'enabled',
      api_version: STRIPE_VERSION,
    });
    const r = await run(['--stripe-webhooks', '--allow-dirty'], { omit: ['STRIPE_WEBHOOK_SECRET'] });
    assert.equal(r.code, 1, r.out);
    assert.match(r.out, /not created by this script \(we_handmade\)/);
    assert.match(r.out, /STRIPE_WEBHOOK_ADOPT/);
    assert.equal(api.state.endpointCreates, 0);
    assert.deepEqual(api.state.endpoints.get('we_handmade').enabled_events, ['*']);
  });

  test('billing inputs: the billing webhook secret is required only with billing on and without --stripe-webhooks; bad values are named', async () => {
    await freshApi();
    const on = await run([], { omit: ['STRIPE_BILLING_WEBHOOK_SECRET'], extra: { BILLING_ENABLED: 'true' } });
    assert.equal(on.code, 1, on.out);
    assert.match(on.out, /- STRIPE_BILLING_WEBHOOK_SECRET: /);
    assert.equal(on.requests.length, 0);

    const off = await run(['--dry-run'], { extra: { BILLING_ENABLED: 'false' } });
    assert.equal(off.code, 0, off.out);
    assert.doesNotMatch(off.out, /STRIPE_BILLING_WEBHOOK_SECRET:/);

    const hooks = await run(['--dry-run', '--stripe-webhooks'], { extra: { BILLING_ENABLED: 'true', BILLING_TRIAL_DAYS: '14' } });
    assert.equal(hooks.code, 0, hooks.out);
    assert.match(hooks.out, /billing: ON, trial 14 day\(s\) \(STRIPE_BILLING_WEBHOOK_SECRET will come from --stripe-webhooks\)/);
    assert.match(hooks.out, /would create the platform billing endpoint and store its signing secret as STRIPE_BILLING_WEBHOOK_SECRET/);
    assert.match(hooks.out, /dry run: would call set_billing_config\(true, 14\) and then billing sync_plans/);
    assert.deepEqual(mutations(hooks.requests), []);

    const bad = await run([], { extra: { BILLING_ENABLED: 'yes', BILLING_TRIAL_DAYS: '-1', STRIPE_BILLING_WEBHOOK_SECRET: 'nope' } });
    assert.equal(bad.code, 1, bad.out);
    assert.match(bad.out, /BILLING_ENABLED: must be true or false/);
    assert.match(bad.out, /BILLING_TRIAL_DAYS: must be a whole number of days from 0 to 730/);
    assert.match(bad.out, /STRIPE_BILLING_WEBHOOK_SECRET: expected whsec_ secret/);
    assert.equal(bad.requests.length, 0);
  });

  test('billing on + --stripe-webhooks: platform endpoint with exactly the billing events, secret stored, config applied, plans synced', async () => {
    await freshApi();
    const r = await run(['--stripe-webhooks', '--allow-dirty'], { omit: ['STRIPE_WEBHOOK_SECRET'], extra: { BILLING_ENABLED: 'true', BILLING_TRIAL_DAYS: '14' } });
    assert.equal(r.code, 0, r.out);
    const s = api.state;
    assert.equal(s.endpoints.size, 2);
    const all = [...s.endpoints.values()];
    const connect = all.find((e) => e.metadata.detail_crm_role === 'connect');
    const billing = all.find((e) => e.metadata.detail_crm_role === 'billing');
    assert.ok(connect && billing, JSON.stringify(all.map((e) => e.metadata)));
    assert.equal(connect.connect, true);
    // a PLATFORM endpoint ("Events on your account"): never connect=true
    assert.equal(billing.connect, false);
    assert.equal(billing.url, `https://${REF}.supabase.co/functions/v1/billing-webhook`);
    assert.equal(billing.api_version, STRIPE_VERSION);
    assert.deepEqual([...billing.enabled_events].sort(), [...BILLING_EVENTS].sort());
    assert.equal(s.secrets.get('STRIPE_BILLING_WEBHOOK_SECRET'), billing.secret);
    assert.equal(s.secrets.get('STRIPE_WEBHOOK_SECRET'), connect.secret);
    assert.notEqual(billing.secret, connect.secret);

    assert.deepEqual(s.billingConfigCalls, [{ enabled: true, trialDays: 14 }]);
    assert.equal(s.billingConfig.get('billing_enabled'), 'true');
    assert.equal(s.syncCalls.length, 1);
    assert.equal(s.syncCalls[0].secretOk, true);
    assert.deepEqual(s.syncCalls[0].body, { action: 'sync_plans' });
    assert.match(r.out, /billing: ON, trial 14 day\(s\) \(set_billing_config\)/);
    assert.match(r.out, /billing plans synced from Stripe: 2 active price\(s\), 0 deactivated/);
    // the sync runs after the functions are deployed (and read back)
    const paths = r.requests.map((q) => `${q.method} ${q.path.replace(REF, '<ref>')}`);
    assert.ok(paths.lastIndexOf('GET /v1/projects/<ref>/functions') < paths.indexOf('POST /functions/v1/billing'), paths.join('\n'));
    assertNoSecretLeak(r.out, 'output');
    assertNoSecretLeak(cliLog().join('\n'), 'CLI argv');

    // re-run: nothing new in Stripe, no secret writes, the same config, a (harmless) resync
    const creates = s.endpointCreates;
    const again = await run(['--stripe-webhooks', '--allow-dirty'], { omit: ['STRIPE_WEBHOOK_SECRET'], extra: { BILLING_ENABLED: 'true', BILLING_TRIAL_DAYS: '14' } });
    assert.equal(again.code, 0, again.out);
    assert.equal(s.endpointCreates, creates);
    assert.equal(s.endpoints.size, 2);
    assert.equal((again.out.match(/is up to date \(\d+ events/g) ?? []).length, 2, again.out);
    assert.deepEqual(again.requests.filter((q) => q.method === 'POST' && q.path.endsWith('/secrets')), []);
    assert.deepEqual(s.billingConfigCalls.at(-1), { enabled: true, trialDays: 14 });
    assert.equal(s.syncCalls.length, 2);

    // billing turned off later: the endpoint is left for existing subscriptions, no sync
    const off = await run(['--stripe-webhooks', '--allow-dirty'], { omit: ['STRIPE_WEBHOOK_SECRET'], extra: { BILLING_ENABLED: 'false', BILLING_TRIAL_DAYS: '14' } });
    assert.equal(off.code, 0, off.out);
    assert.match(off.out, /Platform billing endpoint: we_fake[0-9a-f]+ left as it is/);
    assert.equal(s.endpoints.size, 2);
    assert.deepEqual(s.billingConfigCalls.at(-1), { enabled: false, trialDays: 14 });
    assert.equal(s.syncCalls.length, 2);
  });

  test('an unset BILLING_ENABLED / BILLING_TRIAL_DAYS never silently changes a project that has billing set up', async () => {
    await freshApi();
    api.state.billingConfig.set('billing_enabled', 'true');
    api.state.billingConfig.set('billing_trial_days', '14');
    const r = await run(['--allow-dirty'], { extra: { STRIPE_BILLING_WEBHOOK_SECRET: 'whsec_FAKEbilling0123' } });
    assert.equal(r.code, 1, r.out);
    assert.match(r.out, /BILLING_ENABLED is not set, but billing is ON in this project/);
    assert.deepEqual(api.state.billingConfigCalls, []);
    assert.ok(!api.state.sql.some((q) => q.includes('cron.schedule')), 'nothing changed before the refusal');

    const days = await run(['--allow-dirty'], { extra: { BILLING_ENABLED: 'true', STRIPE_BILLING_WEBHOOK_SECRET: 'whsec_FAKEbilling0123' } });
    assert.equal(days.code, 1, days.out);
    assert.match(days.out, /BILLING_TRIAL_DAYS is not set, but this project has a 14-day trial/);
    assert.deepEqual(api.state.billingConfigCalls, []);
  });

  test('a failed plan sync fails the platform setup with the function\'s own error code', async () => {
    await freshApi();
    api.state.syncResponse = { status: 503, body: { error: 'The payment provider is unavailable.', code: 'service_unavailable', request_id: 'r' } };
    const r = await run(['--allow-dirty'], { extra: { BILLING_ENABLED: 'true', STRIPE_BILLING_WEBHOOK_SECRET: 'whsec_FAKEbilling0123' } });
    assert.equal(r.code, 1, r.out);
    assert.match(r.out, /billing sync_plans: HTTP 503 service_unavailable/);
    assert.ok(!r.out.includes('whsec_FAKEbilling0123'));
  });

  test('the script source never runs config push and guards the CLI', () => {
    const src = readFileSync(SCRIPT, 'utf8');
    const code = src.split('\n').filter((l) => !/^\s*#/.test(l)).join('\n');
    assert.ok(!/\bsb\s+config\b|supabase\s+config\s+push/.test(code.replace(/die "refusing[^\n]*/g, '')));
    assert.match(code, /"config "\*/);
  });
});
