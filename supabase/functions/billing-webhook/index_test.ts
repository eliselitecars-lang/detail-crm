/**
 * billing-webhook end to end: signed platform deliveries -> real handler ->
 * real supabase-js + Stripe SDK against FakeSupabase (billing RPCs faked
 * with the 0101 contract, ../billing/test_fixtures.ts) and a fake platform
 * Stripe account. Signature, platform-vs-Connect filtering, idempotent
 * replay, retry after a failure, out-of-order events (delegated to
 * billing_apply_subscription), the payment-failed notification and plan
 * resyncs on catalog events.
 */
import { assert, assertEquals } from "@std/assert";
import type { ErrorBody } from "../_shared/http.ts";
import {
  emptyRequest,
  FakeRpcError,
  FakeSupabase,
  FUNCTIONS_BASE,
  memoryLogger,
  type Row,
  signStripePayload,
  stripeEvent,
  TEST_ENV,
} from "../_shared/testing/mod.ts";
import {
  type BillingRow,
  billingRow,
  type BillingState,
  FakePlatformStripe,
  installBillingRpcs,
  NOW,
  OTHER_SHOP,
  PLAN_MONTHLY,
  PLAN_YEARLY,
  planRow,
  recurringPrice,
  SHOP,
} from "../billing/test_fixtures.ts";
import { applySubscriptionArgs, HANDLED_EVENT_TYPES, survivingSubscription } from "./handlers.ts";
import { makeHandler, type WebhookResponse } from "./index.ts";

const SECRET = "whsec_FakeBillingSecret0000000000";
const CONNECT_SECRET = TEST_ENV.STRIPE_WEBHOOK_SECRET as string;
const T1 = 1_790_000_000;
const T2 = T1 + 60;
const PERIOD_END = 1_792_600_000;
const iso = (s: number) => new Date(s * 1000).toISOString();

function subscription(overrides: Row = {}): Row {
  return {
    id: "sub_1Shop",
    object: "subscription",
    status: "active",
    customer: "cus_1Shop",
    cancel_at_period_end: false,
    cancel_at: null,
    trial_end: null,
    metadata: { shop_id: SHOP },
    items: {
      object: "list",
      data: [{
        id: "si_1",
        object: "subscription_item",
        price: { id: "price_1Monthly", object: "price" },
        current_period_end: PERIOD_END,
      }],
    },
    ...overrides,
  };
}

function subscriptionInvoice(overrides: Row = {}): Row {
  return {
    id: "in_1Renewal",
    object: "invoice",
    customer: "cus_1Shop",
    status: "paid",
    parent: {
      type: "subscription_details",
      quote_details: null,
      subscription_details: { subscription: "sub_1Shop", metadata: { shop_id: SHOP } },
    },
    ...overrides,
  };
}

function checkoutSession(overrides: Row = {}): Row {
  return {
    id: "cs_test_1Billing",
    object: "checkout.session",
    mode: "subscription",
    status: "complete",
    customer: "cus_1Shop",
    subscription: "sub_1Shop",
    client_reference_id: SHOP,
    metadata: { shop_id: SHOP },
    ...overrides,
  };
}

interface Setup {
  db: FakeSupabase;
  stripe: FakePlatformStripe;
  state: BillingState;
  logs: ReturnType<typeof memoryLogger>;
  handler: (req: Request) => Promise<Response>;
  row(shop?: string): BillingRow;
}

function setup(
  options: { billing?: Partial<BillingRow>; env?: Record<string, string | undefined> } = {},
): Setup {
  const db = new FakeSupabase({
    tables: {
      shop_members: [],
      platform_config: [{ key: "billing_enabled", value: "true" }],
      platform_plans: [
        planRow(),
        planRow({ id: PLAN_YEARLY, stripe_price_id: "price_1Yearly", interval: "year" }),
      ],
      stripe_events: [],
    },
    tableOptions: {
      stripe_events: {
        primaryKey: ["id"],
        defaults: () => ({ attempts: 1, processed_at: null, error: null, account: null }),
      },
    },
  });
  const state: BillingState = {
    billing: new Map([
      [SHOP, billingRow(SHOP, { stripe_customer_id: "cus_1Shop", ...options.billing })],
      [OTHER_SHOP, billingRow(OTHER_SHOP, { stripe_customer_id: "cus_1Other" })],
    ]),
    notifications: [],
    ownerEmails: {},
    shopNames: { [SHOP]: "Shine Co", [OTHER_SHOP]: "Other Shop" },
  };
  installBillingRpcs(db, state, () => NOW);
  const stripe = new FakePlatformStripe();
  stripe.install(db);
  const logs = memoryLogger();
  const handler = makeHandler({
    env: db.env({ STRIPE_BILLING_WEBHOOK_SECRET: SECRET, ...options.env }),
    fetch: db.http.fetch,
    logger: logs.logger,
    now: () => new Date(NOW),
    maxNetworkRetries: 0,
  });
  return {
    db,
    stripe,
    state,
    logs,
    handler,
    row: (shop = SHOP) => {
      const row = state.billing.get(shop);
      assert(row);
      return row;
    },
  };
}

