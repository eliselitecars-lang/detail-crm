/**
 * billing end to end: real handler -> real supabase-js + Stripe SDK against
 * FakeSupabase (billing RPCs faked with the 0101 contract) and a fake
 * PLATFORM Stripe account. Role gating, every error reason, the Checkout
 * parameters (customer reuse/creation, trial rules, metadata, idempotency),
 * the portal configuration error, and the plan sync rules.
 */
import { assert, assertEquals, assertMatch, assertNotEquals } from "@std/assert";
import {
  emptyRequest,
  FakeRpcError,
  preflightRequest,
  responseJson,
  stripeErrorBody,
  TEST_ENV,
} from "../_shared/testing/mod.ts";
import {
  billingRow,
  errorOf,
  fixture,
  HOUR,
  NOW,
  OTHER_SHOP,
  PLAN_MONTHLY,
  PLAN_RETIRED,
  PLAN_YEARLY,
  planRow,
  recurringPrice,
  SHOP,
  USERS,
} from "./test_fixtures.ts";
import {
  checkoutTrialEnd,
  isPortalNotConfigured,
  MIN_TRIAL_LEAD_MS,
  requestPart,
} from "./index.ts";

const CRON = { "x-cron-secret": TEST_ENV.CRON_SECRET as string };
const NONCE = "nonce-0123456789";

function checkoutBody(overrides: Record<string, unknown> = {}) {
  return {
    action: "checkout",
    shop_id: SHOP,
    plan_id: PLAN_MONTHLY,
    request_nonce: NONCE,
    ...overrides,
  };
}

// ---------------------------------------------------------------------------
// plans
// ---------------------------------------------------------------------------

Deno.test("plans: any signed-in user gets the active plans, never Stripe ids", async () => {
  for (const who of ["owner", "admin", "manager", "tech", "outsider"] as const) {
    const f = fixture();
    const res = await f.call({ action: "plans" }, who);
    assertEquals(res.status, 200, who);
    const body = await responseJson<{ billing_enabled: boolean; plans: Record<string, unknown>[] }>(
      res,
    );
    assertEquals(body.billing_enabled, true);
    assertEquals(body.plans.map((p) => p.id), [PLAN_MONTHLY, PLAN_YEARLY]);
    assertEquals(Object.keys(body.plans[0] ?? {}).sort(), [
      "amount_cents",
      "currency",
      "description",
      "features",
      "id",
      "interval",
      "interval_count",
      "max_members",
      "name",
    ]);
    assert(!JSON.stringify(body).includes("price_1"), "no Stripe price id");
    assert(!JSON.stringify(body).includes("prod_1"), "no Stripe product id");
    // the plans are read as the caller (the RPC's client grant), not the service role
    const rpc = f.db.requests.filter((r) =>
      r.kind === "rpc" && r.target === "public_billing_plans"
    );
    assertEquals(rpc.map((r) => [r.role, r.userId]), [["authenticated", USERS[who]]], who);
  }
});

Deno.test("plans: billing off answers billing_enabled false and no plans", async () => {
  const f = fixture({ billingEnabled: false });
  const res = await f.call({ action: "plans" });
  assertEquals(await responseJson(res), { billing_enabled: false, plans: [] });
  assertEquals(f.rpcCalls("public_billing_plans").length, 0);
});

Deno.test("plans: no session or an anonymous session is 401 with the envelope", async () => {
  const f = fixture();
  assertEquals((await errorOf(await f.call({ action: "plans" }, "none"))).slice(0, 2), [
    401,
    "unauthorized",
  ]);
  assertEquals((await errorOf(await f.call({ action: "plans" }, "anon"))).slice(0, 2), [
    401,
    "unauthorized",
  ]);
  const extra = await f.call({ action: "plans", shop_id: SHOP });
  assertEquals((await errorOf(extra)).slice(0, 2), [400, "validation_failed"]);
});

// ---------------------------------------------------------------------------
// checkout: roles and errors
// ---------------------------------------------------------------------------

