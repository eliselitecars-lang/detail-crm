#!/usr/bin/env node
// Local Twilio + Resend simulator for the real-stack harness (scripts/stack/).
// LOCAL / CI ONLY. No dependencies (Node 22).
//
// The edge functions are pointed here with TWILIO_API_BASE / RESEND_API_BASE
// (supabase/functions/_shared/api_base.ts). Every provider request is
// recorded (method, path, query, headers minus Authorization, parsed body) in
// memory and in a JSON file, so tests can assert what would have been sent.
//
// Provider endpoints (shaped like the real APIs, only what the app uses):
//   POST /2010-04-01/Accounts/:sid/Messages.json              -> 201 {sid:"SM…", status:"queued"}
//   GET  /2010-04-01/Accounts/:sid/IncomingPhoneNumbers.json  -> {incoming_phone_numbers:[…]}
//        (numbers registered with POST /__control/twilio/numbers; filtered by ?PhoneNumber=)
//   POST /emails                                              -> 200 {id:"<uuid>"}
//
// Control endpoints (tests):
//   GET    /__control/health                 -> {ok:true}
//   GET    /__control/requests[?service=twilio|resend][&since=<iso>] -> recorded requests
//   DELETE /__control/requests               -> clear the log (file too)
//   POST   /__control/twilio/numbers {phone_number, sms_url[, status_callback]} -> register a number
//   DELETE /__control/twilio/numbers         -> forget all numbers
//   POST   /__control/fail {service, status, code?, message?, times?} -> make the next N
//          provider calls of that service fail (e.g. Twilio 21610 unsubscribed)
//
// Usage: node scripts/stack/provider_mock.mjs [--port 12120] [--file path.json]
//   env PROVIDER_MOCK_PORT / PROVIDER_MOCK_FILE work too.
import { randomBytes, randomUUID } from 'node:crypto';
import { writeFileSync } from 'node:fs';
import { createServer } from 'node:http';

function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i > 0 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}

const PORT = Number(arg('port', process.env.PROVIDER_MOCK_PORT ?? '12120'));
const FILE = arg('file', process.env.PROVIDER_MOCK_FILE ?? '');
const HOST = arg('host', process.env.PROVIDER_MOCK_HOST ?? '0.0.0.0');

/** @type {Array<Record<string, unknown>>} */
let requests = [];
/** @type {Array<{phone_number: string, sms_url: string, status_callback?: string}>} */
let numbers = [];
/** @type {Record<string, {status: number, code?: number|string, message?: string, times: number}>} */
const failures = {};

function persist() {
  if (!FILE) return;
  try {
    writeFileSync(FILE, JSON.stringify(requests, null, 2));
  } catch (err) {
    console.error('provider-mock: could not write', FILE, err);
  }
}

function send(res, status, body) {
  const text = JSON.stringify(body);
  res.writeHead(status, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(text) });
  res.end(text);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

function parseBody(raw, contentType) {
  if (!raw) return null;
  if ((contentType ?? '').includes('application/x-www-form-urlencoded')) {
    return Object.fromEntries(new URLSearchParams(raw));
  }
  try {
    return JSON.parse(raw);
  } catch {
    return raw;
  }
}

function takeFailure(service) {
  const f = failures[service];
  if (!f || f.times <= 0) return null;
  f.times -= 1;
  if (f.times <= 0) delete failures[service];
  return f;
}

const hex = (n) => randomBytes(n).toString('hex');

