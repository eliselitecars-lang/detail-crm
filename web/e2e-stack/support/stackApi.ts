import { randomUUID } from 'node:crypto';
import { stackEnv } from './stackEnv';

/**
 * Direct HTTP helpers against the real stack (GoTrue, PostgREST, functions,
 * provider mock) for arranging test data. Only public/anon or the test's own
 * user JWTs are used for app data, so RLS applies exactly as in the app; the
 * service role is reserved for harness plumbing.
 */

export interface StackUser {
  id: string;
  email: string;
  password: string;
  accessToken: string;
}

export interface StackShop {
  id: string;
  slug: string;
  name: string;
}

/** Short unique suffix for emails/slugs so tests never collide. */
export function uniqueSuffix(): string {
  return randomUUID().replace(/-/g, '').slice(0, 10);
}

async function call<T>(url: string, init: RequestInit & { json?: unknown } = {}): Promise<T> {
  const { json, headers, ...rest } = init;
  const res = await fetch(url, {
    ...rest,
    headers: {
      ...(json !== undefined ? { 'content-type': 'application/json' } : {}),
      ...(headers as Record<string, string> | undefined),
    },
    body: json !== undefined ? JSON.stringify(json) : init.body,
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`${init.method ?? 'GET'} ${url} -> HTTP ${res.status}: ${text}`);
  return (text ? JSON.parse(text) : null) as T;
}

export function userHeaders(user: Pick<StackUser, 'accessToken'>): Record<string, string> {
  return { apikey: stackEnv().anonKey, authorization: `Bearer ${user.accessToken}` };
}

/** Signs a new user up through GoTrue (local stack: confirmed immediately). */
export async function signUpUser(
  options: { email?: string; password?: string; fullName?: string } = {},
): Promise<StackUser> {
  const env = stackEnv();
  const email = options.email ?? `user-${uniqueSuffix()}@stack.test`;
  const password = options.password ?? `Pw-${uniqueSuffix()}!`;
  const session = await call<{ access_token: string; user: { id: string } }>(
    `${env.apiUrl}/auth/v1/signup`,
    {
      method: 'POST',
      headers: { apikey: env.anonKey },
      json: { email, password, data: { full_name: options.fullName ?? 'Stack Tester' } },
    },
  );
  return { id: session.user.id, email, password, accessToken: session.access_token };
}

/** Calls a PostgREST RPC as the given user (or anon). */
export async function rpc<T>(
  name: string,
  args: Record<string, unknown>,
  user?: StackUser,
): Promise<T> {
  const env = stackEnv();
  return call<T>(`${env.apiUrl}/rest/v1/rpc/${name}`, {
    method: 'POST',
    headers: user
      ? userHeaders(user)
      : { apikey: env.anonKey, authorization: `Bearer ${env.anonKey}` },
    json: args,
  });
}

/** Creates a shop owned by `owner` through the real create_shop RPC. */
export async function createShop(owner: StackUser, name?: string): Promise<StackShop> {
  const suffix = uniqueSuffix();
  const shopName = name ?? `Stack Shop ${suffix}`;
  const slug = `stack-${suffix}`;
  const shop = await rpc<{ id: string; slug: string; name: string }>(
    'create_shop',
    { p_name: shopName, p_slug: slug, p_timezone: 'America/Chicago' },
    owner,
  );
  return { id: shop.id, slug: shop.slug, name: shop.name };
}

/** Recorded Twilio/Resend requests (scripts/stack/provider_mock.mjs). */
export async function providerRequests(
  service?: 'twilio' | 'resend',
): Promise<Array<Record<string, unknown>>> {
  const env = stackEnv();
  return call(`${env.providerMockUrl}/__control/requests${service ? `?service=${service}` : ''}`);
}