Deno.test("checkout: only the owner; admin, manager, technician, other shops and former owners get 403", async () => {
  for (const who of ["admin", "manager", "tech", "outsider", "inactiveOwner"] as const) {
    const f = fixture();
    const [status, code] = await errorOf(await f.call(checkoutBody(), who));
    assertEquals([status, code], [403, "forbidden"], who);
    assertEquals(f.stripeCalls().length, 0, who);
    assertEquals(f.rpcCalls("billing_link_customer").length, 0, who);
  }
  const f = fixture();
  assertEquals((await errorOf(await f.call(checkoutBody(), "none"))).slice(0, 2), [
    401,
    "unauthorized",
  ]);
  assertEquals(f.stripeCalls().length, 0);
});

Deno.test("checkout: 422 billing_disabled while billing is off", async () => {
  const f = fixture({ billingEnabled: false });
  assertEquals(await errorOf(await f.call(checkoutBody())), [
    422,
    "unprocessable",
    { reason: "billing_disabled" },
  ]);
  assertEquals(f.stripeCalls().length, 0);
});

Deno.test("checkout: 409 already_subscribed for a live subscription; a canceled one may subscribe again", async () => {
  // 0101 has_live_subscription: unpaid and paused subscriptions still exist in
  // Stripe (the Customer Portal settles them); a new checkout would bill twice
  for (const status of ["active", "trialing", "past_due", "unpaid", "paused"]) {
    const f = fixture({
      billing: { stripe_customer_id: "cus_1Shop", stripe_subscription_id: "sub_1", status },
    });
    assertEquals(
      await errorOf(await f.call(checkoutBody())),
      [409, "conflict", { reason: "already_subscribed" }],
      status,
    );
    assertEquals(f.stripeCalls().length, 0, status);
  }
  for (const status of ["canceled", "incomplete_expired", "incomplete"]) {
    const f = fixture({
      billing: { stripe_customer_id: "cus_1Shop", stripe_subscription_id: "sub_1", status },
    });
    assertEquals((await f.call(checkoutBody())).status, 200, status);
  }
});

Deno.test("checkout: billing_link_customer 23505 — already linked elsewhere, or another shop's customer", async () => {
  // A concurrent first checkout linked its own customer between our read and
  // our link: this shop is now linked to a DIFFERENT customer (never swapped).
  const raced = fixture();
  raced.db.onRpc("billing_link_customer", (a) => {
    const row = raced.state.billing.get(SHOP);
    if (row) row.stripe_customer_id = "cus_1Winner";
    assertEquals(a.p_stripe_customer_id, "cus_1NewShop");
    throw new FakeRpcError("23505", "this shop is already linked to another billing customer", {
      status: 409,
    });
  });
  const a = await raced.call(checkoutBody());
  const bodyA = await a.json();
  assertEquals([a.status, bodyA.code, bodyA.details], [409, "conflict", {
    reason: "billing_account_changed",
  }]);
  assertEquals(
    bodyA.error,
    "This shop's billing account was just set up by another request. Refresh and try again.",
  );
  assertEquals(raced.stripeCalls("POST", "/checkout/sessions").length, 0);
  assertEquals(raced.logs.events("billing_customer_not_linked")[0]?.customer, "cus_1NewShop");
  // the retry the message asks for uses the linked customer
  raced.db.onRpc("billing_link_customer", () => {
    throw new Error("must not relink");
  });
  assertEquals(
    (await raced.call(checkoutBody({ request_nonce: "nonce-retry-000001" }))).status,
    200,
  );
  assertEquals(
    raced.stripeCalls("POST", "/checkout/sessions")[0]?.form.get("customer"),
    "cus_1Winner",
  );

  // The Stripe customer is already another shop's.
  const taken = fixture();
  const other = taken.state.billing.get(OTHER_SHOP);
  if (other) other.stripe_customer_id = "cus_1NewShop";
  assertEquals(await errorOf(await taken.call(checkoutBody())), [409, "conflict", {
    reason: "customer_conflict",
  }]);
  assertEquals(taken.state.billing.get(SHOP)?.stripe_customer_id, null);
  assertEquals(taken.stripeCalls("POST", "/checkout/sessions").length, 0);
});

Deno.test("plans / checkout: platform_plans, platform_config and shop_billing are read only with the service role", async () => {
  // 0100: platform_plans has no client access at all; clients read plans
  // through public_billing_plans() (granted to anon and authenticated).
  const f = fixture();
  assertEquals((await f.call({ action: "plans" }, "tech")).status, 200);
  assertEquals((await f.call(checkoutBody())).status, 200);
  const direct = f.db.requests.filter((r) =>
    ["platform_plans", "platform_config", "shop_billing"].includes(r.target)
  );
  assert(direct.length > 0);
  for (const r of direct) assertEquals(r.role, "service_role", r.target);
  assertEquals(
    f.db.requests.filter((r) => r.target === "public_billing_plans").map((r) => r.role),
    ["authenticated"],
  );
});

