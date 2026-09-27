/** Request builders for handler tests. */

export const FUNCTIONS_BASE = "https://fake-project.supabase.co/functions/v1";

export interface RequestOptions {
  method?: string;
  /** Bearer token → Authorization header. */
  token?: string;
  origin?: string;
  headers?: Record<string, string>;
  /** Query parameters appended to the URL. */
  query?: Record<string, string>;
}

function buildUrl(pathOrUrl: string, query: Record<string, string> = {}): string {
  const url = new URL(
    /^https?:\/\//.test(pathOrUrl)
      ? pathOrUrl
      : `${FUNCTIONS_BASE}/${pathOrUrl.replace(/^\/+/, "")}`,
  );
  for (const [key, value] of Object.entries(query)) url.searchParams.set(key, value);
  return url.toString();
}

function baseHeaders(options: RequestOptions, contentType?: string): Headers {
  const headers = new Headers(options.headers);
  if (contentType && !headers.has("content-type")) headers.set("content-type", contentType);
  if (options.token) headers.set("authorization", `Bearer ${options.token}`);
  if (options.origin) headers.set("origin", options.origin);
  return headers;
}

/** POST (default) with a JSON body; `pathOrUrl` may be "payments" or a full URL. */
export function jsonRequest(
  pathOrUrl: string,
  body: unknown,
  options: RequestOptions = {},
): Request {
  return new Request(buildUrl(pathOrUrl, options.query), {
    method: options.method ?? "POST",
    headers: baseHeaders(options, "application/json"),
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

/** POST with an application/x-www-form-urlencoded body (Twilio webhooks). */
export function formRequest(
  pathOrUrl: string,
  params: Record<string, string> | URLSearchParams,
  options: RequestOptions = {},
): Request {
  const body = params instanceof URLSearchParams ? params : new URLSearchParams(params);
  return new Request(buildUrl(pathOrUrl, options.query), {
    method: options.method ?? "POST",
    headers: baseHeaders(options, "application/x-www-form-urlencoded"),
    body: body.toString(),
  });
}

/** Request without a body (GET by default). */
export function emptyRequest(pathOrUrl: string, options: RequestOptions = {}): Request {
  return new Request(buildUrl(pathOrUrl, options.query), {
    method: options.method ?? "GET",
    headers: baseHeaders(options),
  });
}

/** CORS preflight. */
export function preflightRequest(
  pathOrUrl: string,
  origin: string,
  method = "POST",
  requestHeaders = "authorization, content-type",
): Request {
  return new Request(buildUrl(pathOrUrl), {
    method: "OPTIONS",
    headers: {
      origin,
      "access-control-request-method": method,
      "access-control-request-headers": requestHeaders,
    },
  });
}

/** Reads a JSON response body (asserting the content type). */
export async function responseJson<T = unknown>(response: Response): Promise<T> {
  const type = response.headers.get("content-type") ?? "";
  if (!type.includes("application/json")) {
    throw new Error(`Expected JSON response, got "${type}" (status ${response.status})`);
  }
  return await response.json() as T;
}
