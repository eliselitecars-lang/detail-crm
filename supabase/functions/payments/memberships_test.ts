import { assert, assertEquals, assertMatch } from "@std/assert";
import type { Stripe } from "../_shared/stripe.ts";
import { FakeRpcError, jsonRequest, jsonResponse } from "../_shared/testing/mod.ts";
import { JOIN_UNAVAILABLE_MESSAGE, membershipStatusOf, periodEndOf } from "./memberships.ts";
import {
  ACCT,
  CUSTOMER,
  errorOf,
  fixture,
  MEMBERSHIP,
  PLAN,
  SHOP,
  STRIPE,
} from "./test_fixtures.ts";

const checkout = { action: "membership_checkout", shop_id: SHOP, membership_id: MEMBERSHIP };
const cancel = { action: "membership_cancel", shop_id: SHOP, membership_id: MEMBERSHIP };

Deno.test("membership_checkout: creates the plan's product + price lazily and stores them", async () => {
  const f = fixture();
  const res = await f.call(checkout, "manager");
  assertEquals(await res.json(), {
    url: "https://checkout.stripe.com/c/pay/cs_test_1",
    expires_at: 1_900_000_000,
    amount_cents: 4_900,
    interval: "month",
    interval_count: 1,
    currency: "usd",
  });
  const product = f.stripe("POST", "/products")[0];
  assertEquals(product?.headers.get("stripe-account"), ACCT);
  assertEquals(product?.form.get("name"), "Monthly Wash");
  assertEquals(product?.form.get("metadata[plan_id]"), PLAN);
  assert(product?.headers.get("idempotency-key")?.startsWith("dcrm:membership_product:"));
  const price = f.stripe("POST", "/prices")[0];
  assertEquals(price?.headers.get("stripe-account"), ACCT);
  assertEquals(price?.form.get("product"), "prod_1New");
  assertEquals(price?.form.get("unit_amount"), "4900");
  assertEquals(price?.form.get("currency"), "usd");
  assertEquals(price?.form.get("recurring[interval]"), "month");
  assertEquals(price?.form.get("recurring[interval_count]"), "1");
  assert(price?.headers.get("idempotency-key")?.startsWith("dcrm:membership_price:"));
  const plan = f.db.table("membership_plans")[0];
  assertEquals([plan?.stripe_product_id, plan?.stripe_price_id], ["prod_1New", "price_1New"]);

  const session = f.stripe("POST", "/checkout/sessions")[0];
  const form = session?.form;
  assertEquals(session?.headers.get("stripe-account"), ACCT);
  assertMatch(session?.headers.get("idempotency-key") ?? "", /^dcrm:membership_checkout:/);
  assertEquals(form?.get("mode"), "subscription");
  assertEquals(form?.get("customer"), "cus_1New");
  assertEquals(form?.get("line_items[0][price]"), "price_1New");
  assertEquals(form?.get("line_items[0][quantity]"), "1");
  assertEquals(form?.get("subscription_data[metadata][membership_id]"), MEMBERSHIP);
  assertEquals(form?.get("subscription_data[metadata][shop_id]"), SHOP);
  assertEquals(form?.get("metadata[membership_id]"), MEMBERSHIP);
  assertEquals(form?.get("metadata[customer_id]"), CUSTOMER);
  assertEquals(form?.get("subscription_data[application_fee_percent]"), "2.5");
  assertEquals(form?.get("success_url"), "https://app.example.com/portal?membership=active");
});

Deno.test("membership_checkout: reuses a stored price that still matches the plan", async () => {
  const f = fixture({
    plan: { stripe_product_id: "prod_1Old", stripe_price_id: "price_1Old" },
    env: { PLATFORM_FEE_BPS: "0" },
  });
  assertEquals((await f.call(checkout, "owner")).status, 200);
  assertEquals(f.stripe("POST", "/prices").length + f.stripe("POST", "/products").length, 0);
  const form = f.stripe("POST", "/checkout/sessions")[0]?.form;
  assertEquals(form?.get("line_items[0][price]"), "price_1Old");
  assertEquals(form?.has("subscription_data[application_fee_percent]"), false);
});

