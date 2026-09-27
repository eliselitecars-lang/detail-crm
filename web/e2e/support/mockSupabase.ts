import type { Page, Route, WebSocketRoute } from '@playwright/test';
import type { MockUser } from './fixtures';

export const SUPABASE_URL = 'https://e2e-mock.supabase.co';
const STORAGE_KEY = `sb-${new URL(SUPABASE_URL).hostname.split('.')[0]}-auth-token`;

type Json = null | boolean | number | string | Json[] | { [key: string]: Json };
type Handler = (request: { url: URL; method: string; body: unknown }) => Json | Promise<Json>;

export interface MockBackendOptions {
  /** Signed-in user (session is pre-seeded in localStorage). Omit for signed out. */
  user?: MockUser | null;
  /** Rows returned for `GET /rest/v1/<table>` (all rows; filters are not applied). */
  tables?: Record<string, Json[] | Handler>;
  /** Results for `POST /rest/v1/rpc/<fn>`. */
  rpc?: Record<string, Json | Handler>;
  /** Exact counts for `HEAD` count queries, by table. */
  counts?: Record<string, number>;
  /** Users that may sign in with password (any password is accepted). */
  accounts?: MockUser[];
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

async function json(
  route: Route,
  status: number,
  body: unknown,
  headers: Record<string, string> = {},
) {
  await route.fulfill({
    status,
    contentType: 'application/json',
    headers: { 'access-control-allow-origin': '*', ...headers },
    body: body === undefined ? '' : JSON.stringify(body),
  });
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
  const { user = null, tables = {}, rpc = {}, counts = {}, accounts = [] } = options;

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

    if (path.startsWith('rpc/')) {
      const name = path.slice(4);
      const entry = rpc[name];
      const body: unknown = request.postDataJSON();
      const result =
        typeof entry === 'function' ? await entry({ url, method, body }) : (entry ?? null);
      return json(route, 200, result);
    }

    const table = path.split('?')[0] ?? '';
    if (method === 'HEAD') {
      const count = counts[table] ?? 0;
      return route.fulfill({
        status: 200,
        headers: {
          'content-range': count === 0 ? '*/0' : `0-${count - 1}/${count}`,
          'access-control-expose-headers': 'content-range',
        },
      });
    }
    const entry = tables[table];
    const rows =
      typeof entry === 'function'
        ? await entry({ url, method, body: request.postDataJSON() as unknown })
        : (entry ?? []);
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

  await page.routeWebSocket(/\/realtime\/v1\/websocket/, handleRealtime);
}
