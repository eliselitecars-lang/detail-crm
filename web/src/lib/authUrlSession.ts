/**
 * Which sign-in links in the URL fragment the app accepts.
 *
 * Supabase email links use the implicit flow: GoTrue redirects to the app
 * with `#access_token=…&refresh_token=…&type=…`. The implicit flow is kept
 * because reset and confirmation links must work when they are opened on a
 * different device than the one that asked for them (PKCE needs the code
 * verifier of the requesting browser). But supabase-js' own detection
 * (`detectSessionInUrl: true`) accepts such a fragment on EVERY page and
 * saves it over the stored session: a link someone else built from their own
 * tokens would silently sign this browser in to their account (login CSRF).
 *
 * So the client lets supabase-js pick a session out of the URL only for a
 * password-recovery link on /reset-password, and only when it belongs to the
 * account already signed in here (or nobody is). Sign-up confirmation links
 * land on AUTH_CALLBACK_PATH, which shows the account the link is for and
 * saves the session only when the visitor chooses to continue
 * (features/auth/pages/AuthCallbackPage). Tokens on any other page, or a
 * recovery link for another account than the signed-in one, are ignored and
 * removed from the address bar.
 */

/** Where sign-up confirmation emails return to (`?next=` = where to go afterwards). */
export const AUTH_CALLBACK_PATH = '/auth/callback';
/** Where password-reset emails return to. */
export const RECOVERY_PATH = '/reset-password';

export type UrlSessionRefusal =
  /** A recovery link for another account than the one signed in here. */
  | 'other_account'
  /** Tokens on a page that is not an auth landing page. */
  | 'not_a_callback';

/** Tokens (or a link error) from an AUTH_CALLBACK_PATH fragment, held until the visitor decides. */
export interface CallbackLink {
  accessToken: string | null;
  refreshToken: string | null;
  /** GoTrue's `type` (signup, magiclink, email_change…). */
  type: string | null;
  /** GoTrue's error description for an expired / used link. */
  error: string | null;
  errorCode: string | null;
}

export interface UrlSessionDecision {
  /** Let supabase-js read and save the session in the URL. */
  detect: boolean;
  /** Remove the auth parameters from the address bar (tokens must not linger). */
  scrub: boolean;
  /** Why a session in the URL was not accepted (null when there was none, or it was). */
  refused: UrlSessionRefusal | null;
  /** AUTH_CALLBACK_PATH only: what the page offers the visitor. */
  callback: CallbackLink | null;
}

const AUTH_PARAMS = [
  'access_token',
  'refresh_token',
  'expires_in',
  'expires_at',
  'token_type',
  'provider_token',
  'provider_refresh_token',
  'type',
  'error',
  'error_code',
  'error_description',
] as const;

/** Fragment + query parameters, the way supabase-js reads them (query wins). */
export function urlParameters(href: string): Record<string, string> {
  const url = new URL(href);
  const result: Record<string, string> = {};
  if (url.hash.startsWith('#')) {
    new URLSearchParams(url.hash.slice(1)).forEach((value, key) => {
      result[key] = value;
    });
  }
  url.searchParams.forEach((value, key) => {
    result[key] = value;
  });
  return result;
}

/** `sub` of a JWT, WITHOUT verifying it (only to compare with the stored session). */
export function jwtSubject(token: string | null | undefined): string | null {
  const payload = token?.split('.')[1];
  if (!payload) return null;
  try {
    const base64 = payload.replace(/-/g, '+').replace(/_/g, '/');
    const padded = base64 + '='.repeat((4 - (base64.length % 4)) % 4);
    const parsed: unknown = JSON.parse(atob(padded));
    if (parsed && typeof parsed === 'object' && 'sub' in parsed) {
      const { sub } = parsed;
      return typeof sub === 'string' && sub !== '' ? sub : null;
    }
  } catch {
    // not a JWT
  }
  return null;
}