Deno.test("membership_checkout: changed plan terms get a new price on the same product", async () => {
  const f = fixture({
    plan: { stripe_product_id: "prod_1Old", stripe_price_id: "price_1Old", price_cents: 5_900 },
  });
  assertEquals((await f.call(checkout, "owner")).status, 200);
  assertEquals(f.stripe("POST", "/products").length, 0);
  assertEquals(f.stripe("POST", "/prices")[0]?.form.get("product"), "prod_1Old");
  assertEquals(f.stripe("POST", "/prices")[0]?.form.get("unit_amount"), "5900");
  assertEquals(f.db.table("membership_plans")[0]?.stripe_price_id, "price_1New");
  assertEquals(
    f.stripe("POST", "/checkout/sessions")[0]?.form.get("line_items[0][price]"),
    "price_1New",
  );
});

Deno.test("membership_checkout: plan changed concurrently -> conflict, no checkout", async () => {
  const f = fixture();
  // The plan's price changes while Stripe objects are being created.
  f.db.http.on("POST", `${STRIPE}/prices`, () => {
    f.db.seed(
      "membership_plans",
      f.db.table("membership_plans").map((p) => ({ ...p, price_cents: 9_900 })),
    );
    return jsonResponse({ id: "price_1New", object: "price" });
  });
  assertEquals((await errorOf(await f.call(checkout, "owner")))[2], { reason: "plan_changed" });
  assertEquals(f.stripe("POST", "/checkout/sessions").length, 0);
  assertEquals(f.db.table("membership_plans")[0]?.stripe_price_id, null);
});

Deno.test("membership_checkout: state, plan and role checks", async () => {
  const active = fixture({ membership: { status: "active", stripe_subscription_id: "sub_1" } });
  assertEquals(await errorOf(await active.call(checkout, "owner")), [409, "conflict", {
    reason: "membership_not_incomplete",
  }]);
  const inactive = fixture({ plan: { active: false } });
  assertEquals((await errorOf(await inactive.call(checkout, "owner")))[2], {
    reason: "plan_unavailable",
  });
  const off = fixture({ account: { charges_enabled: false } });
  assertEquals((await errorOf(await off.call(checkout, "owner")))[2], {
    reason: "charges_disabled",
  });
  const f = fixture();
  for (const who of ["tech", "outsider"] as const) {
    assertEquals((await errorOf(await f.call(checkout, who)))[1], "forbidden");
  }
  assertEquals((await errorOf(await f.call(checkout, "none")))[1], "unauthorized");
  assertEquals(
    (await errorOf(
      await f.call({ ...checkout, membership_id: "88888888-8888-4888-8888-00000000abcd" }, "owner"),
    )).slice(0, 2),
    [404, "not_found"],
  );
  assertEquals(
    (await errorOf(await f.call({ ...checkout, price_cents: 1 }, "owner")))[1],
    "validation_failed",
  );
  for (const x of [active, inactive, off, f]) assertEquals(x.stripeCalls().length, 0);
});

Deno.test("membership_cancel: a never-billed membership is simply cancelled", async () => {
  const f = fixture();
  const res = await f.call(cancel, "manager");
  assertEquals(await res.json(), {
    membership_id: MEMBERSHIP,
    status: "cancelled",
    cancel_at_period_end: false,
    current_period_end: null,
  });
  assertEquals(f.db.table("memberships")[0]?.status, "cancelled");
  assertEquals(f.stripeCalls().length, 0);
});

Deno.test("membership_cancel: at period end updates the subscription and syncs", async () => {
  const f = fixture({ membership: { status: "active", stripe_subscription_id: "sub_1Live" } });
  const res = await f.call({ ...cancel, at_period_end: true }, "admin");
  assertEquals(await res.json(), {
    membership_id: MEMBERSHIP,
    status: "active",
    cancel_at_period_end: true,
    current_period_end: "2030-03-17T17:46:40.000Z",
  });
  const update = f.stripe("POST", "/subscriptions/:id")[0];
  assertEquals(update?.url.pathname, "/v1/subscriptions/sub_1Live");
  assertEquals(update?.headers.get("stripe-account"), ACCT);
  assertEquals(update?.form.get("cancel_at_period_end"), "true");
  assert(update?.headers.get("idempotency-key")?.startsWith("dcrm:membership_cancel:"));
  assertEquals(f.rpcCalls.find((c) => c.name === "sync_stripe_subscription")?.args, {
    p_shop_id: SHOP,
    p_subscription_id: "sub_1Live",
    p_status: "active",
    p_current_period_end: "2030-03-17T17:46:40.000Z",
    p_cancel_at_period_end: true,
    p_membership_id: MEMBERSHIP,
  });
});