let counter = 0;
function event(
  type: string,
  object: Row,
  options: { id?: string; created?: number; account?: string } = {},
): Record<string, unknown> {
  counter++;
  return stripeEvent({
    id: options.id ?? `evt_1Billing${counter}`,
    type,
    object,
    created: options.created ?? T1,
    ...(options.account ? { account: options.account } : {}),
  });
}

async function deliver(
  handler: (req: Request) => Promise<Response>,
  body: Record<string, unknown> | string,
  options: { secret?: string; signature?: string | null } = {},
): Promise<Response> {
  const payload = typeof body === "string" ? body : JSON.stringify(body);
  const headers = new Headers({ "content-type": "application/json" });
  const signature = options.signature === undefined
    ? await signStripePayload(payload, options.secret ?? SECRET)
    : options.signature;
  if (signature !== null) headers.set("stripe-signature", signature);
  return await handler(
    new Request(`${FUNCTIONS_BASE}/billing-webhook`, { method: "POST", headers, body: payload }),
  );
}

async function ok(res: Response): Promise<WebhookResponse> {
  const body = await res.json();
  assertEquals(res.status, 200, JSON.stringify(body));
  return body as WebhookResponse;
}

function rpcCalls(db: FakeSupabase, fn: string): Record<string, unknown>[] {
  return db.http.calls
    .filter((c) => c.method === "POST" && c.url.pathname === `/rest/v1/rpc/${fn}`)
    .map((c) => c.json as Record<string, unknown>);
}

function stripeCalls(db: FakeSupabase) {
  return db.http.calls.filter((c) => c.url.hostname === "api.stripe.com");
}

function ledger(db: FakeSupabase, id: string): Row | undefined {
  return db.table("stripe_events").find((e) => e.id === id);
}

// ---------------------------------------------------------------------------
// Signature, filtering, surface
// ---------------------------------------------------------------------------

Deno.test("billing-webhook: HANDLED_EVENT_TYPES is exactly the platform billing events", () => {
  assertEquals([...HANDLED_EVENT_TYPES].sort(), [
    "checkout.session.completed",
    "customer.subscription.created",
    "customer.subscription.deleted",
    "customer.subscription.updated",
    "invoice.paid",
    "invoice.payment_failed",
    "price.created",
    "price.deleted",
    "price.updated",
    "product.created",
    "product.deleted",
    "product.updated",
  ]);
});

Deno.test("billing-webhook: a missing, wrong, tampered or stale signature is 400 and nothing is recorded", async () => {
  const { db, stripe, handler } = setup();
  stripe.putSubscription(subscription());
  const body = event("customer.subscription.updated", subscription());

  for (
    const res of [
      await deliver(handler, body, { signature: null }),
      await deliver(handler, body, { secret: "whsec_SomeoneElse0000000000" }),
      // the Connect endpoint's secret does not sign platform billing events
      await deliver(handler, body, { secret: CONNECT_SECRET }),
    ]
  ) {
    assertEquals(res.status, 400);
    assertEquals((await res.json() as ErrorBody).code, "invalid_signature");
  }
  const payload = JSON.stringify(body);
  const signature = await signStripePayload(payload, SECRET);
  const tampered = await deliver(handler, payload.replace("cus_1Shop", "cus_1Other"), {
    signature,
  });
  assertEquals(tampered.status, 400);
  await tampered.body?.cancel();
  const stale = await signStripePayload(payload, SECRET, Math.floor(Date.now() / 1000) - 3600);
  const late = await deliver(handler, body, { signature: stale });
  assertEquals(late.status, 400);
  await late.body?.cancel();

  assertEquals(db.table("stripe_events"), []);
  assertEquals(db.requests.length, 0);
  assertEquals(stripeCalls(db).length, 0);
});