const server = createServer(async (req, res) => {
  const url = new URL(req.url ?? '/', `http://${req.headers.host ?? 'localhost'}`);
  const path = url.pathname;
  const raw = await readBody(req).catch(() => '');
  const body = parseBody(raw, req.headers['content-type']);

  // ------------------------------------------------------------ control
  if (path.startsWith('/__control/')) {
    if (path === '/__control/health') return send(res, 200, { ok: true });
    if (path === '/__control/requests' && req.method === 'GET') {
      const service = url.searchParams.get('service');
      const since = url.searchParams.get('since');
      return send(
        res,
        200,
        requests.filter(
          (r) => (!service || r.service === service) && (!since || String(r.at) >= since),
        ),
      );
    }
    if (path === '/__control/requests' && req.method === 'DELETE') {
      requests = [];
      persist();
      return send(res, 200, { ok: true });
    }
    if (path === '/__control/twilio/numbers' && req.method === 'POST') {
      if (!body || typeof body !== 'object' || !body.phone_number || !body.sms_url) {
        return send(res, 400, { error: 'phone_number and sms_url are required' });
      }
      numbers = numbers.filter((n) => n.phone_number !== body.phone_number);
      numbers.push({
        phone_number: body.phone_number,
        sms_url: body.sms_url,
        status_callback: body.status_callback,
      });
      return send(res, 200, { ok: true, numbers });
    }
    if (path === '/__control/twilio/numbers' && req.method === 'DELETE') {
      numbers = [];
      return send(res, 200, { ok: true });
    }
    if (path === '/__control/fail' && req.method === 'POST') {
      if (!body?.service || !body?.status) return send(res, 400, { error: 'service and status are required' });
      failures[body.service] = {
        status: Number(body.status),
        code: body.code,
        message: body.message,
        times: Number(body.times ?? 1),
      };
      return send(res, 200, { ok: true });
    }
    return send(res, 404, { error: 'unknown control endpoint' });
  }

  // ----------------------------------------------------------- providers
  const twilioMessages = /^\/2010-04-01\/Accounts\/([^/]+)\/Messages\.json$/.exec(path);
  const twilioNumbers = /^\/2010-04-01\/Accounts\/([^/]+)\/IncomingPhoneNumbers\.json$/.exec(path);
  const service = twilioMessages || twilioNumbers ? 'twilio' : path === '/emails' ? 'resend' : 'unknown';
  const headers = { ...req.headers };
  delete headers.authorization;
  const record = {
    at: new Date().toISOString(),
    service,
    method: req.method,
    path,
    query: Object.fromEntries(url.searchParams),
    headers,
    has_auth: typeof req.headers.authorization === 'string',
    body,
  };
  requests.push(record);
  persist();

  if (!record.has_auth) {
    return service === 'resend'
      ? send(res, 401, { name: 'missing_api_key', message: 'Missing API key' })
      : send(res, 401, { code: 20003, message: 'Authenticate', status: 401 });
  }
  const failure = service !== 'unknown' ? takeFailure(service) : null;
  if (failure) {
    record.simulated_failure = failure.status;
    persist();
    return service === 'resend'
      ? send(res, failure.status, { name: failure.code ?? 'application_error', message: failure.message ?? 'Simulated failure' })
      : send(res, failure.status, {
          code: Number(failure.code ?? 20500),
          message: failure.message ?? 'Simulated failure',
          status: failure.status,
        });
  }

  if (twilioMessages && req.method === 'POST') {
    const sid = `SM${hex(16)}`;
    record.response_id = sid;
    persist();
    return send(res, 201, {
      sid,
      account_sid: twilioMessages[1],
      to: body?.To ?? null,
      from: body?.From ?? null,
      messaging_service_sid: body?.MessagingServiceSid ?? null,
      body: body?.Body ?? '',
      status: 'queued',
      num_segments: '1',
      date_created: new Date().toUTCString(),
      error_code: null,
      error_message: null,
    });
  }
  if (twilioNumbers && req.method === 'GET') {
    const wanted = url.searchParams.get('PhoneNumber');
    const list = numbers
      .filter((n) => !wanted || n.phone_number === wanted)
      .map((n) => ({
        sid: `PN${hex(16)}`,
        account_sid: twilioNumbers[1],
        phone_number: n.phone_number,
        sms_url: n.sms_url,
        sms_method: 'POST',
        status_callback: n.status_callback ?? '',
        capabilities: { sms: true, mms: true, voice: false },
      }));
    return send(res, 200, { incoming_phone_numbers: list, page: 0, page_size: list.length });
  }
  if (service === 'resend' && req.method === 'POST') {
    const id = randomUUID();
    record.response_id = id;
    persist();
    return send(res, 200, { id });
  }
  return send(res, 404, { message: `provider-mock: no route for ${req.method} ${path}` });
});

server.listen(PORT, HOST, () => {
  persist();
  console.log(`provider-mock listening on http://${HOST}:${PORT}${FILE ? ` (recording to ${FILE})` : ''}`);
});
for (const sig of ['SIGINT', 'SIGTERM']) process.on(sig, () => server.close(() => process.exit(0)));
