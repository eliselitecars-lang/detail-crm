import { assert, assertEquals, assertMatch } from "@std/assert";
import { STRIPE_API_VERSION } from "../_shared/stripe.ts";
import { jsonResponse, stripeErrorBody } from "../_shared/testing/mod.ts";
import {
  ACCT,
  CASH_PAYMENT,
  CUSTOMER,
  errorOf,
  fixture,
  INVOICE,
  MEMBERS,
  OTHER_CUSTOMER,
  OTHER_INVOICE,
  PAYMENT,
  SHOP,
  STRIPE,
  type Who,
} from "./test_fixtures.ts";

const sheet = { action: "payment_sheet", shop_id: SHOP, invoice_id: INVOICE };

// ---------------------------------------------------------------------------
// payment_sheet
// ---------------------------------------------------------------------------

Deno.test("payment_sheet: manager gets a PaymentSheet for the balance on the connected account", async () => {
  const f = fixture();
  const res = await f.call({ ...sheet, tip_cents: 1_000 }, "manager");
  assertEquals(res.status, 200);
  assertEquals(await res.json(), {
    payment_intent_id: "pi_1New",
    payment_intent_client_secret: "pi_1New_secret_abc",
    ephemeral_key_secret: "ek_test_secret",
    customer_id: "cus_1New",
    publishable_key: "pk_test_FakePublishableKey00000000",
    stripe_account_id: ACCT,
    amount_cents: 12_345,
    tip_cents: 1_000,
    currency: "usd",
  });
  const pi = f.stripe("POST", "/payment_intents")[0];
  assertEquals(pi?.headers.get("stripe-account"), ACCT);
  assertMatch(pi?.headers.get("idempotency-key") ?? "", /^dcrm:payment_sheet:[0-9a-f]{64}$/);
  assertEquals(pi?.form.get("amount"), "13345");
  assertEquals(pi?.form.get("currency"), "usd");
  assertEquals(pi?.form.get("customer"), "cus_1New");
  assertEquals(pi?.form.get("application_fee_amount"), "309");
  assertEquals(pi?.form.get("metadata[invoice_id]"), INVOICE);
  assertEquals(pi?.form.get("metadata[tip_cents]"), "1000");
  assertEquals(pi?.form.get("metadata[kind]"), "payment");
  const ek = f.stripe("POST", "/ephemeral_keys")[0];
  assertEquals(ek?.headers.get("stripe-account"), ACCT);
  assertEquals(ek?.headers.get("stripe-version"), STRIPE_API_VERSION);
  assertEquals(ek?.form.get("customer"), "cus_1New");
  assert(ek?.headers.get("idempotency-key")?.startsWith("dcrm:ephemeral_key:"));

  const upsert = f.rpcCalls.find((c) => c.name === "upsert_stripe_payment");
  assertEquals(upsert?.args, {
    p_shop_id: SHOP,
    p_payment_intent_id: "pi_1New",
    p_status: "pending",
    p_amount_cents: 12_345,
    p_tip_cents: 1_000,
    p_kind: "payment",
    p_method: "card",
    p_invoice_id: INVOICE,
    p_customer_id: CUSTOMER,
  });
  const rpc = f.db.requests.find((r) => r.target === "upsert_stripe_payment");
  assertEquals(rpc?.role, "service_role");
});