Deno.test("billing-webhook: without STRIPE_BILLING_WEBHOOK_SECRET, unsigned is still 400; signed is server_misconfigured", async () => {
  const { handler, db } = setup({ env: { STRIPE_BILLING_WEBHOOK_SECRET: undefined } });
  const body = event("invoice.paid", subscriptionInvoice());
  const unsigned = await deliver(handler, body, { signature: null });
  assertEquals([unsigned.status, (await unsigned.json() as ErrorBody).code], [
    400,
    "invalid_signature",
  ]);
  const signed = await deliver(handler, body);
  assertEquals([signed.status, (await signed.json() as ErrorBody).code], [
    500,
    "server_misconfigured",
  ]);
  assertEquals(db.table("stripe_events"), []);
});

Deno.test("billing-webhook: Connect events are acknowledged and never processed or recorded", async () => {
  const { db, stripe, handler } = setup();
  stripe.putSubscription(subscription());
  for (
    const type of ["customer.subscription.updated", "invoice.payment_failed", "product.updated"]
  ) {
    const res = await ok(
      await deliver(handler, event(type, subscription(), { account: "acct_1ShopAccount0" })),
    );
    assertEquals(res, { received: true, handled: false, duplicate: false, result: null });
  }
  // the ledger stripe-webhook shares is untouched, and nothing was called
  assertEquals(db.table("stripe_events"), []);
  assertEquals(db.requests.length, 0);
  assertEquals(stripeCalls(db).length, 0);
});

Deno.test("billing-webhook: unknown event types are acknowledged without side effects; only POST", async () => {
  const { db, handler } = setup();
  const res = await ok(
    await deliver(handler, event("customer.created", { id: "cus_1New", object: "customer" })),
  );
  assertEquals(res, { received: true, handled: false, duplicate: false, result: null });
  assertEquals(db.requests.length, 0);
  const get = await handler(emptyRequest("billing-webhook"));
  assertEquals(get.status, 405);
  await get.body?.cancel();
});

// ---------------------------------------------------------------------------
// Subscriptions
// ---------------------------------------------------------------------------

Deno.test("customer.subscription.created: the current subscription is applied to the linked shop", async () => {
  const { db, stripe, handler, row } = setup();
  const trialing = subscription({ status: "trialing", trial_end: PERIOD_END });
  stripe.putSubscription(trialing);
  const body = event("customer.subscription.created", subscription({ status: "incomplete" }), {
    id: "evt_1Created",
  });
  assertEquals(await ok(await deliver(handler, body)), {
    received: true,
    handled: true,
    duplicate: false,
    result: "applied",
  });
  // re-read from Stripe (trialing), not the event's snapshot (incomplete)
  assertEquals(rpcCalls(db, "billing_apply_subscription"), [{
    p_stripe_customer_id: "cus_1Shop",
    p_subscription_id: "sub_1Shop",
    p_price_id: "price_1Monthly",
    p_status: "trialing",
    p_trial_end: iso(PERIOD_END),
    p_current_period_end: iso(PERIOD_END),
    p_cancel_at_period_end: false,
    p_event_created: iso(T1),
  }]);
  assertEquals(
    [row().status, row().plan_id, row().trial_used, row().stripe_subscription_id],
    ["trialing", PLAN_MONTHLY, true, "sub_1Shop"],
  );
  assertEquals(ledger(db, "evt_1Created")?.processed_at, new Date(NOW).toISOString());
  for (const call of stripeCalls(db)) assertEquals(call.headers.get("stripe-account"), null);
});

Deno.test("billing-webhook: a replay of a processed event is a duplicate and runs nothing", async () => {
  const { db, stripe, handler } = setup();
  stripe.putSubscription(subscription());
  const body = event("customer.subscription.updated", subscription(), { id: "evt_1Replay" });
  await ok(await deliver(handler, body));
  const before = rpcCalls(db, "billing_apply_subscription").length;
  const stripeBefore = stripeCalls(db).length;
  assertEquals(await ok(await deliver(handler, body)), {
    received: true,
    handled: true,
    duplicate: true,
    result: null,
  });
  assertEquals(rpcCalls(db, "billing_apply_subscription").length, before);
  assertEquals(stripeCalls(db).length, stripeBefore);
});

Deno.test("billing-webhook: a failed attempt answers 500 and the redelivery processes it", async () => {
  const { db, stripe, handler, state, row } = setup();
  stripe.putSubscription(subscription());
  let failures = 1;
  db.onRpc("billing_apply_subscription", () => {
    if (failures-- > 0) throw new FakeRpcError("08006", "connection lost", { status: 503 });
    const r = state.billing.get(SHOP);
    assert(r);
    r.status = "active";
    return { shop_id: SHOP, applied: true };
  });
  const body = event("customer.subscription.updated", subscription(), { id: "evt_1Retry" });
  const first = await deliver(handler, body);
  assertEquals([first.status, (await first.json() as ErrorBody).code], [500, "internal_error"]);
  assertEquals(ledger(db, "evt_1Retry")?.processed_at, null);
  assert(String(ledger(db, "evt_1Retry")?.error).includes("billing_apply_subscription"));
  assertEquals((await ok(await deliver(handler, body))).result, "applied");
  assertEquals(ledger(db, "evt_1Retry")?.attempts, 2);
  assertEquals(row().status, "active");
});

