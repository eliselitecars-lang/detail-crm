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
