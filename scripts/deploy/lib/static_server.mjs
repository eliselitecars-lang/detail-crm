#!/usr/bin/env node
// A tiny static server that behaves like Cloudflare Pages for a Vite SPA build:
//   - `_headers` rules applied with Pages' semantics (mirrors
//     workers-sdk pages-shared asset-server, as bundled in wrangler 4.x:
//     parseHeaders + generateRulesMatcher + attachHeaders): rules match in
//     file order, "! Name" deletes the header first, a header set by an
//     earlier rule is APPENDED to (joined with ", "), header names are
//     lower-cased, lines over 2000 chars / more than 100 rules are ignored.
//   - SPA mode: without a top-level 404.html every path that is not a file
//     is answered with /index.html and 200.
//   - `_headers` / `_redirects` themselves are never served.
// Used by scripts/deploy/csp_proof.mjs; also handy to preview a build:
//   node scripts/deploy/lib/static_server.mjs <dist> [port]
import { existsSync, readFileSync, statSync } from 'node:fs';
import { createServer } from 'node:http';
import { extname, join, normalize, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const MAX_LINE = 2000;
const MAX_RULES = 100;
const LINE_IS_PATH = /^([^\s]+:\/\/|^\/)/;

/** Parses a _headers file into [{path, set: {name: value}, unset: [name]}] (+ invalid lines). */
export function parseHeadersFile(input) {
  const rules = [];
  const invalid = [];
  let rule;
  const push = () => {
    if (!rule) return;
    if (Object.keys(rule.set).length || rule.unset.length) rules.push(rule);
    else invalid.push({ line: rule.line, message: 'No headers specified' });
  };
  const lines = input.split('\n');
  for (let i = 0; i < lines.length; i++) {
    const line = (lines[i] || '').trim();
    if (!line || line.startsWith('#')) continue;
    if (line.length > MAX_LINE) {
      invalid.push({ lineNumber: i + 1, message: `line exceeds ${MAX_LINE} characters (ignored)` });
      continue;
    }
    if (LINE_IS_PATH.test(line)) {
      push();
      if (rules.length >= MAX_RULES) {
        invalid.push({ lineNumber: i + 1, message: `more than ${MAX_RULES} rules (rest ignored)` });
        rule = undefined;
        break;
      }
      if ((line.match(/\*/g) ?? []).length > 1) {
        invalid.push({ lineNumber: i + 1, message: 'only one * per rule' });
        rule = undefined;
        continue;
      }
      rule = { path: line, line, set: {}, unset: [] };
      continue;
    }
    if (!rule) {
      invalid.push({ lineNumber: i + 1, message: 'header before any path' });
      continue;
    }
    if (!line.includes(':')) {
      if (line.startsWith('! ')) rule.unset.push(line.slice(2).trim().toLowerCase());
      else invalid.push({ lineNumber: i + 1, message: 'expected "name: value"' });
      continue;
    }
    const [rawName, ...rest] = line.split(':');
    const name = rawName.trim().toLowerCase();
    const value = rest.join(':').trim();
    if (!name || name.includes(' ') || !value) {
      invalid.push({ lineNumber: i + 1, message: 'bad header line' });
      continue;
    }
    rule.set[name] = rule.set[name] !== undefined ? `${rule.set[name]}, ${value}` : value;
  }
  push();
  // Pages keys rules by path (a later block with the same path replaces the earlier one).
  const byPath = new Map();
  for (const r of rules) byPath.set(r.path, r);
  return { rules: [...byPath.values()], invalid };
}

function escapeRegex(s) {
  return s.replace(/[-/\\^$*+?.()|[\]{}]/g, '\\$&');
}
export function ruleRegExp(path) {
  let rule = path.split('*').map(escapeRegex).join('(?<splat>.*)');
  for (const m of rule.matchAll(/:([A-Za-z]\w*)/g)) rule = rule.split(m[0]).join(`(?<${m[1]}>[^/]+)`);
  return new RegExp(`^${rule}$`);
}

/**
 * Effective headers for `pathname`: `base` (what Pages sends anyway) with the
 * matching rules applied in order. Returns a Map of lower-case name -> value.
 */
export function applyHeaderRules(rules, pathname, base = {}, host = 'localhost') {
  const headers = new Map(Object.entries(base).map(([k, v]) => [k.toLowerCase(), v]));
  const setByRules = new Set();
  for (const rule of rules) {
    const target = rule.path.startsWith('https://') ? `https://${host}${pathname}` : pathname;
    const m = ruleRegExp(rule.path).exec(target);
    if (!m) continue;
    for (const name of rule.unset) headers.delete(name);
    for (const [name, raw] of Object.entries(rule.set)) {
      let value = raw;
      for (const [k, v] of Object.entries(m.groups ?? {})) value = value.split(`:${k}`).join(v ?? '');
      if (setByRules.has(name) && headers.has(name)) headers.set(name, `${headers.get(name)}, ${value}`);
      else {
        headers.set(name, value);
        setByRules.add(name);
      }
    }
  }
  return headers;
}

const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'application/javascript',
  '.mjs': 'application/javascript',
  '.css': 'text/css; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.json': 'application/json',
  '.map': 'application/json',
  '.webmanifest': 'application/manifest+json',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.ico': 'image/x-icon',
  '.woff2': 'font/woff2',
  '.txt': 'text/plain; charset=utf-8',
};

/** Starts the server. `headersFile` overrides <dir>/_headers (to serve variants of one build). */
export function startStaticServer({ dir, port = 0, host = '127.0.0.1', headersFile } = {}) {
  const root = resolve(dir);
  const hf = headersFile ?? join(root, '_headers');
  const { rules } = existsSync(hf) ? parseHeadersFile(readFileSync(hf, 'utf8')) : { rules: [] };
  const spa = !existsSync(join(root, '404.html'));
  const server = createServer((req, res) => {
    const url = new URL(req.url ?? '/', 'http://localhost');
    let pathname;
    try {
      pathname = decodeURIComponent(url.pathname);
    } catch {
      res.writeHead(400).end();
      return;
    }
    let file = normalize(join(root, pathname));
    if (!file.startsWith(root + sep) && file !== root) {
      res.writeHead(403).end();
      return;
    }
    if (existsSync(file) && statSync(file).isDirectory()) file = join(file, 'index.html');
    const hidden = /\/_(headers|redirects)$/.test(pathname);
    let status = 200;
    if (hidden || !existsSync(file)) {
      if (spa) file = join(root, 'index.html');
      else {
        file = join(root, '404.html');
        status = 404;
      }
    }
    const body = readFileSync(file);
    const base = {
      'content-type': TYPES[extname(file)] ?? 'application/octet-stream',
      'cache-control': 'public, max-age=0, must-revalidate',
      'access-control-allow-origin': '*',
    };
    const headers = applyHeaderRules(rules, url.pathname, base, req.headers.host?.split(':')[0]);
    res.writeHead(status, Object.fromEntries(headers));
    res.end(req.method === 'HEAD' ? undefined : body);
  });
  return new Promise((resolvePromise) => {
    server.listen(port, host, () => {
      const addr = server.address();
      resolvePromise({ url: `http://${host}:${addr.port}`, rules, close: () => new Promise((r) => server.close(() => r())) });
    });
  });
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const dir = process.argv[2];
  if (!dir) {
    console.error('usage: node scripts/deploy/lib/static_server.mjs <dist> [port]');
    process.exit(64);
  }
  const s = await startStaticServer({ dir, port: Number(process.argv[3] ?? 4173) });
  console.log(`serving ${dir} at ${s.url} (${s.rules.length} _headers rules, Cloudflare Pages semantics)`);
}