Deno.test("billing-webhook: out-of-order events are resolved by the RPC (an older event never wins)", async () => {
  const { db, stripe, handler, row } = setup();
  // newer event first: the subscription was canceled at T2
  stripe.putSubscription(subscription({ status: "canceled" }));
  await ok(
    await deliver(
      handler,
      event("customer.subscription.updated", subscription({ status: "canceled" }), {
        created: T2,
      }),
    ),
  );
  assertEquals(row().status, "canceled");
  // the older one (T1) arrives late; even if Stripe now says active, the RPC
  // ignores an event older than what it applied
  stripe.putSubscription(subscription({ status: "active" }));
  const late = await ok(
    await deliver(handler, event("customer.subscription.updated", subscription(), { created: T1 })),
  );
  assertEquals(late.result, "ignored");
  assertEquals(rpcCalls(db, "billing_apply_subscription").map((a) => a.p_event_created), [
    iso(T2),
    iso(T1),
  ]);
  assertEquals([row().status, row().last_event_at], ["canceled", iso(T2)]);
});

Deno.test("customer.subscription.deleted: recorded canceled, keeping the paid-through period end", async () => {
  const { db, stripe, handler, row } = setup({
    billing: { stripe_subscription_id: "sub_1Shop", status: "active" },
  });
  const ended = subscription({ status: "canceled", cancel_at_period_end: true, cancel_at: T2 });
  stripe.putSubscription(ended);
  await ok(await deliver(handler, event("customer.subscription.deleted", ended)));
  const args = rpcCalls(db, "billing_apply_subscription")[0];
  assertEquals(
    [args?.p_status, args?.p_cancel_at_period_end, args?.p_current_period_end],
    ["canceled", false, iso(PERIOD_END)],
  );
  assertEquals([row().status, row().current_period_end], ["canceled", iso(PERIOD_END)]);
});

Deno.test("customer.subscription.*: a subscription Stripe no longer has falls back to the event's object", async () => {
  const { db, handler, row } = setup();
  await ok(
    await deliver(
      handler,
      event("customer.subscription.updated", subscription({ status: "past_due" })),
    ),
  );
  assertEquals(rpcCalls(db, "billing_apply_subscription")[0]?.p_status, "past_due");
  assertEquals(row().status, "past_due");
});

Deno.test("customer.subscription.*: an unknown customer (not a Detail CRM shop) is ignored", async () => {
  const { db, stripe, handler, state, logs } = setup();
  stripe.putSubscription(subscription({ id: "sub_1Foreign", customer: "cus_1Stranger" }));
  const res = await ok(
    await deliver(
      handler,
      event(
        "customer.subscription.updated",
        subscription({ id: "sub_1Foreign", customer: "cus_1Stranger" }),
      ),
    ),
  );
  assertEquals(res.result, "ignored");
  // 0101 answers {shop_id: null, applied: false} (never P0002)
  assertEquals(logs.events("billing_event_ignored").at(-1)?.reason, "unknown_customer");
  assertEquals([...state.billing.values()].map((r) => r.status), ["none", "none"]);
  assertEquals(rpcCalls(db, "billing_apply_subscription").length, 1);
});

Deno.test("customer.subscription.*: a subscription another shop holds (23505) is acknowledged, not retried", async () => {
  const { db, stripe, handler, logs, row, state } = setup();
  const other = state.billing.get(OTHER_SHOP);
  assert(other);
  other.stripe_subscription_id = "sub_1Shop";
  other.status = "active";
  stripe.putSubscription(subscription({ status: "past_due" }));
  const res = await ok(
    await deliver(
      handler,
      event("customer.subscription.updated", subscription({ status: "past_due" })),
    ),
  );
  assertEquals(res.result, "ignored");
  const ignored = logs.events("billing_event_ignored").at(-1);
  assertEquals([ignored?.reason, ignored?.code], ["subscription_conflict", "23505"]);
  // logged as a warning (possible abuse or a bug)
  assertEquals(ignored?.level, "warn");
  assertEquals([row().status, row().stripe_subscription_id], ["none", null]);
  assertEquals(rpcCalls(db, "billing_apply_subscription").length, 1);
});

