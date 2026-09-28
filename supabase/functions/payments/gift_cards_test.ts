import { assert, assertEquals, assertMatch } from "@std/assert";
import { FakeRpcError } from "../_shared/testing/mod.ts";
import {
  ACCT,
  errorOf,
  type Fixture,
  fixture,
  type FixtureOptions,
  NOW,
  SHOP,
} from "./test_fixtures.ts";

const ORDER = "60000000-0000-4000-8000-000000000001";
const ORDER_TOKEN = "60000000-0000-4000-8000-0000000000aa";

const buy = {
  action: "gift_card_checkout",
  slug: "shine-co",
  offer_index: 1,
  purchaser: { name: "Grace Hopper", email: "grace@example.com" },
  recipient: { name: "Alan", email: "alan@example.com", message: "Happy birthday!" },
  request_nonce: "gift-0001",
};

/** A shop selling gift cards: gift_card_order_prepare answers with the offer's value / price. */
function shop(
  options: FixtureOptions & {
    prepare?: (args: Record<string, unknown>) => unknown;
  } = {},
): Fixture {
  const f = fixture({ ...options, shop: { slug: "shine-co", ...options.shop } });
  f.db.onRpc("gift_card_order_prepare", (args, { role }) => {
    f.rpcCalls.push({ name: "gift_card_order_prepare", args });
    assertEquals(role, "service_role");
    if (options.prepare) return options.prepare(args);
    f.db.seed("gift_card_orders", [...f.db.table("gift_card_orders"), {
      id: ORDER,
      shop_id: SHOP,
      token: ORDER_TOKEN,
      value_cents: 10_000,
      price_cents: 9_000,
      purchaser_email: "grace@example.com",
      status: "pending",
      created_at: new Date(NOW).toISOString(),
      stripe_checkout_session_id: null,
    }]);
    return {
      order_id: ORDER,
      token: ORDER_TOKEN,
      shop_id: SHOP,
      value_cents: 10_000,
      price_cents: 9_000,
      currency: "usd",
      purchaser_email: "grace@example.com",
    };
  });
  return f;
}

Deno.test("gift_card_checkout: anonymous buyer pays the offer's price for its value", async () => {
  const f = shop();
  const res = await f.call(buy);
  assertEquals(res.status, 200);
  assertEquals(await res.json(), {
    url: "https://checkout.stripe.com/c/pay/cs_test_1",
    expires_at: 1_900_000_000,
    price_cents: 9_000,
    value_cents: 10_000,
    currency: "usd",
  });
  // The order details go to the database, which prices them.
  const prepare = f.rpcCalls.find((c) => c.name === "gift_card_order_prepare");
  assertEquals(prepare?.args, {
    p_slug: "shine-co",
    p_payload: {
      offer_index: 1,
      purchaser: { name: "Grace Hopper", email: "grace@example.com" },
      recipient: { email: "alan@example.com", name: "Alan", message: "Happy birthday!" },
    },
  });

  const session = f.stripe("POST", "/checkout/sessions")[0];
  const form = session?.form;
  assertEquals(session?.headers.get("stripe-account"), ACCT);
  assertMatch(session?.headers.get("idempotency-key") ?? "", /^dcrm:gift_card_checkout:/);
  assertEquals(form?.get("mode"), "payment");
  assertEquals(form?.get("payment_method_types[0]"), "card");
  assertEquals(form?.get("payment_method_types[1]"), null);
  assertEquals(form?.get("customer"), null);
  assertEquals(form?.get("customer_email"), "grace@example.com");
  assertEquals(form?.get("client_reference_id"), ORDER);
  assertEquals(form?.get("line_items[0][price_data][unit_amount]"), "9000");
  assertEquals(form?.get("line_items[0][price_data][product_data][name]"), "Gift card $100.00");
  assertEquals(form?.get("line_items[1][price_data][unit_amount]"), null);
  // 2.5% platform fee on the price paid
  assertEquals(form?.get("payment_intent_data[application_fee_amount]"), "225");
  assertEquals(form?.get("payment_intent_data[setup_future_usage]"), null);
  for (const prefix of ["payment_intent_data[metadata]", "metadata"]) {
    assertEquals(form?.get(`${prefix}[shop_id]`), SHOP);
    assertEquals(form?.get(`${prefix}[gift_card_order_id]`), ORDER);
    assertEquals(form?.get(`${prefix}[kind]`), "gift_card");
    assertEquals(form?.get(`${prefix}[invoice_id]`), null);
    assertEquals(form?.get(`${prefix}[customer_id]`), null);
  }
  assertEquals(
    form?.get("success_url"),
    `https://app.example.com/gift/shine-co/done?order=${ORDER_TOKEN}`,
  );
  assertEquals(form?.get("cancel_url"), "https://app.example.com/gift/shine-co?canceled=1");
  const expires = Number(form?.get("expires_at"));
  assert(expires > 0);
  // The order remembers the session paying it.
  assertEquals(f.db.table("gift_card_orders")[0]?.stripe_checkout_session_id, "cs_test_1");
  // Never a Stripe customer, never a payment row.
  assertEquals(f.stripe("POST", "/customers").length, 0);
  assertEquals(f.rpcCalls.filter((c) => c.name === "upsert_stripe_payment").length, 0);
  assert(f.db.requests.every((r) => r.role === "service_role"));
});

