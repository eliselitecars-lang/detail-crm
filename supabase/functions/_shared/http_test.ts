import { assert, assertEquals, assertRejects, assertStringIncludes } from "@std/assert";
import { z } from "zod";
import { corsPolicy } from "./cors.ts";
import { EnvError } from "./env.ts";
import { HttpError, UpstreamError } from "./errors.ts";
import {
  createHandler,
  type ErrorBody,
  type HandlerOptions,
  mapError,
  parseJson,
  readForm,
  readText,
} from "./http.ts";
import { testEnv } from "./testing/env.ts";
import { memoryLogger } from "./testing/logger.ts";
import {
  emptyRequest,
  formRequest,
  jsonRequest,
  preflightRequest,
  responseJson,
} from "./testing/requests.ts";

const ORIGIN = "https://app.example.com";

function setup(
  fn: Parameters<typeof createHandler>[1],
  options: Partial<HandlerOptions> = {},
) {
  const logs = memoryLogger();
  const handler = createHandler(
    { name: "test-fn", env: testEnv(), logger: logs.logger, ...options },
    fn,
  );
  return { handler, logs };
}

async function errorOf(
  res: Response,
): Promise<{ code: string; message: string; details?: unknown; request_id: string }> {
  const body = await responseJson<ErrorBody>(res);
  return {
    code: body.code,
    message: body.error,
    details: body.details,
    request_id: body.request_id,
  };
}

Deno.test("handler: JSON value -> 200, undefined -> 204, Response passes through", async () => {
  const { handler } = setup((req) => {
    const mode = new URL(req.url).searchParams.get("mode");
    if (mode === "none") return undefined;
    if (mode === "raw") return new Response("ok", { status: 202 });
    return { ok: true };
  });
  const a = await handler(jsonRequest("fn", {}));
  assertEquals(a.status, 200);
  assertEquals(await a.json(), { ok: true });
  assertEquals(a.headers.get("content-type"), "application/json; charset=utf-8");
  const b = await handler(jsonRequest("fn", {}, { query: { mode: "none" } }));
  assertEquals(b.status, 204);
  assertEquals(await b.text(), "");
  const c = await handler(jsonRequest("fn", {}, { query: { mode: "raw" } }));
  assertEquals(c.status, 202);
  assertEquals(await c.text(), "ok");
});

Deno.test("handler: request ids are reused when well-formed, minted otherwise", async () => {
  const seen: string[] = [];
  const { handler } = setup((_req, ctx) => {
    seen.push(ctx.requestId);
    return {};
  });
  const good = await handler(
    jsonRequest("fn", {}, { headers: { "x-request-id": "web-abc12345" } }),
  );
  assertEquals(good.headers.get("x-request-id"), "web-abc12345");
  await good.body?.cancel();
  const bad = await handler(jsonRequest("fn", {}, { headers: { "x-request-id": "bad id\n" } }));
  assert(bad.headers.get("x-request-id") !== "bad id\n");
  assertEquals(bad.headers.get("x-request-id"), seen[1]);
  await bad.body?.cancel();
});

Deno.test("handler: wrong method -> 405 with Allow header", async () => {
  const { handler } = setup(() => ({}));
  const res = await handler(emptyRequest("fn"));
  assertEquals(res.status, 405);
  assertEquals(res.headers.get("allow"), "POST, OPTIONS");
  assertEquals((await errorOf(res)).code, "method_not_allowed");
});

Deno.test("handler: webhook handlers (cors: false) don't answer OPTIONS", async () => {
  const { handler } = setup(() => ({}), { cors: false });
  const res = await handler(preflightRequest("fn", ORIGIN));
  assertEquals(res.status, 405);
  assertEquals(res.headers.get("allow"), "POST");
  assertEquals(res.headers.get("access-control-allow-origin"), null);
  await res.body?.cancel();
});

