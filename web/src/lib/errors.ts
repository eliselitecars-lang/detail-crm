/**
 * Maps anything thrown by supabase-js (PostgREST / Postgres errors, auth
 * errors, edge-function errors, network failures) to one user-facing message.
 *
 * Rules
 * - RAISE EXCEPTION messages from our own SQL (any SQLSTATE — the DB uses
 *   22023/42501/23505/P0002 with human text) are shown sentence-cased.
 *   Postgres' own wording ("violates … constraint", "row-level security"…)
 *   is recognised and replaced with friendly text.
 * - RLS denials (42501 / "row-level security") never leak policy names.
 * - Shop subscription refusals (SQLSTATE PT402 through PostgREST, or an edge
 *   function's `402 payment_required` envelope) become kind `subscription`
 *   with the server's neutral sentence verbatim; the web adds its own
 *   owner-only "Go to Billing" link (features/billing).
 * - Constraint violations get friendly generic wording; callers can map a
 *   specific constraint to a field error via `AppError.constraint`.
 * - Unknown errors fall back to a generic sentence; the original error is kept
 *   in `cause` for logging.
 */

export type AppErrorKind =
  | 'permission'
  | 'not_found'
  | 'conflict'
  | 'validation'
  | 'auth'
  | 'session_expired'
  | 'network'
  | 'rate_limited'
  | 'server'
  /** The shop's subscription is inactive, or its plan's seat limit is reached (PT402 / HTTP 402). */
  | 'subscription'
  | 'unknown';

export interface AppErrorOptions {
  kind?: AppErrorKind;
  code?: string | undefined;
  constraint?: string | undefined;
  status?: number | undefined;
  cause?: unknown;
}

export class AppError extends Error {
  readonly kind: AppErrorKind;
  /** SQLSTATE / PostgREST / auth error code when known. */
  readonly code: string | undefined;
  /** Constraint name for 23xxx violations when PostgREST reports it. */
  readonly constraint: string | undefined;
  readonly status: number | undefined;

  constructor(message: string, options: AppErrorOptions = {}) {
    super(message, { cause: options.cause });
    this.name = 'AppError';
    this.kind = options.kind ?? 'unknown';
    this.code = options.code;
    this.constraint = options.constraint;
    this.status = options.status;
  }
}

export const GENERIC_ERROR_MESSAGE = 'Something went wrong. Please try again.';
export const SESSION_EXPIRED_MESSAGE = 'Your session has expired. Sign in again.';
export const PERMISSION_MESSAGE = "You don't have permission to do that.";
const RATE_LIMITED_MESSAGE = 'Too many attempts. Please wait a minute and try again.';

/**
 * SQLSTATE of a shop subscription refusal (0102): PostgREST answers it with
 * HTTP 402. Edge functions answer `402 payment_required` with the same text.
 */
export const SUBSCRIPTION_SQLSTATE = 'PT402';
/** The edge envelope `code` of a subscription refusal (never `payment_failed`, a card decline). */
export const SUBSCRIPTION_EDGE_CODE = 'payment_required';
/**
 * The database's own neutral sentence (0102 billing_inactive_message), used
 * only when a refusal arrives without text. Never a price or a call to buy.
 */
export const SUBSCRIPTION_INACTIVE_MESSAGE =
  "This shop's subscription is inactive, so new records can't be created right now.";
/** 0102 billing_seats_message: "This shop's plan allows N team member(s)." */
const SEAT_LIMIT_MESSAGE_RE = /^This shop's plan allows \d+ team members?\.$/;

export type SubscriptionRefusalReason = 'subscription_inactive' | 'seat_limit';

function subscriptionError(message: string, options: Omit<AppErrorOptions, 'kind'>): AppError {
  const text = message.replace(/\s+/g, ' ').trim();
  return new AppError(text || SUBSCRIPTION_INACTIVE_MESSAGE, { ...options, kind: 'subscription' });
}

interface ErrorLike {
  message?: unknown;
  code?: unknown;
  details?: unknown;
  status?: unknown;
  name?: unknown;
}

function str(value: unknown): string | undefined {
  return typeof value === 'string' && value.length > 0 ? value : undefined;
}

function num(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isFinite(value) ? value : undefined;
}

function extractConstraint(...texts: (string | undefined)[]): string | undefined {
  for (const text of texts) {
    const match = text?.match(/constraint "([^"]+)"/);
    if (match?.[1]) return match[1];
  }
  return undefined;
}

