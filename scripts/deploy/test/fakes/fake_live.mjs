// A fake hosted Supabase project (gateway + PostgREST + GoTrue + Storage +
// functions + Realtime websocket + Management API) that answers the way the
// real platform does for a correct deploy, with switchable faults, for
// scripts/deploy/test/verify_live.test.mjs.
import { createHash, randomUUID } from 'node:crypto';
import { createServer } from 'node:http';

const env = (code, message, status) => ({ status, body: { error: message, code, request_id: randomUUID() } });

export async function startFakeLive({ ref, anon, service, token, app, faults = [] }) {
  const f = new Set(faults);
  const verifyJwt = { invites: true, 'stripe-connect': true, payments: false, messaging: false, 'stripe-webhook': false, 'storage-purge': false };
  if (f.has('webhook-verify-jwt')) verifyJwt['stripe-webhook'] = true;
  const corsFns = new Set(['invites', 'messaging', 'payments', 'stripe-connect']);
  const authCfg = {
    site_url: app,
    uri_allow_list: `${app}/**,${app}/reset-password`,
    mailer_autoconfirm: f.has('autoconfirm'),
    smtp_host: 'smtp.resend.com',
  };

  const server = createServer(async (req, res) => {
    const chunks = [];
    for await (const c of req) chunks.push(c);
    const raw = Buffer.concat(chunks).toString('utf8');
    const url = new URL(req.url, 'http://fake');
    const p = url.pathname;
    const send = (status, body, headers = {}) => {
      res.writeHead(status, { 'content-type': 'application/json', ...headers });
      res.end(body === undefined ? '' : JSON.stringify(body));
    };
    const key = req.headers.apikey;
    const bearer = (req.headers.authorization ?? '').replace(/^Bearer /, '');

    // Management API
    if (p.startsWith('/v1/projects/')) {
      if (bearer !== token) return send(401, { message: 'Unauthorized' });
      const sub = p.slice(`/v1/projects/${ref}`.length);
      if (sub === '/api-keys') return send(200, [{ name: 'anon', api_key: anon }, { name: 'service_role', api_key: service }]);
      if (sub === '/config/auth') return send(200, authCfg);
      if (sub === '/functions') return send(200, Object.entries(verifyJwt).map(([slug, v]) => ({ slug, verify_jwt: v, status: 'ACTIVE', version: 3 })));
      if (sub === '/database/query') {
        const q = JSON.parse(raw).query;
        if (/platform_config/.test(q)) return send(201, [{ value: app }]);
        if (/cron\.job/.test(q)) {
          const jobs = ['detail-crm-expire-quotes', 'detail-crm-process-queue', 'detail-crm-run-automations', 'detail-crm-storage-purge', 'detail-crm-sweep-payment-sheets'];
          return send(201, (f.has('cron-missing') ? jobs.slice(1) : jobs).map((jobname) => ({ jobname, active: true })));
        }
        return send(201, []);
      }
      return send(404, {});
    }

    // PostgREST
    if (p.startsWith('/rest/v1')) {
      if (key !== anon && key !== service) return send(401, { message: 'No API key found in request' });
      if (p === '/rest/v1/') return send(200, { swagger: '2.0' });
      if (p.startsWith('/rest/v1/rpc/')) {
        const fn = p.slice('/rest/v1/rpc/'.length);
        const body = raw ? JSON.parse(raw) : {};
        if (['portal_overview', 'create_shop', 'set_app_base_url'].includes(fn) && key === anon) return send(401, { code: '42501', message: `permission denied for function ${fn}` });
        if (body.p_token === 'not-a-uuid') return send(400, { code: '22P02', message: 'invalid input syntax for type uuid' });
        if (['public_get_quote', 'public_get_invoice', 'public_get_booking', 'public_get_form', 'public_shop_profile', 'public_booking_catalog'].includes(fn)) {
          return send(500, { code: 'P0002', message: 'not found' }, { 'proxy-status': 'PostgREST; error=P0002' });
        }
        return send(200, null);
      }
      const table = p.slice('/rest/v1/'.length);
      if (key === service && table === 'platform_config') return send(200, [{ value: app }]);
      if (table === 'shops' && f.has('anon-reads-shops')) return send(200, [{ id: randomUUID() }]);
      return send(401, { code: '42501', message: `permission denied for table ${table}` });
    }

    // GoTrue
    if (p === '/auth/v1/settings') {
      return send(200, { external: { email: true, phone: false, anonymous_users: false }, disable_signup: false, mailer_autoconfirm: f.has('autoconfirm') });
    }
    if (p === '/auth/v1/verify') {
      const to = url.searchParams.get('redirect_to');
      const allowed = to && to.startsWith(`${app}/`);
      const base = allowed ? to : f.has('site-url-localhost') ? 'http://localhost:3000' : app;
      return send(303, undefined, { location: `${base}#error=access_denied&error_code=otp_expired` });
    }

    // Storage
    if (p.startsWith('/storage/v1/object/public/')) {
      const bucket = p.split('/')[5];
      const publicBuckets = new Set(['shop-assets', ...(f.has('photos-public') ? ['job-photos'] : [])]);
      if (publicBuckets.has(bucket)) return send(400, { statusCode: '404', error: 'not_found', message: 'Object not found' });
      return send(400, { statusCode: '404', error: 'Bucket not found', message: 'Bucket not found' });
    }
    if (p === '/storage/v1/bucket') {
      if (key !== service) return send(200, []);
      return send(200, [
        { id: 'job-photos', public: f.has('photos-public') },
        { id: 'signatures', public: false },
        { id: 'shop-assets', public: true },
      ]);
    }

    // Functions (gateway + our envelope)
    if (p.startsWith('/functions/v1/')) {
      const fn = p.slice('/functions/v1/'.length);
      if (!(fn in verifyJwt)) return send(404, { code: 'NOT_FOUND', message: 'Requested function was not found' });
      if (req.method === 'OPTIONS') {
        if (!corsFns.has(fn)) return send(405, env('method_not_allowed', 'Method not allowed.', 405).body);
        const origin = req.headers.origin;
        if (f.has('cors-wildcard')) return send(204, undefined, { 'access-control-allow-origin': '*' });
        if (origin === new URL(app).origin) return send(204, undefined, { 'access-control-allow-origin': origin });
        return send(403, env('origin_not_allowed', 'This origin is not allowed.', 403).body);
      }
      if (verifyJwt[fn] && !bearer) return send(401, { code: 401, message: 'Missing authorization header' });
      const action = url.searchParams.get('action') ?? (raw && req.headers['content-type']?.includes('json') ? JSON.parse(raw).action : undefined);
      const reply = (e) => send(e.status, e.body);
      if (fn === 'stripe-webhook') return reply(env('invalid_signature', 'Invalid Stripe signature.', 400));
      if (fn === 'messaging' && action === 'unsubscribe' && req.method === 'GET') {
        return send(303, undefined, { location: `${f.has('app-url-mismatch') ? 'https://old.example.com' : app}/u/${url.searchParams.get('token')}` });
      }
      if (fn === 'messaging' && action === 'twilio_inbound') return reply(env('invalid_signature', 'The Twilio signature is missing or invalid.', 400));
      if (!action) return reply(env('unknown_action', 'Unknown action.', 400));
      if (['process_queue', 'sweep_payment_sheets', 'purge'].includes(action)) {
        return reply(f.has('cron-secret-missing') ? env('server_misconfigured', 'Server misconfigured.', 500) : env('unauthorized', 'Unauthorized.', 401));
      }
      if (action === 'invoice_checkout') {
        const body = JSON.parse(raw);
        if ('total' in body || !/^[0-9a-f-]{36}$/.test(body.token)) return reply(env('validation_failed', 'Invalid input.', 400));
        return reply(env('not_found', 'Invoice not found.', 404));
      }
      if (action === 'refund') return reply(env('unauthorized', 'Sign in again.', 401));
      return reply(env('unknown_action', 'Unknown action.', 400));
    }
    return send(404, {});
  });

  // Minimal RFC 6455 server for /realtime/v1/websocket: answers phx_join.
  server.on('upgrade', (req, socket) => {
    const u = new URL(req.url, 'http://fake');
    if (u.pathname !== '/realtime/v1/websocket' || u.searchParams.get('apikey') !== anon) {
      socket.end('HTTP/1.1 401 Unauthorized\r\n\r\n');
      return;
    }
    const accept = createHash('sha1').update(`${req.headers['sec-websocket-key']}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`).digest('base64');
    socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
    socket.on('data', (buf) => {
      if ((buf[0] & 0x0f) === 0x8) return socket.end();
      let len = buf[1] & 0x7f;
      let off = 2;
      if (len === 126) {
        len = buf.readUInt16BE(2);
        off = 4;
      }
      const mask = buf.subarray(off, off + 4);
      const data = Buffer.from(buf.subarray(off + 4, off + 4 + len).map((b, i) => b ^ mask[i % 4])).toString('utf8');
      let msg;
      try {
        msg = JSON.parse(data);
      } catch {
        return;
      }
      if (msg.event !== 'phx_join') return;
      const out = Buffer.from(JSON.stringify({ topic: msg.topic, event: 'phx_reply', ref: msg.ref, payload: { status: 'ok', response: {} } }));
      const head = out.length < 126 ? Buffer.from([0x81, out.length]) : Buffer.from([0x81, 126, out.length >> 8, out.length & 0xff]);
      socket.write(Buffer.concat([head, out]));
    });
    socket.on('error', () => {});
  });

  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  return { url: `http://127.0.0.1:${server.address().port}`, close: () => new Promise((r) => { server.closeAllConnections?.(); server.close(r); }) };
}