Deno.test("handler: CORS preflight and CORS headers on success and error", async () => {
  const { handler } = setup((req) => {
    if (new URL(req.url).searchParams.has("fail")) throw new HttpError("forbidden", "Nope.");
    return { ok: true };
  });
  const pre = await handler(preflightRequest("fn", ORIGIN));
  assertEquals(pre.status, 204);
  assertEquals(pre.headers.get("access-control-allow-origin"), ORIGIN);
  const ok = await handler(jsonRequest("fn", {}, { origin: ORIGIN }));
  assertEquals(ok.headers.get("access-control-allow-origin"), ORIGIN);
  assertEquals(ok.headers.get("vary"), "Origin");
  await ok.body?.cancel();
  const failed = await handler(jsonRequest("fn", {}, { origin: ORIGIN, query: { fail: "1" } }));
  assertEquals(failed.status, 403);
  assertEquals(failed.headers.get("access-control-allow-origin"), ORIGIN);
  await failed.body?.cancel();
  const denied = await handler(preflightRequest("fn", "https://evil.test"));
  assertEquals(denied.status, 403);
  assertEquals((await errorOf(denied)).code, "origin_not_allowed");
});

Deno.test("handler: an explicit corsPolicy is used as-is", async () => {
  const { handler } = setup(() => ({}), { corsPolicy: corsPolicy(["http://localhost:5173"]) });
  const res = await handler(jsonRequest("fn", {}, { origin: "http://localhost:5173" }));
  assertEquals(res.headers.get("access-control-allow-origin"), "http://localhost:5173");
  await res.body?.cancel();
});

Deno.test("handler: HttpError maps to its code, status, message, details and headers", async () => {
  const { handler, logs } = setup(() => {
    throw new HttpError("rate_limited", "Slow down.", {
      details: { retry_in: 5 },
      headers: { "Retry-After": "5" },
    });
  });
  const res = await handler(jsonRequest("fn", {}));
  assertEquals(res.status, 429);
  assertEquals(res.headers.get("retry-after"), "5");
  const error = await errorOf(res);
  assertEquals(error.code, "rate_limited");
  assertEquals(error.message, "Slow down.");
  assertEquals(error.details, { retry_in: 5 });
  assertEquals(error.request_id, res.headers.get("x-request-id"));
  assertEquals(logs.events("request_rejected").length, 1);
  assertEquals(logs.events("request_failed").length, 0);
});

Deno.test("handler: unexpected errors become a generic 500 and never leak internals", async () => {
  const { handler, logs } = setup(() => {
    throw new Error("connection to db-internal-host:5432 failed; password=hunter2");
  });
  const res = await handler(jsonRequest("fn", {}));
  assertEquals(res.status, 500);
  const text = await res.text();
  assert(!text.includes("hunter2"));
  assert(!text.includes("db-internal-host"));
  const body = JSON.parse(text) as ErrorBody;
  assertEquals(body.code, "internal_error");
  assertEquals(body.error, "Something went wrong. Please try again.");
  const failure = logs.events("request_failed")[0];
  assert(failure);
  assertStringIncludes(JSON.stringify(failure.error), "db-internal-host");
});

Deno.test("handler: EnvError -> server_misconfigured without naming the variable", async () => {
  const { handler, logs } = setup(() => {
    throw new EnvError("STRIPE_SECRET_KEY", "missing");
  });
  const res = await handler(jsonRequest("fn", {}));
  assertEquals(res.status, 500);
  const text = await res.text();
  assert(!text.includes("STRIPE_SECRET_KEY"));
  assertEquals((JSON.parse(text) as ErrorBody).code, "server_misconfigured");
  assertStringIncludes(JSON.stringify(logs.events("request_failed")[0]), "STRIPE_SECRET_KEY");
});

Deno.test("handler: a broken APP_BASE_URL surfaces as server_misconfigured", async () => {
  const { handler } = setup(() => ({}), { env: testEnv({ APP_BASE_URL: undefined }) });
  const res = await handler(jsonRequest("fn", {}, { origin: ORIGIN }));
  assertEquals(res.status, 500);
  assertEquals((await errorOf(res)).code, "server_misconfigured");
  assert(res.headers.get("x-request-id"));
});