const AUTH_MESSAGES: [RegExp, string, AppErrorKind][] = [
  [/invalid login credentials/i, 'Email or password is incorrect.', 'auth'],
  [
    /email not confirmed/i,
    'Please confirm your email first — check your inbox for the link.',
    'auth',
  ],
  [
    /user already registered|already been registered/i,
    'An account with this email already exists. Try signing in.',
    'conflict',
  ],
  [
    /password should be at least|weak.?password/i,
    'Choose a stronger password (at least 8 characters).',
    'validation',
  ],
  [
    /new password should be different/i,
    'Your new password must be different from the old one.',
    'validation',
  ],
  [/unable to validate email|invalid email/i, 'Enter a valid email address.', 'validation'],
  [
    /(email )?link is invalid or has expired|otp.*expired|token has expired/i,
    'This link is invalid or has expired. Request a new one.',
    'auth',
  ],
  [
    /rate limit|too many requests|over_email_send_rate_limit/i,
    'Too many attempts. Please wait a minute and try again.',
    'rate_limited',
  ],
  [
    /auth session missing|refresh token/i,
    'Your session expired. Please sign in again.',
    'session_expired',
  ],
  [/signups not allowed|signup.*disabled/i, 'New sign-ups are currently disabled.', 'auth'],
];

const AUTH_CODES: Record<string, [string, AppErrorKind]> = {
  invalid_credentials: ['Email or password is incorrect.', 'auth'],
  email_not_confirmed: ['Please confirm your email first — check your inbox for the link.', 'auth'],
  user_already_exists: ['An account with this email already exists. Try signing in.', 'conflict'],
  email_exists: ['An account with this email already exists. Try signing in.', 'conflict'],
  weak_password: ['Choose a stronger password (at least 8 characters).', 'validation'],
  same_password: ['Your new password must be different from the old one.', 'validation'],
  otp_expired: ['This link is invalid or has expired. Request a new one.', 'auth'],
  over_email_send_rate_limit: [
    'Too many emails sent. Please wait a minute and try again.',
    'rate_limited',
  ],
  over_request_rate_limit: [
    'Too many attempts. Please wait a minute and try again.',
    'rate_limited',
  ],
  session_not_found: ['Your session expired. Please sign in again.', 'session_expired'],
  refresh_token_not_found: ['Your session expired. Please sign in again.', 'session_expired'],
  signup_disabled: ['New sign-ups are currently disabled.', 'auth'],
};

/**
 * Postgres' own wording for errors (as opposed to our RAISE EXCEPTION text).
 * Anything matching is replaced by a friendly generic sentence; anything
 * else carrying a SQLSTATE came from our SQL and is written for end users.
 */
const INTERNAL_MESSAGE_RE =
  /violates (unique|foreign key|check|not-null|exclusion) constraint|duplicate key value|row-level security|permission denied for|invalid input (syntax|value)|out of range|value too long|null value in column|does not exist|could not (serialize|obtain|open|choose|determine|identify)|syntax error|cannot be cast|operator does not exist|malformed|canceling statement|deadlock detected|could not serialize|schema cache/i;

function isInternalMessage(message: string): boolean {
  return message === '' || INTERNAL_MESSAGE_RE.test(message);
}

/** "slug is already taken" → "Slug is already taken." */
export function sentenceCase(message: string): string {
  const text = message.trim();
  if (text === '') return text;
  const first = text.charAt(0).toUpperCase() + text.slice(1);
  return /[.!?…]$/.test(first) ? first : `${first}.`;
}

function kindForCode(code: string): AppErrorKind {
  if (code === '42501' || code.startsWith('28')) return 'permission';
  // PT404: our public RPCs' "not found" (HTTP 404 through PostgREST).
  if (code === 'P0002' || code === 'PT404' || code === 'PGRST116') return 'not_found';
  if (
    code === '23505' ||
    code === '23503' ||
    code === '23P01' ||
    code === '40001' ||
    code === '40P01'
  ) {
    return 'conflict';
  }
  if (code.startsWith('22') || code.startsWith('23') || code.startsWith('P0')) return 'validation';
  return 'unknown';
}

