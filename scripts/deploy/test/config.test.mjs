// Unit tests for scripts/deploy/lib/config.mjs (node --test scripts/deploy/test/).
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, test } from 'node:test';
import {
  buildAuthConfig,
  diffAuthConfig,
  functionsBaseUrl,
  functionsPlan,
  normalizeAppBaseUrl,
  parseEmailFrom,
  parseFunctionsConfig,
  parseHandledStripeEvents,
  parseStripeApiVersion,
  planSecrets,
  renderCronSql,
  REPO_ROOT,
  sha256Hex,
  sqlLiteral,
  validateDeployEnv,
} from '../lib/config.mjs';

const SUPA = join(REPO_ROOT, 'supabase');
const CRON = readFileSync(join(SUPA, 'setup', 'cron.sql'), 'utf8');
const GOOD = {
  SUPABASE_ACCESS_TOKEN: 'sbp_x',
  SUPABASE_PROJECT_REF: 'abcdefghijklmnopqrst',
  SUPABASE_DB_PASSWORD: 'pw',
  STRIPE_SECRET_KEY: 'sk_live_abc123',
  STRIPE_PUBLISHABLE_KEY: 'pk_live_abc123',
  STRIPE_WEBHOOK_SECRET: 'whsec_abc123',
  TWILIO_ACCOUNT_SID: `AC${'a'.repeat(32)}`,
  TWILIO_AUTH_TOKEN: '0123456789abcdef0123',
  RESEND_API_KEY: 're_abc123',
  EMAIL_FROM: 'Detail CRM <notifications@example.com>',
  APP_BASE_URL: 'https://app.example.com/',
  CRON_SECRET: 'x'.repeat(32),
};

describe('config.toml / function directories', () => {
  test('parseFunctionsConfig reads verify_jwt per function (default true)', () => {
    const toml = `
[auth]
enabled = true
[functions.a]
verify_jwt = false # comment
import_map = "./functions/deno.json"
[functions.b]
import_map = "./functions/deno.json"
[functions."c-d"]
verify_jwt = true
`;
    assert.deepEqual(parseFunctionsConfig(toml), [
      { name: 'a', verifyJwt: false },
      { name: 'b', verifyJwt: true },
      { name: 'c-d', verifyJwt: true },
    ]);
    assert.throws(() => parseFunctionsConfig('[functions.a]\n[functions.a]\n'), /twice/);
  });

  test('the repo: every function directory is declared, webhooks/cron are verify_jwt=false', () => {
    const plan = Object.fromEntries(functionsPlan(SUPA).map((f) => [f.name, f.verifyJwt]));
    assert.deepEqual(plan, {
      invites: true,
      messaging: false,
      payments: false,
      'storage-purge': false,
      'stripe-connect': true,
      'stripe-webhook': false,
    });
  });
});

describe('Stripe facts', () => {
  test('HANDLED_EVENT_TYPES and STRIPE_API_VERSION are read from the function code', () => {
    const events = parseHandledStripeEvents(readFileSync(join(SUPA, 'functions/stripe-webhook/handlers.ts'), 'utf8'));
    assert.ok(events.includes('checkout.session.completed') && events.includes('account.updated'));
    assert.equal(new Set(events).size, events.length);
    assert.match(parseStripeApiVersion(readFileSync(join(SUPA, 'functions/_shared/stripe.ts'), 'utf8')), /^\d{4}-\d{2}-\d{2}\.[a-z]+$/);
    assert.throws(() => parseHandledStripeEvents('nothing'), /not found/);
  });
});