Deno.test("handler: thrown ZodError -> validation_failed with issue paths", async () => {
  const { handler } = setup(() => z.object({ amount: z.number() }).parse({ amount: "1" }));
  const res = await handler(jsonRequest("fn", {}));
  assertEquals(res.status, 400);
  const error = await errorOf(res);
  assertEquals(error.code, "validation_failed");
  assertEquals((error.details as { issues: { path: string }[] }).issues[0]?.path, "amount");
});

Deno.test("handler: Stripe card errors are shown; other Stripe errors are generic", async () => {
  const card = Object.assign(new Error("Your card has insufficient funds."), {
    type: "StripeCardError",
    code: "card_declined",
    decline_code: "insufficient_funds",
  });
  const auth = Object.assign(new Error("Invalid API Key provided: sk_test_***"), {
    type: "StripeAuthenticationError",
  });
  const rate = Object.assign(new Error("Too many requests"), { type: "StripeRateLimitError" });
  const { handler } = setup((req) => {
    const kind = new URL(req.url).searchParams.get("kind");
    throw kind === "card" ? card : kind === "rate" ? rate : auth;
  });
  const a = await handler(jsonRequest("fn", {}, { query: { kind: "card" } }));
  assertEquals(a.status, 402);
  const cardError = await errorOf(a);
  assertEquals(cardError.code, "payment_failed");
  assertEquals(cardError.message, "Your card has insufficient funds.");
  assertEquals(cardError.details, {
    stripe_code: "card_declined",
    decline_code: "insufficient_funds",
  });
  const b = await handler(jsonRequest("fn", {}, { query: { kind: "auth" } }));
  assertEquals(b.status, 502);
  const text = await b.text();
  assert(!text.includes("sk_test"));
  assertEquals((JSON.parse(text) as ErrorBody).code, "upstream_error");
  const c = await handler(jsonRequest("fn", {}, { query: { kind: "rate" } }));
  assertEquals(c.status, 503);
  assertEquals(c.headers.get("retry-after"), "2");
  await c.body?.cancel();
});

Deno.test("handler: UpstreamError -> 502 naming only the provider", async () => {
  const { handler } = setup(() => {
    throw new UpstreamError("Twilio", "Authenticate: account suspended", { httpStatus: 401 });
  });
  const res = await handler(jsonRequest("fn", {}));
  assertEquals(res.status, 502);
  const error = await errorOf(res);
  assertEquals(error.code, "upstream_error");
  assertEquals(error.message, "The Twilio request failed. Try again shortly.");
});

Deno.test("handler: logs redact credentials", async () => {
  const { handler, logs } = setup((_req, ctx) => {
    ctx.log.info("probe", { authorization: "Bearer secret-jwt", nested: { api_key: "k" }, ok: 1 });
    return {};
  });
  const res = await handler(jsonRequest("fn", {}, { token: "secret-jwt" }));
  await res.body?.cancel();
  const probe = logs.events("probe")[0];
  assertEquals(probe?.authorization, "[redacted]");
  assertEquals(probe?.nested, { api_key: "[redacted]" });
  assertEquals(probe?.ok, 1);
  assertEquals(probe?.fn, "test-fn");
  assert(!JSON.stringify(logs.records).includes("secret-jwt"));
  assertEquals(logs.events("request_completed")[0]?.status, 200);
});

Deno.test("handler: a database PT402 passed on unmapped is 402 payment_required, never 500", async () => {
  const inactive =
    "This shop's subscription is inactive, so new records can't be created right now.";
  const { handler, logs } = setup((req) => {
    const kind = new URL(req.url).searchParams.get("kind");
    const pg = kind === "seats"
      ? { code: "PT402", message: "This shop's plan allows 2 team members.", hint: null }
      : { code: "PT402", message: inactive, details: null, hint: null };
    // A call site that wrapped the PostgREST error in its own "... failed".
    throw new Error("create_invoice_from_job failed", { cause: pg });
  });
  const a = await handler(jsonRequest("fn", {}));
  assertEquals(a.status, 402);
  assertEquals(
    await errorOf(a).then(({ code, message, details }) => ({ code, message, details })),
    {
      code: "payment_required",
      message: inactive,
      details: { reason: "subscription_inactive" },
    },
  );
  const b = await handler(jsonRequest("fn", {}, { query: { kind: "seats" } }));
  assertEquals(b.status, 402);
  const seats = await errorOf(b);
  assertEquals([seats.code, seats.message, seats.details], [
    "payment_required",
    "This shop's plan allows 2 team members.",
    { reason: "seat_limit" },
  ]);
  // An expected refusal: not logged as an unexpected error.
  assertEquals(logs.events("request_failed").length, 0);
});