/** User id of the session supabase-js keeps in storage, or null. */
export function storedSessionUserId(raw: string | null | undefined): string | null {
  if (!raw) return null;
  try {
    const parsed: unknown = JSON.parse(raw);
    if (!parsed || typeof parsed !== 'object') return null;
    const session = parsed as { user?: { id?: unknown }; access_token?: unknown };
    if (typeof session.user?.id === 'string' && session.user.id !== '') return session.user.id;
    return typeof session.access_token === 'string' ? jwtSubject(session.access_token) : null;
  } catch {
    return null;
  }
}

/**
 * Decides what happens to auth parameters in the URL at start-up.
 * `storedUserId` is the account whose session is saved in this browser.
 */
export function decideUrlSession(href: string, storedUserId: string | null): UrlSessionDecision {
  const url = new URL(href);
  const params = urlParameters(href);
  const hasToken = Boolean(params.access_token || params.refresh_token);
  const hasError = Boolean(params.error || params.error_code || params.error_description);
  const none: UrlSessionDecision = { detect: false, scrub: false, refused: null, callback: null };

  if (url.pathname === AUTH_CALLBACK_PATH) {
    if (!hasToken && !hasError) return none;
    return {
      detect: false,
      scrub: true,
      refused: null,
      callback: {
        accessToken: params.access_token ?? null,
        refreshToken: params.refresh_token ?? null,
        type: params.type ?? null,
        error: hasError ? (params.error_description ?? params.error ?? 'error') : null,
        errorCode: params.error_code ?? null,
      },
    };
  }

  if (url.pathname === RECOVERY_PATH) {
    // A link error: supabase-js reports it (ResetPasswordPage reads it first).
    if (!hasToken) return { ...none, detect: hasError };
    if (params.type !== 'recovery') return { ...none, scrub: true, refused: 'not_a_callback' };
    const linkUser = jwtSubject(params.access_token);
    if (storedUserId !== null && linkUser !== storedUserId) {
      return { ...none, scrub: true, refused: 'other_account' };
    }
    return { ...none, detect: true };
  }

  return hasToken ? { ...none, scrub: true, refused: 'not_a_callback' } : none;
}

/** `href` without the auth parameters (fragment and query), for history.replaceState. */
export function scrubbedUrl(href: string): string {
  const url = new URL(href);
  for (const key of AUTH_PARAMS) url.searchParams.delete(key);
  if (url.hash.startsWith('#')) {
    const fragment = new URLSearchParams(url.hash.slice(1));
    const looksLikeParams = url.hash.includes('=');
    if (looksLikeParams) {
      for (const key of AUTH_PARAMS) fragment.delete(key);
      const rest = fragment.toString();
      url.hash = rest ? `#${rest}` : '';
    }
  }
  return `${url.pathname}${url.search}${url.hash}`;
}

let startup: UrlSessionDecision = {
  detect: false,
  scrub: false,
  refused: null,
  callback: null,
};

/**
 * Runs once, when the Supabase client is created (lib/supabase.ts): decides,
 * removes the parameters from the address bar when needed and remembers the
 * outcome for the pages. Returns the decision for `detectSessionInUrl`.
 */
export function inspectStartupUrl(storageKey: string): UrlSessionDecision {
  if (typeof window === 'undefined') return startup;
  let stored: string | null = null;
  try {
    stored = window.localStorage.getItem(storageKey);
  } catch {
    stored = null;
  }
  startup = decideUrlSession(window.location.href, storedSessionUserId(stored));
  if (startup.scrub) {
    try {
      window.history.replaceState(window.history.state, '', scrubbedUrl(window.location.href));
    } catch {
      // the page still works; supabase-js was told not to use the tokens
    }
  }
  return startup;
}

/** Why a sign-in link on this page load was ignored (null when none was). */
export function startupRefusal(): UrlSessionRefusal | null {
  return startup.refused;
}

/**
 * The sign-up confirmation link this page load arrived with (AUTH_CALLBACK_PATH),
 * or null. Kept in memory only.
 */
export function startupCallbackLink(): CallbackLink | null {
  return startup.callback;
}

/** After the visitor continued or declined: the tokens are dropped. */
export function forgetCallbackLink(): void {
  startup = { ...startup, callback: null };
}
