#!/usr/bin/env node
// HTTP side of scripts/deploy/deploy_backend.sh: Supabase Management API
// (project check, function secrets, Auth config, SQL, deployed functions),
// the Stripe API (the Connect webhook endpoint and, with BILLING_ENABLED=true,
// the platform billing endpoint) and one call of the deployed `billing`
// function (sync_plans). Values come ONLY from the environment and never
// appear in argv, files or output: every line printed goes through redact(),
// which masks every secret value it knows.
//
// Usage: node scripts/deploy/lib/deploy_api.mjs <command> [--dry-run] [options]
//   validate        [--stripe-webhooks]          env check: missing / invalid inputs (exit 2)
//   preflight       [--stripe-webhooks]          project exists + token works + the webhook
//                                                secrets that are not inputs are stored there
//   functions-plan  --supabase-dir DIR           "<name> <verify_jwt>" lines for the shell
//   secrets         [--dry-run] [--stripe-webhooks]  set / update, remove unset optional ones
//   stripe-webhook  [--dry-run] --supabase-dir DIR
//   auth            [--dry-run]
//   platform-setup  [--dry-run] --cron-sql FILE
//   check-functions [--dry-run] --supabase-dir DIR
//
// Env: SUPABASE_ACCESS_TOKEN, SUPABASE_PROJECT_REF, the function secrets
// (lib/config.mjs SECRET_SPECS), BILLING_ENABLED / BILLING_TRIAL_DAYS
// (lib/config.mjs BILLING_INPUTS), optional AUTH_* knobs, the one-shot
// --stripe-webhooks knobs (lib/config.mjs WEBHOOK_KNOBS), and for tests
// DEPLOY_SUPABASE_API_BASE / DEPLOY_STRIPE_API_BASE / DEPLOY_FUNCTIONS_API_BASE
// (default: the real APIs and the project's functions URL).
import { randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import {
  billingConfig,
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
  WEBHOOK_KNOBS,
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
  ...SECRET_SPECS.map((s) => s.name).filter((n) => !['APP_BASE_URL', 'EMAIL_FROM', 'PLATFORM_FEE_BPS', 'CORS_ALLOWED_ORIGINS', 'FUNCTIONS_PUBLIC_URL', 'STRIPE_PUBLISHABLE_KEY', 'BILLING_AUTOMATIC_TAX'].includes(n)),
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
  for (const d of result.deferred) say(`${d.name}: not an input; the project must already hold it (checked in the next step)`);
  const billing = billingConfig(env);
  say(
    billing.enabled
      ? `billing: ON, trial ${billing.trialDays} day(s)${STRIPE_WEBHOOKS && !result.secrets.STRIPE_BILLING_WEBHOOK_SECRET ? ' (STRIPE_BILLING_WEBHOOK_SECRET will come from --stripe-webhooks)' : ''}`
      : `billing: off${billing.enabledSet ? '' : ' (BILLING_ENABLED unset)'}`,
  );
}

async function cmdPreflight() {
  requireRef();
  const res = await mgmt('GET', `/v1/projects/${REF}`, { label: 'project lookup' });
  const p = expectOk(res, 'Management API project lookup');
  say(`project ${p?.id ?? REF}: name="${p?.name ?? '?'}" region=${p?.region ?? '?'} status=${p?.status ?? '?'}`);
  if (p?.status && !/ACTIVE_HEALTHY/.test(p.status)) warn(`project status is ${p.status}; the deploy may fail until it is ACTIVE_HEALTHY`);
  // Webhook signing secrets that are not inputs: an earlier deploy (with
  // --stripe-webhooks, or by hand) must have stored them. Checked here,
  // before anything in the project changes.
  const { deferred } = validateDeployEnv(env, { stripeWebhooks: STRIPE_WEBHOOKS });
  if (!deferred.length) return;
  const stored = new Set((await listSecrets()).map((s) => s.name));
  const absent = deferred.filter((d) => !stored.has(d.name));
  for (const d of deferred.filter((x) => stored.has(x.name))) say(`${d.name}: kept as stored in the project (not an input)`);
  if (absent.length) {
    fail(
      `${absent.map((d) => d.name).join(' and ')} ${absent.length === 1 ? 'is' : 'are'} neither an input nor stored in the project. ` +
        'Run the deploy with --stripe-webhooks (workflow: check stripe_webhooks): it creates the endpoint and stores its signing secret. ' +
        'Or set the endpoint\'s signing secret (Stripe Dashboard -> Developers -> Webhooks -> the endpoint -> Signing secret) as that input.',
    );
  }
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
  const remote = await listSecrets();
  const { secrets, missing, invalid } = validateDeployEnv(env, {
    stripeWebhooks: STRIPE_WEBHOOKS,
    storedSecrets: new Set(remote.map((s) => s.name)),
  });
  if (missing.length || invalid.length) fail('inputs are missing or invalid: run the validate and preflight steps first');
  const { plan, unset, harness } = planSecrets(secrets, remote);
  for (const p of plan) say(`  ${p.action.padEnd(9)} ${p.name}`);
  for (const name of unset) say(`  remove    ${name} (unset in this deploy's inputs: off / the default)`);
  for (const name of harness) say(`  remove    ${name} (local-harness override: production must call the real provider)`);
  const changed = plan.filter((p) => p.action !== 'unchanged');
  const removed = [...unset, ...harness];
  if (unset.length) {
    warn(
      `${unset.join(', ')} ${unset.length === 1 ? 'is' : 'are'} set in the project but not in this deploy's inputs, so ${DRY ? 'the deploy would remove' : 'this deploy removes'} ` +
        `${unset.length === 1 ? 'it' : 'them'} (unset = off). To keep a value, set it as a GitHub variable/secret (local run: export it).`,
    );
  }
  if (DRY) {
    say(`dry run: would set ${changed.length} secret(s), remove ${removed.length}; ${plan.length - changed.length} unchanged`);
    return;
  }
  if (changed.length) {
    const res = await mgmt('POST', `/v1/projects/${REF}/secrets`, {
      body: changed.map((p) => ({ name: p.name, value: p.value })),
      label: 'set secrets',
    });
    expectOk(res, 'set function secrets');
  }
  if (removed.length) {
    expectOk(await mgmt('DELETE', `/v1/projects/${REF}/secrets`, { body: removed, label: 'delete secrets' }), 'remove function secrets');
  }
  // Read back: every desired name must now exist, every removed one be gone.
  const after = new Set((await listSecrets()).map((s) => s.name));
  const absent = Object.keys(secrets).filter((n) => !after.has(n));
  if (absent.length) fail(`secrets not present after update: ${absent.join(', ')}`);
  const left = removed.filter((n) => after.has(n));
  if (left.length) fail(`secrets still present after removal: ${left.join(', ')}`);
  say(`secrets: ${changed.length} set, ${removed.length} removed, ${plan.length - changed.length} unchanged`);
}

const WEBHOOK_ROLE_KEY = 'detail_crm_role';

/**
 * The two endpoints the deploy manages, each found again by its metadata tag
 * (detail_crm_role) and URL. They are different endpoints with different
 * signing secrets: shops' own payments arrive on the Connect endpoint,
 * the platform's subscription billing of shops on the billing endpoint.
 */
const ENDPOINTS = {
  connect: {
    role: 'connect',
    label: 'Connect',
    fn: 'stripe-webhook',
    connect: true,
    kind: '"Events on Connected accounts"',
    secretName: 'STRIPE_WEBHOOK_SECRET',
    adoptVar: 'STRIPE_WEBHOOK_ADOPT',
    recreateVar: 'STRIPE_WEBHOOK_RECREATE',
    description: 'Detail CRM Connect webhook (managed by scripts/deploy)',
  },
  billing: {
    role: 'billing',
    label: 'platform billing',
    fn: 'billing-webhook',
    connect: false,
    kind: '"Events on your account"',
    secretName: 'STRIPE_BILLING_WEBHOOK_SECRET',
    adoptVar: 'STRIPE_BILLING_WEBHOOK_ADOPT',
    recreateVar: 'STRIPE_BILLING_WEBHOOK_RECREATE',
    description: 'Detail CRM platform billing webhook (managed by scripts/deploy)',
  },
};

/** How to set one of the endpoint's knobs: the workflow input, or the local variable. */
function knobHint(spec, kind) {
  const name = kind === 'recreate' ? spec.recreateVar : spec.adoptVar;
  const knob = WEBHOOK_KNOBS.find((k) => k.name === name);
  const local = kind === 'recreate' ? `${name}=1` : `${name}=<we_id>`;
  return `the deploy-backend workflow input ${knob?.input ?? name} with stripe_webhooks (local run: ${local} with --stripe-webhooks)`;
}

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

/**
 * Creates or updates one tagged endpoint and stores its signing secret as
 * `spec.secretName`. Idempotent: an up-to-date endpoint is left alone; an
 * endpoint at the URL that the deploy did not create is never touched.
 */
async function ensureEndpoint(spec, { events, apiVersion, endpoints, remoteSecrets }) {
  const url = `${functionsBaseUrl(env)}/${spec.fn}`;
  const wanted = [...events].sort();
  const Label = spec.label.charAt(0).toUpperCase() + spec.label.slice(1);
  say(`${Label} endpoint: ${url} (api_version ${apiVersion}, ${wanted.length} events from ${spec.fn} HANDLED_EVENT_TYPES)`);

  const adopt = env[spec.adoptVar]?.trim();
  let ours = endpoints.filter((e) => e.metadata?.[WEBHOOK_ROLE_KEY] === spec.role && e.url === url);
  const foreign = endpoints.filter((e) => e.url === url && !ours.includes(e));
  if (adopt) {
    const target = foreign.find((e) => e.id === adopt);
    if (!target) fail(`${spec.adoptVar}=${adopt}: no untagged endpoint with that id at ${url}`);
    ours = [target];
    say(`adopting ${adopt} as the ${spec.label} endpoint (you confirmed it listens to ${spec.kind})`);
  } else if (foreign.length) {
    fail(
      `${foreign.length} Stripe endpoint(s) at ${url} were not created by this script (${foreign.map((e) => e.id).join(', ')}). ` +
        `Stripe does not report whether an endpoint is a Connect endpoint, so it is not touched. Either delete it in the Dashboard and re-run with ` +
        `--stripe-webhooks; or, if it IS the ${spec.label} endpoint (${spec.kind}) whose secret is ${spec.secretName}, adopt it with ${knobHint(spec, 'adopt')}; ` +
        'or manage it by hand (run without --stripe-webhooks).',
    );
  }
  const otherTagged = endpoints.filter((e) => e.metadata?.[WEBHOOK_ROLE_KEY] === spec.role && e.url !== url);
  for (const e of otherTagged) warn(`endpoint ${e.id} is tagged ${WEBHOOK_ROLE_KEY}=${spec.role} but points at ${e.url} (another project?): left alone`);
  if (ours.length > 1) fail(`more than one tagged ${spec.label} endpoint at ${url} (${ours.map((e) => e.id).join(', ')}): delete the extras in the Dashboard`);

  const recreate = env[spec.recreateVar] === '1';
  const createParams = {
    url,
    ...(spec.connect ? { connect: 'true' } : {}),
    api_version: apiVersion,
    enabled_events: wanted,
    description: spec.description,
    metadata: { [WEBHOOK_ROLE_KEY]: spec.role },
  };

  async function create() {
    const res = await stripe('POST', '/v1/webhook_endpoints', { form: stripeForm(createParams), apiVersion, idempotent: randomUUID() });
    if (res.status !== 200 || !res.json?.secret) fail(`Stripe create webhook endpoint: HTTP ${res.status}: ${String(res.text).slice(0, 300)}`);
    extraSecrets.add(res.json.secret);
    expectOk(
      await mgmt('POST', `/v1/projects/${REF}/secrets`, { body: [{ name: spec.secretName, value: res.json.secret }], label: 'store webhook secret' }),
      `store ${spec.secretName}`,
    );
    if (env[spec.secretName]?.trim()) {
      warn(
        `${spec.secretName} from the inputs was replaced in the project by the new endpoint's signing secret. Delete the ${spec.secretName} ` +
          'GitHub secret (local run: unset it) now: the next deploy would put the old value back, and the project keeps the new one without it.',
      );
    }
    say(`created ${res.json.id} and stored its signing secret as ${spec.secretName}`);
  }

  if (ours.length === 0) {
    if (DRY) return say(`dry run: would create the ${spec.label} endpoint and store its signing secret as ${spec.secretName}`);
    return create();
  }
  const e = ours[0];
  const have = [...(e.enabled_events ?? [])].sort();
  const eventsDiffer = have.join(',') !== wanted.join(',');
  const versionDiffers = e.api_version && e.api_version !== apiVersion;
  if (versionDiffers && !recreate) {
    warn(`endpoint ${e.id} uses api_version ${e.api_version} but the functions pin ${apiVersion}; Stripe cannot change it in place. Replace it with ${knobHint(spec, 'recreate')} (a new signing secret is stored automatically).`);
  }
  if (recreate) {
    if (DRY) return say(`dry run: would delete ${e.id} and create a new ${spec.label} endpoint (${spec.recreateVar}=1)`);
    const del = await stripe('DELETE', `/v1/webhook_endpoints/${e.id}`, { apiVersion });
    if (del.status !== 200) fail(`Stripe delete ${e.id}: HTTP ${del.status}`);
    say(`deleted ${e.id} (${spec.recreateVar}=1)`);
    return create();
  }
  if (!remoteSecrets.has(spec.secretName)) {
    fail(
      `endpoint ${e.id} exists but ${spec.secretName} is not stored in the project. Stripe reveals a signing secret only when the endpoint is created: ` +
        `copy it from Dashboard -> Developers -> Webhooks -> the endpoint -> Signing secret into ${spec.secretName}, or replace the endpoint with ${knobHint(spec, 'recreate')}.`,
    );
  }
  const needsUpdate = eventsDiffer || e.status === 'disabled' || e.metadata?.[WEBHOOK_ROLE_KEY] !== spec.role;
  if (!needsUpdate) return say(`${e.id} is up to date (${have.length} events, status ${e.status ?? 'enabled'})`);
  if (DRY) return say(`dry run: would update ${e.id} (events ${eventsDiffer ? 'changed' : 'same'}, status ${e.status})`);
  const upd = await stripe('POST', `/v1/webhook_endpoints/${e.id}`, {
    form: stripeForm({ enabled_events: wanted, disabled: 'false', description: createParams.description, metadata: createParams.metadata }),
    apiVersion,
  });
  if (upd.status !== 200) fail(`Stripe update ${e.id}: HTTP ${upd.status}: ${String(upd.text).slice(0, 300)}`);
  say(`updated ${e.id}: ${wanted.length} events, enabled`);
}

async function cmdStripeWebhook() {
  requireRef();
  if (!env.STRIPE_SECRET_KEY) fail('STRIPE_SECRET_KEY is required for --stripe-webhooks');
  const dir = opt('--supabase-dir') ?? fail('--supabase-dir is required');
  const billing = billingConfig(env);
  const { events, billingEvents, apiVersion } = readStripeFacts(dir);
  const endpoints = await listWebhookEndpoints(apiVersion);
  const remoteSecrets = new Set((await listSecrets()).map((s) => s.name));
  const shared = { apiVersion, endpoints, remoteSecrets };

  await ensureEndpoint(ENDPOINTS.connect, { ...shared, events });
  if (billing.enabled) {
    await ensureEndpoint(ENDPOINTS.billing, { ...shared, events: billingEvents });
    return;
  }
  const billingUrl = `${functionsBaseUrl(env)}/${ENDPOINTS.billing.fn}`;
  const existing = endpoints.filter((e) => e.metadata?.[WEBHOOK_ROLE_KEY] === ENDPOINTS.billing.role && e.url === billingUrl);
  if (existing.length) {
    say(`Platform billing endpoint: ${existing.map((e) => e.id).join(', ')} left as it is (BILLING_ENABLED is not true; existing subscriptions keep syncing)`);
  } else {
    say('Platform billing endpoint: not managed (BILLING_ENABLED is not true)');
  }
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

/** platform_config billing keys: absent = off / no trial (0100 contract). */
async function readBillingConfig() {
  const rows = await runSql(
    "select key, value from public.platform_config where key in ('billing_enabled', 'billing_trial_days') order by key",
    'read billing config',
  );
  const by = new Map((Array.isArray(rows) ? rows : []).map((r) => [r.key, r.value]));
  const days = Number(by.get('billing_trial_days') ?? 0);
  return { enabled: String(by.get('billing_enabled') ?? '').toLowerCase() === 'true', trialDays: Number.isFinite(days) ? days : 0 };
}

/**
 * An unset billing input means "the default" (off / no trial) only for a
 * project that has the default: it never silently turns billing off or
 * drops the trial of a project where they were set (say, a local run
 * without the repository variables).
 */
function billingGuard(billing, current) {
  if (!billing.enabledSet && current.enabled !== billing.enabled) {
    fail('BILLING_ENABLED is not set, but billing is ON in this project. Set BILLING_ENABLED=true to keep it on (or false to turn it off) and re-run.');
  }
  if (!billing.trialDaysSet && current.trialDays !== billing.trialDays) {
    fail(`BILLING_TRIAL_DAYS is not set, but this project has a ${current.trialDays}-day trial. Set BILLING_TRIAL_DAYS=${current.trialDays} to keep it (or 0 for none) and re-run.`);
  }
}

/** Calls the deployed billing function's sync_plans (x-cron-secret) and reports it. */
async function syncBillingPlans(cronSecret) {
  const base = (env.DEPLOY_FUNCTIONS_API_BASE || functionsBaseUrl(env)).replace(/\/+$/, '');
  const res = await request(base, 'POST', '/billing', {
    body: { action: 'sync_plans' },
    headers: { 'x-cron-secret': cronSecret },
    label: 'billing sync_plans',
  });
  const out = res.json;
  if (res.status !== 200 || typeof out?.upserted !== 'number') {
    fail(`billing sync_plans: HTTP ${res.status}${out?.code ? ` ${out.code}` : ''}: ${String(out?.error ?? res.text ?? '').slice(0, 300)}`);
  }
  say(`billing plans synced from Stripe: ${out.upserted} active price(s), ${out.deactivated ?? 0} deactivated`);
  for (const x of out.skipped ?? []) warn(`plan price ${x.price_id ?? '-'} of ${x.product_id} not synced: ${x.reason}`);
  for (const x of out.warnings ?? []) warn(`plan ${x.product_id} metadata "${x.key}" ignored: ${x.reason}`);
  if (out.upserted === 0) {
    warn('billing is ON but no plan is active: create the plan Products and Prices in Stripe (docs/BILLING.md); the webhook and the daily job pick them up');
  }
}

async function cmdPlatformSetup() {
  requireRef();
  const file = opt('--cron-sql') ?? fail('--cron-sql is required');
  const template = readFileSync(file, 'utf8');
  const { secrets } = validateDeployEnv(env, { stripeWebhooks: true });
  if (!secrets.APP_BASE_URL || !secrets.CRON_SECRET) fail('APP_BASE_URL and CRON_SECRET are required for the platform setup');
  const billing = billingConfig(env);
  const functionsUrl = functionsBaseUrl(env);
  const sql = renderCronSql(template, { functionsUrl, cronSecret: secrets.CRON_SECRET, appBaseUrl: secrets.APP_BASE_URL });
  const jobs = cronJobNames(template);
  say(`platform setup (supabase/setup/cron.sql, rendered in memory): app_base_url=${secrets.APP_BASE_URL} functions=${functionsUrl}`);
  say(`  jobs: ${jobs.join(', ')}`);
  if (DRY) {
    say('dry run: cron.sql not executed');
    return say(
      `dry run: would call set_billing_config(${billing.enabled}, ${billing.trialDays})${billing.enabled ? ' and then billing sync_plans' : ''}`,
    );
  }
  // Refuse before changing anything when an unset input would change billing.
  billingGuard(billing, await readBillingConfig());
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

  // Shop subscription billing (docs/BILLING.md): both values are validated
  // numbers/booleans, so they are safe to inline.
  await runSql(
    `select public.set_billing_config(p_enabled => ${billing.enabled ? 'true' : 'false'}, p_trial_days => ${Number(billing.trialDays)})`,
    'set billing config',
  );
  const after = await readBillingConfig();
  if (after.enabled !== billing.enabled || after.trialDays !== billing.trialDays) {
    fail(`billing config reads back enabled=${after.enabled} trial_days=${after.trialDays}, expected enabled=${billing.enabled} trial_days=${billing.trialDays}`);
  }
  say(`billing: ${billing.enabled ? 'ON' : 'off'}, trial ${billing.trialDays} day(s) (set_billing_config)`);
  if (billing.enabled) await syncBillingPlans(secrets.CRON_SECRET);
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