Deno.test("membership_cancel: immediately cancels the subscription", async () => {
  const f = fixture({ membership: { status: "past_due", stripe_subscription_id: "sub_1Live" } });
  const res = await f.call(cancel, "owner");
  assertEquals((await res.json()).status, "cancelled");
  const del = f.stripe("DELETE", "/subscriptions/:id")[0];
  assertEquals(del?.headers.get("stripe-account"), ACCT);
  assertEquals(
    f.rpcCalls.find((c) => c.name === "sync_stripe_subscription")?.args.p_status,
    "cancelled",
  );
});

Deno.test("membership_cancel: already cancelled, roles", async () => {
  const done = fixture({ membership: { status: "cancelled" } });
  assertEquals((await errorOf(await done.call(cancel, "owner")))[2], {
    reason: "already_cancelled",
  });
  const f = fixture({ membership: { status: "active", stripe_subscription_id: "sub_1Live" } });
  for (const who of ["tech", "outsider"] as const) {
    assertEquals((await errorOf(await f.call(cancel, who)))[1], "forbidden");
  }
  assertEquals((await errorOf(await f.call(cancel, "anon")))[1], "unauthorized");
  assertEquals(
    (await errorOf(await f.call({ ...cancel, at_period_end: "yes" }, "owner")))[1],
    "validation_failed",
  );
  assertEquals(f.stripeCalls().length, 0);
});

Deno.test("membershipStatusOf / periodEndOf", () => {
  const cases: Array<[Stripe.Subscription.Status, string]> = [
    ["active", "active"],
    ["trialing", "active"],
    ["past_due", "past_due"],
    ["unpaid", "past_due"],
    ["paused", "past_due"],
    ["canceled", "cancelled"],
    ["incomplete_expired", "cancelled"],
    ["incomplete", "incomplete"],
  ];
  for (const [stripe, ours] of cases) assertEquals(membershipStatusOf(stripe), ours);
  const sub = {
    items: { data: [{ current_period_end: 100 }, { current_period_end: 200 }] },
  } as unknown as Stripe.Subscription;
  assertEquals(periodEndOf(sub), "1970-01-01T00:03:20.000Z");
  assertEquals(periodEndOf({ items: { data: [] } } as unknown as Stripe.Subscription), null);
});

// ---------------------------------------------------------------------------
// Checkout links never outlive (or double) a membership
// ---------------------------------------------------------------------------

function membershipSession(id: string, status: string, extra: Record<string, unknown> = {}) {
  return {
    id,
    object: "checkout.session",
    status,
    mode: "subscription",
    customer: "cus_1Saved",
    metadata: { shop_id: SHOP, membership_id: MEMBERSHIP, kind: "membership" },
    ...extra,
  };
}

Deno.test("membership_checkout: a new link expires the membership's older open links", async () => {
  const f = fixture({
    customer: { stripe_customer_id: "cus_1Saved" },
    plan: { stripe_product_id: "prod_1Old", stripe_price_id: "price_1Stored" },
    sessions: [
      membershipSession("cs_1OldLink", "open"),
      membershipSession("cs_1OtherMembership", "open", {
        metadata: { shop_id: SHOP, membership_id: "88888888-8888-4888-8888-000000000009" },
      }),
    ],
  });
  const res = await f.call(checkout, "manager");
  assertEquals(res.status, 200);
  await res.body?.cancel();
  assertEquals(f.sessions.map((x) => x.status), ["expired", "open"]);
});

Deno.test("membership_cancel: a never-billed membership's open links are expired first", async () => {
  const f = fixture({
    customer: { stripe_customer_id: "cus_1Saved" },
    sessions: [membershipSession("cs_1Link", "open")],
  });
  const res = await f.call(cancel, "manager");
  assertEquals((await res.json()).status, "cancelled");
  assertEquals(f.sessions[0]?.status, "expired");
  assertEquals(
    f.stripe("POST", "/checkout/sessions/cs_1Link/expire")[0]?.headers.get("stripe-account"),
    ACCT,
  );
  assertEquals(f.db.table("memberships")[0]?.status, "cancelled");
  assertEquals(f.stripe("DELETE", "/subscriptions/:id").length, 0);
});