Deno.test("payment_sheet: partial amounts are validated against the balance", async () => {
  const f = fixture();
  const ok = await f.call({ ...sheet, amount_cents: 5_000 }, "owner");
  assertEquals((await ok.json()).amount_cents, 5_000);
  assertEquals(f.stripe("POST", "/payment_intents")[0]?.form.get("amount"), "5000");
  assertEquals(f.stripe("POST", "/payment_intents")[0]?.form.get("application_fee_amount"), "125");
  assertEquals(await errorOf(await f.call({ ...sheet, amount_cents: 12_346 }, "owner")), [
    422,
    "unprocessable",
    { reason: "amount_exceeds_balance", balance_cents: 12_345 },
  ]);
  for (const amount of [0, -5, 10.5]) {
    assertEquals(
      (await errorOf(await f.call({ ...sheet, amount_cents: amount }, "owner")))[1],
      "validation_failed",
    );
  }
  assertEquals((await errorOf(await f.call({ ...sheet, tip_cents: 20_000 }, "owner")))[2], {
    reason: "tip_too_large",
    balance_cents: 12_345,
  });
  assertEquals(
    (await errorOf(await f.call({ ...sheet, total_cents: 1 }, "owner")))[1],
    "validation_failed",
  );
  assertEquals(f.stripe("POST", "/payment_intents").length, 1);
});

Deno.test("payment_sheet: technician rules follow techs_can_collect_payments + assignment", async () => {
  const allowed = fixture();
  assertEquals((await allowed.call(sheet, "tech")).status, 200);
  assertEquals(
    allowed.stripe("POST", "/payment_intents")[0]?.form.get("metadata[member_id]"),
    MEMBERS.tech,
  );

  const unassigned = fixture();
  assertEquals(await errorOf(await unassigned.call(sheet, "tech2")), [403, "forbidden", undefined]);

  const disabled = fixture({ shop: { techs_can_collect_payments: false } });
  assertEquals((await errorOf(await disabled.call(sheet, "tech")))[1], "forbidden");

  const noJob = fixture({ invoice: { job_id: null } });
  assertEquals((await errorOf(await noJob.call(sheet, "tech")))[1], "forbidden");

  for (const f of [unassigned, disabled, noJob]) assertEquals(f.stripeCalls().length, 0);
});

Deno.test("payment_sheet: signed-out, anonymous and other-shop callers are refused", async () => {
  const f = fixture();
  const cases: Array<[Who, number, string]> = [
    ["none", 401, "unauthorized"],
    ["anon", 401, "unauthorized"],
    ["outsider", 403, "forbidden"],
  ];
  for (const [who, status, code] of cases) {
    assertEquals((await errorOf(await f.call(sheet, who))).slice(0, 2), [status, code]);
  }
  // Another shop's invoice through our shop id: not found (never charged).
  assertEquals(
    (await errorOf(await f.call({ ...sheet, invoice_id: OTHER_INVOICE }, "owner"))).slice(0, 2),
    [404, "not_found"],
  );
  assertEquals(f.stripeCalls().length, 0);
});

Deno.test("payment_sheet: void/paid/draft invoices and disabled charges", async () => {
  assertEquals(
    (await errorOf(await fixture({ invoice: { status: "void" } }).call(sheet, "owner")))[2],
    {
      reason: "void",
    },
  );
  assertEquals(
    (await errorOf(
      await fixture({ invoice: { status: "paid", balance_cents: 0 } }).call(sheet, "owner"),
    ))[2],
    { reason: "paid" },
  );
  assertEquals(
    (await errorOf(await fixture({ invoice: { status: "draft" } }).call(sheet, "owner")))[2],
    { reason: "draft" },
  );
  assertEquals(
    (await errorOf(
      await fixture({ account: { charges_enabled: false } }).call(sheet, "owner"),
    ))[2],
    { reason: "charges_disabled" },
  );
});

Deno.test("payment_sheet: ephemeral key API version override and retry idempotency", async () => {
  const f = fixture();
  const body = {
    ...sheet,
    request_nonce: "nonce-0001",
    ephemeral_key_api_version: "2020-08-27",
  };
  await (await f.call(body, "manager")).body?.cancel();
  await (await f.call(body, "manager")).body?.cancel();
  await (await f.call({ ...body, request_nonce: "nonce-0002" }, "manager")).body?.cancel();
  assertEquals(f.stripe("POST", "/ephemeral_keys")[0]?.headers.get("stripe-version"), "2020-08-27");
  const keys = f.stripe("POST", "/payment_intents").map((c) => c.headers.get("idempotency-key"));
  assertEquals(keys[0], keys[1]);
  assert(keys[0] !== keys[2]);
  assertEquals(
    (await errorOf(await f.call({ ...sheet, ephemeral_key_api_version: "latest" }, "manager")))[1],
    "validation_failed",
  );
});

