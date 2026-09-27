import { assert, assertEquals, assertMatch } from "@std/assert";
import type { Stripe } from "../_shared/stripe.ts";
import { jsonResponse } from "../_shared/testing/mod.ts";
import { membershipStatusOf, periodEndOf } from "./memberships.ts";
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