Deno.test("membership_cancel: a link completed before the webhook linked it has its subscription stopped", async () => {
  const f = fixture({
    customer: { stripe_customer_id: "cus_1Saved" },
    sessions: [membershipSession("cs_1Paid", "complete", { subscription: "sub_1Stray" })],
  });
  const res = await f.call(cancel, "manager");
  assertEquals((await res.json()).status, "cancelled");
  const del = f.stripe("DELETE", "/subscriptions/:id");
  assertEquals(del.map((c) => c.url.pathname), ["/v1/subscriptions/sub_1Stray"]);
  assertEquals(del[0]?.headers.get("stripe-account"), ACCT);
  assert(del[0]?.headers.get("idempotency-key")?.startsWith("dcrm:membership_stray_cancel:"));
});

Deno.test("membership_cancel: a cancelled membership Stripe still bills is stopped, not refused", async () => {
  const f = fixture({
    membership: { status: "cancelled", stripe_subscription_id: "sub_1Live" },
    subscriptions: { sub_1Live: "active" },
  });
  const res = await f.call(cancel, "owner");
  assertEquals(res.status, 200);
  assertEquals((await res.json()).stopped_subscriptions, 1);
  assertEquals(
    f.stripe("DELETE", "/subscriptions/:id").map((c) => c.url.pathname),
    ["/v1/subscriptions/sub_1Live"],
  );

  const ended = fixture({
    membership: { status: "cancelled", stripe_subscription_id: "sub_1Live" },
    subscriptions: { sub_1Live: "canceled" },
  });
  assertEquals((await errorOf(await ended.call(cancel, "owner")))[2], {
    reason: "already_cancelled",
  });
  assertEquals(ended.stripe("DELETE", "/subscriptions/:id").length, 0);
});

Deno.test("membership_checkout: the subscription link is card-only", async () => {
  const f = fixture();
  const res = await f.call(checkout, "manager");
  assertEquals(res.status, 200);
  await res.body?.cancel();
  const session = f.stripe("POST", "/checkout/sessions")[0];
  assertEquals(session?.form.get("payment_method_types[0]"), "card");
  assertEquals(session?.form.get("payment_method_types[1]"), null);
});

// ---------------------------------------------------------------------------
// Weekly plans, public join (/join/<slug>) and the client portal (P-23)
// ---------------------------------------------------------------------------

Deno.test("membership_checkout: weekly plans bill every N weeks", async () => {
  const f = fixture({ plan: { interval: "week", interval_count: 2 } });
  const res = await f.call(checkout, "manager");
  const body = await res.json();
  assertEquals([body.interval, body.interval_count], ["week", 2]);
  const price = f.stripe("POST", "/prices")[0];
  assertEquals(price?.form.get("recurring[interval]"), "week");
  assertEquals(price?.form.get("recurring[interval_count]"), "2");
});

const join = {
  action: "membership_join_checkout",
  slug: "shine-co",
  plan_id: PLAN,
  customer: {
    first_name: "Grace",
    last_name: "Hopper",
    email: "grace@example.com",
    phone: "(205) 555-0123",
    sms_opt_in: true,
  },
  vehicle: { year: 2021, make: "Subaru", model: "Outback" },
  request_nonce: "join-0001",
};

function joinShop(prepare?: (args: Record<string, unknown>) => unknown, options = {}) {
  const f = fixture({ shop: { slug: "shine-co" }, ...options });
  f.db.onRpc("membership_join_prepare", (args, { role }) => {
    f.rpcCalls.push({ name: "membership_join_prepare", args });
    assertEquals(role, "service_role");
    if (prepare) return prepare(args);
    return {
      membership_id: MEMBERSHIP,
      customer_id: CUSTOMER,
      shop_id: SHOP,
      email: "grace@example.com",
    };
  });
  return f;
}

Deno.test("membership_join_checkout: prepares the membership, then the subscription checkout", async () => {
  const f = joinShop();
  const res = await f.call(join);
  assertEquals(await res.json(), {
    url: "https://checkout.stripe.com/c/pay/cs_test_1",
    expires_at: 1_900_000_000,
    amount_cents: 4_900,
    interval: "month",
    interval_count: 1,
    currency: "usd",
  });
  assertEquals(f.rpcCalls.find((c) => c.name === "membership_join_prepare")?.args, {
    p_slug: "shine-co",
    p_plan_id: PLAN,
    p_payload: { customer: join.customer, vehicle: join.vehicle },
  });
  const form = f.stripe("POST", "/checkout/sessions")[0]?.form;
  assertEquals(form?.get("mode"), "subscription");
  assertEquals(form?.get("subscription_data[metadata][membership_id]"), MEMBERSHIP);
  assertEquals(form?.get("metadata[source]"), "membership_join_checkout");
  assertEquals(form?.get("success_url"), "https://app.example.com/join/shine-co?joined=1");
  assertEquals(form?.get("cancel_url"), "https://app.example.com/join/shine-co?canceled=1");
  assert(f.db.requests.every((r) => r.role === "service_role"));
});

