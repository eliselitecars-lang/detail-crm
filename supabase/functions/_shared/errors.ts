/**
 * Stable, client-facing error codes. Clients (web + iOS) switch on `code`,
 * never on `message`, so codes are a public contract: add new ones, never
 * rename or repurpose existing ones.
 */
export const ERROR_STATUS = {
  bad_request: 400,
  invalid_json: 400,
  validation_failed: 400,
  unknown_action: 400,
  invalid_signature: 400,
  unauthorized: 401,
  payment_failed: 402,
  /** The shop's subscription is inactive or its plan's seat limit is reached (PT402). */
  payment_required: 402,
  forbidden: 403,
  origin_not_allowed: 403,
  not_found: 404,
  method_not_allowed: 405,
  conflict: 409,
  gone: 410,
  payload_too_large: 413,
  unsupported_media_type: 415,
  unprocessable: 422,
  rate_limited: 429,
  internal_error: 500,
  server_misconfigured: 500,
  upstream_error: 502,
  service_unavailable: 503,
} as const;

export type ErrorCode = keyof typeof ERROR_STATUS;

export const ERROR_CODES = Object.keys(ERROR_STATUS) as ErrorCode[];

export interface HttpErrorOptions {
  /** Overrides the default status for the code. */
  status?: number;
  /** Extra JSON-safe data for the client (e.g. validation issues). */
  details?: unknown;
  /** Internal cause; logged, never sent to the client. */
  cause?: unknown;
  /** Extra response headers (e.g. `Allow` for 405, `Retry-After` for 429). */
  headers?: Record<string, string>;
}

/**
 * An error whose `code`, `message` and `details` are safe to show the caller.
 * Anything that is not an HttpError (or mapped to one) becomes a generic
 * `internal_error` so internals never leak.
 */
export class HttpError extends Error {
  readonly code: ErrorCode;
  readonly status: number;
  readonly details: unknown;
  readonly headers: Record<string, string>;

  constructor(code: ErrorCode, message: string, options: HttpErrorOptions = {}) {
    super(message, options.cause === undefined ? undefined : { cause: options.cause });
    this.name = "HttpError";
    this.code = code;
    this.status = options.status ?? ERROR_STATUS[code];
    this.details = options.details;
    this.headers = options.headers ?? {};
  }
}

/** Convenience constructors for the common cases. */
export const errors = {
  badRequest: (message = "The request is invalid.", details?: unknown): HttpError =>
    new HttpError("bad_request", message, { details }),
  unauthorized: (message = "Sign in to continue."): HttpError =>
    new HttpError("unauthorized", message, { headers: { "WWW-Authenticate": "Bearer" } }),
  forbidden: (message = "You do not have permission to do that."): HttpError =>
    new HttpError("forbidden", message),
  notFound: (message = "Not found."): HttpError => new HttpError("not_found", message),
  conflict: (message: string, details?: unknown): HttpError =>
    new HttpError("conflict", message, { details }),
  gone: (message: string): HttpError => new HttpError("gone", message),
  unprocessable: (message: string, details?: unknown): HttpError =>
    new HttpError("unprocessable", message, { details }),
} as const;

// ---------------------------------------------------------------------------
// Shop subscription refusals (PT402, migration 0102)
// ---------------------------------------------------------------------------

/**
 * SQLSTATE the database raises when a shop's subscription is inactive
 * (new business records are paused) or its plan's seat limit is reached.
 * PostgREST answers it with HTTP 402; functions answer `402
 * payment_required` with the database's own sentence.
 */
export const SUBSCRIPTION_SQLSTATE = "PT402";

/** `details.reason` of a `payment_required` answer. */
export type PaymentRequiredReason = "subscription_inactive" | "seat_limit";

/**
 * The database's neutral sentence (0102 billing_inactive_message), used only
 * when a PT402 arrives without one. Shown verbatim on iPhone: no prices, no
 * purchase wording.
 */
export const SUBSCRIPTION_INACTIVE_MESSAGE =
  "This shop's subscription is inactive, so new records can't be created right now.";

/** 0102 billing_seats_message: "This shop's plan allows N team member(s)." */
const SEAT_LIMIT_MESSAGE = /^This shop's plan allows \d+ team members?\.$/;

export function paymentRequiredReason(message: string): PaymentRequiredReason {
  return SEAT_LIMIT_MESSAGE.test(message.trim()) ? "seat_limit" : "subscription_inactive";
}

interface PgErrorLike {
  code?: unknown;
  message?: unknown;
}

/**
 * A database refusal with SQLSTATE PT402 as the standard `402
 * payment_required` error: the database's message verbatim (it is written
 * for people and deliberately neutral) and `details.reason`
 * `subscription_inactive` or `seat_limit`. null for any other error.
 */
export function subscriptionRefusal(error: PgErrorLike | null | undefined): HttpError | null {
  if (!error || typeof error !== "object" || error.code !== SUBSCRIPTION_SQLSTATE) return null;
  const text = typeof error.message === "string" ? error.message.replace(/\s+/g, " ").trim() : "";
  const message = text || SUBSCRIPTION_INACTIVE_MESSAGE;
  return new HttpError("payment_required", message, {
    details: { reason: paymentRequiredReason(message) },
    cause: error,
  });
}

/**
 * The PT402 refusal anywhere in an error's `cause` chain (a PostgREST error
 * wrapped by a function's own "... failed" error), as `payment_required`.
 * The innermost PT402 wins: it is the database's own error, whose message
 * is the sentence to show. Used by the handler's error mapping so a PT402
 * that a call site did not map still answers 402, never 500.
 */
export function subscriptionRefusalIn(err: unknown): HttpError | null {
  let found: PgErrorLike | null = null;
  let node: unknown = err;
  for (let depth = 0; depth < 8 && typeof node === "object" && node !== null; depth++) {
    const candidate = node as PgErrorLike & { cause?: unknown };
    if (candidate.code === SUBSCRIPTION_SQLSTATE) found = candidate;
    node = candidate.cause;
  }
  return found ? subscriptionRefusal(found) : null;
}

/**
 * A failed call to a third-party API (Stripe, Twilio, Resend). The handler
 * maps it to `upstream_error` (502) with a generic message; the provider's
 * own message and code are only logged.
 */
export class UpstreamError extends Error {
  readonly provider: string;
  readonly httpStatus: number | null;
  readonly providerCode: string | null;

  constructor(
    provider: string,
    message: string,
    options: { httpStatus?: number | null; providerCode?: string | null; cause?: unknown } = {},
  ) {
    super(message, options.cause === undefined ? undefined : { cause: options.cause });
    this.name = "UpstreamError";
    this.provider = provider;
    this.httpStatus = options.httpStatus ?? null;
    this.providerCode = options.providerCode ?? null;
  }
}
