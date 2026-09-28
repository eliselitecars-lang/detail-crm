// scripts/deploy/verify_live.mjs against a fake live project (fakes/fake_live.mjs):
// a correct deploy passes, each deploy mistake is caught with a readable reason.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { join } from 'node:path';
import { describe, test } from 'node:test';
import { REPO_ROOT } from '../lib/config.mjs';
import { startFakeLive } from './fakes/fake_live.mjs';

const SCRIPT = join(REPO_ROOT, 'scripts', 'deploy', 'verify_live.mjs');
const REF = 'abcdefghijklmnopqrst';
const ANON = 'anon-key-for-tests';
const SERVICE = 'service-key-SECRET-for-tests';
const TOKEN = 'sbp_verify_SECRET';
const APP = 'https://app.example.com';

async function verify({ faults = [], args = [], management = true, service = true, env: extraEnv = {}, billing } = {}) {
  const live = await startFakeLive({ ref: REF, anon: ANON, service: SERVICE, token: TOKEN, app: APP, faults, billing });
  try {
    const env = {
      PATH: process.env.PATH,
      APP_BASE_URL: APP,
      SUPABASE_URL: live.url,
      SUPABASE_PROJECT_REF: REF,
      SUPABASE_ANON_KEY: ANON,
      DEPLOY_SUPABASE_API_BASE: live.url,
      ...(management ? { SUPABASE_ACCESS_TOKEN: TOKEN } : {}),
      ...(service ? { SUPABASE_SERVICE_ROLE_KEY: SERVICE } : {}),
      ...extraEnv,
    };
    return await new Promise((resolve, reject) => {
      const child = spawn(process.execPath, [SCRIPT, ...args], { env });
      let out = '';
      child.stdout.on('data', (d) => (out += d));
      child.stderr.on('data', (d) => (out += d));
      child.on('error', reject);
      child.on('close', (code) => resolve({ code, out }));
    });
  } finally {
    await live.close();
  }
}

