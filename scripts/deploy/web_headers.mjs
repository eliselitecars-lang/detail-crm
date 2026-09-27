#!/usr/bin/env node
// Generates <dist>/_headers and <dist>/_redirects for the static web app AFTER
// `vite build` (Cloudflare Pages format; see docs/DEPLOY.md "Web hosting").
//
//   VITE_SUPABASE_URL=https://<ref>.supabase.co node scripts/deploy/web_headers.mjs --dist web/dist
//     [--embed-path '/book/*' ...]   paths other sites may iframe (default: none)
//     [--embed-ancestors '*']        frame-ancestors for those paths
//     [--host cloudflare|netlify]    _redirects flavour (default cloudflare)
//     [--report-uri URL]             add a CSP report-uri
//     [--print]                      also print the files
//
// CSP = exactly what the app loads (audited from web/src + web/index.html;
// scripts/deploy/test/web_headers.test.mjs fails when a new external origin
// appears in web/src):
//   - scripts: same origin + the sha256 of each inline <script> in index.html
//     (the pre-paint theme snippet), nothing else
//   - styles: same origin, Google Fonts CSS, and the hash of an EMPTY inline
//     <style> (FullCalendar creates an empty <style data-fullcalendar> and
//     fills it through CSSOM insertRule, which CSP does not govern)
//   - fonts: same origin, fonts.gstatic.com, data: (FullCalendar's icon font
//     is a data: URI inside the CSS it injects)
//   - images: same origin, data: (signature pad), blob: (local previews),
//     the Supabase origin (Storage public + signed URLs)
//   - connect: same origin, Supabase https + wss (REST/Auth/Functions/Storage/
//     Realtime), NHTSA vPIC (VIN decode in jobs/customers)
//   - Stripe Checkout / Connect onboarding and Google Maps are top-level
//     navigations (window.location / links), which CSP does not restrict.
//   - no 'unsafe-eval': zod 4 probes `new Function` once (caught, falls back)
//     unless the app sets z.config({ jitless: true }) before building any
//     schema; see csp_proof.mjs KNOWN_VIOLATIONS.
// Staff/app routes: frame-ancestors 'none' + X-Frame-Options DENY. Only
// --embed-path routes may be framed (neither SPEC nor web/src has an embed
// route yet: "booking embed" is on the SPEC §9 roadmap).
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

/** Third-party origins the built app talks to, with where in web/ they come from. */
export const KNOWN_EXTERNAL = {
  'fonts.googleapis.com': { directive: 'style-src', source: 'web/index.html <link rel=stylesheet> (Inter)' },
  'fonts.gstatic.com': { directive: 'font-src', source: 'font files referenced by the Google Fonts CSS' },
  'vpic.nhtsa.dot.gov': { directive: 'connect-src', source: 'web/src/features/{jobs,customers}/vin.ts (VIN decode)' },
  'www.google.com': { directive: null, source: 'web/src/features/jobs/model.ts Google Maps link (navigation only)' },
};

/** sha256 of the empty string: allows only EMPTY inline <style> elements. */
export const EMPTY_STYLE_HASH = "'sha256-47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU='";

export const PERMISSIONS_POLICY =
  'accelerometer=(), camera=(), display-capture=(), geolocation=(), gyroscope=(), magnetometer=(), microphone=(), midi=(), payment=(), serial=(), usb=()';

const CF_MAX_LINE = 2000; // Cloudflare Pages _headers line limit
const CF_MAX_RULES = 100;

export class HeadersError extends Error {}

export function cspHash(text) {
  return `'sha256-${createHash('sha256').update(text, 'utf8').digest('base64')}'`;
}

/**
 * Inline <script>/<style> hashes of the built index.html, plus anything a
 * hash cannot allow (inline event handlers, style attributes, javascript:
 * URLs), which is reported as a problem.
 */
export function inlineHashes(html) {
  const scripts = [];
  const styles = [];
  const problems = [];
  for (const m of html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi)) {
    if (/\bsrc\s*=/.test(m[1])) continue;
    if (/\btype\s*=\s*["']?application\/(ld\+)?json/i.test(m[1])) continue; // data blocks never execute
    scripts.push(cspHash(m[2]));
  }
  for (const m of html.matchAll(/<style\b[^>]*>([\s\S]*?)<\/style>/gi)) styles.push(cspHash(m[1]));
  const withoutScripts = html.replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, '');
  if (/<[^>]+\son[a-z]+\s*=/i.test(withoutScripts)) problems.push('index.html has an inline event handler (on...=): CSP cannot allow it by hash');
  if (/<[^>]+\sstyle\s*=/i.test(withoutScripts)) problems.push('index.html has a style="" attribute: CSP cannot allow it by hash');
  if (/javascript:/i.test(withoutScripts)) problems.push('index.html has a javascript: URL');
  return { scripts: [...new Set(scripts)], styles: [...new Set(styles)], problems };
}