describe('inputs', () => {
  test('a complete environment validates and APP_BASE_URL is normalized', () => {
    const r = validateDeployEnv(GOOD);
    assert.deepEqual(r.missing, []);
    assert.deepEqual(r.invalid, []);
    assert.equal(r.secrets.APP_BASE_URL, 'https://app.example.com');
    assert.ok(!('SUPABASE_ACCESS_TOKEN' in r.secrets) && !('SUPABASE_DB_PASSWORD' in r.secrets));
  });

  test('missing names are listed with where to get them; webhook secret optional with --stripe-webhooks', () => {
    const { STRIPE_WEBHOOK_SECRET, CRON_SECRET, SUPABASE_DB_PASSWORD, ...rest } = GOOD;
    const r = validateDeployEnv(rest);
    assert.deepEqual(r.missing.map((m) => m.name).sort(), ['CRON_SECRET', 'STRIPE_WEBHOOK_SECRET', 'SUPABASE_DB_PASSWORD']);
    assert.ok(r.missing.every((m) => m.where.length > 10));
    assert.deepEqual(validateDeployEnv(rest, { stripeWebhooks: true }).missing.map((m) => m.name).sort(), ['CRON_SECRET', 'SUPABASE_DB_PASSWORD']);
  });

  test('formats mirror supabase/functions/_shared/env.ts', () => {
    const bad = {
      ...GOOD,
      STRIPE_PUBLISHABLE_KEY: 'pk_test_abc',
      TWILIO_ACCOUNT_SID: 'AC123',
      RESEND_API_KEY: 'sk_abc',
      EMAIL_FROM: 'not an email',
      CRON_SECRET: 'short',
      PLATFORM_FEE_BPS: '10001',
      CORS_ALLOWED_ORIGINS: 'https://ok.example.com, https://bad.example.com/path',
      FUNCTIONS_PUBLIC_URL: 'http://localhost:54321/functions/v1',
      SUPABASE_PROJECT_REF: 'nope',
    };
    const names = validateDeployEnv(bad).invalid.map((i) => i.name).sort();
    assert.deepEqual(names, [
      'CORS_ALLOWED_ORIGINS',
      'CRON_SECRET',
      'EMAIL_FROM',
      'FUNCTIONS_PUBLIC_URL',
      'PLATFORM_FEE_BPS',
      'RESEND_API_KEY',
      'STRIPE_PUBLISHABLE_KEY',
      'SUPABASE_PROJECT_REF',
      'TWILIO_ACCOUNT_SID',
    ]);
    for (const i of validateDeployEnv(bad).invalid) assert.ok(!i.problem.includes('short') || i.name !== 'CRON_SECRET');
  });

  test('test-mode Stripe keys warn, or fail with REQUIRE_LIVE_STRIPE', () => {
    const test = { ...GOOD, STRIPE_SECRET_KEY: 'sk_test_a', STRIPE_PUBLISHABLE_KEY: 'pk_test_a' };
    assert.match(validateDeployEnv(test).warnings.join(), /TEST mode/);
    assert.equal(validateDeployEnv(test, { requireLiveStripe: true }).invalid[0].name, 'STRIPE_SECRET_KEY');
  });

  test('APP_BASE_URL rules', () => {
    assert.equal(normalizeAppBaseUrl('https://app.example.com/crm/'), 'https://app.example.com/crm');
    assert.throws(() => normalizeAppBaseUrl('http://app.example.com'), /https/);
    assert.throws(() => normalizeAppBaseUrl('https://app.example.com/?x=1'), /query/);
    assert.equal(normalizeAppBaseUrl('http://127.0.0.1:5173', { allowHttp: true }), 'http://127.0.0.1:5173');
  });

  test('functions base URL: FUNCTIONS_PUBLIC_URL, else SUPABASE_URL, else the ref', () => {
    assert.equal(functionsBaseUrl({ SUPABASE_PROJECT_REF: 'abcdefghijklmnopqrst' }), 'https://abcdefghijklmnopqrst.supabase.co/functions/v1');
    assert.equal(functionsBaseUrl({ SUPABASE_URL: 'https://api.example.com/' }), 'https://api.example.com/functions/v1');
    assert.equal(functionsBaseUrl({ FUNCTIONS_PUBLIC_URL: 'https://x.example.com/functions/v1/' }), 'https://x.example.com/functions/v1');
  });
});

describe('secrets plan', () => {
  test('unchanged values (sha256 digest) are skipped; harness-only names are flagged', () => {
    const { plan, harness } = planSecrets(
      { A: 'one', B: 'two', C: 'three' },
      [
        { name: 'A', value: sha256Hex('one') },
        { name: 'B', value: sha256Hex('old') },
        { name: 'STRIPE_API_BASE', value: 'x' },
      ],
    );
    assert.deepEqual(plan.map((p) => `${p.name}:${p.action}`), ['A:unchanged', 'B:update', 'C:create']);
    assert.deepEqual(harness, ['STRIPE_API_BASE']);
  });
});

