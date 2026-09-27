import { assert, assertEquals, assertMatch } from "@std/assert";
import type { ErrorBody } from "../_shared/http.ts";
import {
  FakeSupabase,
  jsonRequest,
  jsonResponse,
  memoryLogger,
  responseJson,
  stripeErrorBody,
} from "../_shared/testing/mod.ts";
import { businessUrl, makeHandler } from "./index.ts";

const SHOP = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const OTHER_SHOP = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const OWNER = "10000000-0000-4000-8000-000000000001";
const ADMIN = "10000000-0000-4000-8000-000000000002";
const MANAGER = "10000000-0000-4000-8000-000000000003";
const TECH = "10000000-0000-4000-8000-000000000004";
const OUTSIDER = "10000000-0000-4000-8000-000000000005";
const ACCT = "acct_1NewShopAcct0";
const STRIPE = "https://api.stripe.com/v1";

function member(id: string, shopId: string, userId: string, role: string, active = true) {
  return { id, shop_id: shopId, user_id: userId, role, display_name: role, active };
}

function setup(options: { account?: Record<string, unknown> } = {}) {
  const db = new FakeSupabase({
    users: {
      "tok-owner": { id: OWNER, email: "o@example.com" },
      "tok-admin": { id: ADMIN, email: "a@example.com" },
      "tok-manager": { id: MANAGER, email: "m@example.com" },
      "tok-tech": { id: TECH, email: "t@example.com" },
      "tok-outsider": { id: OUTSIDER, email: "x@example.com" },
      "tok-anon": { id: "10000000-0000-4000-8000-000000000009", is_anonymous: true },
    },
    tables: {
      shop_members: [
        member("20000000-0000-4000-8000-000000000001", SHOP, OWNER, "owner"),
        member("20000000-0000-4000-8000-000000000002", SHOP, ADMIN, "admin"),
        member("20000000-0000-4000-8000-000000000003", SHOP, MANAGER, "manager"),
        member("20000000-0000-4000-8000-000000000004", SHOP, TECH, "technician"),
        member("20000000-0000-4000-8000-000000000005", OTHER_SHOP, OUTSIDER, "owner"),
      ],
      shops: [
        {
          id: SHOP,
          name: "Shine Co",
          slug: "shine-co",
          email: "hello@shine.example.com",
          website: "shine.example.com",
        },
        { id: OTHER_SHOP, name: "Other", slug: "other", email: null, website: null },
      ],
      shop_stripe_accounts: options.account ? [options.account] : [],
    },
    tableOptions: { shop_stripe_accounts: { primaryKey: ["shop_id"] } },
  });
  db.http.on("POST", `${STRIPE}/accounts`, () =>
    jsonResponse({
      id: ACCT,
      object: "account",
      charges_enabled: false,
      payouts_enabled: false,
      details_submitted: false,
    }));
  db.http.on("POST", `${STRIPE}/account_links`, () =>
    jsonResponse({
      object: "account_link",
      url: "https://connect.stripe.com/setup/e/acct_x/abc",
      expires_at: 1_900_000_000,
      created: 1_899_999_700,
    }));
  db.http.on("GET", `${STRIPE}/accounts/:id`, (_req, { params }) =>
    jsonResponse({
      id: params.id,
      object: "account",
      charges_enabled: true,
      payouts_enabled: true,
      details_submitted: true,
    }));
  db.http.on(
    "POST",
    `${STRIPE}/accounts/:id/login_links`,
    () =>
      jsonResponse({
        object: "login_link",
        url: "https://connect.stripe.com/express/xyz",
        created: 1,
      }),
  );
  const logs = memoryLogger();
  const handler = makeHandler({ env: db.env(), fetch: db.http.fetch, logger: logs.logger });
  const call = (body: Record<string, unknown>, token?: string) =>
    handler(jsonRequest("stripe-connect", body, token ? { token } : {}));
  return { db, handler, call, logs };
}

const EXISTING = {
  shop_id: SHOP,
  stripe_account_id: "acct_1Existing000",
  charges_enabled: false,
  payouts_enabled: false,
  details_submitted: false,
};