export function supabaseOrigins(raw) {
  let url;
  try {
    url = new URL(raw);
  } catch {
    throw new HeadersError('VITE_SUPABASE_URL is not a URL');
  }
  if (url.protocol !== 'https:') throw new HeadersError('VITE_SUPABASE_URL must be https:// (the browser app talks to it over TLS)');
  return { https: url.origin, wss: `wss://${url.host}` };
}

export function buildCsp({ supabaseUrl, scriptHashes = [], styleHashes = [], frameAncestors = "'none'", reportUri }) {
  const sb = supabaseOrigins(supabaseUrl);
  const directives = [
    ["default-src", "'self'"],
    ['script-src', "'self'", ...scriptHashes],
    ['style-src', "'self'", 'https://fonts.googleapis.com', EMPTY_STYLE_HASH, ...styleHashes],
    ['font-src', "'self'", 'https://fonts.gstatic.com', 'data:'],
    ['img-src', "'self'", 'data:', 'blob:', sb.https],
    ['connect-src', "'self'", sb.https, sb.wss, 'https://vpic.nhtsa.dot.gov'],
    ['frame-src', "'none'"],
    ['object-src', "'none'"],
    ['base-uri', "'self'"],
    ['form-action', "'self'"],
    ['manifest-src', "'self'"],
    ['frame-ancestors', frameAncestors],
  ];
  if (reportUri) directives.push(['report-uri', reportUri]);
  return directives.map((d) => [...new Set(d)].join(' ')).join('; ');
}

function validateEmbedPath(p) {
  if (!/^\/[A-Za-z0-9_\-./:*]*$/.test(p)) throw new HeadersError(`--embed-path "${p}" is not a path pattern`);
  if ((p.match(/\*/g) ?? []).length > 1) throw new HeadersError(`--embed-path "${p}": only one * is allowed`);
  if (p === '/*' || p === '/' || p.startsWith('/app') || p.startsWith('/assets')) {
    throw new HeadersError(`--embed-path "${p}" would make staff pages frameable`);
  }
}

