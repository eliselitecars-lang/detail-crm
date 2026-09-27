/**
 * HTTP plumbing shared by every function: JSON responses, a stable error
 * envelope, size-limited body parsing with zod validation, and `createHandler`
 * which wraps a function body with CORS, method checks, request ids,
 * structured logs and error mapping that never leaks internals.
 *
 * Error envelope (all non-2xx JSON responses):
 *   { "error": string (human message), "code": ErrorCode,
 *     "details"?: unknown, "request_id": string }
 * `error` is a plain string so web's `edgeFunctionError` (web/src/lib/errors.ts)
 * reads it directly; clients branch on `code`.
 */
import { z } from "zod";
import { corsHeaders, type CorsPolicy, corsPolicyFromEnv, preflightResponse } from "./cors.ts";
import { type Env, env as defaultEnv, EnvError } from "./env.ts";
import { type ErrorCode, HttpError, UpstreamError } from "./errors.ts";
import { requestIdFor } from "./ids.ts";
import { type Logger, logger as defaultLogger } from "./log.ts";
import { isStripeError, stripeErrorToHttpError } from "./stripe_errors.ts";

export const DEFAULT_MAX_BODY_BYTES = 256 * 1024;

const JSON_HEADERS = { "Content-Type": "application/json; charset=utf-8" } as const;

export function json(data: unknown, init: ResponseInit = {}): Response {
  const headers = new Headers(init.headers);
  for (const [key, value] of Object.entries(JSON_HEADERS)) {
    if (!headers.has(key)) headers.set(key, value);
  }
  return new Response(JSON.stringify(data), { ...init, headers });
}

export interface ErrorBody {
  error: string;
  code: ErrorCode;
  details?: unknown;
  request_id: string;
}

export function errorResponse(err: HttpError, requestId: string): Response {
  const body: ErrorBody = { error: err.message, code: err.code, request_id: requestId };
  if (err.details !== undefined) body.details = err.details;
  return json(body, { status: err.status, headers: err.headers });
}

// ---------------------------------------------------------------------------
// Body parsing
// ---------------------------------------------------------------------------

export interface BodyOptions {
  maxBytes?: number;
}

/** Reads the body as UTF-8 text, enforcing a byte limit while streaming. */
export async function readText(req: Request, options: BodyOptions = {}): Promise<string> {
  const maxBytes = options.maxBytes ?? DEFAULT_MAX_BODY_BYTES;
  const tooLarge = () =>
    new HttpError("payload_too_large", `The request body must be at most ${maxBytes} bytes.`);
  const declared = req.headers.get("content-length");
  if (declared !== null && /^\d+$/.test(declared) && Number(declared) > maxBytes) throw tooLarge();
  if (!req.body) return "";
  const reader = req.body.getReader();
  const chunks: Uint8Array[] = [];
  let received = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    received += value.byteLength;
    if (received > maxBytes) {
      await reader.cancel();
      throw tooLarge();
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(received);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    throw new HttpError("bad_request", "The request body is not valid UTF-8.");
  }
}

function mediaType(req: Request): string {
  return (req.headers.get("content-type") ?? "").split(";")[0]?.trim().toLowerCase() ?? "";
}

/** Parses a JSON body and reports its size in bytes. */
export async function readJsonSized(
  req: Request,
  options: BodyOptions = {},
): Promise<{ value: unknown; bytes: number }> {
  const type = mediaType(req);
  if (type !== "application/json" && !type.endsWith("+json")) {
    throw new HttpError("unsupported_media_type", "Send the request body as application/json.");
  }
  const text = await readText(req, options);
  if (text.trim() === "") throw new HttpError("invalid_json", "The request body is empty.");
  try {
    return { value: JSON.parse(text), bytes: new TextEncoder().encode(text).byteLength };
  } catch {
    throw new HttpError("invalid_json", "The request body is not valid JSON.");
  }
}

/** Parses a JSON body (Content-Type must be application/json). */
export async function readJson(req: Request, options: BodyOptions = {}): Promise<unknown> {
  return (await readJsonSized(req, options)).value;
}

/** Parses an application/x-www-form-urlencoded body (Twilio webhooks). */
export async function readForm(req: Request, options: BodyOptions = {}): Promise<URLSearchParams> {
  if (mediaType(req) !== "application/x-www-form-urlencoded") {
    throw new HttpError(
      "unsupported_media_type",
      "Send the request body as application/x-www-form-urlencoded.",
    );
  }
  return new URLSearchParams(await readText(req, options));
}

export interface ValidationIssue {
  path: string;
  message: string;
}

export function issuesOf(error: z.ZodError): ValidationIssue[] {
  return error.issues.map((issue) => ({
    path: issue.path.map(String).join(".") || "(root)",
    message: issue.message,
  }));
}

export function validationError(error: z.ZodError): HttpError {
  return new HttpError("validation_failed", "Some fields are missing or invalid.", {
    details: { issues: issuesOf(error) },
  });
}

/** Validates `value` against `schema`, throwing `validation_failed` with issues. */
export function validate<S extends z.ZodType>(schema: S, value: unknown): z.output<S> {
  const result = schema.safeParse(value);
  if (!result.success) throw validationError(result.error);
  return result.data;
}

