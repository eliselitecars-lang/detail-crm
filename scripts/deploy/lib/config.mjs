// Pure helpers for the production deploy (scripts/deploy/). No network and no
// process-wide side effects: everything here is unit-tested in
// scripts/deploy/test/config.test.mjs and shared by deploy_api.mjs (called by
// deploy_backend.sh) and verify_live.mjs.
//
// Sources of truth these helpers read (never duplicated by hand):
//   supabase/config.toml                         [functions.<name>] verify_jwt
//   supabase/functions/<name>/index.ts           deployable function directories
//   supabase/functions/stripe-webhook/handlers.ts HANDLED_EVENT_TYPES (Connect endpoint)
//   supabase/functions/billing-webhook/handlers.ts HANDLED_EVENT_TYPES (platform billing endpoint)
//   supabase/functions/_shared/stripe.ts          STRIPE_API_VERSION
//   supabase/functions/_shared/env.ts             secret names + formats (mirrored below)
//   supabase/setup/cron.sql                       platform setup template
import { createHash } from 'node:crypto';
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

export const REPO_ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

// ----------------------------------------------------------------- errors
export class DeployConfigError extends Error {
  constructor(message) {
    super(message);
    this.name = 'DeployConfigError';
  }
}

// ------------------------------------------------------ config.toml parsing
/**
 * Every `[functions.<name>]` table in config.toml with its verify_jwt value.
 * Supabase deploys a function with verify_jwt = true unless told otherwise,
 * so a table without the key counts as true.
 */
export function parseFunctionsConfig(tomlText) {
  const out = [];
  let current = null;
  for (const rawLine of tomlText.split('\n')) {
    const line = rawLine.replace(/\s+#.*$/, '').trim();
    if (!line || line.startsWith('#')) continue;
    const table = /^\[([^\]]+)\]$/.exec(line);
    if (table) {
      const m = /^functions\.("?)([A-Za-z0-9_-]+)\1$/.exec(table[1].trim());
      current = m ? { name: m[2], verifyJwt: true } : null;
      if (current) out.push(current);
      continue;
    }
    if (!current) continue;
    const kv = /^verify_jwt\s*=\s*(true|false)$/.exec(line);
    if (kv) current.verifyJwt = kv[1] === 'true';
  }
  const seen = new Set();
  for (const f of out) {
    if (seen.has(f.name)) throw new DeployConfigError(`config.toml declares [functions.${f.name}] twice`);
    seen.add(f.name);
  }
  return out;
}

/** Deployable function directories: supabase/functions/<name>/index.ts, not _shared or dot dirs. */
export function listFunctionDirs(functionsDir) {
  return readdirSync(functionsDir)
    .filter((name) => !name.startsWith('_') && !name.startsWith('.'))
    .filter((name) => statSync(join(functionsDir, name)).isDirectory())
    .filter((name) => existsSync(join(functionsDir, name, 'index.ts')))
    .sort();
}

/**
 * The functions to deploy: config.toml and the directories must agree
 * exactly (supabase/functions/_shared/config_test.ts enforces the same rule),
 * so nothing is deployed with a default verify_jwt by accident.
 */
export function functionsPlan(supabaseDir) {
  const declared = parseFunctionsConfig(readFileSync(join(supabaseDir, 'config.toml'), 'utf8'));
  const dirs = listFunctionDirs(join(supabaseDir, 'functions'));
  const declaredNames = new Set(declared.map((f) => f.name));
  const missingConfig = dirs.filter((d) => !declaredNames.has(d));
  const missingDir = declared.filter((f) => !dirs.includes(f.name)).map((f) => f.name);
  if (missingConfig.length || missingDir.length) {
    throw new DeployConfigError(
      [
        missingConfig.length ? `function directories without [functions.<name>] in config.toml: ${missingConfig.join(', ')}` : '',
        missingDir.length ? `[functions.<name>] tables without a directory: ${missingDir.join(', ')}` : '',
      ].filter(Boolean).join('; '),
    );
  }
  return declared.slice().sort((a, b) => a.name.localeCompare(b.name));
}

// ------------------------------------------------------------- Stripe facts
/** HANDLED_EVENT_TYPES from a webhook's handlers.ts (the webhook's own list). */
export function parseHandledStripeEvents(handlersTs, file = 'stripe-webhook/handlers.ts') {
  const m = /export const HANDLED_EVENT_TYPES\s*=\s*\[([\s\S]*?)\]\s*as const/.exec(handlersTs);
  if (!m) throw new DeployConfigError(`HANDLED_EVENT_TYPES not found in ${file}`);
  const events = [...m[1].matchAll(/"([a-z_.]+)"/g)].map((x) => x[1]);
  if (events.length === 0) throw new DeployConfigError(`HANDLED_EVENT_TYPES is empty in ${file}`);
  return events;
}

/** STRIPE_API_VERSION from _shared/stripe.ts (the version webhook events must use). */
export function parseStripeApiVersion(stripeTs) {
  const m = /export const STRIPE_API_VERSION\s*=\s*"([^"]+)"/.exec(stripeTs);
  if (!m) throw new DeployConfigError('STRIPE_API_VERSION not found in _shared/stripe.ts');
  return m[1];
}