Deno.test("create_account_link: owner creates the Express account once and gets a link", async () => {
  const { db, call } = setup();
  const res = await call({ action: "create_account_link", shop_id: SHOP }, "tok-owner");
  assertEquals(res.status, 200);
  const body = await responseJson<Record<string, unknown>>(res);
  assertEquals(body, {
    url: "https://connect.stripe.com/setup/e/acct_x/abc",
    expires_at: 1_900_000_000,
    stripe_account_id: ACCT,
  });

  const create = db.http.callsTo("POST", `${STRIPE}/accounts`)[0];
  assert(create);
  assertEquals(create.form.get("type"), "express");
  assertEquals(create.form.get("country"), "US");
  assertEquals(create.form.get("email"), "hello@shine.example.com");
  assertEquals(create.form.get("business_profile[name]"), "Shine Co");
  assertEquals(create.form.get("business_profile[url]"), "https://shine.example.com/");
  assertEquals(create.form.get("capabilities[card_payments][requested]"), "true");
  assertEquals(create.form.get("capabilities[transfers][requested]"), "true");
  assertEquals(create.form.get("metadata[shop_id]"), SHOP);
  assertMatch(create.headers.get("idempotency-key") ?? "", /^dcrm:connect_account:[0-9a-f]{64}$/);
  // Platform-level call: never on a connected account.
  assertEquals(create.headers.get("stripe-account"), null);

  const link = db.http.callsTo("POST", `${STRIPE}/account_links`)[0];
  assertEquals(link?.form.get("account"), ACCT);
  assertEquals(link?.form.get("type"), "account_onboarding");
  assertEquals(
    link?.form.get("return_url"),
    "https://app.example.com/app/settings/payments?stripe=return",
  );
  assertEquals(
    link?.form.get("refresh_url"),
    "https://app.example.com/app/settings/payments?stripe=refresh",
  );
  assert(link?.headers.get("idempotency-key")?.startsWith("dcrm:connect_account_link:"));

  const rows = db.table("shop_stripe_accounts");
  assertEquals(rows.length, 1);
  assertEquals(rows[0]?.stripe_account_id, ACCT);
  assertEquals(rows[0]?.charges_enabled, false);
  const write = db.requests.find((r) => r.target === "shop_stripe_accounts" && r.method === "POST");
  assertEquals(write?.role, "service_role");
});

Deno.test("create_account_link: an existing account is reused (no second account)", async () => {
  const { db, call } = setup({ account: EXISTING });
  const res = await call({ action: "create_account_link", shop_id: SHOP }, "tok-admin");
  assertEquals(res.status, 200);
  assertEquals(
    (await responseJson<{ stripe_account_id: string }>(res)).stripe_account_id,
    EXISTING.stripe_account_id,
  );
  assertEquals(db.http.callsTo("POST", `${STRIPE}/accounts`).length, 0);
  assertEquals(
    db.http.callsTo("POST", `${STRIPE}/account_links`)[0]?.form.get("account"),
    EXISTING.stripe_account_id,
  );
});

Deno.test("create_account_link: request_nonce makes link retries idempotent", async () => {
  const { db, call } = setup({ account: EXISTING });
  for (const nonce of ["nonce-0001", "nonce-0001", "nonce-0002"]) {
    await (await call(
      { action: "create_account_link", shop_id: SHOP, request_nonce: nonce },
      "tok-owner",
    ))
      .body?.cancel();
  }
  const keys = db.http.callsTo("POST", `${STRIPE}/account_links`).map((c) =>
    c.headers.get("idempotency-key")
  );
  assertEquals(keys.length, 3);
  assertEquals(keys[0], keys[1]);
  assert(keys[0] !== keys[2]);
});

Deno.test("stripe-connect: managers, technicians, other shops and signed-out callers are refused", async () => {
  const { db, call } = setup({ account: EXISTING });
  for (const action of ["create_account_link", "refresh_status", "login_link"]) {
    for (const token of ["tok-manager", "tok-tech", "tok-outsider"]) {
      const res = await call({ action, shop_id: SHOP }, token);
      assertEquals([res.status, (await responseJson<ErrorBody>(res)).code], [403, "forbidden"]);
    }
    for (const token of [undefined, "tok-anon", "tok-unknown"]) {
      const res = await call({ action, shop_id: SHOP }, token);
      assertEquals([res.status, (await responseJson<ErrorBody>(res)).code], [401, "unauthorized"]);
    }
  }
  assertEquals(db.http.calls.filter((c) => c.url.hostname === "api.stripe.com").length, 0);
});

