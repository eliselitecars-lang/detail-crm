/**
 * CORS for browser-called functions. Only exact, configured origins are
 * reflected (APP_BASE_URL's origin + CORS_ALLOWED_ORIGINS) — never `*` —
 * and credentials are not allowed (auth is a bearer header, not cookies).
 * Server-to-server calls (Stripe, Twilio, pg_cron) send no Origin and are
 * unaffected.
 */
import type { Env } from "./env.ts";
import { HttpError } from "./errors.ts";

export const CORS_ALLOW_METHODS = ["GET", "POST", "OPTIONS"] as const;

/** Headers supabase-js `functions.invoke` and our clients send. */
export const CORS_ALLOW_HEADERS = [
  "authorization",
  "x-client-info",
  "apikey",
  "content-type",
  "x-region",
  "idempotency-key",
  "x-request-id",
] as const;

export const CORS_EXPOSE_HEADERS = ["x-request-id", "retry-after"] as const;

const PREFLIGHT_MAX_AGE_SECONDS = 600;

export interface CorsPolicy {
  readonly allowedOrigins: ReadonlySet<string>;
}

export function corsPolicy(origins: Iterable<string>): CorsPolicy {
  return { allowedOrigins: new Set([...origins].map((origin) => new URL(origin).origin)) };
}

export function corsPolicyFromEnv(env: Env): CorsPolicy {
  return corsPolicy([new URL(env.appBaseUrl()).origin, ...env.corsExtraOrigins()]);
}

export function isOriginAllowed(origin: string | null, policy: CorsPolicy): origin is string {
  return origin !== null && policy.allowedOrigins.has(origin);
}

/** Headers to add to every (non-preflight) response of a browser-facing function. */
export function corsHeaders(req: Request, policy: CorsPolicy): Record<string, string> {
  const origin = req.headers.get("origin");
  const headers: Record<string, string> = { Vary: "Origin" };
  if (isOriginAllowed(origin, policy)) {
    headers["Access-Control-Allow-Origin"] = origin;
    headers["Access-Control-Expose-Headers"] = CORS_EXPOSE_HEADERS.join(", ");
  }
  return headers;
}

/**
 * Answers an OPTIONS preflight: 204 with the allow-lists for a configured
 * origin, 403 `origin_not_allowed` otherwise.
 */
export function preflightResponse(req: Request, policy: CorsPolicy): Response {
  const origin = req.headers.get("origin");
  if (!isOriginAllowed(origin, policy)) {
    throw new HttpError("origin_not_allowed", "This origin is not allowed.", {
      headers: { Vary: "Origin" },
    });
  }
  const requestedMethod = req.headers.get("access-control-request-method")?.toUpperCase();
  if (
    requestedMethod &&
    !(CORS_ALLOW_METHODS as readonly string[]).includes(requestedMethod)
  ) {
    throw new HttpError("method_not_allowed", "Method not allowed.", {
      headers: { Vary: "Origin", Allow: CORS_ALLOW_METHODS.join(", ") },
    });
  }
  return new Response(null, {
    status: 204,
    headers: {
      Vary: "Origin",
      "Access-Control-Allow-Origin": origin,
      "Access-Control-Allow-Methods": CORS_ALLOW_METHODS.join(", "),
      "Access-Control-Allow-Headers": CORS_ALLOW_HEADERS.join(", "),
      "Access-Control-Max-Age": String(PREFLIGHT_MAX_AGE_SECONDS),
    },
  });
}