/**
 * `events`: the Connect endpoint's (stripe-webhook); `billingEvents`: the
 * platform billing endpoint's (billing-webhook, shop subscriptions).
 */
export function readStripeFacts(supabaseDir) {
  const fnDir = join(supabaseDir, 'functions');
  return {
    events: parseHandledStripeEvents(readFileSync(join(fnDir, 'stripe-webhook', 'handlers.ts'), 'utf8')),
    billingEvents: parseHandledStripeEvents(readFileSync(join(fnDir, 'billing-webhook', 'handlers.ts'), 'utf8'), 'billing-webhook/handlers.ts'),
    apiVersion: parseStripeApiVersion(readFileSync(join(fnDir, '_shared', 'stripe.ts'), 'utf8')),
  };
}

// ---------------------------------------------------------------- URLs
function parseUrl(name, raw) {
  try {
    return new URL(raw);
  } catch {
    throw new DeployConfigError(`${name} is not a URL`);
  }
}

/** APP_BASE_URL: https, no query/fragment, no trailing slash (same rules as env.ts + cron.sql). */
export function normalizeAppBaseUrl(raw, { allowHttp = false } = {}) {
  if (!raw || !raw.trim()) throw new DeployConfigError('APP_BASE_URL is empty');
  const url = parseUrl('APP_BASE_URL', raw.trim());
  if (url.protocol !== 'https:' && !(allowHttp && url.protocol === 'http:')) {
    throw new DeployConfigError('APP_BASE_URL must be an https:// URL (cron.sql and Stripe/Twilio links require it)');
  }
  if (url.search || url.hash) throw new DeployConfigError('APP_BASE_URL must not contain a query or fragment');
  if (url.username || url.password) throw new DeployConfigError('APP_BASE_URL must not contain credentials');
  return url.toString().replace(/\/+$/, '');
}

export function projectRefOk(ref) {
  return typeof ref === 'string' && /^[a-z0-9]{20}$/.test(ref);
}

/** Public API URL of the project: SUPABASE_URL when set (custom domain), else https://<ref>.supabase.co. */
export function supabaseUrl(env) {
  if (env.SUPABASE_URL && env.SUPABASE_URL.trim()) {
    const url = parseUrl('SUPABASE_URL', env.SUPABASE_URL.trim());
    if (url.protocol !== 'https:' && url.protocol !== 'http:') throw new DeployConfigError('SUPABASE_URL must be http(s)');
    return url.origin;
  }
  if (!projectRefOk(env.SUPABASE_PROJECT_REF)) {
    throw new DeployConfigError('SUPABASE_PROJECT_REF must be the 20-character project ref (or set SUPABASE_URL)');
  }
  return `https://${env.SUPABASE_PROJECT_REF}.supabase.co`;
}

/** Public functions base URL (what Stripe, Twilio and pg_cron call). Mirrors Env.functionsPublicUrl(). */
export function functionsBaseUrl(env) {
  const override = env.FUNCTIONS_PUBLIC_URL?.trim();
  if (override) return override.replace(/\/+$/, '');
  return `${supabaseUrl(env)}/functions/v1`;
}

// ------------------------------------------------------------ secrets spec
const EMAIL_FROM_RE = /^([^<>]+<[^\s<>@]+@[^\s<>@]+\.[^\s<>@]+>|[^\s<>@]+@[^\s<>@]+\.[^\s<>@]+)$/;

/**
 * Function secrets the deploy sets (supabase/functions/README.md "Secrets",
 * validated exactly like _shared/env.ts so a bad value fails here, before it
 * reaches production). SUPABASE_URL / SUPABASE_ANON_KEY /
 * SUPABASE_SERVICE_ROLE_KEY are injected by Supabase and never set.
 * `required`:
 *   true                              always an input;
 *   'unless-stripe-webhooks'          the webhook signing secrets: an input, OR
 *   'billing-unless-stripe-webhooks'  created and stored by --stripe-webhooks, OR
 *                                     already stored in the project by an earlier
 *                                     deploy (kept as it is); the billing one only
 *                                     while BILLING_ENABLED=true;
 *   false                             optional: unset = off / the default, and an
 *                                     unset one is REMOVED from the project
 *                                     (OPTIONAL_SECRET_NAMES, planSecrets).
 */