Deno.test("stripe-connect: strict input (unknown fields, bad shop id)", async () => {
  const { call } = setup();
  const extra = await call(
    { action: "refresh_status", shop_id: SHOP, charges_enabled: true },
    "tok-owner",
  );
  assertEquals((await responseJson<ErrorBody>(extra)).code, "validation_failed");
  const bad = await call({ action: "refresh_status", shop_id: "nope" }, "tok-owner");
  assertEquals((await responseJson<ErrorBody>(bad)).code, "validation_failed");
  const unknown = await call({ action: "delete_account", shop_id: SHOP }, "tok-owner");
  assertEquals((await responseJson<ErrorBody>(unknown)).code, "unknown_action");
});

Deno.test("refresh_status: stores the account's flags", async () => {
  const { db, call } = setup({ account: EXISTING });
  const res = await call({ action: "refresh_status", shop_id: SHOP }, "tok-owner");
  assertEquals(res.status, 200);
  assertEquals(await res.json(), {
    connected: true,
    stripe_account_id: EXISTING.stripe_account_id,
    charges_enabled: true,
    payouts_enabled: true,
    details_submitted: true,
  });
  const row = db.table("shop_stripe_accounts")[0];
  assertEquals([row?.charges_enabled, row?.payouts_enabled, row?.details_submitted], [
    true,
    true,
    true,
  ]);
  const get = db.http.callsTo("GET", `${STRIPE}/accounts/:id`)[0];
  assertEquals(get?.url.pathname, `/v1/accounts/${EXISTING.stripe_account_id}`);
  assertEquals(get?.headers.get("stripe-account"), null);
});

Deno.test("refresh_status: not connected yet -> connected false, no Stripe call", async () => {
  const { db, call } = setup();
  const res = await call({ action: "refresh_status", shop_id: SHOP }, "tok-admin");
  assertEquals(await res.json(), {
    connected: false,
    stripe_account_id: null,
    charges_enabled: false,
    payouts_enabled: false,
    details_submitted: false,
  });
  assertEquals(db.http.calls.filter((c) => c.url.hostname === "api.stripe.com").length, 0);
});

Deno.test("login_link: requires a connected, onboarded account", async () => {
  const none = setup();
  const r1 = await none.call({ action: "login_link", shop_id: SHOP }, "tok-owner");
  assertEquals([r1.status, (await responseJson<ErrorBody>(r1)).details], [422, {
    reason: "stripe_not_connected",
  }]);

  const pending = setup({ account: EXISTING });
  const r2 = await pending.call({ action: "login_link", shop_id: SHOP }, "tok-owner");
  assertEquals((await responseJson<ErrorBody>(r2)).details, { reason: "onboarding_incomplete" });

  const done = setup({ account: { ...EXISTING, details_submitted: true } });
  const r3 = await done.call({ action: "login_link", shop_id: SHOP }, "tok-owner");
  assertEquals(await r3.json(), { url: "https://connect.stripe.com/express/xyz" });
  const call = done.db.http.callsTo("POST", `${STRIPE}/accounts/:id/login_links`)[0];
  assertEquals(call?.url.pathname, `/v1/accounts/${EXISTING.stripe_account_id}/login_links`);
  assert(call?.headers.get("idempotency-key")?.startsWith("dcrm:connect_login_link:"));
});

Deno.test("stripe-connect: Stripe failures map to stable codes without leaking details", async () => {
  const { db, call } = setup();
  db.http.on(
    "POST",
    `${STRIPE}/accounts`,
    () =>
      jsonResponse(
        stripeErrorBody("invalid_request_error", "secret internal detail sk_test_x"),
        400,
      ),
  );
  const res = await call({ action: "create_account_link", shop_id: SHOP }, "tok-owner");
  const body = await responseJson<ErrorBody>(res);
  assertEquals([res.status, body.code], [502, "upstream_error"]);
  assert(!JSON.stringify(body).includes("secret internal detail"));
  assertEquals(db.table("shop_stripe_accounts").length, 0);
});

Deno.test("businessUrl: only public http(s) URLs", () => {
  assertEquals(
    businessUrl("shine.example.com", "https://app.example.com/book/x"),
    "https://shine.example.com/",
  );
  assertEquals(businessUrl("https://shine.example.com/a", "x"), "https://shine.example.com/a");
  assertEquals(
    businessUrl("not a url", "https://app.example.com/book/x"),
    "https://app.example.com/book/x",
  );
  assertEquals(businessUrl(null, "http://localhost:5173/book/x"), undefined);
  assertEquals(businessUrl("ftp://files.example.com", "http://127.0.0.1/book"), undefined);
});
