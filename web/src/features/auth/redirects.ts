/**
 * `next` redirect handling for auth pages. Only same-origin, absolute paths
 * are accepted — never "//evil.com", "https://…", or "/\\evil.com".
 *
 * `next` must be the value exactly as it will be navigated to: already
 * decoded once by URLSearchParams (LoginPage/SignupPage) or taken from the
 * router location (RequireAuth). It is never decoded again — that would turn
 * "?q=%2520" into "?q=%20" and throw on a literal "%" ("?q=100%").
 */
export const DEFAULT_AFTER_LOGIN = '/app';

const AUTH_PAGE_RE = /^\/(?:login|signup)(?:[/?#]|$)/;

export function safeNext(next: string | null | undefined, fallback = DEFAULT_AFTER_LOGIN): string {
  if (!next) return fallback;
  if (!next.startsWith('/') || next.startsWith('//') || next.startsWith('/\\')) return fallback;
  // Control characters (tab/newline are stripped by URL parsing: "/\t/evil" → "//evil").
  for (let i = 0; i < next.length; i += 1) {
    const code = next.charCodeAt(i);
    if (code < 0x20 || code === 0x7f) return fallback;
  }
  if (AUTH_PAGE_RE.test(next)) return fallback;
  return next;
}

export function loginPath(next?: string): string {
  const target = next ? safeNext(next, '') : '';
  return target && target !== DEFAULT_AFTER_LOGIN
    ? `/login?next=${encodeURIComponent(target)}`
    : '/login';
}

export function signupPath(next?: string): string {
  const target = next ? safeNext(next, '') : '';
  return target && target !== DEFAULT_AFTER_LOGIN
    ? `/signup?next=${encodeURIComponent(target)}`
    : '/signup';
}

/** Absolute URL on this origin, for Supabase email redirect links. */
export function absoluteUrl(path: string): string {
  return new URL(path, window.location.origin).toString();
}

/**
 * Reads an auth error Supabase appended to the recovery redirect
 * (`#error=access_denied&error_code=otp_expired&error_description=…` or the
 * same in the query string). Captured once, before supabase-js cleans the URL.
 */
export function readRecoveryLinkError(href: string): string | null {
  const url = new URL(href);
  const params = new URLSearchParams(url.hash.startsWith('#') ? url.hash.slice(1) : url.hash);
  const description =
    params.get('error_description') ??
    url.searchParams.get('error_description') ??
    params.get('error');
  if (!description) return null;
  const code = params.get('error_code') ?? url.searchParams.get('error_code');
  if (code === 'otp_expired' || /expired|invalid/i.test(description)) {
    return 'This reset link is invalid or has expired. Request a new one.';
  }
  return description.replace(/\+/g, ' ');
}