function fromPostgres(code: string, message: string, details?: string): AppError {
  const constraint = extractConstraint(message, details);
  const base = { code, constraint };

  // PostgREST's own codes are never user-facing text.
  if (code.startsWith('PGRST')) {
    switch (code) {
      case 'PGRST116':
        return new AppError('That record could not be found.', { ...base, kind: 'not_found' });
      case 'PGRST301':
      case 'PGRST302':
      case 'PGRST303':
        return new AppError('Your session expired. Please sign in again.', {
          ...base,
          kind: 'session_expired',
        });
      case 'PGRST202':
      case 'PGRST205':
        return new AppError('This feature is not available on the server yet.', {
          ...base,
          kind: 'server',
        });
      default:
        return new AppError(GENERIC_ERROR_MESSAGE, { ...base, kind: 'unknown' });
    }
  }

  // Shop subscription refusal: the database's neutral sentence, verbatim.
  if (code === SUBSCRIPTION_SQLSTATE) return subscriptionError(message, base);

  // Our own RAISE EXCEPTION messages (any SQLSTATE) are written for humans.
  if (!isInternalMessage(message)) {
    return new AppError(sentenceCase(message), { ...base, kind: kindForCode(code) });
  }

  switch (code) {
    case '42501':
      return new AppError(PERMISSION_MESSAGE, { ...base, kind: 'permission' });
    case '23505':
      return new AppError('That already exists. Use a different value.', {
        ...base,
        kind: 'conflict',
      });
    case '23503':
      return new AppError(
        /still referenced/i.test(details ?? '') || /^update or delete on table/i.test(message)
          ? 'This is still in use by other records, so it can’t be removed. Archive it instead.'
          : 'This refers to something that no longer exists. Refresh and try again.',
        { ...base, kind: 'conflict' },
      );
    case '23514':
      return new AppError(
        'Some values are out of the allowed range. Check the form and try again.',
        {
          ...base,
          kind: 'validation',
        },
      );
    case '23502':
      return new AppError('A required field is missing.', { ...base, kind: 'validation' });
    case '23P01':
      return new AppError('That overlaps with an existing entry.', { ...base, kind: 'conflict' });
    case '22P02':
    case '22007':
    case '22008':
    case '22003':
    case '22001':
    case '22023':
      return new AppError('Some values are not in a valid format.', {
        ...base,
        kind: 'validation',
      });
    case '40001':
    case '40P01':
      return new AppError('Someone else changed this at the same time. Please try again.', {
        ...base,
        kind: 'conflict',
      });
    case '57014':
      return new AppError('That took too long. Please try again.', { ...base, kind: 'server' });
    default:
      break;
  }

  if (/row-level security|permission denied/i.test(message)) {
    return new AppError("You don't have permission to do that.", { ...base, kind: 'permission' });
  }
  return new AppError(GENERIC_ERROR_MESSAGE, { ...base, kind: 'unknown' });
}

/** Normalises any thrown value into an `AppError` (idempotent). */
export function toAppError(error: unknown): AppError {
  if (error instanceof AppError) return error;

  if (error instanceof TypeError && /fetch|network|load failed/i.test(error.message)) {
    return new AppError("Can't reach the server. Check your connection and try again.", {
      kind: 'network',
      cause: error,
    });
  }

  if (typeof error === 'object' && error !== null) {
    const e = error as ErrorLike;
    const message = str(e.message) ?? '';
    const code = str(e.code);
    const status = num(e.status);
    const name = str(e.name) ?? '';

    // supabase-js edge-function errors
    if (name === 'FunctionsFetchError') {
      return new AppError("Can't reach the server. Check your connection and try again.", {
        kind: 'network',
        cause: error,
      });
    }

    // Supabase Auth (AuthApiError / AuthWeakPasswordError / ...)
    if (name.startsWith('Auth') || name === 'AuthApiError') {
      if (code && AUTH_CODES[code]) {
        const [msg, kind] = AUTH_CODES[code];
        return new AppError(msg, { kind, code, status, cause: error });
      }
      for (const [pattern, msg, kind] of AUTH_MESSAGES) {
        if (pattern.test(message)) return new AppError(msg, { kind, code, status, cause: error });
      }
      if (status === 429) {
        return new AppError('Too many attempts. Please wait a minute and try again.', {
          kind: 'rate_limited',
          code,
          status,
          cause: error,
        });
      }
      return new AppError(message || GENERIC_ERROR_MESSAGE, {
        kind: 'auth',
        code,
        status,
        cause: error,
      });
    }

    // PostgREST / Postgres
    if (code && (/^[0-9A-Z]{5}$/.test(code) || code.startsWith('PGRST'))) {
      const appError = fromPostgres(code, message, str(e.details));
      return new AppError(appError.message, {
        kind: appError.kind,
        code: appError.code,
        constraint: appError.constraint,
        status,
        cause: error,
      });
    }

    if (/failed to fetch|networkerror|network request failed|load failed/i.test(message)) {
      return new AppError("Can't reach the server. Check your connection and try again.", {
        kind: 'network',
        cause: error,
      });
    }
    if (status === 429) {
      return new AppError('Too many attempts. Please wait a minute and try again.', {
        kind: 'rate_limited',
        status,
        cause: error,
      });
    }
  }

  return new AppError(GENERIC_ERROR_MESSAGE, { kind: 'unknown', cause: error });
}

