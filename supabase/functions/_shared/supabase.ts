/**
 * Supabase clients for edge functions.
 *
 *  - `adminClient()` — service role; bypasses RLS. Use for writes only
 *    service_role may do (card payments, stripe_events, message status) and
 *    for authorization lookups, ALWAYS scoping queries by the shop the
 *    caller was authorized for.
 *  - `userClient(req)` — anon key + the caller's Authorization header, so
 *    PostgREST applies RLS as that user. Prefer it for reads/writes staff could
 *    do directly; it keeps the database as the single enforcement point.
 *  - `getCaller(req)` — verifies the bearer JWT with Supabase Auth
 *    (`auth.getUser`, a server round trip, so revoked sessions and deleted
 *    users are rejected) and returns the caller's identity.
 */
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { type Env, env as defaultEnv } from "./env.ts";
import { HttpError } from "./errors.ts";

export type { SupabaseClient };

export interface ClientOptions {
  env?: Env;
  /** Injected fetch (tests use FakeFetch / FakeSupabase). */
  fetch?: typeof fetch;
}

const SERVER_AUTH = {
  persistSession: false,
  autoRefreshToken: false,
  detectSessionInUrl: false,
} as const;

let sharedAdmin: SupabaseClient | undefined;

/** Service-role client. Reused across requests when using the process env. */
export function adminClient(options: ClientOptions = {}): SupabaseClient {
  // Only the plain process configuration is cached; injected env/fetch
  // (tests, handler factories) always get their own client.
  const custom = (options.env !== undefined && options.env !== defaultEnv) ||
    options.fetch !== undefined;
  if (!custom && sharedAdmin) return sharedAdmin;
  const { url, serviceRoleKey } = (options.env ?? defaultEnv).supabase();
  const client = createClient(url, serviceRoleKey, {
    auth: SERVER_AUTH,
    global: {
      headers: { "x-client-info": "detail-crm-edge" },
      ...(options.fetch ? { fetch: options.fetch } : {}),
    },
  });
  if (!custom) sharedAdmin = client;
  return client;
}

/** Extracts the bearer token from `Authorization: Bearer <jwt>`. */
export function bearerToken(req: Request): string | null {
  const header = req.headers.get("authorization");
  if (!header) return null;
  const match = /^Bearer\s+(\S+)\s*$/i.exec(header);
  return match?.[1] ?? null;
}

/** Client that acts as the caller (RLS applies). Requires a bearer token. */
export function userClient(req: Request, options: ClientOptions = {}): SupabaseClient {
  const token = bearerToken(req);
  if (!token) throw new HttpError("unauthorized", "Sign in to continue.");
  const { url, anonKey } = (options.env ?? defaultEnv).supabase();
  return createClient(url, anonKey, {
    auth: SERVER_AUTH,
    global: {
      headers: { Authorization: `Bearer ${token}`, "x-client-info": "detail-crm-edge" },
      ...(options.fetch ? { fetch: options.fetch } : {}),
    },
  });
}

/**
 * Client that acts as whoever called: the caller's bearer token when there
 * is one (a signed-in user, or the anon key a signed-out web page sends),
 * else the anon role. For public RPCs whose own checks depend on auth.uid().
 */
export function callerClient(req: Request, options: ClientOptions = {}): SupabaseClient {
  if (bearerToken(req)) return userClient(req, options);
  const { url, anonKey } = (options.env ?? defaultEnv).supabase();
  return createClient(url, anonKey, {
    auth: SERVER_AUTH,
    global: {
      headers: { "x-client-info": "detail-crm-edge" },
      ...(options.fetch ? { fetch: options.fetch } : {}),
    },
  });
}

export interface Caller {
  id: string;
  email: string | null;
  /** True once the email address is confirmed (portal claims depend on it). */
  emailConfirmed: boolean;
  phone: string | null;
  isAnonymous: boolean;
  /** The verified access token, for building a userClient. */
  token: string;
}

export interface AuthErrorLike {
  status?: number;
  name?: string;
  message?: string;
}

/**
 * True when Auth did not give a real answer about the token, so the caller
 * must not be treated as signed out:
 *  - `AuthRetryableFetchError`: network failure or 5xx/52x from Auth/gateway.
 *  - `AuthUnknownError`: a non-JSON body with a non-5xx status (e.g. an HTML
 *    403/429 page from a proxy) - GoTrue itself always answers with JSON.
 *  - 408 / 429: Auth timed out or throttled the lookup (auth-js raises these
 *    as a plain `AuthApiError`).
 *  - any 5xx or status 0.
 * A JSON 4xx (bad_jwt, user_not_found, session_not_found...) is a definitive
 * "not signed in".
 */
export function isTransientAuthError(error: AuthErrorLike): boolean {
  if (error.name === "AuthRetryableFetchError" || error.name === "AuthUnknownError") return true;
  if (typeof error.status !== "number") return false;
  return error.status === 0 || error.status === 408 || error.status === 429 ||
    error.status >= 500;
}

/**
 * Verifies the request's JWT. Returns null when there is no token or the
 * token is invalid/expired/for a deleted user; throws `service_unavailable`
 * when Auth itself could not be reached (so callers don't treat an outage as
 * "signed out").
 */
export async function getCaller(
  req: Request,
  options: { admin?: SupabaseClient } & ClientOptions = {},
): Promise<Caller | null> {
  const token = bearerToken(req);
  if (!token) return null;
  const admin = options.admin ?? adminClient(options);
  const { data, error } = await admin.auth.getUser(token);
  if (error) {
    if (isTransientAuthError(error)) {
      throw new HttpError(
        "service_unavailable",
        "Authentication is temporarily unavailable. Try again.",
        { cause: error },
      );
    }
    return null;
  }
  const user = data.user;
  if (!user) return null;
  return {
    id: user.id,
    email: user.email ?? null,
    emailConfirmed: Boolean(user.email_confirmed_at),
    phone: user.phone || null,
    isAnonymous: user.is_anonymous === true,
    token,
  };
}