Deno.test("checkout: 404 plan_not_found for an unknown or inactive plan", async () => {
  for (const plan of [PLAN_RETIRED, "77777777-7777-4777-8777-00000000dead"]) {
    const f = fixture();
    assertEquals(await errorOf(await f.call(checkoutBody({ plan_id: plan }))), [
      404,
      "not_found",
      { reason: "plan_not_found" },
    ]);
    assertEquals(f.stripeCalls().length, 0);
  }
});

Deno.test("checkout: prices and unknown fields from the client are rejected", async () => {
  const f = fixture();
  for (
    const body of [
      checkoutBody({ price: "price_1Cheap" }),
      checkoutBody({ amount_cents: 1 }),
      checkoutBody({ trial_end: 2_000_000_000 }),
      checkoutBody({ plan_id: "not-a-uuid" }),
      checkoutBody({ request_nonce: "short" }),
      { action: "checkout", shop_id: SHOP },
    ]
  ) {
    assertEquals((await errorOf(await f.call(body)))[1], "validation_failed", JSON.stringify(body));
  }
  assertEquals(f.stripeCalls().length, 0);
});

// ---------------------------------------------------------------------------
// checkout: parameters
// ---------------------------------------------------------------------------

Deno.test("checkout: first checkout creates the platform customer, links it, opens a subscription Checkout", async () => {
  const f = fixture();
  const res = await f.call(checkoutBody());
  assertEquals(await responseJson(res), {
    url: "https://checkout.stripe.com/c/pay/cs_test_1Billing",
  });

  const customer = f.stripeCalls("POST", "/customers")[0];
  assert(customer);
  assertEquals(customer.form.get("email"), "owner@shine.example.com");
  assertEquals(customer.form.get("name"), "Shine Co");
  assertEquals(customer.form.get("metadata[shop_id]"), SHOP);
  assertMatch(
    customer.headers.get("idempotency-key") ?? "",
    /^dcrm:billing_customer:[0-9a-f]{64}$/,
  );
  assertEquals(f.rpcCalls("billing_link_customer"), [
    { p_shop_id: SHOP, p_stripe_customer_id: "cus_1NewShop" },
  ]);
  assertEquals(f.state.billing.get(SHOP)?.stripe_customer_id, "cus_1NewShop");

  const session = f.stripeCalls("POST", "/checkout/sessions")[0];
  assert(session);
  const form = session.form;
  assertEquals(form.get("mode"), "subscription");
  assertEquals(form.get("customer"), "cus_1NewShop");
  assertEquals(form.get("line_items[0][price]"), "price_1Monthly");
  assertEquals(form.get("line_items[0][quantity]"), "1");
  assertEquals(form.get("client_reference_id"), SHOP);
  assertEquals(form.get("metadata[shop_id]"), SHOP);
  assertEquals(form.get("subscription_data[metadata][shop_id]"), SHOP);
  assertEquals(form.get("subscription_data[trial_end]"), null);
  assertEquals(form.get("allow_promotion_codes"), "true");
  assertEquals(
    form.get("success_url"),
    "https://app.example.com/app/settings/billing?checkout=success",
  );
  assertEquals(
    form.get("cancel_url"),
    "https://app.example.com/app/settings/billing?checkout=cancelled",
  );
  // Amounts never come from the request: only the plan's Stripe price.
  assertEquals([...form.keys()].filter((k) => /amount|unit_amount|price_data/.test(k)), []);
  assertMatch(session.headers.get("idempotency-key") ?? "", /^dcrm:billing_checkout:[0-9a-f]{64}$/);

  // PLATFORM account: no call is made on a connected account.
  for (const call of f.stripeCalls()) assertEquals(call.headers.get("stripe-account"), null);
});

