// In-process fake of the Supabase Management API + the Stripe webhook
// endpoints API + the deployed `billing` function (sync_plans), stateful
// enough to run scripts/deploy/deploy_backend.sh end to end
// (test/deploy_backend.test.mjs). Every request is recorded.
import { createHash, randomBytes } from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';
import { createServer } from 'node:http';

const sha = (v) => createHash('sha256').update(v, 'utf8').digest('hex');

export async function startFakeApi({ ref, deployedFile, token = 'sbp_fake', stripeKey, cronSecret }) {
  const state = {
    requests: [],
    secrets: new Map(),
    auth: { site_url: 'http://localhost:3000', uri_allow_list: '', mailer_autoconfirm: true, smtp_host: null },
    authPatches: [],
    sql: [],
    platformConfig: null,
    cronJobs: [],
    vault: [],
    endpoints: new Map(),
    endpointCreates: 0,
    // platform_config billing keys (set_billing_config) and billing sync_plans calls
    billingConfig: new Map(),
    billingConfigCalls: [],
    syncCalls: [],
    syncResponse: { status: 200, body: { upserted: 2, deactivated: 0, skipped: [], warnings: [] } },
  };
  const server = createServer(async (req, res) => {
    const chunks = [];
    for await (const c of req) chunks.push(c);
    const raw = Buffer.concat(chunks).toString('utf8');
    const url = new URL(req.url, 'http://fake');
    const path = url.pathname;
    const rec = { method: req.method, path, query: url.search, raw, auth: req.headers.authorization ?? null, ua: req.headers['user-agent'] ?? null };
    state.requests.push(rec);
    const send = (status, body) => {
      res.writeHead(status, { 'content-type': 'application/json' });
      res.end(body === undefined ? '' : JSON.stringify(body));
    };
    let body;
    try {
      body = raw && (req.headers['content-type'] ?? '').includes('json') ? JSON.parse(raw) : undefined;
    } catch {
      return send(400, { message: 'bad json' });
    }

    // ------------------------------------------------ Stripe
    if (path.startsWith('/v1/webhook_endpoints')) {
      if (req.headers.authorization !== `Bearer ${stripeKey}`) return send(401, { error: { message: 'bad key' } });
      const form = new URLSearchParams(raw);
      const parseForm = () => ({
        url: form.get('url'),
        connect: form.get('connect'),
        api_version: form.get('api_version'),
        enabled_events: form.getAll('enabled_events[]'),
        description: form.get('description'),
        metadata: Object.fromEntries([...form.entries()].filter(([k]) => k.startsWith('metadata[')).map(([k, v]) => [k.slice(9, -1), v])),
        disabled: form.get('disabled'),
      });
      const id = path.split('/')[3];
      if (req.method === 'GET' && !id) return send(200, { object: 'list', data: [...state.endpoints.values()].map(({ secret, ...e }) => e), has_more: false });
      if (req.method === 'POST' && !id) {
        const f = parseForm();
        const e = {
          id: `we_fake${randomBytes(6).toString('hex')}`,
          object: 'webhook_endpoint',
          url: f.url,
          api_version: f.api_version,
          enabled_events: f.enabled_events,
          description: f.description,
          metadata: f.metadata,
          status: 'enabled',
          connect: f.connect === 'true',
          secret: `whsec_fake${randomBytes(16).toString('hex')}`,
        };
        state.endpoints.set(e.id, e);
        state.endpointCreates++;
        return send(200, e);
      }
      const e = state.endpoints.get(id);
      if (!e) return send(404, { error: { message: 'no such endpoint' } });
      if (req.method === 'POST') {
        const f = parseForm();
        if (f.enabled_events.length) e.enabled_events = f.enabled_events;
        if (f.disabled === 'false') e.status = 'enabled';
        if (f.description) e.description = f.description;
        Object.assign(e.metadata, f.metadata);
        const { secret, ...pub } = e;
        return send(200, pub);
      }
      if (req.method === 'DELETE') {
        state.endpoints.delete(id);
        return send(200, { id, deleted: true });
      }
      return send(405, {});
    }

    // ------------------------------------------------ the deployed billing function
    if (path === '/functions/v1/billing') {
      state.syncCalls.push({ secretOk: req.headers['x-cron-secret'] === cronSecret, body });
      if (req.headers['x-cron-secret'] !== cronSecret) {
        return send(401, { error: 'Invalid cron credentials.', code: 'unauthorized', request_id: 'r1' });
      }
      if (body?.action !== 'sync_plans') return send(400, { error: 'Unknown action.', code: 'unknown_action', request_id: 'r2' });
      return send(state.syncResponse.status, state.syncResponse.body);
    }

    // ------------------------------------------------ Management API
    if (req.headers.authorization !== `Bearer ${token}`) return send(401, { message: 'Unauthorized' });
    const m = /^\/v1\/projects\/([^/]+)(\/.*)?$/.exec(path);
    if (!m) return send(404, { message: 'not found' });
    if (m[1] !== ref) return send(404, { message: 'project not found' });
    const sub = m[2] ?? '';
    if (sub === '' && req.method === 'GET') return send(200, { id: ref, name: 'fake-prod', region: 'us-east-1', status: 'ACTIVE_HEALTHY' });
    if (sub === '/secrets') {
      if (req.method === 'GET') return send(200, [...state.secrets.entries()].map(([name, value]) => ({ name, value: sha(value) })));
      if (req.method === 'POST') {
        for (const s of body) {
          if (s.name.startsWith('SUPABASE_')) return send(400, { message: 'reserved name' });
          state.secrets.set(s.name, s.value);
        }
        return send(201);
      }
      if (req.method === 'DELETE') {
        for (const n of body) state.secrets.delete(n);
        return send(200, {});
      }
    }
    if (sub === '/config/auth') {
      if (req.method === 'GET') {
        const { smtp_pass, ...pub } = state.auth;
        return send(200, pub);
      }
      if (req.method === 'PATCH') {
        state.authPatches.push(body);
        Object.assign(state.auth, body);
        const { smtp_pass, ...pub } = state.auth;
        return send(200, pub);
      }
    }
    if (sub === '/functions' && req.method === 'GET') {
      const deployed = new Map();
      if (existsSync(deployedFile)) {
        for (const line of readFileSync(deployedFile, 'utf8').split('\n').filter(Boolean)) {
          const d = JSON.parse(line);
          const prev = deployed.get(d.slug);
          deployed.set(d.slug, { slug: d.slug, verify_jwt: d.verify_jwt, status: 'ACTIVE', version: (prev?.version ?? 0) + 1 });
        }
      }
      return send(200, [...deployed.values()]);
    }
    if (sub === '/database/query' && req.method === 'POST') {
      const q = body.query;
      state.sql.push(q);
      if (/cron\.schedule/.test(q)) {
        // Emulate cron.sql: the DO block raises while placeholders remain.
        const lit = (name) => new RegExp(`${name}\\s+constant\\s+text\\s*:=\\s*'((?:[^']|'')*)'`).exec(q)?.[1]?.replace(/''/g, "'");
        const fnUrl = lit('v_functions_url');
        const secret = lit('v_cron_secret');
        const app = lit('v_app_base_url');
        if (!fnUrl || fnUrl.includes('<PROJECT_REF>') || secret === '<CRON_SECRET>' || app === '<APP_BASE_URL>') {
          return send(400, { message: 'ERROR: cron.sql: replace <PROJECT_REF>, <CRON_SECRET> and <APP_BASE_URL> before running' });
        }
        if (!/v_cron_secret = '<CRON_SECRET>'/.test(q)) return send(400, { message: 'guard clause was modified' });
        state.platformConfig = app;
        state.vault = ['detail_crm_cron_secret', 'detail_crm_functions_url'];
        state.vaultValues = { functionsUrl: fnUrl, cronSecret: secret };
        state.cronJobs = [...q.matchAll(/cron\.schedule\(\s*'([^']+)'/g)].map((x) => ({ jobname: x[1], active: true }));
        return send(201, []);
      }
      const setBilling = /select public\.set_billing_config\(p_enabled => (true|false), p_trial_days => (\d+)\)/.exec(q);
      if (setBilling) {
        state.billingConfigCalls.push({ enabled: setBilling[1] === 'true', trialDays: Number(setBilling[2]) });
        state.billingConfig.set('billing_enabled', setBilling[1]);
        state.billingConfig.set('billing_trial_days', setBilling[2]);
        return send(201, [{ set_billing_config: null }]);
      }
      if (/from public\.platform_config/.test(q) && /billing_enabled/.test(q)) {
        return send(201, [...state.billingConfig.entries()].sort().map(([key, value]) => ({ key, value })));
      }
      if (/from public\.platform_config/.test(q)) return send(201, state.platformConfig ? [{ value: state.platformConfig }] : []);
      if (/from cron\.job/.test(q)) return send(201, state.cronJobs);
      if (/from vault\.secrets/.test(q)) return send(201, state.vault.map((name) => ({ name })));
      return send(201, []);
    }
    return send(404, { message: `unhandled ${req.method} ${sub}` });
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  return { url: `http://127.0.0.1:${server.address().port}`, state, close: () => new Promise((r) => server.close(r)) };
}