Deno.test("applySubscriptionArgs: scheduled cancellation, unknown statuses and malformed ids", () => {
  const sub = (o: Row) => subscription(o) as never;
  assertEquals(
    applySubscriptionArgs(sub({ cancel_at_period_end: true }), T1)?.p_cancel_at_period_end,
    true,
  );
  assertEquals(applySubscriptionArgs(sub({ cancel_at: T2 }), T1)?.p_cancel_at_period_end, true);
  assertEquals(applySubscriptionArgs(sub({ status: "someday" }), T1), null);
  assertEquals(applySubscriptionArgs(sub({ customer: "nope" }), T1), null);
  assertEquals(
    applySubscriptionArgs(sub({ customer: { id: "cus_1Obj", object: "customer" } }), T1)
      ?.p_stripe_customer_id,
    "cus_1Obj",
  );
  assertEquals(applySubscriptionArgs(sub({ items: { data: [] } }), T1)?.p_price_id, null);
  assertEquals(applySubscriptionArgs(sub({}), T1, { deleted: true })?.p_status, "canceled");
});

// ---------------------------------------------------------------------------
// Checkout
// ---------------------------------------------------------------------------

Deno.test("checkout.session.completed: links the customer to the shop, then applies the subscription", async () => {
  const { db, stripe, handler, row } = setup({ billing: { stripe_customer_id: null } });
  stripe.putSubscription(subscription());
  const res = await ok(
    await deliver(handler, event("checkout.session.completed", checkoutSession())),
  );
  assertEquals(res.result, "applied");
  assertEquals(rpcCalls(db, "billing_link_customer"), [
    { p_shop_id: SHOP, p_stripe_customer_id: "cus_1Shop" },
  ]);
  assertEquals([row().stripe_customer_id, row().status], ["cus_1Shop", "active"]);
});

Deno.test("checkout.session.completed: sessions that are not this platform's shop checkouts are ignored", async () => {
  const cases: Array<[Row, string]> = [
    [{ mode: "payment" }, "not a subscription"],
    // a Payment Link can carry any client_reference_id, never our metadata
    [{ metadata: {} }, "no metadata"],
    [{ client_reference_id: null }, "no shop"],
    [{ metadata: { shop_id: OTHER_SHOP } }, "shop mismatch"],
    [{ customer: null }, "no customer"],
  ];
  for (const [overrides, what] of cases) {
    const { db, handler, row } = setup({ billing: { stripe_customer_id: null } });
    const res = await ok(
      await deliver(handler, event("checkout.session.completed", checkoutSession(overrides))),
    );
    assertEquals(res.result, "ignored", what);
    assertEquals(rpcCalls(db, "billing_link_customer").length, 0, what);
    assertEquals(row().stripe_customer_id, null, what);
  }
});

Deno.test("checkout.session.completed: a customer another shop owns is acknowledged, not retried", async () => {
  const { db, handler, row } = setup({ billing: { stripe_customer_id: null } });
  const res = await ok(
    await deliver(
      handler,
      event("checkout.session.completed", checkoutSession({ customer: "cus_1Other" })),
    ),
  );
  assertEquals(res.result, "ignored");
  assertEquals(row().stripe_customer_id, null);
  assertEquals(rpcCalls(db, "billing_apply_subscription").length, 0);
});

// ---------------------------------------------------------------------------
// Invoices
// ---------------------------------------------------------------------------

Deno.test("invoice.paid: refreshes the subscription from Stripe", async () => {
  const { db, stripe, handler, row } = setup({
    billing: { stripe_subscription_id: "sub_1Shop", status: "past_due" },
  });
  stripe.putSubscription(subscription({ status: "active" }));
  assertEquals(
    (await ok(await deliver(handler, event("invoice.paid", subscriptionInvoice())))).result,
    "applied",
  );
  assertEquals(row().status, "active");
  assert(stripeCalls(db).some((c) => c.url.pathname === "/v1/subscriptions/sub_1Shop"));

  const oneOff = setup();
  const res = await ok(
    await deliver(oneOff.handler, event("invoice.paid", subscriptionInvoice({ parent: null }))),
  );
  assertEquals(res.result, "ignored");
  assertEquals(rpcCalls(oneOff.db, "billing_apply_subscription").length, 0);
});