/** Shortcut for rendering: the friendly message for any thrown value. */
export function errorMessage(error: unknown): string {
  return toAppError(error).message;
}

/** True when retrying cannot help (permissions, validation, not found…). */
export function isNonRetryable(error: unknown): boolean {
  const kind = toAppError(error).kind;
  return (
    kind === 'permission' ||
    kind === 'validation' ||
    kind === 'not_found' ||
    kind === 'conflict' ||
    kind === 'auth' ||
    kind === 'session_expired' ||
    kind === 'subscription'
  );
}

/**
 * A shop subscription refusal (PT402 from PostgREST or an edge function's
 * `402 payment_required`): new records are paused or the plan's seat limit
 * is reached. Card declines (`402 payment_failed`) are not.
 */
export function isSubscriptionError(error: unknown): boolean {
  return toAppError(error).kind === 'subscription';
}

/** Which subscription refusal it is (null for any other error). */
export function subscriptionRefusalReason(error: unknown): SubscriptionRefusalReason | null {
  const appError = toAppError(error);
  if (appError.kind !== 'subscription') return null;
  return SEAT_LIMIT_MESSAGE_RE.test(appError.message) ? 'seat_limit' : 'subscription_inactive';
}

function kindForStatus(status: number): AppErrorKind {
  if (status === 401) return 'session_expired';
  if (status === 403) return 'permission';
  if (status === 404) return 'not_found';
  if (status === 409) return 'conflict';
  if (status === 429) return 'rate_limited';
  if (status >= 500) return 'server';
  return 'validation';
}

/**
 * An HTTP failure whose body is NOT our envelope (the Supabase gateway's
 * `{ code: 401, message: 'Invalid JWT' }`, a proxy's HTML page, an empty
 * body…): the status decides, never the gateway's wording.
 */
function fromHttpStatus(status: number, message: string | undefined, cause: unknown): AppError {
  const base = { status, cause };
  if (status === 401)
    return new AppError(SESSION_EXPIRED_MESSAGE, { ...base, kind: 'session_expired' });
  if (status === 403) return new AppError(PERMISSION_MESSAGE, { ...base, kind: 'permission' });
  if (status === 404) return new AppError('Not found.', { ...base, kind: 'not_found' });
  if (status === 429) return new AppError(RATE_LIMITED_MESSAGE, { ...base, kind: 'rate_limited' });
  if (status >= 500 || !message) {
    return new AppError(GENERIC_ERROR_MESSAGE, {
      ...base,
      kind: status >= 500 ? 'server' : 'unknown',
    });
  }
  return new AppError(sentenceCase(message), { ...base, kind: kindForStatus(status) });
}

/**
 * Edge functions (supabase.functions.invoke) return `FunctionsHttpError`
 * whose JSON body is our envelope `{ error, code, details? }` (see
 * supabase/functions/_shared/errors.ts): its `error` text is written for end
 * users and shown as-is, with the kind taken from the HTTP status. Any other
 * body (`{ message }` / `{ msg }` from the gateway or auth, non-JSON) falls
 * back to the HTTP status (401 → session expired, 403 → permission, 404 →
 * not found, 429 → rate limited, 5xx → generic).
 */
export async function edgeFunctionError(error: unknown): Promise<AppError> {
  if (typeof error === 'object' && error !== null) {
    const e = error as { name?: unknown; context?: unknown };
    if (e.name === 'FunctionsHttpError' && e.context instanceof Response) {
      const status = e.context.status;
      let body: unknown = null;
      try {
        body = await e.context.clone().json();
      } catch {
        // not JSON: the status decides
      }
      const fields =
        typeof body === 'object' && body !== null ? (body as Record<string, unknown>) : {};
      const envelopeMessage = str(fields.error);
      // 402 payment_required: the shop's subscription refusal (a card
      // decline is 402 payment_failed and stays a validation error).
      if (status === 402 && fields.code === SUBSCRIPTION_EDGE_CODE) {
        return subscriptionError(envelopeMessage ?? '', {
          status,
          code: SUBSCRIPTION_SQLSTATE,
          cause: error,
        });
      }
      if (envelopeMessage) {
        return new AppError(envelopeMessage, { kind: kindForStatus(status), status, cause: error });
      }
      return fromHttpStatus(status, str(fields.message) ?? str(fields.msg), error);
    }
  }
  return toAppError(error);
}
