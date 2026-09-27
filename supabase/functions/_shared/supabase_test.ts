import { assertEquals, assertRejects, assertThrows } from "@std/assert";
import { HttpError } from "./errors.ts";
import {
  adminClient,
  bearerToken,
  getCaller,
  isTransientAuthError,
  userClient,
} from "./supabase.ts";
import { jsonResponse } from "./testing/fake_fetch.ts";
import { FAKE_ANON_KEY, FAKE_SERVICE_ROLE_KEY, FakeSupabase } from "./testing/fake_supabase.ts";
import { jsonRequest } from "./testing/requests.ts";

const USER_ID = "11111111-1111-4111-8111-111111111111";

function fake(): FakeSupabase {
  return new FakeSupabase({
    users: {
      "tok-user": {
        id: USER_ID,
        email: "owner@example.com",
        email_confirmed_at: "2026-01-01T00:00:00Z",
        phone: "+12055550100",
      },
      "tok-unconfirmed": { id: "22222222-2222-4222-8222-222222222222", email: "new@example.com" },
      "tok-anon": { id: "33333333-3333-4333-8333-333333333333", is_anonymous: true },
    },
    tables: { widgets: [{ id: "w1", name: "a" }] },
  });
}

Deno.test("bearerToken: parses Bearer headers case-insensitively", () => {
  assertEquals(bearerToken(jsonRequest("f", {}, { token: "abc.def" })), "abc.def");
  assertEquals(
    bearerToken(jsonRequest("f", {}, { headers: { authorization: "bearer   xyz  " } })),
    "xyz",
  );
  assertEquals(
    bearerToken(jsonRequest("f", {}, { headers: { authorization: "Basic abc" } })),
    null,
  );
  assertEquals(bearerToken(jsonRequest("f", {})), null);
});

Deno.test("getCaller: verifies the JWT with Auth and returns identity", async () => {
  const db = fake();
  const caller = await getCaller(jsonRequest("f", {}, { token: "tok-user" }), {
    admin: db.admin(),
  });
  assertEquals(caller, {
    id: USER_ID,
    email: "owner@example.com",
    emailConfirmed: true,
    phone: "+12055550100",
    isAnonymous: false,
    token: "tok-user",
  });
  const auth = db.requests.find((r) => r.kind === "auth");
  // The token is checked with the service-role client's apikey + the user's JWT.
  assertEquals(auth?.role, "authenticated");
  assertEquals(db.http.calls[0]?.headers.get("apikey"), FAKE_SERVICE_ROLE_KEY);
});

Deno.test("getCaller: unconfirmed email and anonymous users are flagged", async () => {
  const db = fake();
  const unconfirmed = await getCaller(jsonRequest("f", {}, { token: "tok-unconfirmed" }), {
    admin: db.admin(),
  });
  assertEquals(unconfirmed?.emailConfirmed, false);
  assertEquals(unconfirmed?.phone, null);
  const anon = await getCaller(jsonRequest("f", {}, { token: "tok-anon" }), { admin: db.admin() });
  assertEquals(anon?.isAnonymous, true);
});

Deno.test("getCaller: missing or invalid tokens -> null", async () => {
  const db = fake();
  assertEquals(await getCaller(jsonRequest("f", {}), { admin: db.admin() }), null);
  assertEquals(
    await getCaller(jsonRequest("f", {}, { token: "forged" }), { admin: db.admin() }),
    null,
  );
  // supabase-js sends the anon key as the bearer when signed out.
  assertEquals(
    await getCaller(jsonRequest("f", {}, { token: FAKE_ANON_KEY }), { admin: db.admin() }),
    null,
  );
});

Deno.test("getCaller: an Auth outage is service_unavailable, not 'signed out'", async () => {
  const db = fake();
  db.http.on("GET", `${db.url}/auth/v1/user`, () => jsonResponse({ msg: "upstream down" }, 503));
  const err = await assertRejects(
    () => getCaller(jsonRequest("f", {}, { token: "tok-user" }), { admin: db.admin() }),
    HttpError,
  );
  assertEquals(err.code, "service_unavailable");
});