export const SECRET_SPECS = [
  {
    name: 'STRIPE_SECRET_KEY',
    required: true,
    where: 'Stripe Dashboard -> Developers -> API keys (platform account; sk_live_... for production)',
    validate: (v) => (/^(sk|rk)_(test|live)_[A-Za-z0-9]+$/.test(v) ? null : 'expected sk_test_/sk_live_/rk_ key'),
  },
  {
    name: 'STRIPE_PUBLISHABLE_KEY',
    required: true,
    where: 'Stripe Dashboard -> Developers -> API keys (pk_live_... for production)',
    validate: (v, env) => {
      const mode = /^pk_(test|live)_[A-Za-z0-9]+$/.exec(v)?.[1];
      if (!mode) return 'expected pk_test_/pk_live_ key';
      const secretMode = /^(sk|rk)_(test|live)_/.exec(env.STRIPE_SECRET_KEY ?? '')?.[2];
      if (secretMode && secretMode !== mode) return `publishable key is ${mode} but secret key is ${secretMode}`;
      return null;
    },
  },
  {
    name: 'STRIPE_WEBHOOK_SECRET',
    required: 'unless-stripe-webhooks',
    where:
      'Signing secret of the Stripe Connect webhook endpoint; not needed once the project holds it: run with --stripe-webhooks (workflow: stripe_webhooks) to create the endpoint and store it',
    validate: (v) => (/^whsec_[A-Za-z0-9+/=_-]+$/.test(v) ? null : 'expected whsec_ secret'),
  },
  {
    name: 'STRIPE_BILLING_WEBHOOK_SECRET',
    required: 'billing-unless-stripe-webhooks',
    where:
      'Signing secret of the Stripe PLATFORM webhook endpoint for billing-webhook (shop subscriptions), needed while BILLING_ENABLED=true; not needed once the project holds it: run with --stripe-webhooks (workflow: stripe_webhooks) to create the endpoint and store it',
    validate: (v) => (/^whsec_[A-Za-z0-9+/=_-]+$/.test(v) ? null : 'expected whsec_ secret'),
  },
  {
    name: 'BILLING_AUTOMATIC_TAX',
    required: false,
    where: '"true" = Stripe Tax on shop subscription Checkout (Stripe Tax must be set up on the platform account); unset = off (docs/BILLING.md)',
    validate: (v) => (/^(true|false)$/i.test(v) ? null : 'must be true or false'),
  },
  {
    name: 'PLATFORM_FEE_BPS',
    required: false,
    where: 'Your platform fee in basis points (0-10000); unset = 0',
    validate: (v) => (/^\d+$/.test(v) && Number(v) <= 10000 ? null : 'must be a whole number of basis points, at most 10000'),
  },
  {
    name: 'TWILIO_ACCOUNT_SID',
    required: true,
    where: 'Twilio Console -> Account info (AC...)',
    validate: (v) => (/^AC[0-9a-fA-F]{32}$/.test(v) ? null : 'expected AC followed by 32 hex characters'),
  },
  {
    name: 'TWILIO_AUTH_TOKEN',
    required: true,
    where: 'Twilio Console -> Account info (Auth Token)',
    validate: (v) => (v.length >= 16 ? null : 'looks too short for a Twilio auth token'),
  },
  {
    name: 'RESEND_API_KEY',
    required: true,
    where: 'Resend -> API Keys (re_...; also used as the Auth SMTP password)',
    validate: (v) => (v.startsWith('re_') ? null : 'expected re_ key'),
  },
  {
    name: 'EMAIL_FROM',
    required: true,
    where: '"Name <notifications@your-verified-domain>" on a domain verified in Resend',
    validate: (v) => (EMAIL_FROM_RE.test(v) ? null : 'expected "Name <user@domain>" or an address'),
  },
  {
    name: 'APP_BASE_URL',
    required: true,
    where: 'The web app origin, e.g. https://app.yourdomain.com',
    validate: (v) => {
      try {
        normalizeAppBaseUrl(v);
        return null;
      } catch (err) {
        return err.message;
      }
    },
  },
  {
    name: 'CRON_SECRET',
    required: true,
    where: 'Generate once: openssl rand -hex 32 (at least 24 characters)',
    validate: (v) => (v.length >= 24 ? (/[\s'\\]/.test(v) ? 'must not contain whitespace, quotes or backslashes' : null) : 'must be at least 24 characters'),
  },
  {
    name: 'CORS_ALLOWED_ORIGINS',
    required: false,
    where: 'Optional extra browser origins, comma-separated (e.g. a staging web app)',
    validate: (v) => {
      for (const part of v.split(',').map((p) => p.trim()).filter(Boolean)) {
        let url;
        try {
          url = new URL(part);
        } catch {
          return `"${part}" is not a URL`;
        }
        if (!['http:', 'https:'].includes(url.protocol) || url.pathname !== '/' || url.search || url.hash) {
          return `"${part}" is not a bare origin`;
        }
      }
      return null;
    },
  },
  {
    name: 'FUNCTIONS_PUBLIC_URL',
    required: false,
    where: 'Leave unset in production (only for tunnels / custom domains)',
    validate: (v) => (/^https:\/\/[^/\s]+\/functions\/v1\/?$/.test(v) ? null : 'must look like https://<host>/functions/v1'),
  },  // Optional: APNs push for the staff iPhone app (push function). All four
  // or none: while none is set pushes are simply not sent.
  {
    name: 'APNS_KEY_ID',
    required: false,
    where: 'developer.apple.com -> Keys -> the APNs auth key (.p8): its 10-character Key ID',
    validate: (v) => (/^[A-Z0-9]{10}$/.test(v) ? null : 'expected the 10-character key id'),
  },
  {
    name: 'APNS_TEAM_ID',
    required: false,
    where: 'developer.apple.com -> Account -> Membership details -> Team ID',
    validate: (v) => (/^[A-Z0-9]{10}$/.test(v) ? null : 'expected the 10-character team id'),
  },
  {
    name: 'APNS_PRIVATE_KEY',
    required: false,
    where: 'the contents of the APNs AuthKey_<id>.p8 file (line breaks may be written as \\n)',
    validate: (v) =>
      /^-----BEGIN PRIVATE KEY-----\s*[A-Za-z0-9+/=\s]+-----END PRIVATE KEY-----$/.test(v.replace(/\\n/g, '\n'))
        ? null
        : 'expected the PEM contents of the .p8 file (BEGIN PRIVATE KEY)',
  },
  {
    name: 'APNS_TOPIC',
    required: false,
    where: "the iPhone app's bundle id (the APNs topic)",
    validate: (v) => (/^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$/.test(v) ? null : "expected the app's bundle id"),
  },
  // Optional feature flags (unset = off): self-serve SMS numbers ship dark.
  {
    name: 'SMS_PROVISIONING_ENABLED',
    required: false,
    where: '"true" once the platform Twilio account may buy numbers and submit toll-free verifications',
    validate: (v) => (/^(true|false)$/i.test(v) ? null : 'must be true or false'),
  },
  {
    name: 'TWILIO_ISV_ENABLED',
    required: false,
    where: '"true" once the platform Twilio account is an approved A2P 10DLC ISV',
    validate: (v) => (/^(true|false)$/i.test(v) ? null : 'must be true or false'),
  },
  {
    name: 'TWILIO_PRIMARY_CUSTOMER_PROFILE_SID',
    required: false,
    where: "Twilio Console -> Trust Hub -> the platform's primary customer profile (BU...), needed for 10DLC",
    validate: (v) => (/^BU[0-9a-fA-F]{32}$/.test(v) ? null : 'expected BU followed by 32 hex characters'),
  },
];

/**
 * Secrets that only work together, checked after each value on its own.
 * Each value alone passes its own format check, but the functions fail at
 * run time with a partial set: push treats any APNS_* value as "configured"
 * and then needs all four (the every-minute push cron would answer 500
 * server_misconfigured forever), and 10DLC submission needs the primary
 * Trust Hub profile as soon as TWILIO_ISV_ENABLED is true.
 */
export const SECRET_GROUPS = [
  {
    kind: 'all-or-none',
    names: ['APNS_KEY_ID', 'APNS_TEAM_ID', 'APNS_PRIVATE_KEY', 'APNS_TOPIC'],
    why: 'APNs push needs all four APNS_* values or none',
  },
  {
    kind: 'requires',
    when: { name: 'TWILIO_ISV_ENABLED', equals: 'true' },
    names: ['TWILIO_PRIMARY_CUSTOMER_PROFILE_SID'],
    why: 'required while TWILIO_ISV_ENABLED=true (10DLC registration assigns it to every shop profile)',
  },
];

/** Secrets the local real-stack harness uses; they must never exist in production. */
export const HARNESS_ONLY_SECRETS = ['STRIPE_API_BASE', 'TWILIO_API_BASE', 'RESEND_API_BASE'];

/**
 * Optional function secrets ("unset = off / the default"). The deploy inputs
 * are their desired state: one the inputs leave unset is removed from the
 * project (planSecrets), so deleting a GitHub variable really switches the
 * feature off (the platform fee, self-serve numbers, Stripe Tax, an extra
 * CORS origin, APNs push) instead of leaving the old value in force.
 */
export const OPTIONAL_SECRET_NAMES = SECRET_SPECS.filter((spec) => spec.required === false).map((spec) => spec.name);

/**
 * One-shot knobs of --stripe-webhooks (deploy_api.mjs ensureEndpoint), per
 * endpoint: RECREATE=1 deletes and recreates the tagged endpoint (a new
 * signing secret is stored); ADOPT=<we_...> takes over an endpoint made by
 * hand at the same URL. The deploy-backend workflow sets them from its
 * stripe_webhook_recreate / stripe_webhook_adopt_* inputs.
 */
export const WEBHOOK_KNOBS = [
  { name: 'STRIPE_WEBHOOK_RECREATE', endpoint: 'connect', kind: 'recreate', input: 'stripe_webhook_recreate = connect (or both)' },
  { name: 'STRIPE_WEBHOOK_ADOPT', endpoint: 'connect', kind: 'adopt', input: 'stripe_webhook_adopt_connect' },
  { name: 'STRIPE_BILLING_WEBHOOK_RECREATE', endpoint: 'billing', kind: 'recreate', input: 'stripe_webhook_recreate = billing (or both)' },
  { name: 'STRIPE_BILLING_WEBHOOK_ADOPT', endpoint: 'billing', kind: 'adopt', input: 'stripe_webhook_adopt_billing' },
];

/** Problems with the --stripe-webhooks knobs: [{name, problem}] (values never included). */
function webhookKnobProblems(env, { stripeWebhooks, billingOn }) {
  const problems = [];
  for (const knob of WEBHOOK_KNOBS) {
    const raw = env[knob.name]?.trim() ?? '';
    if (knob.kind === 'recreate') {
      if (raw === '' || raw === '0') continue;
      if (raw !== '1') {
        problems.push({ name: knob.name, problem: 'must be 1 (or unset)' });
        continue;
      }
    } else {
      if (raw === '') continue;
      if (!/^we_[A-Za-z0-9]+$/.test(raw)) {
        problems.push({ name: knob.name, problem: 'must be a Stripe webhook endpoint id (we_...)' });
        continue;
      }
    }
    if (!stripeWebhooks) {
      problems.push({
        name: knob.name,
        problem: 'acts only together with --stripe-webhooks (workflow: check stripe_webhooks); nothing would change without it',
      });
    } else if (knob.endpoint === 'billing' && !billingOn) {
      problems.push({
        name: knob.name,
        problem: 'acts only while BILLING_ENABLED=true (the platform billing endpoint is managed only then); nothing would change',
      });
    }
  }
  return problems;
}

/** Deploy-script inputs that are not function secrets. */
export const DEPLOY_INPUTS = [
  { name: 'SUPABASE_ACCESS_TOKEN', where: 'supabase.com -> Account -> Access Tokens (personal access token)' },
  { name: 'SUPABASE_PROJECT_REF', where: 'Project Settings -> General -> Reference ID (20 lowercase letters)' },
  { name: 'SUPABASE_DB_PASSWORD', where: 'The database password chosen when the project was created (Project Settings -> Database to reset)' },
];

/**
 * Shop subscription billing (docs/BILLING.md): database settings, not
 * function secrets. The platform-setup step applies them with
 * public.set_billing_config(p_enabled, p_trial_days).
 */
export const BILLING_INPUTS = [
  {
    name: 'BILLING_ENABLED',
    where: '"true" turns on shop subscription billing (docs/BILLING.md); "false" or unset = off, every shop fully usable',
    validate: (v) => (/^(true|false)$/i.test(v) ? null : 'must be true or false'),
  },
  {
    name: 'BILLING_TRIAL_DAYS',
    where: 'free trial for shops once billing is on, in whole days (0 = no trial; unset = 0; at most 730, Stripe\'s longest trial)',
    validate: (v) => (/^\d{1,3}$/.test(v) && Number(v) <= 730 ? null : 'must be a whole number of days from 0 to 730'),
  },
];

/**
 * The billing inputs: { enabled, trialDays } with the defaults (off, 0) and
 * whether each was set explicitly (an unset input never silently changes a
 * project that has another value: see deploy_api.mjs platform-setup).
 */
export function billingConfig(env) {
  const enabledRaw = env.BILLING_ENABLED?.trim() ?? '';
  const trialRaw = env.BILLING_TRIAL_DAYS?.trim() ?? '';
  for (const input of BILLING_INPUTS) {
    const raw = env[input.name]?.trim();
    const problem = raw ? input.validate(raw) : null;
    if (problem) throw new DeployConfigError(`${input.name} ${problem}`);
  }
  return {
    enabled: enabledRaw.toLowerCase() === 'true',
    enabledSet: enabledRaw !== '',
    trialDays: trialRaw === '' ? 0 : Number(trialRaw),
    trialDaysSet: trialRaw !== '',
  };
}

/**
 * Validates the environment for a deploy. Returns the exact lists the
 * operator needs; values are never included in messages.
 *
 * A webhook signing secret that is not an input (and not coming from
 * --stripe-webhooks) may already be stored in the project by an earlier
 * deploy: `storedSecrets` (a Set of the project's secret names) settles it
 * (stored = kept as it is; not stored = missing). Without `storedSecrets`
 * (before the project is contacted) such names are returned in `deferred`
 * for the caller to check against the project.
 */
export function validateDeployEnv(env, { stripeWebhooks = false, requireLiveStripe = false, storedSecrets } = {}) {
  const missing = [];
  const invalid = [];
  const warnings = [];
  const deferred = [];
  const secrets = {};
  for (const input of DEPLOY_INPUTS) {
    if (!env[input.name]?.trim()) missing.push({ name: input.name, where: input.where });
  }
  if (env.SUPABASE_PROJECT_REF?.trim() && !projectRefOk(env.SUPABASE_PROJECT_REF.trim())) {
    invalid.push({ name: 'SUPABASE_PROJECT_REF', problem: 'must be the 20-character project ref (lowercase letters/digits)' });
  }
  for (const input of BILLING_INPUTS) {
    const raw = env[input.name]?.trim();
    const problem = raw ? input.validate(raw) : null;
    if (problem) invalid.push({ name: input.name, problem });
  }
  const billingOn = env.BILLING_ENABLED?.trim().toLowerCase() === 'true';
  for (const spec of SECRET_SPECS) {
    const value = env[spec.name]?.trim();
    const webhookSecret =
      (spec.required === 'unless-stripe-webhooks' || (spec.required === 'billing-unless-stripe-webhooks' && billingOn)) && !stripeWebhooks;
    if (!value) {
      if (spec.required === true) {
        missing.push({ name: spec.name, where: spec.where });
      } else if (webhookSecret) {
        if (!storedSecrets) deferred.push({ name: spec.name, where: spec.where });
        else if (!storedSecrets.has(spec.name)) missing.push({ name: spec.name, where: `not an input and not stored in the project yet. ${spec.where}` });
      }
      continue;
    }
    const problem = spec.validate(value, env);
    if (problem) {
      invalid.push({ name: spec.name, problem });
      continue;
    }
    secrets[spec.name] = spec.name === 'APP_BASE_URL' ? normalizeAppBaseUrl(value) : value;
  }
  const isSet = (name) => Boolean(env[name]?.trim());
  const whereOf = (name) => SECRET_SPECS.find((spec) => spec.name === name)?.where ?? '';
  for (const group of SECRET_GROUPS) {
    const unset = group.names.filter((name) => !isSet(name));
    if (group.kind === 'all-or-none') {
      const set = group.names.filter(isSet);
      if (set.length === 0 || unset.length === 0) continue;
      for (const name of unset) {
        missing.push({ name, where: `${group.why} (${set.join(', ')} ${set.length === 1 ? 'is' : 'are'} set): ${whereOf(name)}` });
      }
    } else if (env[group.when.name]?.trim().toLowerCase() === group.when.equals) {
      for (const name of unset) missing.push({ name, where: `${group.why}: ${whereOf(name)}` });
    }
  }
  if (!billingOn && Number(env.BILLING_TRIAL_DAYS?.trim() || 0) > 0 && /^\d+$/.test(env.BILLING_TRIAL_DAYS.trim())) {
    warnings.push('BILLING_TRIAL_DAYS is set but BILLING_ENABLED is not true: the trial length is stored and starts applying once billing is turned on');
  }
  if (env.TWILIO_ISV_ENABLED?.trim().toLowerCase() === 'true' && env.SMS_PROVISIONING_ENABLED?.trim().toLowerCase() !== 'true') {
    warnings.push('TWILIO_ISV_ENABLED=true has no effect until SMS_PROVISIONING_ENABLED=true (self-serve numbers stay off)');
  }
  invalid.push(...webhookKnobProblems(env, { stripeWebhooks, billingOn }));
  const mode = /^(sk|rk)_(test|live)_/.exec(env.STRIPE_SECRET_KEY ?? '')?.[2];
  if (mode === 'test') {
    (requireLiveStripe ? invalid : warnings).push(
      requireLiveStripe
        ? { name: 'STRIPE_SECRET_KEY', problem: 'is a TEST mode key but REQUIRE_LIVE_STRIPE=1' }
        : 'Stripe keys are TEST mode: real cards will not be charged (set REQUIRE_LIVE_STRIPE=1 to refuse this)',
    );
  }
  for (const name of HARNESS_ONLY_SECRETS) {
    if (env[name]) warnings.push(`${name} is set in this environment; it is never sent to production (local harness only)`);
  }
  return { missing, invalid, warnings, deferred, secrets };
}

export function sha256Hex(value) {
  return createHash('sha256').update(value, 'utf8').digest('hex');
}

/**
 * What to send to POST /v1/projects/{ref}/secrets. The Management API lists
 * secrets as {name, value: <sha256 hex digest>}; unchanged values are
 * skipped (a digest in another format simply means "update").
 * `unset`: optional secrets (OPTIONAL_SECRET_NAMES) the project has but the
 * inputs leave unset, to remove ("unset = off" is the desired state).
 * `harness`: local-harness overrides found in the project, to remove.
 * Names the deploy does not manage (and the webhook signing secrets, which
 * the project keeps when they are not inputs) are never removed.
 */
export function planSecrets(desired, remoteList) {
  const remote = new Map((remoteList ?? []).map((s) => [s.name, s.value]));
  const plan = [];
  for (const [name, value] of Object.entries(desired)) {
    if (!remote.has(name)) plan.push({ name, action: 'create', value });
    else if (remote.get(name) === sha256Hex(value)) plan.push({ name, action: 'unchanged', value });
    else plan.push({ name, action: 'update', value });
  }
  const unset = OPTIONAL_SECRET_NAMES.filter((n) => remote.has(n) && !Object.hasOwn(desired, n));
  const harness = HARNESS_ONLY_SECRETS.filter((n) => remote.has(n));
  return { plan, unset, harness };
}

// ---------------------------------------------------------------- cron.sql
/**
 * The three assignments cron.sql asks the operator to edit (see its header).
 * Only these literals are replaced: the placeholder tokens also appear in the
 * script's own guard (`v_cron_secret = '<CRON_SECRET>'`) and in comments,
 * which must stay as they are or the guard would reject real values.
 */
const CRON_ASSIGNMENTS = [
  { key: 'functionsUrl', re: /(v_functions_url\s+constant\s+text\s*:=\s*)'https:\/\/<PROJECT_REF>\.supabase\.co\/functions\/v1'/g },
  { key: 'cronSecret', re: /(v_cron_secret\s+constant\s+text\s*:=\s*)'<CRON_SECRET>'/g },
  { key: 'appBaseUrl', re: /(v_app_base_url\s+constant\s+text\s*:=\s*)'<APP_BASE_URL>'/g },
];

export function sqlLiteral(value) {
  if (typeof value !== 'string') throw new DeployConfigError('sqlLiteral expects a string');
  if (value.includes('\0')) throw new DeployConfigError('value contains a NUL byte');
  return `'${value.replace(/'/g, "''")}'`;
}

/**
 * Renders supabase/setup/cron.sql with real values, in memory. Throws when the
 * template no longer has exactly one of each expected assignment (the file's
 * placeholder format changed: update CRON_ASSIGNMENTS rather than guessing).
 */
export function renderCronSql(template, { functionsUrl, cronSecret, appBaseUrl }) {
  const values = { functionsUrl, cronSecret, appBaseUrl };
  if (!/^https:\/\/[^/\s]+\/functions\/v1$/.test(functionsUrl ?? '')) {
    throw new DeployConfigError('functions URL must look like https://<host>/functions/v1 (cron.sql rejects anything else)');
  }
  if (!cronSecret || cronSecret.length < 24) throw new DeployConfigError('CRON_SECRET must be at least 24 characters');
  if (!/^https:\/\//.test(appBaseUrl ?? '')) throw new DeployConfigError('APP_BASE_URL must be https (cron.sql rejects anything else)');
  let sql = template;
  for (const { key, re } of CRON_ASSIGNMENTS) {
    const count = [...template.matchAll(re)].length;
    if (count !== 1) {
      throw new DeployConfigError(
        `supabase/setup/cron.sql: expected exactly one "${key}" placeholder assignment, found ${count}. ` +
          'The file\'s placeholder format changed; update CRON_ASSIGNMENTS in scripts/deploy/lib/config.mjs.',
      );
    }
    sql = sql.replace(re, (_m, prefix) => `${prefix}${sqlLiteral(values[key])}`);
  }
  return sql;
}

// ---------------------------------------------------------------- Auth
export function parseEmailFrom(from) {
  const m = /^\s*([^<>]+?)\s*<([^\s<>@]+@[^\s<>@]+\.[^\s<>@]+)>\s*$/.exec(from ?? '');
  if (m) return { name: m[1].replace(/^"|"$/g, ''), address: m[2] };
  if (/^[^\s<>@]+@[^\s<>@]+\.[^\s<>@]+$/.test((from ?? '').trim())) return { name: null, address: from.trim() };
  throw new DeployConfigError('EMAIL_FROM must be "Name <user@domain>" or an address');
}

/** Web routes GoTrue may redirect to (email links): mirrors config.toml additional_redirect_urls. */
export const AUTH_REDIRECT_PATHS = ['/**', '/reset-password', '/invite/**', '/portal', '/app/**', '/login'];

function intEnv(env, name, fallback, { min, max }) {
  const raw = env[name]?.trim();
  if (!raw) return fallback;
  if (!/^\d+$/.test(raw)) throw new DeployConfigError(`${name} must be a whole number`);
  const n = Number(raw);
  if (n < min || n > max) throw new DeployConfigError(`${name} must be between ${min} and ${max}`);
  return n;
}

/**
 * Production Auth settings (PATCH /v1/projects/{ref}/config/auth). This is
 * the ONLY way the deploy touches hosted Auth: supabase/config.toml is tuned
 * for local journeys (confirmations off, 127.0.0.1 URLs) and is never pushed.
 * Returns { body, redacted } where `redacted` is safe to print.
 */
export function buildAuthConfig(env) {
  const app = normalizeAppBaseUrl(env.APP_BASE_URL);
  const sender = parseEmailFrom(env.EMAIL_FROM);
  const senderEmail = env.AUTH_SMTP_SENDER_EMAIL?.trim() || sender.address;
  const senderName = env.AUTH_SMTP_SENDER_NAME?.trim() || sender.name || 'Detail CRM';
  if (!/^[^\s<>@]+@[^\s<>@]+\.[^\s<>@]+$/.test(senderEmail)) throw new DeployConfigError('AUTH_SMTP_SENDER_EMAIL is not an email address');
  if (!env.RESEND_API_KEY?.startsWith('re_')) throw new DeployConfigError('RESEND_API_KEY is required for Auth SMTP');
  const extra = (env.AUTH_ADDITIONAL_REDIRECT_URLS ?? '')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);
  for (const u of extra) {
    if (!/^[a-z][a-z0-9+.-]*:\/\/\S+$/i.test(u)) throw new DeployConfigError(`AUTH_ADDITIONAL_REDIRECT_URLS: "${u}" is not a URL`);
  }
  const allow = [...new Set([...AUTH_REDIRECT_PATHS.map((p) => `${app}${p}`), ...extra])];
  // 8 = the apps' own rule (web zPassword, iOS Validation.minimumPasswordLength).
  const minLength = intEnv(env, 'AUTH_PASSWORD_MIN_LENGTH', 8, { min: 8, max: 72 });
  const body = {
    site_url: app,
    uri_allow_list: allow.join(','),
    disable_signup: false,
    external_email_enabled: true,
    external_phone_enabled: false,
    external_anonymous_users_enabled: false,
    // Email confirmations ON: portal_claim_customers() links customers by CONFIRMED email.
    mailer_autoconfirm: false,
    mailer_secure_email_change_enabled: true,
    security_update_password_require_reauthentication: true,
    refresh_token_rotation_enabled: true,
    security_refresh_token_reuse_interval: 10,
    jwt_exp: 3600,
    password_min_length: minLength,
    smtp_host: 'smtp.resend.com',
    smtp_port: '465',
    smtp_user: 'resend',
    smtp_pass: env.RESEND_API_KEY,
    smtp_admin_email: senderEmail,
    smtp_sender_name: senderName,
    smtp_max_frequency: intEnv(env, 'AUTH_SMTP_MAX_FREQUENCY', 60, { min: 1, max: 3600 }),
    rate_limit_email_sent: intEnv(env, 'AUTH_RATE_LIMIT_EMAIL_SENT', 100, { min: 1, max: 100000 }),
  };
  if (env.AUTH_PASSWORD_HIBP?.trim()) {
    if (!/^(0|1|true|false)$/.test(env.AUTH_PASSWORD_HIBP.trim())) throw new DeployConfigError('AUTH_PASSWORD_HIBP must be 0/1');
    body.password_hibp_enabled = /^(1|true)$/.test(env.AUTH_PASSWORD_HIBP.trim());
  }
  const redacted = { ...body, smtp_pass: '<RESEND_API_KEY>' };
  return { body, redacted };
}

/** Fields of `desired` whose value differs in `current` (smtp_pass is write-only: never compared). */
export function diffAuthConfig(desired, current) {
  const changes = [];
  for (const [key, value] of Object.entries(desired)) {
    if (key === 'smtp_pass') continue;
    const now = current?.[key];
    const same =
      key === 'uri_allow_list'
        ? new Set(String(now ?? '').split(',').map((s) => s.trim()).filter(Boolean)).size ===
            new Set(String(value).split(',')).size &&
          String(value).split(',').every((u) => String(now ?? '').split(',').map((s) => s.trim()).includes(u))
        : String(now) === String(value);
    if (!same) changes.push(key);
  }
  return changes;
}