Deno.test("invoice.payment_failed: refreshes the subscription and notifies the owner once", async () => {
  const { db, stripe, handler, state, row } = setup({
    billing: { stripe_subscription_id: "sub_1Shop", status: "active" },
  });
  stripe.putSubscription(subscription({ status: "past_due" }));
  const body = event("invoice.payment_failed", subscriptionInvoice({ status: "open" }), {
    id: "evt_1Failed",
    created: T2,
  });
  assertEquals((await ok(await deliver(handler, body))).result, "applied");
  assertEquals(row().status, "past_due");
  assertEquals(rpcCalls(db, "billing_payment_failed"), [
    { p_stripe_customer_id: "cus_1Shop", p_event_created: iso(T2) },
  ]);
  assertEquals(state.notifications, [
    { shop_id: SHOP, kind: "billing_payment_failed", at: iso(T2) },
  ]);
  // a replay does not notify again
  assertEquals((await ok(await deliver(handler, body))).duplicate, true);
  assertEquals(state.notifications.length, 1);
});

Deno.test("invoice.payment_failed: an unknown customer is ignored and nobody is notified", async () => {
  const { db, stripe, handler, state } = setup();
  stripe.putSubscription(subscription({ id: "sub_1Foreign", customer: "cus_1Stranger" }));
  const invoice = subscriptionInvoice({
    customer: "cus_1Stranger",
    parent: {
      type: "subscription_details",
      subscription_details: { subscription: "sub_1Foreign", metadata: {} },
    },
  });
  assertEquals(
    (await ok(await deliver(handler, event("invoice.payment_failed", invoice)))).result,
    "ignored",
  );
  assertEquals(rpcCalls(db, "billing_payment_failed").length, 0);
  assertEquals(state.notifications, []);
});

// ---------------------------------------------------------------------------
// Catalog
// ---------------------------------------------------------------------------

Deno.test("product.* / price.* events re-run the plan sync", async () => {
  for (
    const type of [
      "product.created",
      "product.updated",
      "product.deleted",
      "price.created",
      "price.updated",
      "price.deleted",
    ]
  ) {
    const { db, stripe, handler } = setup();
    stripe.products = [{
      id: "prod_1Studio",
      name: "Studio",
      metadata: { detailcrm_plan: "true", max_members: "3" },
    }];
    stripe.prices = [recurringPrice("price_1Monthly", "prod_1Studio", 5_900, "month")];
    const res = await ok(
      await deliver(handler, event(type, { id: "prod_1Studio", object: type.split(".")[0] })),
    );
    assertEquals(res.result, "applied", type);
    const plans = Object.fromEntries(
      db.table("platform_plans").map((p) => [p.stripe_price_id as string, p]),
    );
    assertEquals(
      [plans.price_1Monthly?.amount_cents, plans.price_1Monthly?.max_members],
      [5_900, 3],
      type,
    );
    // the yearly price is no longer listed in Stripe: deactivated
    assertEquals(plans.price_1Yearly?.active, false, type);
    assertEquals(rpcCalls(db, "billing_deactivate_plans_except").length, 1, type);
  }
});

// ---------------------------------------------------------------------------
// Duplicate subscriptions (one live subscription per shop)
// ---------------------------------------------------------------------------

const FIRST = "sub_1First";
const SECOND = "sub_2Second";

/** The shop's paid subscription (older) and a second one paid later. */
function twoSubscriptions(
  stripe: FakePlatformStripe,
  second: Row = {},
): void {
  stripe.putSubscription(subscription({ id: FIRST, created: T1 - 600 }));
  stripe.putSubscription(subscription({ id: SECOND, created: T1 - 60, ...second }));
  stripe.invoices = [
    { id: "in_1First", object: "invoice", subscription: FIRST, status: "paid", amount_paid: 4_900 },
    {
      id: "in_2Second",
      object: "invoice",
      subscription: SECOND,
      status: "paid",
      amount_paid: 4_900,
    },
  ];
  stripe.invoicePayments = [
    {
      id: "inpay_1",
      object: "invoice_payment",
      invoice: "in_1First",
      status: "paid",
      amount_paid: 4_900,
      payment: { type: "payment_intent", payment_intent: "pi_1First" },
    },
    {
      id: "inpay_2",
      object: "invoice_payment",
      invoice: "in_2Second",
      status: "paid",
      amount_paid: 4_900,
      payment: { type: "payment_intent", payment_intent: "pi_2Second" },
    },
  ];
}

function status(stripe: FakePlatformStripe, id: string): unknown {
  return stripe.subscriptions.get(id)?.status;
}

