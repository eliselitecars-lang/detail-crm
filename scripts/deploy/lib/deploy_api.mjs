#!/usr/bin/env node
// HTTP side of scripts/deploy/deploy_backend.sh: Supabase Management API
// (project check, function secrets, Auth config, SQL, deployed functions)
// and the Stripe API (Connect webhook endpoint). Values come ONLY from the
// environment and never appear in argv, files or output: every line printed
// goes through redact(), which masks every secret value it knows.
//
// Usage: node scripts/deploy/lib/deploy_api.mjs <command> [--dry-run] [options]
//   validate        [--stripe-webhooks]          env check: missing / invalid inputs (exit 2)
//   preflight                                    project exists + token works
//   functions-plan  --supabase-dir DIR           "<name> <verify_jwt>" lines for the shell
//   secrets         [--dry-run] [--stripe-webhooks]
//   stripe-webhook  [--dry-run] --supabase-dir DIR
//   auth            [--dry-run]
//   platform-setup  [--dry-run] --cron-sql FILE
//   check-functions [--dry-run] --supabase-dir DIR
//
// Env: SUPABASE_ACCESS_TOKEN, SUPABASE_PROJECT_REF, the function secrets
// (lib/config.mjs SECRET_SPECS), optional AUTH_* knobs, and for tests
// DEPLOY_SUPABASE_API_BASE / DEPLOY_STRIPE_API_BASE (default: the real APIs).
import { randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import {
  buildAuthConfig,
  DeployConfigError,
  diffAuthConfig,
  functionsBaseUrl,
  functionsPlan,
  planSecrets,
  readStripeFacts,
  renderCronSql,
  SECRET_SPECS,
  validateDeployEnv,
} from './config.mjs';

const env = process.env;
const SUPABASE_API = (env.DEPLOY_SUPABASE_API_BASE || 'https://api.supabase.com').replace(/\/+$/, '');
const STRIPE_API = (env.DEPLOY_STRIPE_API_BASE || 'https://api.stripe.com').replace(/\/+$/, '');
const USER_AGENT = 'detail-crm-deploy/1 (+scripts/deploy)';
const REF = env.SUPABASE_PROJECT_REF?.trim();

// ------------------------------------------------------------- output
const SECRET_ENV_NAMES = [
  'SUPABASE_ACCESS_TOKEN',
  'SUPABASE_DB_PASSWORD',
  'SUPABASE_SERVICE_ROLE_KEY',
  ...SECRET_SPECS.map((s) => s.name).filter((n) => !['APP_BASE_URL', 'EMAIL_FROM', 'PLATFORM_FEE_BPS', 'CORS_ALLOWED_ORIGINS', 'FUNCTIONS_PUBLIC_URL', 'STRIPE_PUBLISHABLE_KEY'].includes(n)),
];
const extraSecrets = new Set();
export function redact(text) {
  let out = String(text);
  const values = [...SECRET_ENV_NAMES.map((n) => env[n]?.trim()), ...extraSecrets].filter((v) => v && v.length >= 6);
  for (const v of values.sort((a, b) => b.length - a.length)) out = out.split(v).join('***');
  return out;
}
const say = (msg) => process.stdout.write(`${redact(msg)}\n`);
const warn = (msg) => process.stderr.write(`WARN  ${redact(msg)}\n`);
class Fail extends Error {}
const fail = (msg) => {
  throw new Fail(msg);
};

// --------------------------------------------------------------- args
const argv = process.argv.slice(2);
const command = argv[0];
const flags = new Set(argv.filter((a) => a.startsWith('--') && !a.includes('=')));
function opt(name) {
  const i = argv.indexOf(name);
  if (i === -1) return undefined;
  const v = argv[i + 1];
  if (!v || v.startsWith('--')) fail(`${name} needs a value`);
  return v;
}
const DRY = flags.has('--dry-run');
const STRIPE_WEBHOOKS = flags.has('--stripe-webhooks');

// --------------------------------------------------------------- HTTP
async function request(base, method, path, { headers = {}, body, form, retries = 2, label } = {}) {
  const url = `${base}${path}`;
  let attempt = 0;
  for (;;) {
    attempt++;
    let res;
    let text;
    try {
      res = await fetch(url, {
        method,
        headers: {
          'user-agent': USER_AGENT,
          accept: 'application/json',
          ...(body !== undefined ? { 'content-type': 'application/json' } : {}),
          ...(form !== undefined ? { 'content-type': 'application/x-www-form-urlencoded' } : {}),
          ...headers,
        },
        body: body !== undefined ? JSON.stringify(body) : form,
        signal: AbortSignal.timeout(60_000),
      });
      text = await res.text();
    } catch (err) {
      if (attempt <= retries) {
        await new Promise((r) => setTimeout(r, 1000 * attempt));
        continue;
      }
      fail(`${label ?? `${method} ${path}`}: network error: ${err.message}`);
    }
    if ((res.status === 429 || res.status >= 500) && attempt <= retries) {
      await new Promise((r) => setTimeout(r, 1500 * attempt));
      continue;
    }
    let json;
    try {
      json = text ? JSON.parse(text) : null;
    } catch {
      json = undefined;
    }
    return { status: res.status, json, text };
  }
}

function mgmt(method, path, opts = {}) {
  return request(SUPABASE_API, method, path, {
    ...opts,
    headers: { authorization: `Bearer ${env.SUPABASE_ACCESS_TOKEN}`, ...(opts.headers ?? {}) },
  });
}
function expectOk(res, what) {
  if (res.status >= 200 && res.status < 300) return res.json;
  const hint =
    res.status === 401 ? ' (SUPABASE_ACCESS_TOKEN is invalid or expired)' : res.status === 403 ? ' (the token has no access to this project)' : res.status === 404 ? ' (project ref not found?)' : '';
  fail(`${what}: HTTP ${res.status}${hint}: ${String(res.text ?? '').slice(0, 300)}`);
}

function stripeForm(params) {
  const parts = [];
  for (const [k, v] of Object.entries(params)) {
    if (Array.isArray(v)) for (const item of v) parts.push(`${encodeURIComponent(`${k}[]`)}=${encodeURIComponent(item)}`);
    else if (v && typeof v === 'object') for (const [sk, sv] of Object.entries(v)) parts.push(`${encodeURIComponent(`${k}[${sk}]`)}=${encodeURIComponent(sv)}`);
    else parts.push(`${encodeURIComponent(k)}=${encodeURIComponent(String(v))}`);
  }
  return parts.join('&');
}
function stripe(method, path, { form, apiVersion, idempotent } = {}) {
  return request(STRIPE_API, method, path, {
    form,
    headers: {
      authorization: `Bearer ${env.STRIPE_SECRET_KEY}`,
      ...(apiVersion ? { 'stripe-version': apiVersion } : {}),
      ...(idempotent ? { 'idempotency-key': idempotent } : {}),
    },
  });
}

// ------------------------------------------------------------ commands
function requireRef() {
  if (!REF) fail('SUPABASE_PROJECT_REF is not set');
  if (!env.SUPABASE_ACCESS_TOKEN) fail('SUPABASE_ACCESS_TOKEN is not set');
}

function cmdValidate() {
  const result = validateDeployEnv(env, { stripeWebhooks: STRIPE_WEBHOOKS, requireLiveStripe: env.REQUIRE_LIVE_STRIPE === '1' });
  for (const w of result.warnings) warn(w);
  try {
    buildAuthConfig({ ...env, APP_BASE_URL: result.secrets.APP_BASE_URL ?? env.APP_BASE_URL });
  } catch (err) {
    if (result.secrets.APP_BASE_URL && result.secrets.EMAIL_FROM && result.secrets.RESEND_API_KEY) {
      result.invalid.push({ name: 'AUTH_*', problem: err.message });
    }
  }
  if (result.missing.length || result.invalid.length) {
    if (result.missing.length) {
      say('Missing required inputs (set them as environment variables / GitHub secrets):');
      for (const m of result.missing) say(`  - ${m.name}: ${m.where}`);
    }
    if (result.invalid.length) {
      say('Invalid inputs:');
      for (const i of result.invalid) say(`  - ${i.name}: ${i.problem}`);
    }
    process.exitCode = 2;
    return;
  }
  say(`inputs OK: ${Object.keys(result.secrets).length} function secrets validated${STRIPE_WEBHOOKS && !result.secrets.STRIPE_WEBHOOK_SECRET ? ' (STRIPE_WEBHOOK_SECRET will come from --stripe-webhooks)' : ''}`);
}

async function cmdPreflight() {
  requireRef();
  const res = await mgmt('GET', `/v1/projects/${REF}`, { label: 'project lookup' });
  const p = expectOk(res, 'Management API project lookup');
  say(`project ${p?.id ?? REF}: name="${p?.name ?? '?'}" region=${p?.region ?? '?'} status=${p?.status ?? '?'}`);
  if (p?.status && !/ACTIVE_HEALTHY/.test(p.status)) warn(`project status is ${p.status}; the deploy may fail until it is ACTIVE_HEALTHY`);
}

function cmdFunctionsPlan() {
  const dir = opt('--supabase-dir') ?? fail('--supabase-dir is required');
  for (const f of functionsPlan(dir)) say(`${f.name} ${f.verifyJwt}`);
}

async function listSecrets() {
  return expectOk(await mgmt('GET', `/v1/projects/${REF}/secrets`, { label: 'list secrets' }), 'list function secrets') ?? [];
}

async function cmdSecrets() {
  requireRef();
  const { secrets, missing, invalid } = validateDeployEnv(env, { stripeWebhooks: STRIPE_WEBHOOKS });
  if (missing.length || invalid.length) fail('inputs are missing or invalid: run the validate step first');
  const remote = await listSecrets();
  const { plan, harness } = planSecrets(secrets, remote);
  for (const p of plan) say(`  ${p.action.padEnd(9)} ${p.name}`);
  for (const name of harness) say(`  remove    ${name} (local-harness override: production must call the real provider)`);
  const changed = plan.filter((p) => p.action !== 'unchanged');
  if (DRY) {
    say(`dry run: would set ${changed.length} secret(s), remove ${harness.length}; ${plan.length - changed.length} unchanged`);
    return;
  }
  if (changed.length) {
    const res = await mgmt('POST', `/v1/projects/${REF}/secrets`, {
      body: changed.map((p) => ({ name: p.name, value: p.value })),
      label: 'set secrets',
    });
    expectOk(res, 'set function secrets');
  }
  if (harness.length) {
    expectOk(await mgmt('DELETE', `/v1/projects/${REF}/secrets`, { body: harness, label: 'delete secrets' }), 'remove harness-only secrets');
  }
  // Read back: every desired name must now exist.
  const after = new Set((await listSecrets()).map((s) => s.name));
  const absent = Object.keys(secrets).filter((n) => !after.has(n));
  if (absent.length) fail(`secrets not present after update: ${absent.join(', ')}`);
  say(`secrets: ${changed.length} set, ${harness.length} removed, ${plan.length - changed.length} unchanged`);
}

const WEBHOOK_ROLE_KEY = 'detail_crm_role';
const WEBHOOK_ROLE = 'connect';

async function listWebhookEndpoints(apiVersion) {
  const all = [];
  let after;
  for (let page = 0; page < 20; page++) {
    const q = `?limit=100${after ? `&starting_after=${encodeURIComponent(after)}` : ''}`;
    const res = await stripe('GET', `/v1/webhook_endpoints${q}`, { apiVersion });
    if (res.status === 401) fail('Stripe rejected STRIPE_SECRET_KEY (401)');
    if (res.status === 403) fail('STRIPE_SECRET_KEY may not manage webhook endpoints (403): use the secret key or give the restricted key "Webhook Endpoints: write"');
    if (res.status !== 200) fail(`Stripe list webhook endpoints: HTTP ${res.status}: ${String(res.text).slice(0, 300)}`);
    all.push(...(res.json?.data ?? []));
    if (!res.json?.has_more || !res.json.data?.length) break;
    after = res.json.data[res.json.data.length - 1].id;
  }
  return all;
}

async function cmdStripeWebhook() {
  requireRef();
  if (!env.STRIPE_SECRET_KEY) fail('STRIPE_SECRET_KEY is required for --stripe-webhooks');
  const dir = opt('--supabase-dir') ?? fail('--supabase-dir is required');
  const { events, apiVersion } = readStripeFacts(dir);
  const url = `${functionsBaseUrl(env)}/stripe-webhook`;
  const wanted = [...events].sort();
  say(`Connect endpoint: ${url} (api_version ${apiVersion}, ${wanted.length} events from HANDLED_EVENT_TYPES)`);
  say('No platform (non-Connect) endpoint is managed: every handler acts on connected-account events only, and the function verifies a single signing secret (STRIPE_WEBHOOK_SECRET).');

  const endpoints = await listWebhookEndpoints(apiVersion);
  const adopt = env.STRIPE_WEBHOOK_ADOPT?.trim();
  let ours = endpoints.filter((e) => e.metadata?.[WEBHOOK_ROLE_KEY] === WEBHOOK_ROLE && e.url === url);
  const foreign = endpoints.filter((e) => e.url === url && !ours.includes(e));
  if (adopt) {
    const target = foreign.find((e) => e.id === adopt);
    if (!target) fail(`STRIPE_WEBHOOK_ADOPT=${adopt}: no untagged endpoint with that id at ${url}`);
    ours = [target];
    say(`adopting ${adopt} as the Connect endpoint (you confirmed it listens to "Events on Connected accounts")`);
  } else if (foreign.length) {
    fail(
      `${foreign.length} Stripe endpoint(s) at ${url} were not created by this script (${foreign.map((e) => e.id).join(', ')}). ` +
        'Stripe does not report whether an endpoint is a Connect endpoint, so it is not touched. Either delete it in the Dashboard and re-run with ' +
        '--stripe-webhooks, set STRIPE_WEBHOOK_ADOPT=<we_id> if it IS the Connect endpoint whose secret is STRIPE_WEBHOOK_SECRET, or manage it by hand ' +
        '(run without --stripe-webhooks).',
    );
  }
  const otherTagged = endpoints.filter((e) => e.metadata?.[WEBHOOK_ROLE_KEY] === WEBHOOK_ROLE && e.url !== url);
  for (const e of otherTagged) warn(`endpoint ${e.id} is tagged ${WEBHOOK_ROLE_KEY}=${WEBHOOK_ROLE} but points at ${e.url} (another project?): left alone`);
  if (ours.length > 1) fail(`more than one tagged Connect endpoint at ${url} (${ours.map((e) => e.id).join(', ')}): delete the extras in the Dashboard`);

  const recreate = env.STRIPE_WEBHOOK_RECREATE === '1';
  const createParams = {
    url,
    connect: 'true',
    api_version: apiVersion,
    enabled_events: wanted,
    description: 'Detail CRM Connect webhook (managed by scripts/deploy)',
    metadata: { [WEBHOOK_ROLE_KEY]: WEBHOOK_ROLE },
  };
  const remoteSecrets = new Set((await listSecrets()).map((s) => s.name));

  async function create() {
    const res = await stripe('POST', '/v1/webhook_endpoints', { form: stripeForm(createParams), apiVersion, idempotent: randomUUID() });
    if (res.status !== 200 || !res.json?.secret) fail(`Stripe create webhook endpoint: HTTP ${res.status}: ${String(res.text).slice(0, 300)}`);
    extraSecrets.add(res.json.secret);
    expectOk(
      await mgmt('POST', `/v1/projects/${REF}/secrets`, { body: [{ name: 'STRIPE_WEBHOOK_SECRET', value: res.json.secret }], label: 'store webhook secret' }),
      'store STRIPE_WEBHOOK_SECRET',
    );
    if (env.STRIPE_WEBHOOK_SECRET) warn('STRIPE_WEBHOOK_SECRET from the environment was replaced by the new endpoint\'s signing secret');
    say(`created ${res.json.id} and stored its signing secret as STRIPE_WEBHOOK_SECRET`);
  }

  if (ours.length === 0) {
    if (DRY) return say('dry run: would create the Connect endpoint and store its signing secret as STRIPE_WEBHOOK_SECRET');
    return create();
  }
  const e = ours[0];
  const have = [...(e.enabled_events ?? [])].sort();
  const eventsDiffer = have.join(',') !== wanted.join(',');
  const versionDiffers = e.api_version && e.api_version !== apiVersion;
  if (versionDiffers && !recreate) {
    warn(`endpoint ${e.id} uses api_version ${e.api_version} but the functions pin ${apiVersion}; Stripe cannot change it in place. Re-run with STRIPE_WEBHOOK_RECREATE=1 to replace it (a new signing secret is stored automatically).`);
  }
  if (recreate) {
    if (DRY) return say(`dry run: would delete ${e.id} and create a new Connect endpoint (STRIPE_WEBHOOK_RECREATE=1)`);
    const del = await stripe('DELETE', `/v1/webhook_endpoints/${e.id}`, { apiVersion });
    if (del.status !== 200) fail(`Stripe delete ${e.id}: HTTP ${del.status}`);
    say(`deleted ${e.id} (STRIPE_WEBHOOK_RECREATE=1)`);
    return create();
  }
  if (!remoteSecrets.has('STRIPE_WEBHOOK_SECRET')) {
    fail(
      `endpoint ${e.id} exists but STRIPE_WEBHOOK_SECRET is not stored in the project. Stripe reveals a signing secret only when the endpoint is created: ` +
        'copy it from Dashboard -> Developers -> Webhooks -> the endpoint -> Signing secret into STRIPE_WEBHOOK_SECRET, or re-run with STRIPE_WEBHOOK_RECREATE=1.',
    );
  }
  const needsUpdate = eventsDiffer || e.status === 'disabled' || e.metadata?.[WEBHOOK_ROLE_KEY] !== WEBHOOK_ROLE;
  if (!needsUpdate) return say(`${e.id} is up to date (${have.length} events, status ${e.status ?? 'enabled'})`);
  if (DRY) return say(`dry run: would update ${e.id} (events ${eventsDiffer ? 'changed' : 'same'}, status ${e.status})`);
  const upd = await stripe('POST', `/v1/webhook_endpoints/${e.id}`, {
    form: stripeForm({ enabled_events: wanted, disabled: 'false', description: createParams.description, metadata: createParams.metadata }),
    apiVersion,
  });
  if (upd.status !== 200) fail(`Stripe update ${e.id}: HTTP ${upd.status}: ${String(upd.text).slice(0, 300)}`);
  say(`updated ${e.id}: ${wanted.length} events, enabled`);
}

async function cmdAuth() {
  requireRef();
  const { body, redacted } = buildAuthConfig(env);
  const current = expectOk(await mgmt('GET', `/v1/projects/${REF}/config/auth`, { label: 'read auth config' }), 'read Auth config');
  const changes = diffAuthConfig(body, current ?? {});
  say(`Auth: site_url=${redacted.site_url} redirects=${redacted.uri_allow_list.split(',').length} smtp=${redacted.smtp_host}:${redacted.smtp_port} sender="${redacted.smtp_sender_name} <${redacted.smtp_admin_email}>" confirmations=ON`);
  say(`Auth: ${changes.length ? `will change ${changes.join(', ')}` : 'no differences'} (+ smtp_pass is always re-sent)`);
  if (DRY) return say('dry run: Auth config not changed');
  expectOk(await mgmt('PATCH', `/v1/projects/${REF}/config/auth`, { body, label: 'update auth config' }), 'update Auth config');
  const after = expectOk(await mgmt('GET', `/v1/projects/${REF}/config/auth`, { label: 'read auth config' }), 'read Auth config back');
  const still = diffAuthConfig(body, after ?? {});
  if (still.length) fail(`Auth config did not take these values: ${still.join(', ')}`);
  say('Auth config applied and read back');
}

async function runSql(query, label) {
  const res = await mgmt('POST', `/v1/projects/${REF}/database/query`, { body: { query }, label });
  return expectOk(res, label);
}

function cronJobNames(template) {
  return [...template.matchAll(/cron\.schedule\(\s*'([^']+)'/g)].map((m) => m[1]).sort();
}

async function cmdPlatformSetup() {
  requireRef();
  const file = opt('--cron-sql') ?? fail('--cron-sql is required');
  const template = readFileSync(file, 'utf8');
  const { secrets } = validateDeployEnv(env, { stripeWebhooks: true });
  if (!secrets.APP_BASE_URL || !secrets.CRON_SECRET) fail('APP_BASE_URL and CRON_SECRET are required for the platform setup');
  const functionsUrl = functionsBaseUrl(env);
  const sql = renderCronSql(template, { functionsUrl, cronSecret: secrets.CRON_SECRET, appBaseUrl: secrets.APP_BASE_URL });
  const jobs = cronJobNames(template);
  say(`platform setup (supabase/setup/cron.sql, rendered in memory): app_base_url=${secrets.APP_BASE_URL} functions=${functionsUrl}`);
  say(`  jobs: ${jobs.join(', ')}`);
  if (DRY) return say('dry run: cron.sql not executed');
  await runSql(sql, 'run cron.sql');
  // Verify what the script is supposed to leave behind.
  const cfg = await runSql("select value from public.platform_config where key = 'app_base_url'", 'read platform_config');
  const value = Array.isArray(cfg) ? cfg[0]?.value : undefined;
  if (value !== secrets.APP_BASE_URL) fail(`platform_config.app_base_url is ${JSON.stringify(value)}, expected ${secrets.APP_BASE_URL}`);
  const rows = await runSql("select jobname, active from cron.job where jobname like 'detail-crm-%' order by jobname", 'read cron jobs');
  const active = (Array.isArray(rows) ? rows : []).filter((r) => r.active !== false).map((r) => r.jobname).sort();
  const missingJobs = jobs.filter((j) => !active.includes(j));
  if (missingJobs.length) fail(`cron jobs missing or inactive after setup: ${missingJobs.join(', ')}`);
  const vault = await runSql("select name from vault.secrets where name in ('detail_crm_functions_url', 'detail_crm_cron_secret') order by name", 'read vault names');
  if ((Array.isArray(vault) ? vault : []).length !== 2) fail('Vault secrets detail_crm_functions_url / detail_crm_cron_secret were not created');
  say(`platform setup applied: app_base_url set, ${jobs.length} cron jobs active, Vault secrets present`);
}

async function cmdCheckFunctions() {
  requireRef();
  const dir = opt('--supabase-dir') ?? fail('--supabase-dir is required');
  const plan = functionsPlan(dir);
  const deployed = expectOk(await mgmt('GET', `/v1/projects/${REF}/functions`, { label: 'list functions' }), 'list deployed functions') ?? [];
  const bySlug = new Map(deployed.map((f) => [f.slug, f]));
  const problems = [];
  for (const f of plan) {
    const d = bySlug.get(f.name);
    if (!d) {
      problems.push(`${f.name}: not deployed`);
      say(`  ${f.name.padEnd(16)} verify_jwt want=${f.verifyJwt} deployed=-`);
      continue;
    }
    say(`  ${f.name.padEnd(16)} verify_jwt want=${f.verifyJwt} deployed=${d.verify_jwt} status=${d.status ?? '?'} version=${d.version ?? '?'}`);
    if (d.verify_jwt !== f.verifyJwt) problems.push(`${f.name}: verify_jwt is ${d.verify_jwt}, config.toml says ${f.verifyJwt}`);
    if (d.status && d.status !== 'ACTIVE') problems.push(`${f.name}: status ${d.status}`);
  }
  const extra = deployed.map((d) => d.slug).filter((s) => !plan.some((f) => f.name === s));
  if (extra.length) warn(`functions deployed but not in this repo (left alone): ${extra.join(', ')}`);
  if (problems.length) {
    if (DRY) return say(`dry run: current state differs (${problems.join('; ')}) - the deploy step fixes this`);
    fail(`deployed functions do not match config.toml: ${problems.join('; ')}`);
  }
  say('deployed functions match config.toml');
}

const COMMANDS = {
  validate: cmdValidate,
  preflight: cmdPreflight,
  'functions-plan': cmdFunctionsPlan,
  secrets: cmdSecrets,
  'stripe-webhook': cmdStripeWebhook,
  auth: cmdAuth,
  'platform-setup': cmdPlatformSetup,
  'check-functions': cmdCheckFunctions,
};

const handler = COMMANDS[command];
if (!handler) {
  process.stderr.write(`usage: deploy_api.mjs <${Object.keys(COMMANDS).join('|')}> [--dry-run]\n`);
  process.exit(64);
}
try {
  await handler();
} catch (err) {
  if (err instanceof Fail || err instanceof DeployConfigError) {
    process.stderr.write(`ERROR ${redact(err.message)}\n`);
    process.exit(1);
  }
  process.stderr.write(`ERROR ${redact(err?.stack ?? err)}\n`);
  process.exit(1);
}
