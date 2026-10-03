#!/usr/bin/env node
// Proves the public tunnel reaches the CI stack the way the iPhone app will
// use it, before .github/workflows/screenshots.yml publishes it: GoTrue
// health, a password sign-in for each demo login, a PostgREST read of the
// demo shop with that session (RLS applies), and the edge-function gateway.
// Retries while a fresh quick-tunnel hostname is still propagating.
//
//   node ios/screenshots/verify_tunnel.mjs <backend.json>
//
// backend.json: { tunnelUrl, anonKey, shop: { id }, owner: { email, password },
// technician?: { email, password } }

import { readFileSync } from 'node:fs';

const file = process.argv[2];
if (!file) {
  console.error('usage: node ios/screenshots/verify_tunnel.mjs <backend.json>');
  process.exit(2);
}
const backend = JSON.parse(readFileSync(file, 'utf8'));
const base = String(backend.tunnelUrl || '').replace(/\/+$/, '');
const anonKey = backend.anonKey;
if (!base.startsWith('https://') || !anonKey) throw new Error('backend.json needs tunnelUrl (https) and anonKey');

async function request(path, { method = 'GET', token = anonKey, json } = {}) {
  const res = await fetch(`${base}${path}`, {
    method,
    headers: {
      apikey: anonKey,
      authorization: `Bearer ${token}`,
      ...(json === undefined ? {} : { 'content-type': 'application/json' }),
    },
    body: json === undefined ? undefined : JSON.stringify(json),
    signal: AbortSignal.timeout(20_000),
  });
  const text = await res.text();
  let body = null;
  try {
    body = text ? JSON.parse(text) : null;
  } catch {
    body = text;
  }
  return { status: res.status, body };
}

async function signIn(label, who) {
  const res = await request('/auth/v1/token?grant_type=password', {
    method: 'POST',
    json: { email: who.email, password: who.password },
  });
  if (res.status !== 200 || !res.body?.access_token) {
    throw new Error(`${label} sign-in through the tunnel: HTTP ${res.status} ${JSON.stringify(res.body)}`);
  }
  return res.body.access_token;
}

async function verify() {
  const health = await request('/auth/v1/health');
  if (health.status !== 200) throw new Error(`auth health: HTTP ${health.status}`);
  const logins = [['owner', backend.owner]];
  if (backend.technician?.email) logins.push(['technician', backend.technician]);
  for (const [label, who] of logins) {
    const token = await signIn(label, who);
    const shops = await request(`/rest/v1/shops?select=id,name&id=eq.${backend.shop.id}`, { token });
    if (shops.status !== 200 || !Array.isArray(shops.body) || shops.body.length !== 1) {
      throw new Error(`${label} cannot read the demo shop: HTTP ${shops.status} ${JSON.stringify(shops.body)}`);
    }
    console.log(`ok   ${label} ${who.email} signs in and reads "${shops.body[0].name}" through ${base}`);
    if (label === 'owner') {
      const fn = await request('/functions/v1/payments', { method: 'POST', token, json: {} });
      const reached = typeof fn.body === 'object' && fn.body !== null && 'error' in fn.body;
      console.log(`${reached ? 'ok  ' : 'WARN'} edge functions answer through the tunnel (HTTP ${fn.status})`);
    }
  }
}

const deadline = Date.now() + 4 * 60_000;
for (let attempt = 1; ; attempt += 1) {
  try {
    await verify();
    break;
  } catch (error) {
    if (Date.now() > deadline) {
      console.error(`tunnel verification failed: ${error.message}`);
      process.exit(1);
    }
    console.log(`attempt ${attempt}: ${error.cause?.code ?? ''} ${error.message} — retrying`);
    await new Promise((done) => setTimeout(done, 5_000));
  }
}
