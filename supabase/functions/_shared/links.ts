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
} as const;

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
