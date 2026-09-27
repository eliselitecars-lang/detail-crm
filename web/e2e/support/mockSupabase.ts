import type { Page, Route, WebSocketRoute } from '@playwright/test';
import type { MockUser } from './fixtures';

export const SUPABASE_URL = 'https://e2e-mock.supabase.co';
/** localStorage key supabase-js keeps the session under. */
export const STORAGE_KEY = `sb-${new URL(SUPABASE_URL).hostname.split('.')[0]}-auth-token`;

export type Json = null | boolean | number | string | Json[] | { [key: string]: Json };

/**
 * A non-2xx (or explicit-status) answer from a handler: `{ status, body }`.
 * Build it with `reply(status, body)`. Any handler (tables, rpc, functions,
 * storage) may return one, e.g. an edge-function refusal
 * `reply(422, { error, code: 'unprocessable', details: { reason } })`, the
 * gateway's `reply(401, { code: 401, message: 'Invalid JWT' })` or a PostgREST
 * error `reply(404, { code: 'PT404', message: 'quote not found' })`.
 */
const REPLY = Symbol('mockReply');

export interface MockReply {
  readonly [REPLY]: true;
  readonly status: number;
  readonly body: Json;
}

/** An explicit HTTP status + JSON body for any mock handler. */
export function reply(status: number, body: Json): MockReply {
  return { [REPLY]: true, status, body };
}

function isReply(value: unknown): value is MockReply {
  return typeof value === 'object' && value !== null && REPLY in value;
}

export interface MockRequest {
  url: URL;
  method: string;
  /** Parsed JSON body (functions / rpc / tables); raw bytes for storage uploads. */
  body: unknown;
  headers: Record<string, string>;
}

export type Handler = (request: MockRequest) => Json | MockReply | Promise<Json | MockReply>;

export interface MockBackendOptions {
  /** Signed-in user (session is pre-seeded in localStorage). Omit for signed out. */
  user?: MockUser | null;
  /** Rows returned for `GET /rest/v1/<table>` (all rows; filters are not applied). */
  tables?: Record<string, Json[] | MockReply | Handler>;
  /** Results for `POST /rest/v1/rpc/<fn>`. */
  rpc?: Record<string, Json | MockReply | Handler>;
  /** Exact counts for `HEAD` count queries, by table. */
  counts?: Record<string, number>;
  /** Users that may sign in with password (any password is accepted). */
  accounts?: MockUser[];
  /**
   * Results for `POST /functions/v1/<name>`, by function name. A handler sees
   * the JSON body (`{ action, … }`). Unknown functions answer 404.
   */
  functions?: Record<string, Json | MockReply | Handler>;
  /** Handler for every `/storage/v1/**` request (uploads, removes, signed URLs); default 200 `{}`. */
  storage?: Handler;
}

function base64url(value: object): string {
  return Buffer.from(JSON.stringify(value)).toString('base64url');
}

/** Unsigned JWT with the claims supabase-js/realtime-js read. */
function fakeJwt(user: MockUser, exp: number): string {
  return [
    base64url({ alg: 'HS256', typ: 'JWT' }),
    base64url({
      sub: user.id,
      email: user.email,
      role: 'authenticated',
      aud: 'authenticated',
      exp,
    }),
    'e2e-signature',
  ].join('.');
}

export function authUser(user: MockUser) {
  return {
    id: user.id,
    aud: 'authenticated',
    role: 'authenticated',
    email: user.email,
    email_confirmed_at: '2026-01-01T00:00:00Z',
    app_metadata: { provider: 'email', providers: ['email'] },
    user_metadata: { full_name: user.fullName },
    created_at: '2026-01-01T00:00:00Z',
    updated_at: '2026-01-01T00:00:00Z',
  };
}

export function sessionFor(user: MockUser) {
  const expiresAt = Math.floor(Date.now() / 1000) + 3600;
  return {
    access_token: fakeJwt(user, expiresAt),
    refresh_token: `refresh-${user.id}`,
    token_type: 'bearer',
    expires_in: 3600,
    expires_at: expiresAt,
    user: authUser(user),
  };
}

const CORS = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': '*',
  'access-control-allow-methods': 'GET, POST, PATCH, PUT, DELETE, HEAD, OPTIONS',
  'access-control-expose-headers': 'content-range',
};

async function json(
  route: Route,
  status: number,
  body: unknown,
  headers: Record<string, string> = {},
) {
  await route.fulfill({
    status,
    contentType: 'application/json',
    headers: { ...CORS, ...headers },
    body: body === undefined ? '' : JSON.stringify(body),
  });
}

function jsonBody(route: Route): unknown {
  try {
    return route.request().postDataJSON() as unknown;
  } catch {
    return route.request().postData();
  }
}

async function resolve(
  entry: Json | MockReply | Handler | undefined,
  request: MockRequest,
): Promise<Json | MockReply | undefined> {
  return typeof entry === 'function' ? entry(request) : entry;
}

