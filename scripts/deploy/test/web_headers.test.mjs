// Unit tests for scripts/deploy/web_headers.mjs and lib/static_server.mjs
// (Cloudflare Pages _headers semantics). node --test scripts/deploy/test/
import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { after, describe, test } from 'node:test';
import { REPO_ROOT } from '../lib/config.mjs';
import { applyHeaderRules, parseHeadersFile, startStaticServer } from '../lib/static_server.mjs';
import { buildCsp, buildHeadersFile, buildRedirectsFile, cspHash, EMPTY_STYLE_HASH, generate, inlineHashes, KNOWN_EXTERNAL, TRACKING_SOURCES } from '../web_headers.mjs';

const SB = 'https://abcdefghijklmnopqrst.supabase.co';
const THEME = "(function(){document.documentElement.dataset.theme='light'})();";
const HTML = `<!doctype html><html><head><script>${THEME}</script><script type="module" crossorigin src="/assets/index-abc.js"></script></head><body><div id="root"></div></body></html>`;
const tmp = mkdtempSync(join(tmpdir(), 'web-headers-test-'));
after(() => rmSync(tmp, { recursive: true, force: true }));

function effective(text, path) {
  return Object.fromEntries(applyHeaderRules(parseHeadersFile(text).rules, path, { 'cache-control': 'public, max-age=0, must-revalidate' }));
}

describe('inline hashes', () => {
  test('hashes inline scripts only; refuses what a hash cannot allow', () => {
    const r = inlineHashes(HTML);
    assert.deepEqual(r.scripts, [cspHash(THEME)]);
    assert.deepEqual(r.problems, []);
    assert.equal(cspHash(''), EMPTY_STYLE_HASH);
    assert.match(inlineHashes('<button onclick="x()">').problems[0], /event handler/);
    assert.match(inlineHashes('<div style="color:red">').problems[0], /style=/);
    assert.deepEqual(inlineHashes('<script type="application/ld+json">{}</script>').scripts, []);
  });

  test('the real web/index.html needs exactly one hash (the theme snippet) and nothing unsafe', () => {
    const r = inlineHashes(readFileSync(join(REPO_ROOT, 'web', 'index.html'), 'utf8'));
    assert.equal(r.scripts.length, 1);
    assert.deepEqual(r.problems, []);
  });
});

describe('CSP', () => {
  test('allows exactly the app origins and never unsafe-inline/unsafe-eval', () => {
    const csp = buildCsp({ supabaseUrl: SB, scriptHashes: ["'sha256-x'"] });
    const d = Object.fromEntries(csp.split('; ').map((p) => [p.split(' ')[0], p.split(' ').slice(1)]));
    assert.deepEqual(d['script-src'], ["'self'", "'sha256-x'"]);
    assert.deepEqual(d['connect-src'], ["'self'", SB, 'wss://abcdefghijklmnopqrst.supabase.co', 'https://vpic.nhtsa.dot.gov']);
    assert.deepEqual(d['img-src'], ["'self'", 'data:', 'blob:', SB, 'https://tile.openstreetmap.org']);
    assert.deepEqual(d['media-src'], ["'self'", 'blob:', SB]);
    assert.deepEqual(d['style-src'], ["'self'", 'https://fonts.googleapis.com', EMPTY_STYLE_HASH]);
    assert.deepEqual(d['font-src'], ["'self'", 'https://fonts.gstatic.com', 'data:']);
    assert.deepEqual(d['frame-ancestors'], ["'none'"]);
    assert.deepEqual(d['object-src'], ["'none'"]);
    assert.deepEqual(d['frame-src'], ["'none'"]);
    assert.ok(!/unsafe-/.test(csp));
    assert.throws(() => buildCsp({ supabaseUrl: 'http://127.0.0.1:54321' }), /https/);
    assert.match(buildCsp({ supabaseUrl: SB, reportUri: 'https://r.example.com/csp' }), /; report-uri https:\/\/r\.example\.com\/csp$/);
  });
});