Deno.test("payment_sheet: a failed pending-row write is logged, the sheet still returned", async () => {
  const f = fixture();
  f.db.onRpc("upsert_stripe_payment", () => {
    throw new Error("boom");
  });
  const res = await f.call(sheet, "manager");
  assertEquals(res.status, 200);
  await res.body?.cancel();
});

// ---------------------------------------------------------------------------
// charge_saved_card
// ---------------------------------------------------------------------------

const charge = { action: "charge_saved_card", shop_id: SHOP, invoice_id: INVOICE };

Deno.test("charge_saved_card: off-session charge of the default card, recorded as succeeded", async () => {
  const f = fixture({ customer: { stripe_customer_id: "cus_1Saved" } });
  const res = await f.call(charge, "manager");
  assertEquals(res.status, 200);
  assertEquals(await res.json(), {
    payment_id: "50000000-0000-4000-8000-000000000001",
    payment_intent_id: "pi_1New",
    status: "succeeded",
    amount_cents: 12_345,
    card_brand: "visa",
    card_last4: "4242",
  });
  const pi = f.stripe("POST", "/payment_intents")[0];
  assertEquals(pi?.headers.get("stripe-account"), ACCT);
  assertMatch(pi?.headers.get("idempotency-key") ?? "", /^dcrm:charge_saved_card:/);
  assertEquals(pi?.form.get("customer"), "cus_1Saved");
  assertEquals(pi?.form.get("payment_method"), "pm_1Default");
  assertEquals(pi?.form.get("off_session"), "true");
  assertEquals(pi?.form.get("confirm"), "true");
  assertEquals(pi?.form.get("amount"), "12345");
  assertEquals(pi?.form.get("application_fee_amount"), "309");
  const upsert = f.rpcCalls.find((c) => c.name === "upsert_stripe_payment")?.args;
  assertEquals(upsert?.p_status, "succeeded");
  assertEquals(upsert?.p_payment_intent_id, "pi_1New");
  assertEquals(upsert?.p_charge_id, "ch_1New");
  assertEquals(upsert?.p_amount_cents, 12_345);
  assertEquals([upsert?.p_card_brand, upsert?.p_card_last4], ["visa", "4242"]);
  assertEquals(upsert?.p_paid_at, "2026-09-27T12:00:00.000Z");
});

Deno.test("charge_saved_card: chosen card must be this customer's saved card", async () => {
  const f = fixture({ customer: { stripe_customer_id: "cus_1Saved" } });
  const other = await f.call(
    { ...charge, payment_method_id: "pm_1Other", amount_cents: 1_000 },
    "admin",
  );
  assertEquals(other.status, 200);
  await other.body?.cancel();
  assertEquals(f.stripe("POST", "/payment_intents")[0]?.form.get("payment_method"), "pm_1Other");
  assertEquals(f.stripe("POST", "/payment_intents")[0]?.form.get("amount"), "1000");
  assertEquals(
    (await errorOf(await f.call({ ...charge, payment_method_id: "pm_1Foreign" }, "admin"))).slice(
      0,
      2,
    ),
    [404, "not_found"],
  );
  assertEquals(
    (await errorOf(await f.call({ ...charge, payment_method_id: "4242424242424242" }, "admin")))[1],
    "validation_failed",
  );
  const noCards = fixture({ cards: [], customer: { stripe_customer_id: "cus_1Saved" } });
  assertEquals((await errorOf(await noCards.call(charge, "owner")))[2], {
    reason: "no_saved_card",
  });
  const noCustomer = fixture();
  assertEquals((await errorOf(await noCustomer.call(charge, "owner")))[2], {
    reason: "no_saved_card",
  });
  assertEquals(f.stripe("POST", "/payment_intents").length, 1);
});

