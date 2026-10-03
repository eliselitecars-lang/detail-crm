#!/usr/bin/env node
// Minimal stand-in for scripts/screenshots/seed_demo.mjs, used by
// .github/workflows/screenshots.yml only when that seed is not in the
// commit: an owner account (GoTrue sign-up), their shop (create_shop RPC)
// and two customers, all through the public APIs as the owner (RLS
// applies). No technician: the screenshot tour skips the technician part.
//
//   node ios/screenshots/fallback_seed.mjs <out.json>
//
// Reads scripts/stack/.state/stack.env (scripts/stack/up.sh) and writes the
// same JSON shape as the real seed: apiUrl, anonKey, shop, owner,
// technician (null). LOCAL / CI STACK ONLY.

import { randomBytes } from 'node:crypto';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const out = process.argv[2];
if (!out) {
  console.error('usage: node ios/screenshots/fallback_seed.mjs <out.json>');
  process.exit(2);
}

const env = Object.fromEntries(
  readFileSync(resolve(root, 'scripts/stack/.state/stack.env'), 'utf8')
    .split('\n')
    .filter((line) => /^[A-Z_]+=/.test(line))
    .map((line) => [line.slice(0, line.indexOf('=')), line.slice(line.indexOf('=') + 1)]),
);
const apiUrl = env.STACK_API_URL;
const anonKey = env.STACK_ANON_KEY;
if (!apiUrl || !anonKey) throw new Error('STACK_API_URL / STACK_ANON_KEY missing from stack.env');

async function call(path, { method = 'GET', token = anonKey, json, prefer } = {}) {
  const res = await fetch(`${apiUrl}${path}`, {
    method,
    headers: {
      apikey: anonKey,
      authorization: `Bearer ${token}`,
      ...(json === undefined ? {} : { 'content-type': 'application/json' }),
      ...(prefer ? { prefer } : {}),
    },
    body: json === undefined ? undefined : JSON.stringify(json),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`${method} ${path} -> HTTP ${res.status}: ${text}`);
  return text ? JSON.parse(text) : null;
}

const suffix = randomBytes(4).toString('hex');
const owner = {
  email: `owner-${suffix}@screenshots.test`,
  password: `Shots-${randomBytes(9).toString('base64url')}`,
  name: 'Sample Owner',
};
const signup = await call('/auth/v1/signup', {
  method: 'POST',
  json: { email: owner.email, password: owner.password, data: { full_name: owner.name } },
});
const token = signup.access_token;
if (!token) throw new Error('sign-up returned no session (is email confirmation on?)');

const shop = await call('/rest/v1/rpc/create_shop', {
  method: 'POST',
  token,
  json: { p_name: 'Sample Detail Shop', p_slug: `sample-${suffix}`, p_timezone: 'America/Chicago' },
});

for (const customer of [
  { first_name: 'Sample', last_name: 'Customer One', phone: '+12055550101' },
  { first_name: 'Sample', last_name: 'Customer Two', phone: '+12055550102' },
]) {
  try {
    await call('/rest/v1/customers', {
      method: 'POST',
      token,
      json: { shop_id: shop.id, ...customer },
      prefer: 'return=minimal',
    });
  } catch (error) {
    console.warn(`customer not created: ${error.message}`);
  }
}

const demo = {
  apiUrl,
  anonKey,
  shop: { id: shop.id, slug: shop.slug, name: shop.name, timeZone: 'America/Chicago' },
  owner,
  technician: null,
  client: null,
  links: {},
  fallback: true,
};
mkdirSync(dirname(resolve(out)), { recursive: true });
writeFileSync(out, `${JSON.stringify(demo, null, 2)}\n`);
console.log(`fallback seed: shop ${shop.name} (${shop.id}), owner ${owner.email} -> ${out}`);
