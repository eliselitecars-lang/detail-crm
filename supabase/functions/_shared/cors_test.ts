import { assertEquals, assertThrows } from "@std/assert";
import {
  CORS_ALLOW_HEADERS,
  corsHeaders,
  corsPolicy,
  corsPolicyFromEnv,
  isOriginAllowed,
  preflightResponse,
} from "./cors.ts";
import { HttpError } from "./errors.ts";
import { testEnv } from "./testing/env.ts";
import { jsonRequest, preflightRequest } from "./testing/requests.ts";

const policy = corsPolicy(["https://app.example.com", "http://localhost:5173"]);

Deno.test("cors: policy from env = APP_BASE_URL origin + extra origins", () => {
  const fromEnv = corsPolicyFromEnv(
    testEnv({
      APP_BASE_URL: "https://app.example.com/base",
      CORS_ALLOWED_ORIGINS: "http://localhost:5173",
    }),
  );
  assertEquals([...fromEnv.allowedOrigins].sort(), [
    "http://localhost:5173",
    "https://app.example.com",
  ]);
});

Deno.test("cors: only exact origins are allowed", () => {
  assertEquals(isOriginAllowed("https://app.example.com", policy), true);
  assertEquals(isOriginAllowed("https://app.example.com.evil.test", policy), false);
  assertEquals(isOriginAllowed("http://app.example.com", policy), false);
  assertEquals(isOriginAllowed("null", policy), false);
  assertEquals(isOriginAllowed(null, policy), false);
});

Deno.test("cors: preflight from an allowed origin returns 204 with allow lists", () => {
  const res = preflightResponse(preflightRequest("payments", "https://app.example.com"), policy);
  assertEquals(res.status, 204);
  assertEquals(res.headers.get("access-control-allow-origin"), "https://app.example.com");
  assertEquals(res.headers.get("access-control-allow-methods"), "GET, POST, OPTIONS");
  assertEquals(res.headers.get("access-control-allow-headers"), CORS_ALLOW_HEADERS.join(", "));
  assertEquals(res.headers.get("vary"), "Origin");
  assertEquals(res.headers.get("access-control-allow-credentials"), null);
});

Deno.test("cors: preflight from an unknown origin is rejected", () => {
  const err = assertThrows(
    () => preflightResponse(preflightRequest("payments", "https://evil.test"), policy),
    HttpError,
  );
  assertEquals(err.code, "origin_not_allowed");
  assertEquals(err.status, 403);
});

Deno.test("cors: preflight for a disallowed method is rejected", () => {
  const err = assertThrows(
    () =>
      preflightResponse(preflightRequest("payments", "https://app.example.com", "DELETE"), policy),
    HttpError,
  );
  assertEquals(err.code, "method_not_allowed");
});

Deno.test("cors: response headers reflect allowed origins only", () => {
  const allowed = corsHeaders(
    jsonRequest("payments", {}, { origin: "http://localhost:5173" }),
    policy,
  );
  assertEquals(allowed["Access-Control-Allow-Origin"], "http://localhost:5173");
  assertEquals(allowed["Access-Control-Expose-Headers"], "x-request-id, retry-after");
  const denied = corsHeaders(jsonRequest("payments", {}, { origin: "https://evil.test" }), policy);
  assertEquals(denied, { Vary: "Origin" });
  const serverToServer = corsHeaders(jsonRequest("payments", {}), policy);
  assertEquals(serverToServer, { Vary: "Origin" });
});