describe('_headers (Cloudflare Pages semantics)', () => {
  const { text, csp, embedCsp } = buildHeadersFile({ supabaseUrl: SB, html: HTML });

  test('app routes: strict CSP, DENY, HSTS, nosniff, referrer, permissions, COOP, no-cache', () => {
    for (const path of ['/', '/login', '/app', '/app/jobs/123', '/book/shine', '/i/tok', '/portal', '/does-not-exist']) {
      const h = effective(text, path);
      assert.equal(h['content-security-policy'], csp, path);
      assert.match(csp, /frame-ancestors 'none'/);
      assert.equal(h['x-frame-options'], 'DENY', path);
      assert.equal(h['strict-transport-security'], 'max-age=31536000; includeSubDomains');
      assert.equal(h['x-content-type-options'], 'nosniff');
      assert.equal(h['referrer-policy'], 'strict-origin-when-cross-origin');
      assert.match(h['permissions-policy'], /camera=\(\)/);
      assert.equal(h['cross-origin-opener-policy'], 'same-origin');
      assert.equal(h['cache-control'], 'no-cache', path);
    }
  });

  test('hashed assets: one-year immutable cache, not joined with no-cache', () => {
    const h = effective(text, '/assets/index-abc123.js');
    assert.equal(h['cache-control'], 'public, max-age=31536000, immutable');
    assert.equal(h['content-security-policy'], csp);
  });

  test('embed paths: only they drop DENY and get frame-ancestors from --embed-ancestors', () => {
    const e = buildHeadersFile({ supabaseUrl: SB, html: HTML, embedPaths: ['/book/*'] });
    const book = effective(e.text, '/book/shine');
    assert.equal(book['content-security-policy'], e.embedCsp);
    assert.match(e.embedCsp, /frame-ancestors \*$/);
    assert.ok(!book['content-security-policy'].includes("'none', "), 'the strict policy must not be joined in');
    assert.equal(book['x-frame-options'], undefined);
    for (const path of ['/app', '/login', '/booking/tok', '/']) {
      assert.equal(effective(e.text, path)['x-frame-options'], 'DENY', path);
      assert.equal(effective(e.text, path)['content-security-policy'], e.csp, path);
    }
    assert.equal(embedCsp.replace("frame-ancestors *", "frame-ancestors 'none'"), csp);
    const limited = buildHeadersFile({ supabaseUrl: SB, html: HTML, embedPaths: ['/book/*'], embedAncestors: 'https://shop.example.com' });
    assert.match(effective(limited.text, '/book/x')['content-security-policy'], /frame-ancestors https:\/\/shop\.example\.com$/);
  });

  test('tracking paths: only /book/* and /booking/* may load the shop Meta Pixel / GA4 tag', () => {
    const t = buildHeadersFile({ supabaseUrl: SB, html: HTML, trackingPaths: ['/book/*', '/booking/*'] });
    const d = Object.fromEntries(t.trackingCsp.split('; ').map((p) => [p.split(' ')[0], p.split(' ').slice(1)]));
    assert.deepEqual(d['script-src'], ["'self'", cspHash(THEME), ...TRACKING_SOURCES['script-src']]);
    assert.ok(d['connect-src'].includes('https://*.google-analytics.com'));
    assert.ok(d['img-src'].includes('https://www.facebook.com'));
    assert.deepEqual(d['frame-ancestors'], ["'none'"]);
    assert.ok(!/unsafe-/.test(t.trackingCsp));
    for (const path of ['/book/shine', '/booking/0f0e']) {
      const h = effective(t.text, path);
      assert.equal(h['content-security-policy'], t.trackingCsp, path);
      assert.equal(h['x-frame-options'], 'DENY', path);
    }
    for (const path of ['/app', '/login', '/lead/tok', '/q/tok', '/portal']) {
      assert.equal(effective(t.text, path)['content-security-policy'], t.csp, path);
    }
    assert.ok(!t.csp.includes('facebook'), 'the default policy never allows tracking');
    // Embed + tracking on the same path: one framed policy that also allows the tags.
    const both = buildHeadersFile({ supabaseUrl: SB, html: HTML, embedPaths: ['/book/*', '/lead/*'], trackingPaths: ['/book/*'] });
    const book = effective(both.text, '/book/shine');
    assert.match(book['content-security-policy'], /connect\.facebook\.net/);
    assert.match(book['content-security-policy'], /frame-ancestors \*$/);
    assert.equal(book['x-frame-options'], undefined);
    const lead = effective(both.text, '/lead/tok');
    assert.equal(lead['content-security-policy'], both.embedCsp);
    assert.ok(!lead['content-security-policy'].includes('facebook'));
    assert.deepEqual(parseHeadersFile(both.text).invalid, []);
    for (const p of ['/*', '/app/*', '/lead/*', '/portal']) {
      assert.throws(() => buildHeadersFile({ supabaseUrl: SB, html: HTML, trackingPaths: [p] }), /only allowed/);
    }
  });

  test('refuses embed paths that would expose staff pages, and bad ancestors', () => {
    for (const p of ['/*', '/app/*', '/', '/assets/*']) assert.throws(() => buildHeadersFile({ supabaseUrl: SB, html: HTML, embedPaths: [p] }), /frameable|pattern/);
    assert.throws(() => buildHeadersFile({ supabaseUrl: SB, html: HTML, embedPaths: ['/book/*'], embedAncestors: "'unsafe-inline'" }), /source list/);
  });

  test('fits Cloudflare limits and parses without invalid lines', () => {
    const e = buildHeadersFile({ supabaseUrl: SB, html: HTML, embedPaths: ['/book/*', '/embed/*'] });
    assert.ok(e.text.split('\n').every((l) => l.length <= 2000));
    assert.deepEqual(parseHeadersFile(e.text).invalid, []);
  });

  test('_redirects: Cloudflare relies on SPA mode (no /* rule), Netlify gets the fallback', () => {
    assert.ok(!/^\/\*/m.test(buildRedirectsFile({ host: 'cloudflare' })));
    assert.match(buildRedirectsFile({ host: 'netlify' }), /^\/\*\s+\/index\.html\s+200$/m);
    assert.throws(() => buildRedirectsFile({ host: 'vercel' }), /unknown/);
  });
});