Deno.test("charge_saved_card: technicians cannot charge saved cards", async () => {
  const f = fixture({ customer: { stripe_customer_id: "cus_1Saved" } });
  for (const who of ["tech", "tech2", "outsider"] as const) {
    assertEquals((await errorOf(await f.call(charge, who)))[1], "forbidden");
  }
  assertEquals((await errorOf(await f.call(charge, "none")))[1], "unauthorized");
  assertEquals(f.stripeCalls().length, 0);
});

Deno.test("charge_saved_card: declines and authentication_required map to payment_failed", async () => {
  const f = fixture({ customer: { stripe_customer_id: "cus_1Saved" } });
  f.db.http.once("POST", `${STRIPE}/payment_intents`, () =>
    jsonResponse(
      stripeErrorBody("card_error", "Your card has insufficient funds.", {
        code: "card_declined",
        decline_code: "insufficient_funds",
        payment_intent: { id: "pi_1Declined", object: "payment_intent" },
      }),
      402,
    ));
  const declined = await f.call(charge, "manager");
  const body = await declined.json();
  assertEquals(declined.status, 402);
  assertEquals(body.code, "payment_failed");
  assertEquals(body.error, "Your card has insufficient funds.");
  assertEquals(body.details, {
    reason: "card_declined",
    stripe_code: "card_declined",
    decline_code: "insufficient_funds",
  });
  const failed = f.rpcCalls.find((c) => c.name === "upsert_stripe_payment")?.args;
  assertEquals([failed?.p_payment_intent_id, failed?.p_status], ["pi_1Declined", "failed"]);

  f.db.http.once("POST", `${STRIPE}/payment_intents`, () =>
    jsonResponse(
      stripeErrorBody("card_error", "This payment requires authentication.", {
        code: "authentication_required",
        payment_intent: { id: "pi_1Auth", object: "payment_intent" },
      }),
      402,
    ));
  const auth = await f.call(charge, "manager");
  const authBody = await auth.json();
  assertEquals([auth.status, authBody.code], [402, "payment_failed"]);
  assertEquals(authBody.details.reason, "authentication_required");
  assertMatch(authBody.error, /payment link/);
});

Deno.test("charge_saved_card: charges_enabled false and void invoices are refused", async () => {
  const off = fixture({
    customer: { stripe_customer_id: "cus_1Saved" },
    account: { charges_enabled: false },
  });
  assertEquals((await errorOf(await off.call(charge, "owner")))[2], { reason: "charges_disabled" });
  const voided = fixture({
    customer: { stripe_customer_id: "cus_1Saved" },
    invoice: { status: "void" },
  });
  assertEquals((await errorOf(await voided.call(charge, "owner")))[1], "conflict");
  assertEquals(off.stripeCalls().length + voided.stripeCalls().length, 0);
});

// ---------------------------------------------------------------------------
// setup_card / setup_card_link
// ---------------------------------------------------------------------------

Deno.test("setup_card: SetupIntent (off_session) + ephemeral key for PaymentSheet setup mode", async () => {
  const f = fixture();
  const res = await f.call(
    { action: "setup_card", shop_id: SHOP, customer_id: CUSTOMER },
    "manager",
  );
  assertEquals(await res.json(), {
    setup_intent_id: "seti_1",
    setup_intent_client_secret: "seti_1_secret_abc",
    ephemeral_key_secret: "ek_test_secret",
    customer_id: "cus_1New",
    publishable_key: "pk_test_FakePublishableKey00000000",
    stripe_account_id: ACCT,
  });
  const si = f.stripe("POST", "/setup_intents")[0];
  assertEquals(si?.headers.get("stripe-account"), ACCT);
  assert(si?.headers.get("idempotency-key")?.startsWith("dcrm:setup_card:"));
  assertEquals(si?.form.get("usage"), "off_session");
  assertEquals(si?.form.get("customer"), "cus_1New");
  assertEquals(si?.form.get("metadata[customer_id]"), CUSTOMER);
  assertEquals(si?.form.get("metadata[shop_id]"), SHOP);
});

