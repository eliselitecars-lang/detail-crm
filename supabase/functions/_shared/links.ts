/**
 * Public web links sent to customers (SPEC §6 routes). Always built from
 * APP_BASE_URL so SMS/email/Stripe return URLs point at the right deploy.
 */

function build(baseUrl: string, path: string): string {
  return `${baseUrl.replace(/\/+$/, "")}${path}`;
}

function segment(value: string): string {
  if (value === "") throw new TypeError("link segment must not be empty");
  return encodeURIComponent(value);
}

export const links = {
  booking: (baseUrl: string, token: string): string => build(baseUrl, `/booking/${segment(token)}`),
  quote: (baseUrl: string, token: string): string => build(baseUrl, `/q/${segment(token)}`),
  invoice: (baseUrl: string, token: string): string => build(baseUrl, `/i/${segment(token)}`),
  form: (baseUrl: string, token: string): string => build(baseUrl, `/f/${segment(token)}`),
  invite: (baseUrl: string, token: string): string => build(baseUrl, `/invite/${segment(token)}`),
  bookingPage: (baseUrl: string, slug: string): string => build(baseUrl, `/book/${segment(slug)}`),
  portal: (baseUrl: string): string => build(baseUrl, "/portal"),
  /**
   * Staff payments settings page Stripe Connect onboarding returns to:
   * `return` after the account link flow, `refresh` when the link expired.
   */
  stripeConnect: (baseUrl: string, state: "refresh" | "return"): string =>
    build(baseUrl, `/app/settings/payments?stripe=${state}`),
} as const;

/**
 * `url` with query parameters added (or replaced), e.g. Stripe Checkout
 * success/cancel URLs: `withQuery(links.invoice(base, token), { paid: "1" })`.
 */
export function withQuery(url: string, params: Readonly<Record<string, string>>): string {
  const parsed = new URL(url);
  for (const [key, value] of Object.entries(params)) parsed.searchParams.set(key, value);
  return parsed.toString();
}

/** Public URL of an edge function (+ optional query), e.g. Twilio callbacks. */
export function functionUrl(
  functionsPublicUrl: string,
  name: string,
  query: Readonly<Record<string, string>> = {},
): string {
  if (!/^[a-z][a-z0-9-]*$/.test(name)) throw new TypeError("invalid function name");
  const search = new URLSearchParams(query).toString();
  return `${functionsPublicUrl.replace(/\/+$/, "")}/${name}${search ? `?${search}` : ""}`;
}

/**
 * The public URL a provider called, rebuilt from the configured functions
 * base plus the request's own query string (verbatim). Use this — not
 * `req.url`, which may carry an internal host/scheme — for signature checks.
 */
export function publicRequestUrl(functionsPublicUrl: string, name: string, req: Request): string {
  return `${functionUrl(functionsPublicUrl, name)}${new URL(req.url).search}`;
}