describe('static server = Cloudflare Pages rules', () => {
  test('documented examples: multiple rules merge, same header joins with ", ", "!" detaches', () => {
    const doc = `/secure/page\n  X-Frame-Options: DENY\n  X-Content-Type-Options: nosniff\n/static/*\n  Access-Control-Allow-Origin: *\n  X-Robots-Tag: nosnippet\nhttps://myproject.pages.dev/*\n  X-Robots-Tag: noindex\n`;
    const { rules } = parseHeadersFile(doc);
    const h = Object.fromEntries(applyHeaderRules(rules, '/static/styles.css', {}, 'myproject.pages.dev'));
    assert.equal(h['x-robots-tag'], 'nosnippet, noindex');
    const d = parseHeadersFile("/*\n  Content-Security-Policy: default-src 'self';\n/*.jpg\n  ! Content-Security-Policy\n").rules;
    assert.equal(Object.fromEntries(applyHeaderRules(d, '/a.jpg'))['content-security-policy'], undefined);
    assert.equal(Object.fromEntries(applyHeaderRules(d, '/a.png'))['content-security-policy'], "default-src 'self';");
  });

  test('serves files, SPA fallback with 200, hides _headers, applies rules', async () => {
    const dist = join(tmp, 'dist');
    mkdirSync(join(dist, 'assets'), { recursive: true });
    writeFileSync(join(dist, 'index.html'), HTML);
    writeFileSync(join(dist, 'assets', 'index-abc.js'), 'console.log(1)');
    generate({ dist, supabaseUrl: SB });
    const s = await startStaticServer({ dir: dist });
    try {
      const app = await fetch(`${s.url}/app/jobs/1`);
      assert.equal(app.status, 200);
      assert.match(await app.text(), /<div id="root">/);
      assert.equal(app.headers.get('cache-control'), 'no-cache');
      assert.match(app.headers.get('content-security-policy'), /frame-ancestors 'none'/);
      const js = await fetch(`${s.url}/assets/index-abc.js`);
      assert.equal(js.headers.get('cache-control'), 'public, max-age=31536000, immutable');
      assert.equal(js.headers.get('content-type'), 'application/javascript');
      const hidden = await fetch(`${s.url}/_headers`);
      assert.doesNotMatch(await hidden.text(), /Content-Security-Policy/);
    } finally {
      await s.close();
    }
  });

  test('generate() refuses a non-Vite dir and a 404.html (would disable SPA mode)', () => {
    const d = join(tmp, 'bad');
    mkdirSync(d, { recursive: true });
    assert.throws(() => generate({ dist: d, supabaseUrl: SB }), /index\.html not found/);
    writeFileSync(join(d, 'index.html'), HTML);
    mkdirSync(join(d, 'assets'));
    writeFileSync(join(d, '404.html'), 'x');
    assert.throws(() => generate({ dist: d, supabaseUrl: SB }), /404\.html/);
  });
});

describe('external origins used by web/ are all accounted for', () => {
  test('every https host literal in web/src (non-test) and web/index.html is in KNOWN_EXTERNAL', () => {
    const files = [];
    const walk = (dir) => {
      for (const name of readdirSync(dir)) {
        const p = join(dir, name);
        if (statSync(p).isDirectory()) walk(p);
        else if (/\.(ts|tsx|css)$/.test(name) && !/\.test\.|test-data|\/testing\/|\/test\//.test(p)) files.push(p);
      }
    };
    walk(join(REPO_ROOT, 'web', 'src'));
    files.push(join(REPO_ROOT, 'web', 'index.html'));
    const unknown = new Map();
    for (const f of files) {
      const src = readFileSync(f, 'utf8');
      for (const m of src.matchAll(/https?:\/\/([a-z0-9.-]+\.[a-z]{2,})/gi)) {
        const host = m[1].toLowerCase();
        if (KNOWN_EXTERNAL[host]) continue;
        // Documentation / placeholders / user-entered values, not resources the app loads.
        if (/(^|\.)(example\.(com|org|net)|test|invalid|localhost|w3\.org|supabase\.co)$/.test(host)) continue;
        const line = src.slice(0, m.index).split('\n').length;
        const text = src.split('\n')[line - 1].trim();
        if (/^(\*|\/\/|\/\*)/.test(text)) continue; // comments
        unknown.set(`${host}`, `${f.replace(REPO_ROOT + '/', '')}:${line}`);
      }
    }
    assert.deepEqual(
      Object.fromEntries(unknown),
      {},
      'web/ references an external origin the CSP does not know: add it to KNOWN_EXTERNAL and buildCsp in scripts/deploy/web_headers.mjs (and re-run csp_proof.mjs)',
    );
  });
});