export async function parseJson<S extends z.ZodType>(
  req: Request,
  schema: S,
  options: BodyOptions = {},
): Promise<z.output<S>> {
  return validate(schema, await readJson(req, options));
}

// ---------------------------------------------------------------------------
// Error mapping
// ---------------------------------------------------------------------------

export interface MappedError {
  httpError: HttpError;
  /** Whether this is an unexpected failure worth an error-level log. */
  unexpected: boolean;
}

export function mapError(err: unknown): MappedError {
  if (err instanceof HttpError) {
    return { httpError: err, unexpected: err.status >= 500 };
  }
  if (err instanceof z.ZodError) {
    return { httpError: validationError(err), unexpected: false };
  }
  if (err instanceof EnvError) {
    return {
      httpError: new HttpError(
        "server_misconfigured",
        "The server is not configured correctly. Please contact support.",
        { cause: err },
      ),
      unexpected: true,
    };
  }
  if (isStripeError(err)) {
    const httpError = stripeErrorToHttpError(err);
    return { httpError, unexpected: httpError.status >= 500 };
  }
  if (err instanceof UpstreamError) {
    return {
      httpError: new HttpError(
        "upstream_error",
        `The ${err.provider} request failed. Try again shortly.`,
        { cause: err },
      ),
      unexpected: true,
    };
  }
  return {
    httpError: new HttpError("internal_error", "Something went wrong. Please try again.", {
      cause: err,
    }),
    unexpected: true,
  };
}

// ---------------------------------------------------------------------------
// Handler wrapper
// ---------------------------------------------------------------------------

export interface HandlerContext {
  requestId: string;
  log: Logger;
  env: Env;
}

export type HandlerResult = Response | unknown;

export interface HandlerOptions {
  /** Function name, used in logs. */
  name: string;
  /** Allowed methods besides OPTIONS. Default: POST. */
  methods?: readonly string[];
  /**
   * Browser-facing functions answer CORS preflights and reflect allowed
   * origins. Webhook-only functions set `cors: false`. Default: true.
   */
  cors?: boolean;
  /** Injected for tests; defaults to the process Env / JSON logger. */
  env?: Env;
  logger?: Logger;
  /** Precomputed CORS policy (tests); defaults to one derived from env. */
  corsPolicy?: CorsPolicy;
}

function withHeaders(response: Response, extra: Record<string, string>): Response {
  const headers = new Headers(response.headers);
  for (const [key, value] of Object.entries(extra)) {
    if (key.toLowerCase() === "vary" && headers.has("vary")) {
      const existing = headers.get("vary") ?? "";
      if (!existing.toLowerCase().split(/\s*,\s*/).includes(value.toLowerCase())) {
        headers.set("vary", `${existing}, ${value}`);
      }
    } else {
      headers.set(key, value);
    }
  }
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

/**
 * Wraps a function body. The body may return a Response, a JSON-serializable
 * value (→ 200 JSON) or undefined (→ 204). Any thrown error is mapped by
 * `mapError`; only HttpError messages ever reach the client.
 */
export function createHandler(
  options: HandlerOptions,
  fn: (req: Request, ctx: HandlerContext) => Promise<HandlerResult> | HandlerResult,
): (req: Request) => Promise<Response> {
  const methods = (options.methods ?? ["POST"]).map((m) => m.toUpperCase());
  const useCors = options.cors ?? true;
  const env = options.env ?? defaultEnv;
  const baseLogger = (options.logger ?? defaultLogger).child({ fn: options.name });
  let cachedPolicy: CorsPolicy | undefined = options.corsPolicy;
  const policy = (): CorsPolicy => (cachedPolicy ??= corsPolicyFromEnv(env));

  return async (req: Request): Promise<Response> => {
    const requestId = requestIdFor(req);
    const log = baseLogger.child({ request_id: requestId });
    const started = performance.now();
    let extraHeaders: Record<string, string> = { "x-request-id": requestId };
    let response: Response;

    try {
      if (useCors) {
        // Resolved inside try so a bad APP_BASE_URL maps to server_misconfigured.
        extraHeaders = { ...corsHeaders(req, policy()), ...extraHeaders };
      }
      if (useCors && req.method === "OPTIONS") {
        response = preflightResponse(req, policy());
      } else if (!methods.includes(req.method.toUpperCase())) {
        throw new HttpError("method_not_allowed", "Method not allowed.", {
          headers: { Allow: [...methods, ...(useCors ? ["OPTIONS"] : [])].join(", ") },
        });
      } else {
        const result = await fn(req, { requestId, log, env });
        if (result instanceof Response) response = result;
        else if (result === undefined) response = new Response(null, { status: 204 });
        else response = json(result);
      }
    } catch (err) {
      const { httpError, unexpected } = mapError(err);
      const fields = {
        code: httpError.code,
        status: httpError.status,
        method: req.method,
        error: httpError.cause ?? httpError,
      };
      if (unexpected) log.error("request_failed", fields);
      else log.warn("request_rejected", { ...fields, error: httpError.message });
      response = errorResponse(httpError, requestId);
    }

    log.info("request_completed", {
      method: req.method,
      status: response.status,
      ms: Math.round(performance.now() - started),
    });
    return withHeaders(response, extraHeaders);
  };
}