/** Answers realtime joins/heartbeats so channels subscribe quietly. */
function handleRealtime(ws: WebSocketRoute) {
  ws.onMessage((message) => {
    if (typeof message !== 'string') return;
    let parsed: unknown;
    try {
      parsed = JSON.parse(message);
    } catch {
      return;
    }
    // vsn 2.0.0: [join_ref, ref, topic, event, payload]; vsn 1.0.0: object
    const frame = Array.isArray(parsed)
      ? {
          join_ref: parsed[0],
          ref: parsed[1],
          topic: parsed[2],
          event: parsed[3],
          payload: parsed[4],
        }
      : (parsed as {
          join_ref?: unknown;
          ref: unknown;
          topic: unknown;
          event: unknown;
          payload: unknown;
        });
    let response: Record<string, unknown> = {};
    if (frame.event === 'phx_join') {
      const config = (
        frame.payload as { config?: { postgres_changes?: Record<string, unknown>[] } }
      ).config;
      response = {
        postgres_changes: (config?.postgres_changes ?? []).map((binding, index) => ({
          ...binding,
          id: index + 1,
        })),
      };
    } else if (
      frame.event !== 'heartbeat' &&
      frame.event !== 'access_token' &&
      frame.event !== 'phx_leave'
    ) {
      return;
    }
    const payload = { status: 'ok', response };
    ws.send(
      JSON.stringify(
        Array.isArray(parsed)
          ? [frame.join_ref ?? null, frame.ref, frame.topic, 'phx_reply', payload]
          : {
              topic: frame.topic,
              event: 'phx_reply',
              payload,
              ref: frame.ref,
              join_ref: frame.join_ref,
            },
      ),
    );
  });
}

/**
 * Intercepts every Supabase request the app makes (auth, PostgREST, RPC,
 * realtime) and serves fixtures. Unknown tables/RPCs return an empty result
 * so pages render their empty states instead of hanging.
 */
export async function mockSupabase(page: Page, options: MockBackendOptions = {}) {
  const {
    user = null,
    tables = {},
    rpc = {},
    counts = {},
    accounts = [],
    functions = {},
    storage,
  } = options;

  if (user) {
    await page.addInitScript(
      ({ key, value }) => {
        window.localStorage.setItem(key, value);
      },
      { key: STORAGE_KEY, value: JSON.stringify(sessionFor(user)) },
    );
  }

  await page.route(`${SUPABASE_URL}/auth/v1/**`, async (route) => {
    const request = route.request();
    const url = new URL(request.url());
    if (request.method() === 'OPTIONS') return json(route, 204, undefined);
    if (url.pathname.endsWith('/token')) {
      const body = (request.postDataJSON() ?? {}) as { email?: string };
      const account = accounts.find((a) => a.email === body.email?.toLowerCase());
      if (!account) {
        return json(route, 400, {
          code: 'invalid_credentials',
          error_code: 'invalid_credentials',
          msg: 'Invalid login credentials',
        });
      }
      return json(route, 200, sessionFor(account));
    }
    if (url.pathname.endsWith('/user')) {
      return user ? json(route, 200, authUser(user)) : json(route, 401, { msg: 'no session' });
    }
    if (url.pathname.endsWith('/logout')) return route.fulfill({ status: 204 });
    if (url.pathname.endsWith('/recover')) return json(route, 200, {});
    return json(route, 200, {});
  });

  await page.route(`${SUPABASE_URL}/rest/v1/**`, async (route) => {
    const request = route.request();
    const url = new URL(request.url());
    const method = request.method();
    if (method === 'OPTIONS') return json(route, 204, undefined);
    const path = url.pathname.replace(/^\/rest\/v1\//, '');

    const headers = request.headers();
    if (path.startsWith('rpc/')) {
      const name = path.slice(4);
      const result = await resolve(rpc[name], { url, method, body: jsonBody(route), headers });
      if (isReply(result)) return json(route, result.status, result.body);
      return json(route, 200, result ?? null);
    }

    const table = path.split('?')[0] ?? '';
    if (method === 'HEAD') {
      const count = counts[table] ?? 0;
      return route.fulfill({
        status: 200,
        headers: {
          'content-range': count === 0 ? '*/0' : `0-${count - 1}/${count}`,
          ...CORS,
        },
      });
    }
    const result = await resolve(tables[table], { url, method, body: jsonBody(route), headers });
    if (isReply(result)) return json(route, result.status, result.body);
    const rows = result ?? [];
    const wantsObject = (request.headers()['accept'] ?? '').includes('vnd.pgrst.object');
    if (wantsObject) {
      const first = Array.isArray(rows) ? rows[0] : rows;
      return first === undefined
        ? json(route, 406, { code: 'PGRST116', message: 'no rows' })
        : json(route, 200, first);
    }
    return json(route, method === 'POST' ? 201 : 200, rows, {
      'content-range': `0-${Array.isArray(rows) ? rows.length - 1 : 0}/*`,
    });
  });

  await page.route(`${SUPABASE_URL}/functions/v1/**`, async (route) => {
    const request = route.request();
    const url = new URL(request.url());
    const method = request.method();
    if (method === 'OPTIONS') return json(route, 204, undefined);
    const name = url.pathname.replace(/^\/functions\/v1\//, '').split('/')[0] ?? '';
    if (!(name in functions)) {
      return json(route, 404, { code: 'NOT_FOUND', message: 'Requested function was not found' });
    }
    const result = await resolve(functions[name], {
      url,
      method,
      body: jsonBody(route),
      headers: request.headers(),
    });
    if (isReply(result)) return json(route, result.status, result.body);
    return json(route, 200, result ?? null);
  });

  await page.route(`${SUPABASE_URL}/storage/v1/**`, async (route) => {
    const request = route.request();
    const url = new URL(request.url());
    const method = request.method();
    if (method === 'OPTIONS') return json(route, 204, undefined);
    if (!storage) return json(route, 200, {});
    const contentType = request.headers()['content-type'] ?? '';
    const body: unknown = contentType.includes('application/json')
      ? jsonBody(route)
      : request.postDataBuffer();
    const result = await storage({ url, method, body, headers: request.headers() });
    if (isReply(result)) return json(route, result.status, result.body);
    return json(route, 200, result);
  });

  await page.routeWebSocket(/\/realtime\/v1\/websocket/, handleRealtime);
}