describe('cron.sql rendering', () => {
  const values = { functionsUrl: 'https://abcdefghijklmnopqrst.supabase.co/functions/v1', cronSecret: "s3cr3t-with-'quote'-and-more-chars", appBaseUrl: 'https://app.example.com' };

  test('replaces exactly the three assignments and keeps the guard intact', () => {
    const sql = renderCronSql(CRON, values);
    assert.match(sql, /v_functions_url constant text := 'https:\/\/abcdefghijklmnopqrst\.supabase\.co\/functions\/v1';/);
    assert.ok(sql.includes("v_cron_secret   constant text := 's3cr3t-with-''quote''-and-more-chars';"));
    assert.match(sql, /v_app_base_url  constant text := 'https:\/\/app\.example\.com';/);
    // The guard still compares against the placeholder tokens.
    assert.ok(sql.includes("v_cron_secret = '<CRON_SECRET>'"));
    assert.ok(sql.includes("v_app_base_url = '<APP_BASE_URL>'"));
    assert.ok(sql.includes("like '%<PROJECT_REF>%'"));
    // Only the assignment lines changed.
    const a = CRON.split('\n');
    const b = sql.split('\n');
    assert.equal(a.length, b.length);
    assert.equal(a.filter((l, i) => l !== b[i]).length, 3);
  });

  test('refuses a template whose placeholder format changed, and bad values', () => {
    assert.throws(() => renderCronSql(CRON.replace("'<CRON_SECRET>';", ":'cron_secret';"), values), /placeholder format changed/);
    assert.throws(() => renderCronSql(`${CRON}\n${CRON}`, values), /found 2/);
    assert.throws(() => renderCronSql(CRON, { ...values, functionsUrl: 'http://127.0.0.1:54321/functions/v1' }), /functions URL/);
    assert.throws(() => renderCronSql(CRON, { ...values, cronSecret: 'short' }), /24/);
    assert.throws(() => renderCronSql(CRON, { ...values, appBaseUrl: 'http://x' }), /https/);
  });

  test('sqlLiteral doubles quotes and refuses NUL', () => {
    assert.equal(sqlLiteral("a'b"), "'a''b'");
    assert.throws(() => sqlLiteral('a\0b'), /NUL/);
  });
});

describe('Auth config', () => {
  test('production values: confirmations ON, Resend SMTP, app redirects only', () => {
    const { body, redacted } = buildAuthConfig(GOOD);
    assert.equal(body.site_url, 'https://app.example.com');
    assert.equal(body.mailer_autoconfirm, false);
    assert.equal(body.external_anonymous_users_enabled, false);
    assert.equal(body.external_phone_enabled, false);
    assert.equal(body.password_min_length, 8);
    assert.equal(body.smtp_host, 'smtp.resend.com');
    assert.equal(body.smtp_port, '465');
    assert.equal(body.smtp_user, 'resend');
    assert.equal(body.smtp_pass, GOOD.RESEND_API_KEY);
    assert.equal(body.smtp_admin_email, 'notifications@example.com');
    assert.equal(body.smtp_sender_name, 'Detail CRM');
    assert.deepEqual(body.uri_allow_list.split(','), [
      'https://app.example.com/**',
      'https://app.example.com/reset-password',
      'https://app.example.com/invite/**',
      'https://app.example.com/portal',
      'https://app.example.com/app/**',
      'https://app.example.com/login',
    ]);
    assert.equal(redacted.smtp_pass, '<RESEND_API_KEY>');
    assert.ok(!JSON.stringify(redacted).includes(GOOD.RESEND_API_KEY));
    assert.ok(!('password_hibp_enabled' in body));
  });

  test('knobs: sender override, extra redirects, min length floor, HIBP', () => {
    const { body } = buildAuthConfig({
      ...GOOD,
      AUTH_SMTP_SENDER_EMAIL: 'auth@example.com',
      AUTH_SMTP_SENDER_NAME: 'Shop Accounts',
      AUTH_ADDITIONAL_REDIRECT_URLS: 'https://staging.example.com/**',
      AUTH_PASSWORD_MIN_LENGTH: '12',
      AUTH_PASSWORD_HIBP: '1',
    });
    assert.equal(body.smtp_admin_email, 'auth@example.com');
    assert.equal(body.smtp_sender_name, 'Shop Accounts');
    assert.ok(body.uri_allow_list.endsWith(',https://staging.example.com/**'));
    assert.equal(body.password_min_length, 12);
    assert.equal(body.password_hibp_enabled, true);
    assert.throws(() => buildAuthConfig({ ...GOOD, AUTH_PASSWORD_MIN_LENGTH: '6' }), /between 8/);
  });

  test('diff ignores smtp_pass and allow-list order', () => {
    const { body } = buildAuthConfig(GOOD);
    const current = { ...body, smtp_pass: null, uri_allow_list: body.uri_allow_list.split(',').reverse().join(', ') };
    assert.deepEqual(diffAuthConfig(body, current), []);
    assert.deepEqual(diffAuthConfig(body, { ...current, mailer_autoconfirm: true, smtp_port: 465 }), ['mailer_autoconfirm']);
  });

  test('EMAIL_FROM parsing', () => {
    assert.deepEqual(parseEmailFrom('"Shine Spa" <hi@shine.example>'), { name: 'Shine Spa', address: 'hi@shine.example' });
    assert.deepEqual(parseEmailFrom('hi@shine.example'), { name: null, address: 'hi@shine.example' });
    assert.throws(() => parseEmailFrom('nope'));
  });
});