Deno.test("survivingSubscription: the oldest live subscription; ended and incomplete never survive", () => {
  const sub = (id: string, status: string, created: number) => ({ id, status, created });
  assertEquals(
    survivingSubscription([sub("sub_b", "active", 20), sub("sub_a", "trialing", 10)]),
    "sub_a",
  );
  assertEquals(
    survivingSubscription([sub("sub_a", "canceled", 1), sub("sub_b", "past_due", 5)]),
    "sub_b",
  );
  assertEquals(
    survivingSubscription([sub("sub_b", "active", 5), sub("sub_a", "active", 5)]),
    "sub_a",
  );
  assertEquals(survivingSubscription([sub("sub_a", "incomplete", 1)]), null);
  assertEquals(survivingSubscription([]), null);
});

Deno.test("duplicate subscription: a second one paid later is refunded and cancelled; the shop keeps the first", async () => {
  const { db, stripe, handler, row, logs } = setup({
    billing: { stripe_subscription_id: FIRST, status: "active", last_event_at: iso(T1 - 600) },
  });
  twoSubscriptions(stripe);
  const res = await ok(
    await deliver(
      handler,
      event("customer.subscription.created", subscription({ id: SECOND }), { created: T1 }),
    ),
  );
  assertEquals(res.result, "applied");
  // only the first one is ever applied to the shop
  assertEquals(rpcCalls(db, "billing_apply_subscription").map((a) => a.p_subscription_id), [
    FIRST,
  ]);
  assertEquals([row().stripe_subscription_id, row().status], [FIRST, "active"]);
  // what the second one charged is refunded, then it is cancelled now
  assertEquals(stripe.refunds.map((r) => [r.payment_intent, r.reason, r.amount]), [
    ["pi_2Second", "duplicate", 4_900],
  ]);
  assert(String(stripe.refunds[0]?.idempotency_key).startsWith("dcrm:billing_duplicate_refund:"));
  const calls = stripeCalls(db);
  const refundAt = calls.findIndex((c) => c.url.pathname === "/v1/refunds");
  const cancelAt = calls.findIndex((c) =>
    c.method === "DELETE" && c.url.pathname === `/v1/subscriptions/${SECOND}`
  );
  assert(refundAt >= 0 && refundAt < cancelAt, "refund before the cancellation");
  assertEquals([status(stripe, FIRST), status(stripe, SECOND)], ["active", "canceled"]);
  for (const call of calls) assertEquals(call.headers.get("stripe-account"), null);
  const warned = logs.events("billing_duplicate_subscription_cancelled")[0];
  assertEquals([warned?.subscription, warned?.kept, warned?.refunded_cents], [
    SECOND,
    FIRST,
    4_900,
  ]);

  // The duplicate's own later events never flip the shop to it: its
  // cancellation leaves the shop active on the first subscription.
  await ok(
    await deliver(
      handler,
      event("customer.subscription.deleted", subscription({ id: SECOND, status: "canceled" }), {
        created: T2,
      }),
    ),
  );
  assertEquals([row().stripe_subscription_id, row().status], [FIRST, "active"]);
  assertEquals(stripe.refunds.length, 1);
});

Deno.test("duplicate subscription: resolved the same way whichever event arrives first", async () => {
  // Neither subscription's webhook has arrived yet; the second checkout's
  // completion is the first event the shop sees.
  const { db, stripe, handler, row } = setup({ billing: { stripe_customer_id: null } });
  twoSubscriptions(stripe);
  const res = await ok(
    await deliver(
      handler,
      event("checkout.session.completed", checkoutSession({ subscription: SECOND })),
    ),
  );
  assertEquals(res.result, "applied");
  assertEquals(rpcCalls(db, "billing_apply_subscription").map((a) => a.p_subscription_id), [
    FIRST,
  ]);
  assertEquals([row().stripe_customer_id, row().stripe_subscription_id, row().status], [
    "cus_1Shop",
    FIRST,
    "active",
  ]);
  assertEquals(status(stripe, SECOND), "canceled");
  // the first subscription's own events apply normally and cancel nothing
  await ok(
    await deliver(
      handler,
      event("customer.subscription.created", subscription({ id: FIRST }), { created: T2 }),
    ),
  );
  assertEquals([row().stripe_subscription_id, status(stripe, FIRST)], [FIRST, "active"]);
  assertEquals(stripe.refunds.length, 1);
});

Deno.test("duplicate subscription: a trialing or unpaid duplicate is cancelled without a refund", async () => {
  const { stripe, handler, row } = setup({
    billing: { stripe_subscription_id: FIRST, status: "active" },
  });
  twoSubscriptions(stripe, { status: "incomplete" });
  stripe.invoices = [];
  await ok(
    await deliver(handler, event("customer.subscription.updated", subscription({ id: SECOND }))),
  );
  assertEquals(stripe.refunds, []);
  assertEquals(status(stripe, SECOND), "canceled");
  assertEquals(row().stripe_subscription_id, FIRST);
});