Deno.test("checkout: Stripe Tax is off by default and on only with BILLING_AUTOMATIC_TAX=true", async () => {
  const off = fixture();
  assertEquals((await off.call(checkoutBody())).status, 200);
  const offForm = off.stripeCalls("POST", "/checkout/sessions")[0]?.form;
  assertEquals(offForm?.get("automatic_tax[enabled]"), null);
  assertEquals(offForm?.get("customer_update[address]"), null);

  const on = fixture({ env: { BILLING_AUTOMATIC_TAX: "true" } });
  assertEquals((await on.call(checkoutBody())).status, 200);
  const onCall = on.stripeCalls("POST", "/checkout/sessions")[0];
  assertEquals(onCall?.form.get("automatic_tax[enabled]"), "true");
  assertEquals(onCall?.form.get("customer_update[address]"), "auto");
  // a different request to Stripe, so a different idempotency key
  assertNotEquals(
    onCall?.headers.get("idempotency-key"),
    off.stripeCalls("POST", "/checkout/sessions")[0]?.headers.get("idempotency-key"),
  );
});

Deno.test("checkout: an existing platform customer is reused (no new customer, no relink)", async () => {
  const f = fixture({ billing: { stripe_customer_id: "cus_1Existing" } });
  assertEquals((await f.call(checkoutBody({ plan_id: PLAN_YEARLY }))).status, 200);
  assertEquals(f.stripeCalls("POST", "/customers").length, 0);
  assertEquals(f.rpcCalls("billing_link_customer").length, 0);
  const form = f.stripeCalls("POST", "/checkout/sessions")[0]?.form;
  assertEquals(form?.get("customer"), "cus_1Existing");
  assertEquals(form?.get("line_items[0][price]"), "price_1Yearly");
});

Deno.test("checkout: an owner without an email still gets a customer (name + shop id only)", async () => {
  const f = fixture({ ownerEmail: null });
  assertEquals((await f.call(checkoutBody())).status, 200);
  const customer = f.stripeCalls("POST", "/customers")[0];
  assertEquals(customer?.form.get("email"), null);
  assertEquals(customer?.form.get("name"), "Shine Co");
});

Deno.test("checkout: a customer already owned by another shop is a 409, and no session is opened", async () => {
  const f = fixture();
  f.state.billing.set(OTHER_SHOP, billingRow(OTHER_SHOP, { stripe_customer_id: "cus_1NewShop" }));
  const [status, code] = await errorOf(await f.call(checkoutBody()));
  assertEquals([status, code], [409, "conflict"]);
  assertEquals(f.stripeCalls("POST", "/checkout/sessions").length, 0);
});

Deno.test("checkout: the remaining in-app trial carries over only when it is at least 48h away", async () => {
  const cases: Array<[Partial<ReturnType<typeof billingRow>>, number | null]> = [
    [{ trial_ends_at: new Date(NOW + 72 * HOUR).toISOString() }, (NOW + 72 * HOUR) / 1000],
    [
      { trial_ends_at: new Date(NOW + 48 * HOUR + 61_000).toISOString() },
      Math.floor((NOW + 48 * HOUR + 61_000) / 1000),
    ],
    // exactly 48h (Stripe's minimum) is too close once the request is in flight
    [{ trial_ends_at: new Date(NOW + 48 * HOUR).toISOString() }, null],
    [{ trial_ends_at: new Date(NOW + 47 * HOUR).toISOString() }, null],
    [{ trial_ends_at: new Date(NOW - HOUR).toISOString() }, null],
    // a trial that was already used on an earlier subscription never repeats
    [{ trial_ends_at: new Date(NOW + 72 * HOUR).toISOString(), trial_used: true }, null],
    [{}, null],
  ];
  for (const [billing, expected] of cases) {
    const f = fixture({ billing });
    assertEquals((await f.call(checkoutBody())).status, 200);
    const form = f.stripeCalls("POST", "/checkout/sessions")[0]?.form;
    assertEquals(
      form?.get("subscription_data[trial_end]") ?? null,
      expected === null ? null : String(expected),
      JSON.stringify(billing),
    );
  }
  assertEquals(MIN_TRIAL_LEAD_MS, 48 * HOUR + 60_000);
  assertEquals(checkoutTrialEnd("not a date", NOW), null);
});