Deno.test("mapError: HttpError 5xx counts as unexpected; 4xx does not", () => {
  assertEquals(mapError(new HttpError("service_unavailable", "x")).unexpected, true);
  assertEquals(mapError(new HttpError("not_found", "x")).unexpected, false);
  assertEquals(mapError("a string").httpError.code, "internal_error");
});

// ---------------------------------------------------------------------------
// Body parsing
// ---------------------------------------------------------------------------

const schema = z.object({ shop_id: z.string(), amount_cents: z.number().int() }).strict();

async function codeOf(promise: Promise<unknown>): Promise<string> {
  const err = await assertRejects(() => promise, HttpError);
  return err.code;
}

Deno.test("parseJson: valid body is parsed and typed", async () => {
  const value = await parseJson(jsonRequest("fn", { shop_id: "s", amount_cents: 5 }), schema);
  assertEquals(value, { shop_id: "s", amount_cents: 5 });
});

Deno.test("parseJson: content type, JSON syntax, emptiness and validation errors", async () => {
  assertEquals(
    await codeOf(parseJson(formRequest("fn", { a: "1" }), schema)),
    "unsupported_media_type",
  );
  assertEquals(await codeOf(parseJson(jsonRequest("fn", "{not json"), schema)), "invalid_json");
  assertEquals(await codeOf(parseJson(jsonRequest("fn", ""), schema)), "invalid_json");
  const err = await assertRejects(
    () => parseJson(jsonRequest("fn", { shop_id: 1, amount_cents: 1.5, extra: true }), schema),
    HttpError,
  );
  assertEquals(err.code, "validation_failed");
  const paths = (err.details as { issues: { path: string }[] }).issues.map((i) => i.path).sort();
  assertEquals(paths, ["(root)", "amount_cents", "shop_id"]);
});

Deno.test("readText: enforces the byte limit via Content-Length and while streaming", async () => {
  const big = "x".repeat(2048);
  assertEquals(
    await codeOf(readText(jsonRequest("fn", big), { maxBytes: 1024 })),
    "payload_too_large",
  );
  const stream = new ReadableStream<Uint8Array>({
    start(controller) {
      for (let i = 0; i < 4; i++) controller.enqueue(new TextEncoder().encode("y".repeat(512)));
      controller.close();
    },
  });
  const streamed = new Request("https://x.example/fn", { method: "POST", body: stream });
  assertEquals(streamed.headers.get("content-length"), null);
  assertEquals(await codeOf(readText(streamed, { maxBytes: 1024 })), "payload_too_large");
  assertEquals(await readText(jsonRequest("fn", "abc"), { maxBytes: 3 }), "abc");
});

Deno.test("readText: rejects invalid UTF-8", async () => {
  const req = new Request("https://x.example/fn", {
    method: "POST",
    body: new Uint8Array([0xff, 0xfe, 0x41]),
  });
  assertEquals(await codeOf(readText(req)), "bad_request");
});

Deno.test("readForm: parses urlencoded bodies and rejects other types", async () => {
  const form = await readForm(formRequest("fn", { Body: "Hi there", From: "+12055550100" }));
  assertEquals(form.get("Body"), "Hi there");
  assertEquals(form.get("From"), "+12055550100");
  assertEquals(await codeOf(readForm(jsonRequest("fn", {}))), "unsupported_media_type");
});

Deno.test("handler: error envelope is { error: string, code, details?, request_id }", async () => {
  const { handler } = setup(() => {
    throw new HttpError("not_found", "Invoice not found.");
  });
  const res = await handler(jsonRequest("fn", {}, { headers: { "x-request-id": "req-12345678" } }));
  assertEquals(await res.json(), {
    error: "Invoice not found.",
    code: "not_found",
    request_id: "req-12345678",
  });
});