Deno.test("duplicate subscription: a failed refund answers 500 and the redelivery finishes it once", async () => {
  const { db, stripe, handler, row } = setup({
    billing: { stripe_subscription_id: FIRST, status: "active" },
  });
  twoSubscriptions(stripe);
  db.http.once("POST", "https://api.stripe.com/v1/refunds", () =>
    new Response(
      JSON.stringify({ error: { type: "api_error", message: "Stripe is down" } }),
      { status: 500, headers: { "content-type": "application/json" } },
    ));
  const body = event(
    "invoice.paid",
    subscriptionInvoice({
      parent: { type: "subscription_details", subscription_details: { subscription: SECOND } },
    }),
    { id: "evt_1DupRetry" },
  );
  const first = await deliver(handler, body);
  assertEquals(first.status, 500);
  await first.body?.cancel();
  // not cancelled yet, so the redelivery still recognises it as a duplicate
  assertEquals(status(stripe, SECOND), "active");
  assertEquals(row().stripe_subscription_id, FIRST);
  assertEquals((await ok(await deliver(handler, body))).result, "applied");
  assertEquals(stripe.refunds.length, 1);
  assertEquals(status(stripe, SECOND), "canceled");
  assertEquals(row().stripe_subscription_id, FIRST);
});

Deno.test("duplicate subscription: a failed payment of the duplicate does not notify the owner", async () => {
  const { stripe, handler, state } = setup({
    billing: { stripe_subscription_id: FIRST, status: "active" },
  });
  twoSubscriptions(stripe, { status: "past_due" });
  stripe.invoices = [];
  const invoice = subscriptionInvoice({
    status: "open",
    parent: { type: "subscription_details", subscription_details: { subscription: SECOND } },
  });
  await ok(await deliver(handler, event("invoice.payment_failed", invoice)));
  assertEquals(state.notifications, []);
  assertEquals(status(stripe, SECOND), "canceled");
});

Deno.test("duplicate subscription: one made outside Detail CRM is logged, never applied or cancelled", async () => {
  const { db, stripe, handler, row, logs } = setup({
    billing: { stripe_subscription_id: FIRST, status: "active" },
  });
  twoSubscriptions(stripe, { metadata: {} });
  const res = await ok(
    await deliver(handler, event("customer.subscription.created", subscription({ id: SECOND }))),
  );
  assertEquals(res.result, "ignored");
  const ignored = logs.events("billing_event_ignored").at(-1);
  assertEquals([ignored?.reason, ignored?.level, ignored?.kept], [
    "duplicate_subscription",
    "warn",
    FIRST,
  ]);
  assertEquals(rpcCalls(db, "billing_apply_subscription").map((a) => a.p_subscription_id), [
    FIRST,
  ]);
  assertEquals([row().stripe_subscription_id, status(stripe, SECOND)], [FIRST, "active"]);
  assertEquals(stripe.refunds, []);
});

Deno.test("duplicate subscription: nothing is cancelled for a customer that is not a Detail CRM shop's", async () => {
  const { stripe, handler } = setup();
  twoSubscriptions(stripe, { customer: "cus_1Stranger" });
  stripe.putSubscription(subscription({ id: FIRST, customer: "cus_1Stranger", created: 1 }));
  const res = await ok(
    await deliver(
      handler,
      event(
        "customer.subscription.created",
        subscription({ id: SECOND, customer: "cus_1Stranger" }),
      ),
    ),
  );
  assertEquals(res.result, "ignored");
  assertEquals([status(stripe, FIRST), status(stripe, SECOND)], ["active", "active"]);
  assertEquals(stripe.refunds, []);
});

Deno.test("resubscribing after the first subscription ended is not a duplicate", async () => {
  const { stripe, handler, row } = setup({
    billing: { stripe_subscription_id: FIRST, status: "canceled" },
  });
  twoSubscriptions(stripe);
  const first = stripe.subscriptions.get(FIRST);
  assert(first);
  first.status = "canceled";
  await ok(
    await deliver(handler, event("customer.subscription.created", subscription({ id: SECOND }))),
  );
  assertEquals([row().stripe_subscription_id, row().status], [SECOND, "active"]);
  assertEquals(status(stripe, SECOND), "active");
  assertEquals(stripe.refunds, []);
});