Deno.test("checkout: idempotency key follows the request nonce (retry = same key, new attempt = new key)", async () => {
  const keyFor = async (body: Record<string, unknown>, billing = {}) => {
    const f = fixture({ billing });
    assertEquals((await f.call(body)).status, 200);
    return f.stripeCalls("POST", "/checkout/sessions")[0]?.headers.get("idempotency-key");
  };
  const first = await keyFor(checkoutBody());
  assertEquals(await keyFor(checkoutBody()), first);
  assertNotEquals(await keyFor(checkoutBody({ request_nonce: "nonce-other-0001" })), first);
  assertNotEquals(await keyFor(checkoutBody({ plan_id: PLAN_YEARLY })), first);
  assertNotEquals(
    await keyFor(checkoutBody(), { trial_ends_at: new Date(NOW + 72 * HOUR).toISOString() }),
    first,
  );
  // Without a nonce: identical requests in the same 10-minute window share one.
  const { request_nonce: _n, ...noNonce } = checkoutBody();
  assertEquals(await keyFor(noNonce), await keyFor(noNonce));
  assertEquals(requestPart(undefined, NOW), requestPart(undefined, NOW + 1_000));
  assertNotEquals(requestPart(undefined, NOW), requestPart(undefined, NOW + 11 * 60_000));
  assertEquals(requestPart("abc", NOW), "n:abc");
});

// ---------------------------------------------------------------------------
// portal
// ---------------------------------------------------------------------------

Deno.test("portal: the owner gets a Customer Portal session for the shop's platform customer", async () => {
  const f = fixture({
    billing: { stripe_customer_id: "cus_1Shop", stripe_subscription_id: "sub_1", status: "active" },
  });
  const res = await f.call({ action: "portal", shop_id: SHOP });
  assertEquals(await responseJson(res), {
    url: "https://billing.stripe.com/p/session/test_1Billing",
  });
  const session = f.stripeCalls("POST", "/billing_portal/sessions")[0];
  assertEquals(session?.form.get("customer"), "cus_1Shop");
  assertEquals(session?.form.get("return_url"), "https://app.example.com/app/settings/billing");
  // the operator's Dashboard configuration is used (none is created here)
  assertEquals(session?.form.get("configuration"), null);
  assertEquals(f.stripeCalls("POST", "/billing_portal/configurations").length, 0);
  assertEquals(session?.headers.get("stripe-account"), null);
});

Deno.test("portal: only the owner", async () => {
  for (const who of ["admin", "manager", "tech", "outsider", "inactiveOwner"] as const) {
    const f = fixture({ billing: { stripe_customer_id: "cus_1Shop" } });
    assertEquals(
      (await errorOf(await f.call({ action: "portal", shop_id: SHOP }, who))).slice(0, 2),
      [
        403,
        "forbidden",
      ],
      who,
    );
    assertEquals(f.stripeCalls().length, 0, who);
  }
});

Deno.test("portal: 409 no_billing_account before the first checkout", async () => {
  const f = fixture();
  assertEquals(await errorOf(await f.call({ action: "portal", shop_id: SHOP })), [
    409,
    "conflict",
    { reason: "no_billing_account" },
  ]);
  assertEquals(f.stripeCalls().length, 0);
});

Deno.test("portal: works while billing is off (a shop can always manage or cancel)", async () => {
  const f = fixture({ billingEnabled: false, billing: { stripe_customer_id: "cus_1Shop" } });
  assertEquals((await f.call({ action: "portal", shop_id: SHOP })).status, 200);
});

Deno.test("portal: Stripe's missing portal configuration is 503 portal_not_configured", async () => {
  for (
    const message of [
      "You can't create a portal session in live mode until you save your customer portal settings in live mode at https://dashboard.stripe.com/settings/billing/portal.",
      "No configuration provided and your test mode default configuration has not been created. Provide a configuration or create your default by saving your customer portal settings in test mode at https://dashboard.stripe.com/test/settings/billing/portal.",
    ]
  ) {
    const f = fixture({ billing: { stripe_customer_id: "cus_1Shop" } });
    f.stripe.portalError = { status: 400, body: stripeErrorBody("invalid_request_error", message) };
    const [status, code, details] = await errorOf(
      await f.call({ action: "portal", shop_id: SHOP }),
    );
    assertEquals([status, code, details], [503, "service_unavailable", {
      reason: "portal_not_configured",
    }]);
  }
  // any other rejection stays a generic upstream error
  const f = fixture({ billing: { stripe_customer_id: "cus_1Gone" } });
  f.stripe.portalError = {
    status: 400,
    body: stripeErrorBody("invalid_request_error", "No such customer: 'cus_1Gone'"),
  };
  const [status, code] = await errorOf(await f.call({ action: "portal", shop_id: SHOP }));
  assertEquals([status, code], [502, "upstream_error"]);
  assertEquals(isPortalNotConfigured(new Error("customer portal settings")), false);
});

