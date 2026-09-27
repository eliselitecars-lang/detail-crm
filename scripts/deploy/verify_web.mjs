#!/usr/bin/env node
// Checks that a deployed web build serves the headers web_headers.mjs
// generated (the host really applied _headers) and the SPA fallback works.
//
//   node scripts/deploy/verify_web.mjs <https://deployment-url> --dist web/dist
//
// For each probe path it compares the security + cache headers the host sent
// with what dist/_headers says (evaluated with Cloudflare Pages semantics,
// lib/static_server.mjs). Exit 1 on any mismatch.
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { applyHeaderRules, parseHeadersFile } from './lib/static_server.mjs';

const [base, ...rest] = process.argv.slice(2);
const dist = rest.includes('--dist') ? rest[rest.indexOf('--dist') + 1] : 'web/dist';
if (!base || !/^https?:\/\//.test(base)) {
  console.error('usage: node scripts/deploy/verify_web.mjs <https://deployment-url> [--dist web/dist]');
  process.exit(64);
}
const { rules } = parseHeadersFile(readFileSync(join(dist, '_headers'), 'utf8'));
const asset = readdirSync(join(dist, 'assets')).find((f) => f.endsWith('.js'));
const CHECKED = ['content-security-policy', 'x-frame-options', 'strict-transport-security', 'x-content-type-options', 'referrer-policy', 'permissions-policy', 'cross-origin-opener-policy', 'cache-control'];
const probes = ['/', '/login', '/app/jobs/verify-web', `/book/verify-web`, ...(asset ? [`/assets/${asset}`] : [])];

let failed = 0;
for (const path of probes) {
  const url = new URL(path, base).toString();
  let res;
  try {
    res = await fetch(url, { redirect: 'manual', signal: AbortSignal.timeout(20_000) });
  } catch (err) {
    console.log(`FAIL  ${path}: ${err.message}`);
    failed++;
    continue;
  }
  const want = applyHeaderRules(rules, path, {}, new URL(base).hostname);
  const problems = [];
  if (res.status !== 200) problems.push(`HTTP ${res.status}${path.startsWith('/app') ? ' (SPA fallback missing: is there a 404.html?)' : ''}`);
  for (const name of CHECKED) {
    const expected = want.get(name);
    const got = res.headers.get(name);
    if (expected !== undefined && got !== expected) problems.push(`${name}: expected ${JSON.stringify(expected.slice(0, 80))}${expected.length > 80 ? '…' : ''}, got ${JSON.stringify(got?.slice(0, 80) ?? null)}`);
    if (expected === undefined && name === 'x-frame-options' && got) problems.push(`x-frame-options should be absent, got ${got}`);
  }
  if (path.startsWith('/app') && !(await res.text()).includes('id="root"')) problems.push('SPA fallback did not serve index.html');
  console.log(`${problems.length ? 'FAIL' : 'PASS'}  ${path}${problems.length ? `\n      ${problems.join('\n      ')}` : ''}`);
  if (problems.length) failed++;
}
console.log(`\n${probes.length - failed}/${probes.length} paths serve the generated headers`);
process.exit(failed ? 1 : 0);