Deno.test("membership_join_checkout: errors", async () => {
  const unavailable = joinShop(() => {
    throw new FakeRpcError("55000", "this membership plan is not available online");
  });
  assertEquals(await errorOf(await unavailable.call(join)), [409, "conflict", {
    reason: "plan_unavailable",
  }]);
  const limited = joinShop(() => {
    throw new FakeRpcError("PT429", "too many membership sign-ups for this email today");
  });
  assertEquals((await errorOf(await limited.call(join))).slice(0, 2), [429, "rate_limited"]);
  const member = joinShop(() => {
    throw new FakeRpcError("22023", "this customer already has this membership");
  });
  // neutral: an anonymous caller must not learn that this email holds the plan
  const memberRes = await member.call(join);
  const memberBody = await memberRes.json();
  assertEquals([memberRes.status, memberBody.details], [409, { reason: "join_unavailable" }]);
  assertEquals(memberBody.error, JOIN_UNAVAILABLE_MESSAGE);
  const invalid = joinShop(() => {
    throw new FakeRpcError("22023", "enter a valid phone number");
  });
  const invalidRes = await invalid.call(join);
  const body = await invalidRes.json();
  assertEquals([invalidRes.status, body.details, body.error], [422, {
    reason: "invalid_details",
  }, "Enter a valid phone number."]);
  // never before Stripe can bill it, never for an unknown shop
  const none = joinShop(undefined, { account: null });
  assertEquals((await errorOf(await none.call(join)))[2], { reason: "stripe_not_connected" });
  assertEquals(none.rpcCalls.length, 0);
  const unknown = joinShop();
  assertEquals((await errorOf(await unknown.call({ ...join, slug: "nobody" })))[0], 404);
  // strict body: never a price
  assertEquals(
    (await errorOf(await unknown.call({ ...join, price_cents: 1 })))[1],
    "validation_failed",
  );
  // a membership that is already billing is not checked out again
  const active = joinShop(undefined, {
    membership: { status: "active", stripe_subscription_id: "sub_1Live" },
  });
  assertEquals((await errorOf(await active.call(join)))[2], {
    reason: "membership_not_incomplete",
  });
});

const CLIENT = "10000000-0000-4000-8000-0000000000c1";

function portal(access: Record<string, unknown> | null, options = {}) {
  const f = fixture(options);
  f.db.addUser("tok-client", { id: CLIENT, email: "ada@example.com" });
  f.db.onRpc("portal_membership_access", (args, { role }) => {
    f.rpcCalls.push({ name: "portal_membership_access", args });
    assertEquals(role, "service_role");
    return args.p_user_id === CLIENT && args.p_membership_id === MEMBERSHIP ? access : null;
  });
  return f;
}

const BILLED = {
  shop_id: SHOP,
  stripe_subscription_id: "sub_1Live",
  stripe_customer_id: "cus_1Saved",
  status: "active",
};

function asClient(f: ReturnType<typeof fixture>, body: Record<string, unknown>) {
  return f.handler(jsonRequest("payments", body, { token: "tok-client" }));
}

Deno.test("portal_membership_cancel: the client's own membership ends at the period end", async () => {
  const f = portal(BILLED);
  const res = await asClient(f, { action: "portal_membership_cancel", membership_id: MEMBERSHIP });
  assertEquals(await res.json(), {
    membership_id: MEMBERSHIP,
    status: "active",
    cancel_at_period_end: true,
    current_period_end: new Date(1_900_000_000 * 1000).toISOString(),
  });
  const update = f.stripe("POST", "/subscriptions/sub_1Live")[0];
  assertEquals(update?.headers.get("stripe-account"), ACCT);
  assertEquals(update?.form.get("cancel_at_period_end"), "true");
  assert(update?.headers.get("idempotency-key")?.startsWith("dcrm:portal_membership_cancel:"));
  // never an immediate cancel
  assertEquals(f.db.http.callsTo("DELETE", `${STRIPE}/subscriptions/:id`).length, 0);
  const sync = f.rpcCalls.find((c) => c.name === "sync_stripe_subscription");
  assertEquals([sync?.args.p_cancel_at_period_end, sync?.args.p_membership_id], [true, MEMBERSHIP]);
});