// ---------------------------------------------------------------------------
// sync_plans
// ---------------------------------------------------------------------------

function catalog(f: ReturnType<typeof fixture>) {
  f.stripe.products = [
    {
      id: "prod_1Studio",
      name: "Studio",
      description: "For one location",
      metadata: {
        detailcrm_plan: "true",
        max_members: "5",
        features: "online_booking,sms",
        sort: "1",
      },
    },
    {
      id: "prod_1Pro",
      name: "Pro",
      metadata: {
        detailcrm_plan: "true",
        max_members: "lots",
        features: "all!,reports",
        sort: "x",
      },
    },
    { id: "prod_1Merch", name: "T-shirt", metadata: {} },
    { id: "prod_1Other", name: "Consulting", metadata: { detailcrm_plan: "false" } },
    { id: "prod_1Archived", name: "Old", active: false, metadata: { detailcrm_plan: "true" } },
  ];
  f.stripe.prices = [
    recurringPrice("price_1Monthly", "prod_1Studio", 4_900, "month"),
    recurringPrice("price_1Yearly", "prod_1Studio", 49_000, "year"),
    recurringPrice("price_1ProMonthly", "prod_1Pro", 9_900, "month"),
    recurringPrice("price_1ProWeekly", "prod_1Pro", 2_500, "week"),
    recurringPrice("price_1Metered", "prod_1Pro", 10, "month", {
      recurring: { interval: "month", interval_count: 1, usage_type: "metered", meter: "mtr_1" },
    }),
    recurringPrice("price_1Inactive", "prod_1Pro", 1_000, "month", { active: false }),
    recurringPrice("price_1Shirt", "prod_1Merch", 2_000, "month"),
    recurringPrice("price_1Consult", "prod_1Other", 10_000, "month"),
    recurringPrice("price_1Old", "prod_1Archived", 100, "month"),
  ];
}

Deno.test("sync_plans: needs the cron secret (a signed-in owner is not enough)", async () => {
  const f = fixture();
  assertEquals((await errorOf(await f.call({ action: "sync_plans" }, "none"))).slice(0, 2), [
    401,
    "unauthorized",
  ]);
  assertEquals((await errorOf(await f.call({ action: "sync_plans" }, "owner"))).slice(0, 2), [
    401,
    "unauthorized",
  ]);
  const wrong = await f.call({ action: "sync_plans" }, "none", {
    "x-cron-secret": "wrong-secret-0123456789abcdef",
  });
  assertEquals((await errorOf(wrong)).slice(0, 2), [401, "unauthorized"]);
  assertEquals(f.stripeCalls().length, 0);
});