Deno.test("setup_card / setup_card_link: role and customer checks", async () => {
  const f = fixture();
  for (const action of ["setup_card", "setup_card_link"]) {
    const body = { action, shop_id: SHOP, customer_id: CUSTOMER };
    assertEquals((await errorOf(await f.call(body, "tech")))[1], "forbidden");
    assertEquals((await errorOf(await f.call(body, "outsider")))[1], "forbidden");
    assertEquals((await errorOf(await f.call(body, "none")))[1], "unauthorized");
    assertEquals(
      (await errorOf(await f.call({ ...body, customer_id: OTHER_CUSTOMER }, "owner"))).slice(0, 2),
      [404, "not_found"],
    );
  }
  const archived = fixture({ customer: { archived_at: "2026-01-01T00:00:00Z" } });
  assertEquals(
    (await errorOf(
      await archived.call({ action: "setup_card", shop_id: SHOP, customer_id: CUSTOMER }, "owner"),
    ))[2],
    { reason: "customer_archived" },
  );
  assertEquals(f.stripeCalls().length + archived.stripeCalls().length, 0);
});

Deno.test("setup_card_link: Checkout in setup mode that can be texted", async () => {
  const f = fixture();
  const res = await f.call(
    { action: "setup_card_link", shop_id: SHOP, customer_id: CUSTOMER },
    "manager",
  );
  assertEquals(await res.json(), {
    url: "https://checkout.stripe.com/c/pay/cs_test_1",
    expires_at: 1_900_000_000,
  });
  const session = f.stripe("POST", "/checkout/sessions")[0];
  assertEquals(session?.headers.get("stripe-account"), ACCT);
  assert(session?.headers.get("idempotency-key")?.startsWith("dcrm:setup_card_link:"));
  assertEquals(session?.form.get("mode"), "setup");
  assertEquals(session?.form.get("currency"), "usd");
  assertEquals(session?.form.get("customer"), "cus_1New");
  assertEquals(session?.form.get("setup_intent_data[metadata][customer_id]"), CUSTOMER);
  assertEquals(session?.form.get("success_url"), "https://app.example.com/portal?card=saved");
  assertEquals(session?.form.get("cancel_url"), "https://app.example.com/portal?card=canceled");
});

// ---------------------------------------------------------------------------
// refund
// ---------------------------------------------------------------------------

const refundBody = { action: "refund", shop_id: SHOP, payment_id: PAYMENT };

Deno.test("refund: admin refunds the remaining amount on the connected account", async () => {
  const f = fixture();
  const res = await f.call(refundBody, "admin");
  assertEquals(await res.json(), {
    payment_id: PAYMENT,
    refund_id: "re_1",
    refund_status: "succeeded",
    amount_cents: 10_500,
    refunded_cents_total: 10_500,
    payment_status: "refunded",
  });
  const get = f.stripe("GET", "/payment_intents/:id")[0];
  assertEquals(get?.url.pathname, "/v1/payment_intents/pi_1Paid");
  assertMatch(decodeURIComponent(get?.url.search ?? ""), /expand\[\d*\]=latest_charge/);
  assertEquals(get?.headers.get("stripe-account"), ACCT);
  const refund = f.stripe("POST", "/refunds")[0];
  assertEquals(refund?.headers.get("stripe-account"), ACCT);
  assertEquals(refund?.form.get("payment_intent"), "pi_1Paid");
  assertEquals(refund?.form.get("amount"), "10500");
  assertEquals(refund?.form.has("refund_application_fee"), false);
  assertMatch(refund?.headers.get("idempotency-key") ?? "", /^dcrm:refund:[0-9a-f]{64}$/);
  assertEquals(f.rpcCalls.find((c) => c.name === "apply_stripe_refund")?.args, {
    p_payment_intent_id: "pi_1Paid",
    p_refunded_cents_total: 10_500,
  });
});