/** The _headers file (Cloudflare Pages semantics, see lib/static_server.mjs). */
export function buildHeadersFile({ supabaseUrl, html, embedPaths = [], embedAncestors = '*', reportUri }) {
  const { scripts, styles, problems } = inlineHashes(html);
  if (problems.length) throw new HeadersError(problems.join('; '));
  for (const p of embedPaths) validateEmbedPath(p);
  if (!/^(\*|'self'|'none'|https:\/\/[^\s;,]+)( (\*|'self'|https:\/\/[^\s;,]+))*$/.test(embedAncestors)) {
    throw new HeadersError(`--embed-ancestors "${embedAncestors}" is not a frame-ancestors source list`);
  }
  const csp = buildCsp({ supabaseUrl, scriptHashes: scripts, styleHashes: styles, reportUri });
  const embedCsp = buildCsp({ supabaseUrl, scriptHashes: scripts, styleHashes: styles, frameAncestors: embedAncestors, reportUri });
  const lines = [
    '# Generated by scripts/deploy/web_headers.mjs after `vite build`. Do not edit:',
    '# it is regenerated on every deploy (hashes follow web/index.html).',
    '# Cloudflare Pages: every matching rule applies in file order; a header set',
    '# twice is joined with ", "; "! Name" first removes it (per rule).',
    '/*',
    `  Content-Security-Policy: ${csp}`,
    '  X-Frame-Options: DENY',
    '  Strict-Transport-Security: max-age=31536000; includeSubDomains',
    '  X-Content-Type-Options: nosniff',
    '  Referrer-Policy: strict-origin-when-cross-origin',
    `  Permissions-Policy: ${PERMISSIONS_POLICY}`,
    '  Cross-Origin-Opener-Policy: same-origin',
    '  Cache-Control: no-cache',
    '',
    '# Vite content-hashed bundles never change: cache for a year.',
    '/assets/*',
    '  ! Cache-Control',
    '  Cache-Control: public, max-age=31536000, immutable',
  ];
  for (const p of embedPaths) {
    lines.push('', `# Embeddable (booking embed): framing allowed from ${embedAncestors}.`, p, '  ! Content-Security-Policy', '  ! X-Frame-Options', `  Content-Security-Policy: ${embedCsp}`);
  }
  const text = `${lines.join('\n')}\n`;
  const long = text.split('\n').filter((l) => l.length > CF_MAX_LINE);
  if (long.length) throw new HeadersError(`a _headers line exceeds Cloudflare's ${CF_MAX_LINE}-character limit`);
  const rules = text.split('\n').filter((l) => /^\//.test(l)).length;
  if (rules > CF_MAX_RULES) throw new HeadersError(`more than ${CF_MAX_RULES} _headers rules`);
  return { text, csp, embedCsp, scriptHashes: scripts, styleHashes: styles };
}

export function buildRedirectsFile({ host = 'cloudflare' } = {}) {
  if (host === 'cloudflare') {
    return [
      '# Generated by scripts/deploy/web_headers.mjs.',
      '# SPA fallback: Cloudflare Pages serves /index.html (200) for any path that is',
      '# not a file as long as the build has no top-level 404.html (checked by the',
      '# generator). A "/* /index.html 200" rule is NOT used: Pages ignores it as an',
      '# infinite loop. Add real redirects below this line if ever needed.',
      '',
    ].join('\n');
  }
  if (host === 'netlify') {
    return ['# Generated by scripts/deploy/web_headers.mjs: SPA fallback.', '/*    /index.html   200', ''].join('\n');
  }
  throw new HeadersError(`unknown --host ${host} (cloudflare | netlify)`);
}

export function generate({ dist, supabaseUrl, embedPaths = [], embedAncestors = '*', host = 'cloudflare', reportUri }) {
  const indexPath = join(dist, 'index.html');
  if (!existsSync(indexPath)) throw new HeadersError(`${indexPath} not found: run vite build first`);
  if (!existsSync(join(dist, 'assets'))) throw new HeadersError(`${join(dist, 'assets')} not found: not a Vite build output`);
  if (host === 'cloudflare' && existsSync(join(dist, '404.html'))) {
    throw new HeadersError('dist/404.html exists: Cloudflare Pages would stop serving the SPA fallback');
  }
  const html = readFileSync(indexPath, 'utf8');
  const headers = buildHeadersFile({ supabaseUrl, html, embedPaths, embedAncestors, reportUri });
  const redirects = buildRedirectsFile({ host });
  writeFileSync(join(dist, '_headers'), headers.text);
  writeFileSync(join(dist, '_redirects'), redirects);
  return { ...headers, redirects };
}

function parseArgs(argv) {
  const out = { embedPaths: [], host: 'cloudflare', embedAncestors: process.env.WEB_EMBED_ANCESTORS || '*' };
  for (const p of (process.env.WEB_EMBED_PATHS ?? '').split(',').map((s) => s.trim()).filter(Boolean)) out.embedPaths.push(p);
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const next = () => {
      const v = argv[++i];
      if (v === undefined) throw new HeadersError(`${a} needs a value`);
      return v;
    };
    if (a === '--dist') out.dist = next();
    else if (a === '--supabase-url') out.supabaseUrl = next();
    else if (a === '--embed-path') out.embedPaths.push(next());
    else if (a === '--embed-ancestors') out.embedAncestors = next();
    else if (a === '--host') out.host = next();
    else if (a === '--report-uri') out.reportUri = next();
    else if (a === '--print') out.print = true;
    else throw new HeadersError(`unknown argument ${a}`);
  }
  return out;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const args = parseArgs(process.argv.slice(2));
    if (!args.dist) throw new HeadersError('--dist <build dir> is required');
    const supabaseUrl = args.supabaseUrl ?? process.env.VITE_SUPABASE_URL;
    if (!supabaseUrl) throw new HeadersError('VITE_SUPABASE_URL (or --supabase-url) is required');
    const out = generate({ ...args, supabaseUrl });
    console.log(`wrote ${join(args.dist, '_headers')} (${out.scriptHashes.length} inline script hash(es); embeddable: ${args.embedPaths.join(', ') || 'none'})`);
    console.log(`wrote ${join(args.dist, '_redirects')} (${args.host})`);
    if (args.print) console.log(`\n${out.text}\n${out.redirects}`);
  } catch (err) {
    console.error(`web_headers: ${err.message}`);
    process.exit(1);
  }
}
