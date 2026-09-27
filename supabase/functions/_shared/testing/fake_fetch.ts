/**
 * A routing fake for `fetch`. Business functions receive `fetch` by
 * injection (Stripe via `createStripe({ fetch })`, Twilio/Resend helpers via
 * their `fetchFn` argument, Supabase via `adminClient({ fetch })`), so tests
 * stub every third-party HTTP API without network access.
 *
 *   const http = new FakeFetch();
 *   http.on("POST", "https://api.twilio.com/2010-04-01/Accounts/:sid/Messages.json",
 *     () => jsonResponse({ sid: "SM1", status: "queued" }, 201));
 *   await sendSms(creds, params, http.fetch);
 *   http.calls[0].form.get("Body");
 *
 * Unmatched requests reject with a descriptive error (and are recorded in
 * `unmatched`) so a missing stub can never silently pass.
 */

export interface RecordedCall {
  method: string;
  url: URL;
  headers: Headers;
  bodyText: string;
  /** Parsed JSON body (undefined when not JSON). */
  json: unknown;
  /** Parsed form body (empty when not form-encoded). */
  form: URLSearchParams;
}

export interface RouteMatch {
  params: Record<string, string | undefined>;
  url: URL;
  call: RecordedCall;
}

export type RouteHandler = (
  req: Request,
  match: RouteMatch,
) => Response | unknown | Promise<Response | unknown>;

interface Route {
  method: string;
  pattern: URLPattern;
  handler: RouteHandler;
  times: number | null;
}

export function jsonResponse(
  data: unknown,
  status = 200,
  headers: Record<string, string> = {},
): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json", ...headers },
  });
}

/**
 * "https://host[:port]/path/:param" (URLPattern pathname syntax). Any query
 * string matches unless the pattern includes "?query-pattern".
 */
function toPattern(pattern: string | URLPattern): URLPattern {
  if (pattern instanceof URLPattern) return pattern;
  const match = /^([a-z][a-z0-9+.-]*):\/\/([^/?]+)([^?]*)(?:\?(.*))?$/i.exec(pattern);
  if (!match) throw new TypeError(`FakeFetch: invalid pattern "${pattern}"`);
  const [, protocol = "", authority = "", pathname = "", search] = match;
  const portMatch = /^(.*):(\d+)$/.exec(authority);
  return new URLPattern({
    protocol,
    hostname: portMatch?.[1] ?? authority,
    port: portMatch?.[2] ?? "",
    pathname: pathname || "/",
    search: search ?? "*",
    hash: "*",
  });
}

export class FakeFetch {
  readonly calls: RecordedCall[] = [];
  readonly unmatched: RecordedCall[] = [];
  readonly #routes: Route[] = [];

  /** Registers a route. Later registrations take precedence. */
  on(method: string, pattern: string | URLPattern, handler: RouteHandler): this {
    this.#routes.unshift({
      method: method.toUpperCase(),
      pattern: toPattern(pattern),
      handler,
      times: null,
    });
    return this;
  }

  /** Registers a route that answers only the next `times` matching calls. */
  once(method: string, pattern: string | URLPattern, handler: RouteHandler, times = 1): this {
    this.#routes.unshift({
      method: method.toUpperCase(),
      pattern: toPattern(pattern),
      handler,
      times,
    });
    return this;
  }

  /** Calls matching method + pattern, in order. */
  callsTo(method: string, pattern: string | URLPattern): RecordedCall[] {
    const compiled = toPattern(pattern);
    return this.calls.filter((call) =>
      call.method === method.toUpperCase() && compiled.test(call.url.href)
    );
  }

  /** The `fetch` to inject. */
  readonly fetch: typeof fetch = async (input, init) => {
    const req = new Request(input, init);
    const bodyText = req.body ? await req.clone().text() : "";
    const contentType = req.headers.get("content-type") ?? "";
    let json: unknown = undefined;
    if (contentType.includes("json") && bodyText) {
      try {
        json = JSON.parse(bodyText);
      } catch {
        json = undefined;
      }
    }
    const form = contentType.includes("application/x-www-form-urlencoded")
      ? new URLSearchParams(bodyText)
      : new URLSearchParams();
    const call: RecordedCall = {
      method: req.method.toUpperCase(),
      url: new URL(req.url),
      headers: new Headers(req.headers),
      bodyText,
      json,
      form,
    };
    this.calls.push(call);

    for (const route of this.#routes) {
      if (route.method !== call.method && route.method !== "*") continue;
      const result = route.pattern.exec(req.url);
      if (!result) continue;
      if (route.times !== null) {
        if (route.times <= 0) continue;
        route.times -= 1;
      }
      const params = { ...result.pathname.groups };
      const output = await route.handler(req, { params, url: call.url, call });
      return output instanceof Response ? output : jsonResponse(output);
    }
    this.unmatched.push(call);
    throw new TypeError(`FakeFetch: no route for ${call.method} ${call.url.href}`);
  };
}