/** A resume in the Stripe Dashboard: the subscription bills on (never through the CRM). */
async function resumeInStripe(f: ReturnType<typeof fixture>, id: string) {
  const res = await f.db.http.fetch(`${STRIPE}/subscriptions/${id}`, {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
      "idempotency-key": `dashboard-resume-${crypto.randomUUID()}`,
    },
    body: "cancel_at_period_end=false",
  });
  await res.body?.cancel();
}

Deno.test("portal_membership_cancel: a cancel after a resume in Stripe is sent again, never a replay", async () => {
  const f = portal(BILLED);
  const cancelIt = async () =>
    await (await asClient(f, { action: "portal_membership_cancel", membership_id: MEMBERSHIP }))
      .json();
  assertEquals((await cancelIt()).cancel_at_period_end, true);
  await resumeInStripe(f, "sub_1Live");
  // Stripe replays the first response under the same key (cancelling) without
  // running it: the edge re-reads the subscription and sends the update again
  // under a new key, so Stripe really stops billing at the period end
  const again = await cancelIt();
  assertEquals(again.cancel_at_period_end, true);
  const updates = f.stripe("POST", "/subscriptions/sub_1Live")
    .filter((c) => c.headers.get("idempotency-key")?.startsWith("dcrm:"));
  assertEquals(updates.length, 3);
  assertEquals(new Set(updates.map((c) => c.headers.get("idempotency-key"))).size, 2);
  const current = await (await f.db.http.fetch(`${STRIPE}/subscriptions/sub_1Live`)).json();
  assertEquals(current.cancel_at_period_end, true);
  const syncs = f.rpcCalls.filter((c) => c.name === "sync_stripe_subscription");
  assertEquals(syncs.map((c) => c.args.p_cancel_at_period_end), [true, true]);
});

Deno.test("portal_membership_cancel: a subscription that never takes the cancel is a 409, not a false success", async () => {
  const f = portal(BILLED);
  // Stripe keeps answering "not cancelling" (e.g. a schedule re-applies it)
  f.db.http.on("GET", `${STRIPE}/subscriptions/:id`, (_req, { params }) =>
    jsonResponse({
      id: params.id,
      object: "subscription",
      status: "active",
      cancel_at_period_end: false,
      items: { object: "list", data: [{ id: "si_1", current_period_end: 1_900_000_000 }] },
    }));
  const res = await asClient(f, { action: "portal_membership_cancel", membership_id: MEMBERSHIP });
  assertEquals(await errorOf(res), [409, "conflict", { reason: "membership_changed" }]);
  assertEquals(f.stripe("POST", "/subscriptions/sub_1Live").length, 4);
  assertEquals(f.rpcCalls.filter((c) => c.name === "sync_stripe_subscription").length, 0);
});

Deno.test("membership_cancel (period end): a cancel after a resume in Stripe is sent again", async () => {
  const f = fixture({ membership: { status: "active", stripe_subscription_id: "sub_1Live" } });
  assertEquals(
    (await (await f.call({ ...cancel, at_period_end: true }, "owner")).json())
      .cancel_at_period_end,
    true,
  );
  await resumeInStripe(f, "sub_1Live");
  assertEquals(
    (await (await f.call({ ...cancel, at_period_end: true }, "owner")).json())
      .cancel_at_period_end,
    true,
  );
  const current = await (await f.db.http.fetch(`${STRIPE}/subscriptions/sub_1Live`)).json();
  assertEquals(current.cancel_at_period_end, true);
});