Deno.test("getCaller: Auth throttling, timeouts and non-JSON gateway pages are not 'signed out'", async () => {
  const cases: Array<[string, () => Response]> = [
    [
      "429 rate limited (JSON)",
      () =>
        jsonResponse({ code: 429, error_code: "over_request_rate_limit", msg: "slow down" }, 429),
    ],
    ["408 timeout (JSON)", () => jsonResponse({ code: 408, msg: "timeout" }, 408)],
    ["429 HTML page from a proxy", () =>
      new Response("<html>Too Many Requests</html>", {
        status: 429,
        headers: { "content-type": "text/html" },
      })],
    ["403 HTML page from a gateway/WAF", () =>
      new Response("<html>Forbidden</html>", {
        status: 403,
        headers: { "content-type": "text/html" },
      })],
    ["502 HTML page", () => new Response("<html>Bad Gateway</html>", { status: 502 })],
  ];
  for (const [label, respond] of cases) {
    const db = fake();
    db.http.on("GET", `${db.url}/auth/v1/user`, respond);
    const err = await assertRejects(
      () => getCaller(jsonRequest("f", {}, { token: "tok-user" }), { admin: db.admin() }),
      HttpError,
      undefined,
      label,
    );
    assertEquals(err.code, "service_unavailable", label);
    assertEquals(err.status, 503, label);
  }
});

Deno.test("getCaller: definitive JSON 4xx answers from Auth mean 'not signed in'", async () => {
  const cases: Array<[string, () => Response]> = [
    ["bad_jwt", () => jsonResponse({ code: 403, error_code: "bad_jwt", msg: "invalid JWT" }, 403)],
    [
      "user_not_found",
      () => jsonResponse({ code: 404, error_code: "user_not_found", msg: "User not found" }, 404),
    ],
    [
      "session_not_found",
      () =>
        jsonResponse({ code: 403, error_code: "session_not_found", msg: "Session not found" }, 403),
    ],
    ["401", () => jsonResponse({ code: 401, msg: "no authorization" }, 401)],
  ];
  for (const [label, respond] of cases) {
    const db = fake();
    db.http.on("GET", `${db.url}/auth/v1/user`, respond);
    assertEquals(
      await getCaller(jsonRequest("f", {}, { token: "tok-user" }), { admin: db.admin() }),
      null,
      label,
    );
  }
});

Deno.test("isTransientAuthError: classification", () => {
  assertEquals(isTransientAuthError({ name: "AuthRetryableFetchError", status: 0 }), true);
  assertEquals(isTransientAuthError({ name: "AuthUnknownError" }), true);
  assertEquals(isTransientAuthError({ name: "AuthApiError", status: 429 }), true);
  assertEquals(isTransientAuthError({ name: "AuthApiError", status: 408 }), true);
  assertEquals(isTransientAuthError({ name: "AuthApiError", status: 500 }), true);
  assertEquals(isTransientAuthError({ name: "AuthApiError", status: 403 }), false);
  assertEquals(isTransientAuthError({ name: "AuthApiError", status: 404 }), false);
  assertEquals(isTransientAuthError({ name: "AuthSessionMissingError", status: 400 }), false);
  assertEquals(isTransientAuthError({ name: "AuthApiError" }), false);
});

Deno.test("adminClient: uses the service role key", async () => {
  const db = fake();
  const { data, error } = await db.admin().from("widgets").select("id");
  assertEquals(error, null);
  assertEquals(data, [{ id: "w1" }]);
  assertEquals(db.requests[0]?.role, "service_role");
  assertEquals(db.http.calls[0]?.headers.get("authorization"), `Bearer ${FAKE_SERVICE_ROLE_KEY}`);
});

Deno.test("adminClient: requires Supabase env", () => {
  const db = fake();
  assertThrows(
    () =>
      adminClient({ env: db.env({ SUPABASE_SERVICE_ROLE_KEY: undefined }), fetch: db.http.fetch }),
    Error,
    "SUPABASE_SERVICE_ROLE_KEY",
  );
});

Deno.test("userClient: forwards the caller's JWT with the anon key (RLS applies)", async () => {
  const db = fake();
  const client = userClient(jsonRequest("f", {}, { token: "tok-user" }), {
    env: db.env(),
    fetch: db.http.fetch,
  });
  await client.from("widgets").select("id");
  const call = db.http.calls.at(-1);
  assertEquals(call?.headers.get("apikey"), FAKE_ANON_KEY);
  assertEquals(call?.headers.get("authorization"), "Bearer tok-user");
  assertEquals(db.requests.at(-1)?.role, "authenticated");
  assertEquals(db.requests.at(-1)?.userId, USER_ID);
});

Deno.test("userClient: no bearer token -> unauthorized", () => {
  const db = fake();
  const err = assertThrows(
    () => userClient(jsonRequest("f", {}), { env: db.env(), fetch: db.http.fetch }),
    HttpError,
  );
  assertEquals(err.code, "unauthorized");
});