Deno.test("refund: partial refunds key on the cumulative total and respect Stripe's refunded amount", async () => {
  const f = fixture();
  f.db.http.on("GET", `${STRIPE}/payment_intents/:id`, (_req, { params }) =>
    jsonResponse({
      id: params.id,
      object: "payment_intent",
      latest_charge: {
        id: "ch_1Paid",
        object: "charge",
        amount: 10_500,
        amount_refunded: 2_000, // refunded in the Stripe dashboard, webhook not in yet
        application_fee_amount: 250,
      },
    }));
  const first = await f.call({ ...refundBody, amount_cents: 3_000 }, "owner");
  assertEquals((await first.json()).refunded_cents_total, 5_000);
  const again = await f.call({ ...refundBody, amount_cents: 3_000 }, "owner");
  await again.body?.cancel();
  const other = await f.call({ ...refundBody, amount_cents: 4_000 }, "owner");
  await other.body?.cancel();
  const calls = f.stripe("POST", "/refunds");
  assertEquals(calls[0]?.form.get("refund_application_fee"), "true");
  // Same cumulative target -> same key (a retry cannot refund twice).
  assertEquals(calls[0]?.headers.get("idempotency-key"), calls[1]?.headers.get("idempotency-key"));
  assert(calls[0]?.headers.get("idempotency-key") !== calls[2]?.headers.get("idempotency-key"));
  assertEquals(await errorOf(await f.call({ ...refundBody, amount_cents: 8_501 }, "owner")), [
    422,
    "unprocessable",
    { reason: "amount_exceeds_refundable", refundable_cents: 8_500 },
  ]);
});

Deno.test("refund: only owner/admin; managers and technicians are refused", async () => {
  const f = fixture();
  for (const who of ["manager", "tech", "tech2", "outsider"] as const) {
    assertEquals((await errorOf(await f.call(refundBody, who)))[1], "forbidden");
  }
  assertEquals((await errorOf(await f.call(refundBody, "none")))[1], "unauthorized");
  assertEquals(f.stripeCalls().length, 0);
});

Deno.test("refund: cash, pending and fully refunded payments", async () => {
  const f = fixture();
  assertEquals(
    (await errorOf(await f.call({ ...refundBody, payment_id: CASH_PAYMENT }, "owner")))[2],
    {
      reason: "not_a_card_payment",
    },
  );
  assertEquals(
    (await errorOf(
      await f.call({ ...refundBody, payment_id: "ffffffff-ffff-4fff-8fff-00000000abcd" }, "owner"),
    )).slice(0, 2),
    [404, "not_found"],
  );
  f.db.http.on("GET", `${STRIPE}/payment_intents/:id`, (_req, { params }) =>
    jsonResponse({
      id: params.id,
      object: "payment_intent",
      latest_charge: { id: "ch_1", object: "charge", amount: 10_500, amount_refunded: 10_500 },
    }));
  assertEquals((await errorOf(await f.call(refundBody, "owner")))[2], { reason: "fully_refunded" });
  assertEquals(f.stripe("POST", "/refunds").length, 0);
});

Deno.test("refund: a refund the database cannot record yet still succeeds (webhook reconciles)", async () => {
  const f = fixture();
  f.db.onRpc("apply_stripe_refund", () => {
    throw new Error("db down");
  });
  const res = await f.call({ ...refundBody, amount_cents: 500 }, "owner");
  assertEquals(res.status, 200);
  assertEquals((await res.json()).payment_status, null);
});