Deno.test("portal_membership_cancel: only for the linked client, only while billing", async () => {
  // someone else's membership (or staff, or an unknown id): 403, nothing in Stripe
  const f = portal(BILLED);
  assertEquals(
    (await errorOf(
      await f.call({ action: "portal_membership_cancel", membership_id: MEMBERSHIP }, "owner"),
    ))[0],
    403,
  );
  assertEquals(
    (await errorOf(
      await asClient(f, {
        action: "portal_membership_cancel",
        membership_id: "88888888-8888-4888-8888-000000000099",
      }),
    ))[0],
    403,
  );
  assertEquals(
    (await errorOf(
      await f.call({ action: "portal_membership_cancel", membership_id: MEMBERSHIP }),
    ))[0],
    401,
  );
  assertEquals(f.stripe("POST", "/subscriptions/sub_1Live").length, 0);
  // already cancelled / never billed
  const cancelled = portal({ ...BILLED, status: "cancelled" });
  assertEquals(
    (await errorOf(
      await asClient(cancelled, { action: "portal_membership_cancel", membership_id: MEMBERSHIP }),
    ))[2],
    { reason: "already_cancelled" },
  );
  const unbilled = portal({ ...BILLED, status: "incomplete", stripe_subscription_id: null });
  assertEquals(
    (await errorOf(
      await asClient(unbilled, { action: "portal_membership_cancel", membership_id: MEMBERSHIP }),
    ))[2],
    { reason: "membership_not_billed" },
  );
});

function billingPortalStubs(
  f: ReturnType<typeof fixture>,
  configs: Record<string, unknown>[] = [],
) {
  f.db.http.on(
    "GET",
    `${STRIPE}/billing_portal/configurations`,
    () => jsonResponse({ object: "list", has_more: false, data: configs }),
  );
  f.db.http.on(
    "POST",
    `${STRIPE}/billing_portal/configurations`,
    () => jsonResponse({ id: "bpc_1New", object: "billing_portal.configuration" }),
  );
  f.db.http.on("POST", `${STRIPE}/billing_portal/sessions`, () =>
    jsonResponse({
      id: "bps_1",
      object: "billing_portal.session",
      url: "https://billing.stripe.com/p/session/test_1",
    }));
  f.db.http.on("GET", `${STRIPE}/subscriptions/:id`, (_req, { params }) =>
    jsonResponse({
      id: params.id,
      object: "subscription",
      status: "active",
      customer: "cus_1Billed",
      items: { object: "list", data: [] },
    }));
}

Deno.test("portal_billing_portal: card updates and billing history, never cancelling there", async () => {
  const f = portal(BILLED);
  billingPortalStubs(f);
  const res = await asClient(f, { action: "portal_billing_portal", membership_id: MEMBERSHIP });
  assertEquals(await res.json(), { url: "https://billing.stripe.com/p/session/test_1" });
  const config = f.stripe("POST", "/billing_portal/configurations")[0];
  assertEquals(config?.headers.get("stripe-account"), ACCT);
  assertEquals(config?.form.get("features[payment_method_update][enabled]"), "true");
  assertEquals(config?.form.get("features[invoice_history][enabled]"), "true");
  assertEquals(config?.form.get("features[subscription_cancel][enabled]"), "false");
  assertEquals(config?.form.get("features[subscription_update][enabled]"), "false");
  assertEquals(config?.form.get("metadata[detail_crm_portal_v1]"), "1");
  const session = f.stripe("POST", "/billing_portal/sessions")[0];
  assertEquals(session?.headers.get("stripe-account"), ACCT);
  // the Stripe customer the subscription bills
  assertEquals(session?.form.get("customer"), "cus_1Billed");
  assertEquals(session?.form.get("configuration"), "bpc_1New");
  assertEquals(session?.form.get("return_url"), "https://app.example.com/portal");

  // the configuration is created once per account, then found by its tag
  const again = portal(BILLED);
  billingPortalStubs(again, [
    { id: "bpc_1Other", object: "billing_portal.configuration", metadata: {} },
    {
      id: "bpc_1Ours",
      object: "billing_portal.configuration",
      metadata: { detail_crm_portal_v1: "1" },
    },
  ]);
  await (await asClient(again, { action: "portal_billing_portal", membership_id: MEMBERSHIP })).body
    ?.cancel();
  assertEquals(again.stripe("POST", "/billing_portal/configurations").length, 0);
  assertEquals(
    again.stripe("POST", "/billing_portal/sessions")[0]?.form.get("configuration"),
    "bpc_1Ours",
  );

  // not the client's membership: 403 before any Stripe call
  const other = portal(null);
  billingPortalStubs(other);
  assertEquals(
    (await errorOf(
      await asClient(other, { action: "portal_billing_portal", membership_id: MEMBERSHIP }),
    ))[0],
    403,
  );
  assertEquals(other.stripeCalls().length, 0);
});