Deno.test("gift_card_checkout: a custom amount is only a request the database validates", async () => {
  const f = shop();
  const { offer_index: _offer, ...custom } = buy;
  assertEquals((await f.call({ ...custom, amount_cents: 7_500 })).status, 200);
  const payload = f.rpcCalls.find((c) => c.name === "gift_card_order_prepare")?.args.p_payload as
    | Record<string, unknown>
    | undefined;
  assertEquals(payload?.amount_cents, 7_500);
  assertEquals(payload?.offer_index, undefined);
  // exactly one of the two, and never a price
  for (
    const body of [
      { ...buy, amount_cents: 7_500 },
      custom,
      { ...buy, price_cents: 1 },
      { ...buy, value_cents: 1 },
      { ...buy, purchaser: { ...buy.purchaser, email: "not-an-email" } },
      { ...buy, slug: "../etc" },
    ]
  ) {
    assertEquals((await errorOf(await f.call(body)))[1], "validation_failed");
  }
});

Deno.test("gift_card_checkout: shop rules map to stable errors", async () => {
  // unknown shop: 404 before anything is written
  const missing = shop({ shop: { slug: "someone-else" } });
  assertEquals((await errorOf(await missing.call(buy)))[0], 404);
  assertEquals(missing.rpcCalls.length, 0);
  // Stripe not connected / charges disabled: 422 before an order is created
  const none = shop({ account: null });
  assertEquals((await errorOf(await none.call(buy)))[2], { reason: "stripe_not_connected" });
  assertEquals(none.rpcCalls.length, 0);
  const off = shop({ account: { charges_enabled: false } });
  assertEquals((await errorOf(await off.call(buy)))[2], { reason: "charges_disabled" });
  // online sales off (55000)
  const disabled = shop({
    prepare: () => {
      throw new FakeRpcError("55000", "online gift card sales are not enabled for this shop");
    },
  });
  assertEquals(await errorOf(await disabled.call(buy)), [409, "conflict", { reason: "disabled" }]);
  // abuse limit (PT429)
  const limited = shop({
    prepare: () => {
      throw new FakeRpcError("PT429", "too many gift card orders for this email today");
    },
  });
  const res = await limited.call(buy);
  assertEquals(res.status, 429);
  assertEquals(res.headers.get("retry-after"), "3600");
  assertEquals((await errorOf(res))[1], "rate_limited");
  // validation from the database (customer-facing wording)
  const range = shop({
    prepare: () => {
      throw new FakeRpcError("22023", "amount out of range: choose between $10.00 and $500.00");
    },
  });
  const rangeRes = await range.call(buy);
  const body = await rangeRes.json();
  assertEquals([rangeRes.status, body.code, body.details], [422, "unprocessable", {
    reason: "amount_out_of_range",
  }]);
  assertEquals(body.error, "Amount out of range: choose between $10.00 and $500.00.");
  const offer = shop({
    prepare: () => {
      throw new FakeRpcError("22023", "that offer is no longer available");
    },
  });
  assertEquals((await errorOf(await offer.call(buy)))[2], { reason: "invalid_order" });
  // nothing reached Stripe in any of these
  for (const f of [disabled, limited, range, offer]) {
    assertEquals(f.stripe("POST", "/checkout/sessions").length, 0);
  }
});