Deno.test("sync_plans: flagged Products' active recurring month/year Prices become plans; the rest is deactivated", async () => {
  const f = fixture({
    plans: [
      planRow({ name: "Studio (old name)", max_members: 3 }),
      planRow({ id: PLAN_RETIRED, stripe_price_id: "price_1Gone", active: true }),
    ],
  });
  catalog(f);
  const res = await f.call({ action: "sync_plans" }, "none", CRON);
  const body = await responseJson<Record<string, unknown>>(res);
  assertEquals(body.upserted, 3);
  assertEquals(body.deactivated, 1);
  assertEquals(body.skipped, [
    { product_id: "prod_1Pro", price_id: "price_1ProWeekly", reason: "unsupported_interval" },
    { product_id: "prod_1Pro", price_id: "price_1Metered", reason: "metered_price" },
  ]);
  assertEquals(
    (body.warnings as Array<Record<string, string>>).map((w) => [w.product_id, w.key]),
    [["prod_1Pro", "max_members"], ["prod_1Pro", "features"], ["prod_1Pro", "sort"]],
  );

  const byPrice = Object.fromEntries(
    f.db.table("platform_plans").map((p) => [p.stripe_price_id as string, p]),
  );
  // the existing row is updated in place (same id), from Stripe's values
  assertEquals(byPrice.price_1Monthly?.id, PLAN_MONTHLY);
  assertEquals(
    [
      byPrice.price_1Monthly?.name,
      byPrice.price_1Monthly?.max_members,
      byPrice.price_1Monthly?.features,
    ],
    ["Studio", 5, ["online_booking", "sms"]],
  );
  assertEquals(
    [
      byPrice.price_1Yearly?.interval,
      byPrice.price_1Yearly?.amount_cents,
      byPrice.price_1Yearly?.active,
    ],
    ["year", 49_000, true],
  );
  // invalid metadata: unlimited members, valid features only, sort 0
  assertEquals(
    [
      byPrice.price_1ProMonthly?.max_members,
      byPrice.price_1ProMonthly?.features,
      byPrice.price_1ProMonthly?.sort,
    ],
    [null, ["reports"], 0],
  );
  assertEquals(byPrice.price_1Gone?.active, false);
  for (
    const p of [
      "price_1Shirt",
      "price_1Consult",
      "price_1Old",
      "price_1Inactive",
      "price_1ProWeekly",
    ]
  ) {
    assertEquals(byPrice[p], undefined, p);
  }
  assertEquals(f.rpcCalls("billing_deactivate_plans_except"), [
    { p_active_price_ids: ["price_1Monthly", "price_1Yearly", "price_1ProMonthly"] },
  ]);
  const upsert = f.rpcCalls("billing_upsert_plan")[0];
  assertEquals(upsert, {
    p_stripe_price_id: "price_1Monthly",
    p_stripe_product_id: "prod_1Studio",
    p_name: "Studio",
    p_description: "For one location",
    p_amount_cents: 4_900,
    p_currency: "usd",
    p_interval: "month",
    p_interval_count: 1,
    p_max_members: 5,
    p_features: ["online_booking", "sms"],
    p_sort: 1,
    p_active: true,
  });
  for (const call of f.stripeCalls()) assertEquals(call.headers.get("stripe-account"), null);

  // idempotent: a second run changes nothing and deactivates nothing more
  const again = await responseJson<Record<string, unknown>>(
    await f.call({ action: "sync_plans" }, "none", CRON),
  );
  assertEquals([again.upserted, again.deactivated], [3, 0]);
});

Deno.test("sync_plans: follows Stripe's pagination", async () => {
  const f = fixture({ plans: [] });
  catalog(f);
  f.stripe.pageSize = 2;
  const body = await responseJson<Record<string, unknown>>(
    await f.call({ action: "sync_plans" }, "none", CRON),
  );
  assertEquals(body.upserted, 3);
  // 4 active products and Pro's 3 active prices: two pages each
  assertEquals(f.stripeCalls("GET", "/products").length, 2);
  assertEquals(
    f.stripeCalls("GET", "/prices").filter((c) => c.url.searchParams.get("product") === "prod_1Pro")
      .length,
    2,
  );
});

Deno.test("sync_plans: no plan Products deactivates every plan; a Stripe outage deactivates nothing", async () => {
  const empty = fixture();
  const body = await responseJson<Record<string, unknown>>(
    await empty.call({ action: "sync_plans" }, "none", CRON),
  );
  assertEquals([body.upserted, body.deactivated], [0, 2]);

  const down = fixture();
  catalog(down);
  down.stripe.listError = {
    status: 500,
    body: stripeErrorBody("api_error", "An unknown error occurred"),
  };
  const [status, code] = await errorOf(await down.call({ action: "sync_plans" }, "none", CRON));
  assertEquals([status, code], [503, "service_unavailable"]);
  assertEquals(down.rpcCalls("billing_deactivate_plans_except").length, 0);
  assertEquals(down.db.table("platform_plans").filter((p) => p.active === true).length, 2);
});

// ---------------------------------------------------------------------------
// HTTP surface
// ---------------------------------------------------------------------------

Deno.test("billing: unknown action 400, GET 405, CORS only for the app origin", async () => {
  const f = fixture();
  assertEquals((await errorOf(await f.call({ action: "subscribe" }))).slice(0, 2), [
    400,
    "unknown_action",
  ]);
  const get = await f.handler(emptyRequest("billing"));
  assertEquals(get.status, 405);
  await get.body?.cancel();
  const ok = await f.handler(preflightRequest("billing", "https://app.example.com"));
  assertEquals(ok.headers.get("access-control-allow-origin"), "https://app.example.com");
  await ok.body?.cancel();
  const bad = await f.handler(preflightRequest("billing", "https://evil.example.com"));
  assertEquals(bad.status, 403);
  await bad.body?.cancel();
});
