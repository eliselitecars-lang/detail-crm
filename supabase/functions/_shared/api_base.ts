/**
 * Provider API base URL overrides — LOCAL / CI ONLY.
 *
 * The real-stack harness (scripts/stack/) points Stripe, Twilio and Resend at
 * local simulators (stripe-mock, scripts/stack/provider_mock.mjs) by setting:
 *
 *   STRIPE_API_BASE   e.g. http://host.docker.internal:12111   (default https://api.stripe.com)
 *   TWILIO_API_BASE   e.g. http://host.docker.internal:12120/2010-04-01
 *                                                  (default https://api.twilio.com/2010-04-01)
 *   RESEND_API_BASE   e.g. http://host.docker.internal:12120   (default https://api.resend.com)
 *
 * They are never set in hosted projects, so production always talks to the
 * real hosts (the defaults). Values are read once, at module load; an invalid
 * value throws so a misconfigured harness fails loudly instead of silently
 * reaching a real provider.
 */

export const DEFAULT_STRIPE_API_BASE = "https://api.stripe.com";
export const DEFAULT_TWILIO_API_BASE = "https://api.twilio.com/2010-04-01";
export const DEFAULT_RESEND_API_BASE = "https://api.resend.com";

export type ApiBaseName = "STRIPE_API_BASE" | "TWILIO_API_BASE" | "RESEND_API_BASE";

/** Reads a variable without requiring --allow-env (denied/unset -> undefined). */
export function readEnvSafely(name: string): string | undefined {
  try {
    return Deno.env.get(name);
  } catch {
    return undefined;
  }
}

/**
 * The override for `name` (http(s) URL without query/fragment, trailing slash
 * removed) or `fallback` when unset/blank.
 */
export function apiBaseFromEnv(
  name: ApiBaseName,
  fallback: string,
  read: (name: string) => string | undefined = readEnvSafely,
): string {
  const raw = read(name)?.trim();
  if (!raw) return fallback;
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    throw new Error(`${name} must be an http(s) URL`);
  }
  if ((url.protocol !== "http:" && url.protocol !== "https:") || url.search || url.hash) {
    throw new Error(`${name} must be an http(s) URL without query or fragment`);
  }
  return url.toString().replace(/\/+$/, "");
}

export interface StripeHostOptions {
  host?: string;
  port?: number;
  protocol?: "http" | "https";
}

/**
 * Stripe SDK host options for STRIPE_API_BASE ({} when unset, i.e. the SDK's
 * own default https://api.stripe.com). The Stripe SDK takes host/port/
 * protocol, not a URL, and a path is not supported.
 */
export function stripeHostOptions(
  read: (name: string) => string | undefined = readEnvSafely,
): StripeHostOptions {
  const base = apiBaseFromEnv("STRIPE_API_BASE", DEFAULT_STRIPE_API_BASE, read);
  if (base === DEFAULT_STRIPE_API_BASE) return {};
  const url = new URL(base);
  if (url.pathname !== "/") throw new Error("STRIPE_API_BASE must not contain a path");
  const protocol = url.protocol === "http:" ? "http" : "https";
  return {
    host: url.hostname,
    port: url.port ? Number(url.port) : protocol === "http" ? 80 : 443,
    protocol,
  };
}
