/**
 * Time caps for third-party HTTP calls (Twilio, Resend). A provider that
 * accepts the connection and then stops answering must fail the one request,
 * not hang the caller until the edge runtime kills the worker.
 */

/** Default cap on one provider request, response body included. */
export const PROVIDER_TIMEOUT_MS = 10_000;

/** A request that exceeded its time cap (a transport failure, like a network error). */
export class FetchTimeoutError extends Error {
  readonly timeoutMs: number;

  constructor(ms: number) {
    super(`the request did not complete within ${ms} ms`);
    this.name = "TimeoutError";
    this.timeoutMs = ms;
  }
}

/**
 * Wraps `base` so every request (headers AND body) settles within `ms`:
 * past the deadline the request is aborted and the promise rejects with
 * FetchTimeoutError, which sendSms / sendEmail report like any transport
 * failure (UpstreamError with no HTTP status). The body is read inside the
 * deadline and returned buffered (provider answers are small JSON), so a
 * response whose body stalls is bounded too. The promise rejects on time
 * even if `base` ignores the abort signal. A caller's own `signal` still
 * aborts the request.
 */
export function withTimeout(base: typeof fetch, ms: number = PROVIDER_TIMEOUT_MS): typeof fetch {
  if (!Number.isFinite(ms) || ms <= 0) throw new RangeError("timeout must be a positive number");
  return (input, init) => {
    const controller = new AbortController();
    const signal = init?.signal
      ? AbortSignal.any([init.signal, controller.signal])
      : controller.signal;
    return new Promise<Response>((resolve, reject) => {
      const timer = setTimeout(() => {
        const error = new FetchTimeoutError(ms);
        controller.abort(error);
        reject(error);
      }, ms);
      (async () => {
        const response = await base(input, { ...init, signal });
        const body = await response.arrayBuffer();
        return new Response(body.byteLength === 0 ? null : body, {
          status: response.status,
          statusText: response.statusText,
          headers: response.headers,
        });
      })().then(resolve, reject).finally(() => clearTimeout(timer));
    });
  };
}