describe('verify_live.mjs', () => {
  test('a correct deploy passes with no KNOWN defect left (unknown public tokens are 404 PT404)', async () => {
    const r = await verify();
    assert.equal(r.code, 0, r.out);
    assert.match(r.out, /0 failed, 0 known/);
    assert.doesNotMatch(r.out, /^KNOWN /m);
    for (const name of [
      'rest: an unknown public token answers HTTP 404 PT404',
      'rest: public rpc public_get_quote is exposed to anon',
      'anon cannot read tenant tables',
      'verify_jwt=true',
      'CORS allows exactly',
      'job-photos and signatures are not public',
      'realtime: websocket',
      'deployed functions carry',
      'cron jobs',
      'fn billing: plans without a user session is 401',
      'fn billing: a client-sent price on checkout is 400',
      'fn billing: sync_plans without x-cron-secret is 401',
      'fn billing-webhook: an unsigned request is 400 invalid_signature',
      'fn billing-webhook: a forged signature is 400',
      'fn billing-webhook: verify_jwt=false',
      'management: billing config',
    ]) {
      assert.match(r.out, new RegExp(`PASS  [^\\n]*${name.replace(/[()]/g, '\\$&')}`), `${name}:\n${r.out}`);
    }
    assert.ok(!r.out.includes(SERVICE) && !r.out.includes(TOKEN), 'keys must not be printed');
  });

  test('--strict passes a correct deploy (no known defects remain)', async () => {
    const r = await verify({ args: ['--strict'] });
    assert.equal(r.code, 0, r.out);
    assert.match(r.out, /0 failed/);
  });

  test('a regression to HTTP 500 P0002 for an unknown public token FAILs (not KNOWN), also without --strict', async () => {
    const r = await verify({ faults: ['public-token-500'] });
    assert.equal(r.code, 1, r.out);
    assert.match(r.out, /FAIL  rest: an unknown public token answers HTTP 404 PT404[\s\S]*HTTP 500 [^\n]*P0002/);
    assert.match(r.out, /FAIL  rest: public rpc public_get_quote is exposed to anon[\s\S]*never a 5xx/);
    assert.doesNotMatch(r.out, /^KNOWN /m);
  });

  test('anon-key only: site_url is inferred from GoTrue redirects; service/management checks skip', async () => {
    const r = await verify({ management: false, service: false });
    assert.equal(r.code, 0, r.out);
    assert.match(r.out, /PASS  auth: site_url[^\n]*foreign redirect falls back to APP_BASE_URL/);
    assert.match(r.out, /SKIP  storage: bucket settings/);
    assert.match(r.out, /SKIP  management: deployed functions/);
  });

  for (const [fault, expect] of [
    ['webhook-verify-jwt', /FAIL  fn stripe-webhook: verify_jwt=false[\s\S]*deployed with verify_jwt=true/],
    ['anon-reads-shops', /FAIL  rest: anon cannot read tenant tables[\s\S]*shops: HTTP 200/],
    ['photos-public', /FAIL  storage: job-photos and signatures are not public[\s\S]*job-photos answers a public-URL request like a public bucket/],
    ['autoconfirm', /FAIL  auth: settings[\s\S]*email confirmations are OFF/],
    ['cors-wildcard', /FAIL  fn payments: CORS allows exactly[\s\S]*allow-origin=\*/],
    ['cron-secret-missing', /FAIL  fn messaging: process_queue[\s\S]*server_misconfigured[\s\S]*function secret is missing/],
    ['app-url-mismatch', /FAIL  fn messaging: unsubscribe GET[\s\S]*old\.example\.com/],
    ['cron-missing', /FAIL  management: platform setup[\s\S]*detail-crm-expire-quotes/],
  ]) {
    test(`catches: ${fault}`, async () => {
      const r = await verify({ faults: [fault] });
      assert.equal(r.code, 1, r.out);
      assert.match(r.out, expect);
    });
  }

  test('billing: a missing billing webhook secret is a SKIP while billing is off, a FAIL when it is on', async () => {
    const off = await verify({ faults: ['billing-secret-missing'] });
    assert.equal(off.code, 0, off.out);
    assert.match(off.out, /SKIP  fn billing-webhook: a forged signature[^\n]*STRIPE_BILLING_WEBHOOK_SECRET is not set/);
    const on = await verify({ faults: ['billing-secret-missing'], env: { BILLING_ENABLED: 'true' }, billing: { enabled: true, trialDays: 0 } });
    assert.equal(on.code, 1, on.out);
    assert.match(on.out, /FAIL  fn billing-webhook: a forged signature[\s\S]*server_misconfigured/);
  });

  test('billing: the project config must match the deploy inputs; billing deployed with verify_jwt=true is caught', async () => {
    const ok = await verify({ env: { BILLING_ENABLED: 'true', BILLING_TRIAL_DAYS: '14' }, billing: { enabled: true, trialDays: 14 } });
    assert.equal(ok.code, 0, ok.out);
    assert.match(ok.out, /PASS  management: billing config[^\n]*billing ON, trial 14 day\(s\)/);
    const mismatch = await verify({ env: { BILLING_ENABLED: 'true' }, billing: { enabled: false, trialDays: 0 } });
    assert.equal(mismatch.code, 1, mismatch.out);
    assert.match(mismatch.out, /FAIL  management: billing config[\s\S]*billing is off in the project but BILLING_ENABLED=true/);
    const jwt = await verify({ faults: ['billing-verify-jwt'] });
    assert.equal(jwt.code, 1, jwt.out);
    assert.match(jwt.out, /FAIL  fn billing: verify_jwt=false[\s\S]*deployed with verify_jwt=true/);
  });

  test('catches a site_url that is not APP_BASE_URL without the Management API', async () => {
    const r = await verify({ faults: ['site-url-localhost'], management: false });
    assert.equal(r.code, 1, r.out);
    assert.match(r.out, /FAIL  auth: site_url[\s\S]*site_url is not APP_BASE_URL \(fallback went to http:\/\/localhost:3000\)/);
  });
});