Deno.test("gift_card_checkout: an order of another shop is never paid here", async () => {
  const f = shop({
    prepare: () => ({
      order_id: ORDER,
      token: ORDER_TOKEN,
      shop_id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
      value_cents: 10_000,
      price_cents: 10_000,
      currency: "usd",
    }),
  });
  assertEquals((await errorOf(await f.call(buy)))[0], 500);
  assertEquals(f.stripe("POST", "/checkout/sessions").length, 0);
});

// ---------------------------------------------------------------------------
// request_nonce: a retried submission gets its order's session back
// ---------------------------------------------------------------------------

const prepares = (f: Fixture) =>
  f.rpcCalls.filter((c) => c.name === "gift_card_order_prepare").length;

Deno.test("gift_card_checkout: a retry with the same nonce hands back the open session, no second order", async () => {
  const f = shop();
  const first = await (await f.call(buy)).json();
  const again = await f.call(buy);
  assertEquals(again.status, 200);
  assertEquals(await again.json(), first);
  // one order, one payable session, one use of the purchaser's order allowance
  assertEquals(prepares(f), 1);
  assertEquals(f.stripe("POST", "/checkout/sessions").length, 1);
  // the session (not the payment) carries the request's hash, never the nonce itself
  const form = f.stripe("POST", "/checkout/sessions")[0]?.form;
  assertMatch(form?.get("metadata[request_key]") ?? "", /^dcrm:gift_card_request:[0-9a-f]{64}$/);
  assertEquals(form?.get("payment_intent_data[metadata][request_key]"), null);
  assert(![...(form?.values() ?? [])].includes("gift-0001"));
});

Deno.test("gift_card_checkout: a new nonce, changed details or no nonce is a new order", async () => {
  // another submission (new nonce)
  const renewed = shop();
  await (await renewed.call(buy)).body?.cancel();
  await (await renewed.call({ ...buy, request_nonce: "gift-0002" })).body?.cancel();
  assertEquals(prepares(renewed), 2);
  // the same nonce with other details is not the same request
  const edited = shop();
  await (await edited.call(buy)).body?.cancel();
  await (await edited.call({ ...buy, recipient: { ...buy.recipient, name: "Ada" } })).body
    ?.cancel();
  assertEquals(prepares(edited), 2);
  // without a nonce there is nothing to recognise a retry by
  const { request_nonce: _nonce, ...plain } = buy;
  const bare = shop();
  await (await bare.call(plain)).body?.cancel();
  await (await bare.call(plain)).body?.cancel();
  assertEquals(prepares(bare), 2);
  assertEquals(
    bare.stripe("POST", "/checkout/sessions")[0]?.form.get("metadata[request_key]"),
    null,
  );
});

Deno.test("gift_card_checkout: a retry after the order was paid is 409; after it expired, a new order", async () => {
  const paid = shop();
  await (await paid.call(buy)).body?.cancel();
  const session = paid.created["cs_test_1"];
  assert(session);
  session.status = "complete";
  assertEquals((await errorOf(await paid.call(buy)))[2], { reason: "payment_in_progress" });
  assertEquals(prepares(paid), 1);

  const expired = shop();
  await (await expired.call(buy)).body?.cancel();
  const old = expired.created["cs_test_1"];
  assert(old);
  expired.sessions.push({ ...old, id: "cs_test_old", status: "expired" });
  delete expired.created["cs_test_1"];
  expired.db.seed(
    "gift_card_orders",
    expired.db.table("gift_card_orders").map((o) => ({
      ...o,
      stripe_checkout_session_id: "cs_test_old",
    })),
  );
  const res = await expired.call(buy);
  assertEquals(res.status, 200);
  await res.body?.cancel();
  assertEquals(prepares(expired), 2);
  assertEquals(expired.stripe("POST", "/checkout/sessions").length, 2);
});
