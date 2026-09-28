import { assert, assertEquals, assertMatch } from "@std/assert";
import { FakeRpcError, jsonResponse, stripeErrorBody } from "../_shared/testing/mod.ts";
import { rpcError } from "./lib.ts";
import {
  ACCT,
  CUSTOMER,
  errorOf,
  fixture,
  INVOICE,
  INVOICE_TOKEN,
  JOB,
  JOB_TOKEN,
  NOW,
  SHOP,
  STRIPE,
} from "./test_fixtures.ts";

const checkout = { action: "invoice_checkout", token: INVOICE_TOKEN };

Deno.test("invoice_checkout: anonymous payer gets a session for exactly the DB balance", async () => {
  const f = fixture();
  const res = await f.call(checkout);
  assertEquals(res.status, 200);
  assertEquals(await res.json(), {
    url: "https://checkout.stripe.com/c/pay/cs_test_1",
    expires_at: 1_900_000_000,
    amount_cents: 12_345,
    tip_cents: 0,
    currency: "usd",
  });

  const session = f.stripe("POST", "/checkout/sessions")[0];
  assert(session);
  const form = session.form;
  assertEquals(session.headers.get("stripe-account"), ACCT);
  assertMatch(session.headers.get("idempotency-key") ?? "", /^dcrm:invoice_checkout:[0-9a-f]{64}$/);
  assertEquals(form.get("mode"), "payment");
  assertEquals(form.get("customer"), "cus_1New");
  assertEquals(form.get("client_reference_id"), INVOICE);
  assertEquals(form.get("line_items[0][price_data][unit_amount]"), "12345");
  assertEquals(form.get("line_items[0][price_data][currency]"), "usd");
  assertEquals(form.get("line_items[0][price_data][product_data][name]"), "Invoice #2001");
  assertEquals(form.get("line_items[1][price_data][unit_amount]"), null);
  // P-31: the card is saved through the card options (a top-level
  // setup_future_usage would hide pay-later and restrict bank debits).
  assertEquals(form.get("payment_intent_data[setup_future_usage]"), null);
  assertEquals(form.get("payment_method_options[card][setup_future_usage]"), "off_session");
  // 2.5% of 12,345 = 308.625 -> 309 (round half away from zero)
  assertEquals(form.get("payment_intent_data[application_fee_amount]"), "309");
  for (const prefix of ["payment_intent_data[metadata]", "metadata"]) {
    assertEquals(form.get(`${prefix}[shop_id]`), SHOP);
    assertEquals(form.get(`${prefix}[invoice_id]`), INVOICE);
    assertEquals(form.get(`${prefix}[job_id]`), JOB);
    assertEquals(form.get(`${prefix}[customer_id]`), CUSTOMER);
    assertEquals(form.get(`${prefix}[kind]`), "payment");
    assertEquals(form.get(`${prefix}[tip_cents]`), "0");
  }
  assertEquals(form.get("success_url"), `https://app.example.com/i/${INVOICE_TOKEN}?paid=1`);
  assertEquals(form.get("cancel_url"), `https://app.example.com/i/${INVOICE_TOKEN}?canceled=1`);

  // The Stripe customer is created on the connected account, prefilled, and stored.
  const customer = f.stripe("POST", "/customers")[0];
  assertEquals(customer?.headers.get("stripe-account"), ACCT);
  assertEquals(customer?.form.get("email"), "ada@example.com");
  assertEquals(customer?.form.get("name"), "Ada Lovelace");
  assertEquals(customer?.form.get("metadata[customer_id]"), CUSTOMER);
  assert(customer?.headers.get("idempotency-key")?.startsWith("dcrm:customer:"));
  assertEquals(
    f.db.table("customers").find((c) => c.id === CUSTOMER)?.stripe_customer_id,
    "cus_1New",
  );
  // Public request: every database call used the service role.
  assert(f.db.requests.every((r) => r.role === "service_role"));
});

Deno.test("invoice_checkout: tip is a separate line; fee excludes the tip", async () => {
  const f = fixture();
  const res = await f.call({ ...checkout, tip_cents: 2_000 });
  assertEquals((await res.json()).tip_cents, 2_000);
  const form = f.stripe("POST", "/checkout/sessions")[0]?.form;
  assertEquals(form?.get("line_items[0][price_data][unit_amount]"), "12345");
  assertEquals(form?.get("line_items[1][price_data][unit_amount]"), "2000");
  assertEquals(form?.get("line_items[1][price_data][product_data][name]"), "Tip");
  assertEquals(form?.get("payment_intent_data[application_fee_amount]"), "309");
  assertEquals(form?.get("payment_intent_data[metadata][tip_cents]"), "2000");
});

Deno.test("invoice_checkout: tip bounds and client amounts", async () => {
  const f = fixture();
  assertEquals((await errorOf(await f.call({ ...checkout, tip_cents: 12_346 })))[0], 422);
  const maxTip = await f.call({ ...checkout, tip_cents: 12_345 });
  assertEquals(maxTip.status, 200);
  await maxTip.body?.cancel();
  assertEquals(
    (await errorOf(await f.call({ ...checkout, tip_cents: -1 })))[1],
    "validation_failed",
  );
  assertEquals(
    (await errorOf(await f.call({ ...checkout, tip_cents: 1.5 })))[1],
    "validation_failed",
  );
  assertEquals(
    (await errorOf(await f.call({ ...checkout, tip_cents: "100" })))[1],
    "validation_failed",
  );
  // A client-sent amount is never accepted on the public action.
  assertEquals(
    (await errorOf(await f.call({ ...checkout, amount_cents: 1 })))[1],
    "validation_failed",
  );
  // Only the tip_cents=12345 call reached Stripe.
  assertEquals(f.stripe("POST", "/checkout/sessions").length, 1);
});

Deno.test("invoice_checkout: tokens and invoice states", async () => {
  const unknown = fixture();
  assertEquals(
    (await errorOf(
      await unknown.call({ ...checkout, token: "99999999-9999-4999-8999-00000000abcd" }),
    )).slice(0, 2),
    [404, "not_found"],
  );
  assertEquals(
    (await errorOf(await unknown.call({ ...checkout, token: "not-a-token" }))).slice(0, 2),
    [400, "validation_failed"],
  );
  const cases: Array<[Record<string, unknown>, number, string, unknown]> = [
    [{ status: "draft" }, 404, "not_found", undefined],
    [{ status: "void" }, 409, "conflict", { reason: "void" }],
    [{ status: "paid", balance_cents: 0 }, 409, "conflict", { reason: "paid" }],
    [{ status: "open", balance_cents: -500 }, 409, "conflict", { reason: "paid" }],
  ];
  for (const [invoice, status, code, details] of cases) {
    const f = fixture({ invoice });
    assertEquals(await errorOf(await f.call(checkout)), [status, code, details]);
    assertEquals(f.stripeCalls().length, 0);
  }
});

Deno.test("invoice_checkout: Stripe not connected / charges disabled", async () => {
  const off = fixture({ account: { charges_enabled: false } });
  assertEquals(await errorOf(await off.call(checkout)), [422, "unprocessable", {
    reason: "charges_disabled",
  }]);
  const none = fixture({ account: null });
  assertEquals(await errorOf(await none.call(checkout)), [422, "unprocessable", {
    reason: "stripe_not_connected",
  }]);
  assertEquals(off.stripeCalls().length + none.stripeCalls().length, 0);
});

Deno.test("invoice_checkout: below Stripe's minimum is a 422, not a 500", async () => {
  const f = fixture({ invoice: { balance_cents: 49 } });
  const [status, code, details] = await errorOf(await f.call(checkout));
  assertEquals([status, code], [422, "unprocessable"]);
  assertEquals((details as { reason: string }).reason, "amount_out_of_range");
});

Deno.test("invoice_checkout: no platform fee when PLATFORM_FEE_BPS is 0", async () => {
  const f = fixture({ env: { PLATFORM_FEE_BPS: "0" } });
  assertEquals((await f.call(checkout)).status, 200);
  const form = f.stripe("POST", "/checkout/sessions")[0]?.form;
  assertEquals(form?.has("payment_intent_data[application_fee_amount]"), false);
});

Deno.test("invoice_checkout: an existing Stripe customer is reused, a missing one replaced", async () => {
  const reuse = fixture({ customer: { stripe_customer_id: "cus_1Existing" } });
  await (await reuse.call(checkout)).body?.cancel();
  assertEquals(reuse.stripe("POST", "/customers").length, 0);
  assertEquals(reuse.stripe("GET", "/customers/:id")[0]?.headers.get("stripe-account"), ACCT);
  assertEquals(
    reuse.stripe("POST", "/checkout/sessions")[0]?.form.get("customer"),
    "cus_1Existing",
  );

  const gone = fixture({ customer: { stripe_customer_id: "cus_1Gone" } });
  gone.db.http.on("GET", `${STRIPE}/customers/:id`, () =>
    jsonResponse(
      stripeErrorBody("invalid_request_error", "No such customer", { code: "resource_missing" }),
      404,
    ));
  assertEquals((await gone.call(checkout)).status, 200);
  assertEquals(gone.stripe("POST", "/customers").length, 1);
  assertEquals(
    gone.db.table("customers").find((c) => c.id === CUSTOMER)?.stripe_customer_id,
    "cus_1New",
  );
});

Deno.test("invoice_checkout: idempotency keys follow nonce, amount and tip", async () => {
  const f = fixture();
  for (
    const body of [
      { ...checkout, request_nonce: "nonce-0001" },
      { ...checkout, request_nonce: "nonce-0001" },
      { ...checkout, request_nonce: "nonce-0002" },
      { ...checkout, request_nonce: "nonce-0001", tip_cents: 100 },
      checkout,
      checkout,
    ]
  ) {
    await (await f.call(body)).body?.cancel();
  }
  const keys = f.stripe("POST", "/checkout/sessions").map((c) => c.headers.get("idempotency-key"));
  assertEquals(keys.length, 6);
  assertEquals(keys[0], keys[1]);
  assertEquals(new Set([keys[0], keys[2], keys[3], keys[4]]).size, 4);
  // Without a nonce, identical requests in the same window collapse.
  assertEquals(keys[4], keys[5]);
});

Deno.test("invoice_checkout: Stripe outages map to service_unavailable", async () => {
  const f = fixture();
  f.db.http.on(
    "POST",
    `${STRIPE}/checkout/sessions`,
    () => jsonResponse(stripeErrorBody("api_error", "internal stripe detail"), 500),
  );
  const res = await f.call(checkout);
  const text = await res.text();
  assertEquals(res.status, 503);
  assert(!text.includes("internal stripe detail"));
});

// ---------------------------------------------------------------------------

const deposit = { action: "booking_deposit_checkout", token: JOB_TOKEN };

Deno.test("booking_deposit_checkout: charges the deposit due computed by the database", async () => {
  const f = fixture({ depositDue: 4_321 });
  const res = await f.call(deposit);
  assertEquals(res.status, 200);
  assertEquals(await res.json(), {
    url: "https://checkout.stripe.com/c/pay/cs_test_1",
    expires_at: 1_900_000_000,
    amount_cents: 4_321,
    tip_cents: 0,
    currency: "usd",
  });
  assertEquals(f.rpcCalls.find((c) => c.name === "public_get_booking")?.args, {
    p_token: JOB_TOKEN,
  });
  const session = f.stripe("POST", "/checkout/sessions")[0];
  const form = session?.form;
  assertEquals(session?.headers.get("stripe-account"), ACCT);
  assertMatch(session?.headers.get("idempotency-key") ?? "", /^dcrm:deposit_checkout:/);
  assertEquals(form?.get("line_items[0][price_data][unit_amount]"), "4321");
  assertEquals(form?.get("payment_intent_data[metadata][kind]"), "deposit");
  assertEquals(form?.get("payment_intent_data[metadata][job_id]"), JOB);
  assertEquals(form?.get("payment_intent_data[metadata][invoice_id]"), null);
  assertEquals(form?.get("payment_intent_data[application_fee_amount]"), "108");
  assertEquals(form?.get("success_url"), `https://app.example.com/booking/${JOB_TOKEN}?paid=1`);
  assertEquals(form?.get("cancel_url"), `https://app.example.com/booking/${JOB_TOKEN}?canceled=1`);
});

Deno.test("booking_deposit_checkout: nothing due, closed bookings, unknown tokens", async () => {
  const paid = fixture({ depositDue: 0 });
  assertEquals(await errorOf(await paid.call(deposit)), [409, "conflict", {
    reason: "deposit_not_due",
  }]);
  for (const status of ["cancelled", "no_show", "completed"]) {
    const f = fixture({ job: { status } });
    assertEquals(await errorOf(await f.call(deposit)), [409, "conflict", {
      reason: "booking_closed",
    }]);
  }
  const unknown = fixture();
  assertEquals(
    (await errorOf(
      await unknown.call({ ...deposit, token: "99999999-9999-4999-8999-00000000abcd" }),
    ))
      .slice(0, 2),
    [404, "not_found"],
  );
  // A client amount is rejected outright.
  assertEquals(
    (await errorOf(await unknown.call({ ...deposit, amount_cents: 100 })))[1],
    "validation_failed",
  );
  const off = fixture({ account: { charges_enabled: false } });
  assertEquals((await errorOf(await off.call(deposit)))[2], { reason: "charges_disabled" });
});

Deno.test("public not-found (PT404, 0042) is a 404, like P0002", async () => {
  // The booking disappears between the token lookup and public_get_booking.
  const f = fixture();
  f.db.onRpc("public_get_booking", () => {
    throw new FakeRpcError("PT404", "booking not found", { status: 404 });
  });
  assertEquals((await errorOf(await f.call(deposit))).slice(0, 2), [404, "not_found"]);
  assertEquals(f.stripe("POST", "/checkout/sessions").length, 0);
  for (const code of ["PT404", "P0002"]) {
    const mapped = rpcError("public_get_invoice", { code, message: "invoice not found" }, {
      notFound: "Invoice not found.",
    });
    assertEquals([(mapped as { code?: string }).code, mapped.message], [
      "not_found",
      "Invoice not found.",
    ]);
  }
});

Deno.test("booking_deposit_checkout: never charges more than the job's invoice still owes", async () => {
  // Job $120 with a $100 deposit; the invoice created from it was then
  // discounted to $90 (allowed while nothing is paid). The deposit lands on
  // that invoice, so only $90 may be collected.
  for (const status of ["open", "draft"]) {
    const f = fixture({ depositDue: 10_000, invoice: { status, balance_cents: 9_000 } });
    const res = await f.call(deposit);
    assertEquals(res.status, 200);
    assertEquals((await res.json()).amount_cents, 9_000);
    const form = f.stripe("POST", "/checkout/sessions")[0]?.form;
    assertEquals(form?.get("line_items[0][price_data][unit_amount]"), "9000");
    assertEquals(form?.get("payment_intent_data[metadata][kind]"), "deposit");
  }
  // The deposit share still below the invoice balance is charged as is.
  const below = fixture({ depositDue: 2_000, invoice: { status: "open", balance_cents: 9_000 } });
  assertEquals((await (await below.call(deposit)).json()).amount_cents, 2_000);
});

Deno.test("booking_deposit_checkout: nothing to charge once the job's invoice is paid", async () => {
  // Job $300 / deposit $100; the invoice was cut to $80 and paid in full.
  // The job-based deposit still reads $20 due, but the invoice owes nothing.
  for (
    const invoice of [
      { status: "paid", balance_cents: 0 },
      { status: "partially_paid", balance_cents: 0 },
      { status: "open", balance_cents: -500 },
    ]
  ) {
    const f = fixture({ depositDue: 2_000, invoice });
    assertEquals(await errorOf(await f.call(deposit)), [409, "conflict", {
      reason: "deposit_not_due",
    }]);
    assertEquals(f.stripe("POST", "/checkout/sessions").length, 0);
  }
});

Deno.test("booking_deposit_checkout: a void invoice or no invoice leaves the deposit uncapped", async () => {
  for (const invoice of [{ status: "void", balance_cents: 0 }, { job_id: null }]) {
    const f = fixture({ depositDue: 5_000, invoice });
    const res = await f.call(deposit);
    assertEquals(res.status, 200);
    assertEquals((await res.json()).amount_cents, 5_000);
  }
});

// ---------------------------------------------------------------------------
// One live, short-lived session per invoice / booking
// ---------------------------------------------------------------------------

function openSession(id: string, metadata: Record<string, string>, extra = {}) {
  return {
    id,
    object: "checkout.session",
    status: "open",
    mode: "payment",
    customer: "cus_1Saved",
    metadata: { shop_id: SHOP, ...metadata },
    ...extra,
  };
}

Deno.test("invoice_checkout: sessions close within ~40 minutes and the expiry is stable per key", async () => {
  const f = fixture();
  await (await f.call(checkout)).body?.cancel();
  await (await f.call(checkout)).body?.cancel();
  await (await f.call({ ...checkout, request_nonce: "nonce-0001" })).body?.cancel();
  const calls = f.stripe("POST", "/checkout/sessions");
  const expiries = calls.map((c) => Number(c.form.get("expires_at")));
  const nowS = Math.floor(NOW / 1000);
  for (const at of expiries) {
    assert(at >= nowS + 30 * 60 + 60, `expires_at ${at} is under Stripe's 30-minute minimum`);
    assert(at <= nowS + 45 * 60, `expires_at ${at} leaves a stale link open too long`);
  }
  // Same key -> same parameters (an idempotent replay never mismatches).
  assertEquals(calls[0]?.headers.get("idempotency-key"), calls[1]?.headers.get("idempotency-key"));
  assertEquals(expiries[0], expiries[1]);
  const deposit = fixture();
  await (await deposit.call({ action: "booking_deposit_checkout", token: JOB_TOKEN })).body
    ?.cancel();
  assert(Number(deposit.stripe("POST", "/checkout/sessions")[0]?.form.get("expires_at")) > 0);
});

Deno.test("invoice_checkout: a new pay link expires the invoice's older links and its job's deposit links only", async () => {
  const f = fixture({
    customer: { stripe_customer_id: "cus_1Saved" },
    sessions: [
      openSession("cs_1Phone", { invoice_id: INVOICE, kind: "payment" }),
      openSession("cs_test_1", { invoice_id: INVOICE, kind: "payment" }), // the one returned
      openSession("cs_1Deposit", { job_id: JOB, kind: "deposit" }),
      openSession("cs_1OtherDeposit", {
        job_id: "dddddddd-dddd-4ddd-8ddd-00000000000f",
        kind: "deposit",
      }),
      openSession("cs_1Other", {
        invoice_id: "eeeeeeee-eeee-4eee-8eee-00000000000f",
        kind: "payment",
      }),
      openSession("cs_1Foreign", {
        shop_id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
        invoice_id: INVOICE,
        kind: "payment",
      }),
    ],
  });
  const res = await f.call(checkout);
  assertEquals(res.status, 200);
  await res.body?.cancel();
  assertEquals(f.sessions.map((x) => [x.id, x.status]), [
    ["cs_1Phone", "expired"],
    ["cs_test_1", "open"],
    ["cs_1Deposit", "expired"],
    ["cs_1OtherDeposit", "open"],
    ["cs_1Other", "open"],
    ["cs_1Foreign", "open"],
  ]);
  const list = f.stripe("GET", "/checkout/sessions")[0];
  assertEquals(list?.headers.get("stripe-account"), ACCT);
  assertEquals(list?.url.searchParams.get("customer"), "cus_1Saved");
  assertEquals(list?.url.searchParams.get("status"), "open");
  const expire = f.stripe("POST", "/checkout/sessions/cs_1Phone/expire")[0];
  assertEquals(expire?.headers.get("stripe-account"), ACCT);
  assert(expire?.headers.get("idempotency-key")?.startsWith("dcrm:checkout_expire:"));
});

Deno.test("booking_deposit_checkout: a new deposit link expires the booking's older deposit and invoice links", async () => {
  const f = fixture({
    customer: { stripe_customer_id: "cus_1Saved" },
    sessions: [
      openSession("cs_1OldDeposit", { job_id: JOB, kind: "deposit" }),
      openSession("cs_1Invoice", { invoice_id: INVOICE, job_id: JOB, kind: "payment" }),
      openSession("cs_1OtherJobInvoice", {
        invoice_id: "eeeeeeee-eeee-4eee-8eee-00000000000f",
        job_id: "dddddddd-dddd-4ddd-8ddd-00000000000f",
        kind: "payment",
      }),
    ],
  });
  await (await f.call(deposit)).body?.cancel();
  // The job's invoice link already covers the deposit share of the balance.
  assertEquals(f.sessions.map((x) => x.status), ["expired", "expired", "open"]);
});

// Stripe's idempotency layer replays the FIRST response under a key (the
// creation-time body: open, with its url), never the session's current
// state, so these replays look open and only the retrieve tells the truth.
function replayOpen(f: ReturnType<typeof fixture>, id: string, current: string) {
  f.sessions.push({
    ...openSession(id, { invoice_id: INVOICE, kind: "payment" }),
    status: current,
  });
  f.db.http.once("POST", `${STRIPE}/checkout/sessions`, () =>
    jsonResponse({
      id,
      object: "checkout.session",
      status: "open",
      url: `https://checkout.stripe.com/c/pay/${id}`,
      expires_at: 1_900_000_000,
    }));
}

Deno.test("invoice_checkout: a replayed session that was expired since is replaced", async () => {
  const f = fixture({ customer: { stripe_customer_id: "cus_1Saved" } });
  replayOpen(f, "cs_1Expired", "expired");
  const res = await f.call(checkout);
  assertEquals((await res.json()).url, "https://checkout.stripe.com/c/pay/cs_test_1");
  const keys = f.stripe("POST", "/checkout/sessions").map((c) => c.headers.get("idempotency-key"));
  assertEquals(keys.length, 2);
  assert(keys[0] !== keys[1]);
  assertEquals(f.stripe("GET", "/checkout/sessions/cs_1Expired").length, 1);
});

Deno.test("invoice_checkout: a replayed session that was already paid is 409, never a second link", async () => {
  const f = fixture({ customer: { stripe_customer_id: "cus_1Saved" } });
  replayOpen(f, "cs_1Paid", "complete");
  assertEquals((await errorOf(await f.call(checkout))).slice(0, 3), [
    409,
    "conflict",
    { reason: "payment_in_progress" },
  ]);
  assertEquals(f.stripe("POST", "/checkout/sessions").length, 1);
});

Deno.test("public pay links use the account's enabled methods and save cards (P-31)", async () => {
  const f = fixture();
  await (await f.call(checkout)).body?.cancel();
  await (await f.call(deposit)).body?.cancel();
  const creates = f.stripe("POST", "/checkout/sessions");
  assertEquals(creates.length, 2);
  for (const call of creates) {
    // dynamic payment methods: cards and wallets always, ACH / pay-later when enabled
    assertEquals(call.form.get("payment_method_types[0]"), null);
    assertEquals(call.form.get("payment_method_options[card][setup_future_usage]"), "off_session");
    assertEquals(call.form.get("payment_intent_data[setup_future_usage]"), null);
    // Link is its own payment method type that the card options would not
    // save: it is not offered, so a paid link always leaves a card on file
    assertEquals(call.form.get("wallet_options[link][display]"), "never");
  }
});

// ---------------------------------------------------------------------------
// quote_deposit_checkout (P-16)
// ---------------------------------------------------------------------------

const QUOTE = "70000000-0000-4000-8000-000000000001";
const QUOTE_TOKEN = "99999999-9999-4999-8999-0000000000a1";
const quoteDeposit = { action: "quote_deposit_checkout", token: QUOTE_TOKEN };

function scheduledQuote(extra: Record<string, unknown> = {}) {
  return {
    id: QUOTE,
    shop_id: SHOP,
    public_token: QUOTE_TOKEN,
    customer_id: CUSTOMER,
    status: "converted",
    converted_job_id: JOB,
    self_scheduled_at: "2026-09-27T11:00:00.000Z",
    ...extra,
  };
}

Deno.test("quote_deposit_checkout: the self-scheduled job's deposit, back to the quote page", async () => {
  const f = fixture({ quotes: [scheduledQuote()] });
  const res = await f.call({ ...quoteDeposit, request_nonce: "quote-0001" });
  assertEquals(await res.json(), {
    url: "https://checkout.stripe.com/c/pay/cs_test_1",
    expires_at: 1_900_000_000,
    amount_cents: 5_000,
    tip_cents: 0,
    currency: "usd",
  });
  // the deposit due comes from the booking summary of the quote's job
  assertEquals(
    f.rpcCalls.find((c) => c.name === "public_get_booking")?.args,
    { p_token: JOB_TOKEN },
  );
  const form = f.stripe("POST", "/checkout/sessions")[0]?.form;
  assertEquals(form?.get("line_items[0][price_data][unit_amount]"), "5000");
  assertEquals(form?.get("payment_method_types[0]"), null);
  assertEquals(form?.get("payment_method_options[card][setup_future_usage]"), "off_session");
  assertEquals(form?.get("wallet_options[link][display]"), "never");
  for (const prefix of ["payment_intent_data[metadata]", "metadata"]) {
    assertEquals(form?.get(`${prefix}[kind]`), "deposit");
    assertEquals(form?.get(`${prefix}[job_id]`), JOB);
    assertEquals(form?.get(`${prefix}[quote_id]`), QUOTE);
    assertEquals(form?.get(`${prefix}[source]`), "quote_deposit_checkout");
  }
  assertEquals(form?.get("success_url"), `https://app.example.com/q/${QUOTE_TOKEN}?paid=1`);
  assertEquals(form?.get("cancel_url"), `https://app.example.com/q/${QUOTE_TOKEN}?canceled=1`);
  assert(f.db.requests.every((r) => r.role === "service_role"));
});

Deno.test("quote_deposit_checkout: only a quote the customer scheduled on its page", async () => {
  // converted by staff (no self_scheduled_at): the job is never exposed here
  const staff = fixture({ quotes: [scheduledQuote({ self_scheduled_at: null })] });
  assertEquals(await errorOf(await staff.call(quoteDeposit)), [409, "conflict", {
    reason: "not_scheduled",
  }]);
  // approved but not scheduled yet
  const approved = fixture({
    quotes: [
      scheduledQuote({ status: "approved", converted_job_id: null, self_scheduled_at: null }),
    ],
  });
  assertEquals((await errorOf(await approved.call(quoteDeposit)))[2], { reason: "not_scheduled" });
  // drafts and unknown tokens are not found
  const draft = fixture({ quotes: [scheduledQuote({ status: "draft" })] });
  assertEquals((await errorOf(await draft.call(quoteDeposit)))[0], 404);
  const unknown = fixture({ quotes: [] });
  assertEquals((await errorOf(await unknown.call(quoteDeposit)))[0], 404);
  assertEquals(
    (await errorOf(await unknown.call({ ...quoteDeposit, token: "nope" })))[1],
    "validation_failed",
  );
  for (const f of [staff, approved, draft, unknown]) {
    assertEquals(f.stripe("POST", "/checkout/sessions").length, 0);
  }
});

Deno.test("quote_deposit_checkout: a job moved to another customer is not offered", async () => {
  // Staff moved the self-scheduled job to another customer of the shop: the
  // old quote link must not open a Checkout on that customer (their Stripe
  // customer, email and saved card), nor expire their own deposit links —
  // the same rule as money_public_quote_json (0067).
  const moved = fixture({
    quotes: [scheduledQuote()],
    job: { customer_id: "cccccccc-cccc-4ccc-8ccc-000000000003" },
  });
  assertEquals(await errorOf(await moved.call(quoteDeposit)), [409, "conflict", {
    reason: "booking_closed",
  }]);
  assertEquals(moved.stripeCalls().length, 0);
  assertEquals(moved.rpcCalls.filter((c) => c.name === "public_get_booking").length, 0);
});

Deno.test("quote_deposit_checkout: the booking deposit rules apply", async () => {
  // a payment on its way (card attempt, ACH processing) blocks a second one
  const pending = fixture({ quotes: [scheduledQuote()], depositPending: true });
  assertEquals((await errorOf(await pending.call(quoteDeposit)))[2], {
    reason: "payment_in_progress",
  });
  // nothing due
  const paid = fixture({ quotes: [scheduledQuote()], depositDue: 0 });
  assertEquals((await errorOf(await paid.call(quoteDeposit)))[2], { reason: "deposit_not_due" });
  // a cancelled appointment takes no deposit
  const cancelled = fixture({ quotes: [scheduledQuote()], job: { status: "cancelled" } });
  assertEquals((await errorOf(await cancelled.call(quoteDeposit)))[2], {
    reason: "booking_closed",
  });
  // strict body: no amounts from the client
  assertEquals(
    (await errorOf(await paid.call({ ...quoteDeposit, amount_cents: 100 })))[1],
    "validation_failed",
  );
});

// ---------------------------------------------------------------------------
// Multi-job (grouped) invoices (P-7) and ACH still clearing (P-31)
// ---------------------------------------------------------------------------

const GROUPED = "eeeeeeee-eeee-4eee-8eee-0000000000f1";
const JOB2 = "dddddddd-dddd-4ddd-8ddd-000000000002";

function grouped(extra: Record<string, unknown> = {}) {
  return fixture({
    customer: { stripe_customer_id: "cus_1Saved" },
    // the single-job invoice is void; the job is billed on a grouped invoice
    invoice: { status: "void" },
    extraInvoices: [{
      id: GROUPED,
      shop_id: SHOP,
      number: 2100,
      job_id: null,
      customer_id: CUSTOMER,
      status: "open",
      balance_cents: 3_000,
      public_token: "99999999-9999-4999-8999-0000000000f1",
    }],
    extraJobs: [{
      id: JOB2,
      shop_id: SHOP,
      number: 1002,
      customer_id: CUSTOMER,
      status: "completed",
      public_token: "99999999-9999-4999-8999-0000000000f2",
    }],
    invoiceJobs: [
      {
        id: "31000000-0000-4000-8000-0000000000f1",
        shop_id: SHOP,
        invoice_id: GROUPED,
        job_id: JOB,
        voided: false,
      },
      {
        id: "31000000-0000-4000-8000-0000000000f2",
        shop_id: SHOP,
        invoice_id: GROUPED,
        job_id: JOB2,
        voided: false,
      },
    ],
    ...extra,
  });
}

Deno.test("booking_deposit_checkout: capped by the job's grouped invoice", async () => {
  const f = grouped();
  const res = await f.call(deposit);
  assertEquals((await res.json()).amount_cents, 3_000);
});

Deno.test("invoice_checkout: a grouped invoice expires every billed job's deposit links", async () => {
  const f = grouped({
    sessions: [
      openSession("cs_1Dep1", { job_id: JOB, kind: "deposit" }),
      openSession("cs_1Dep2", { job_id: JOB2, kind: "deposit" }),
      openSession("cs_1Other", { job_id: "dddddddd-dddd-4ddd-8ddd-000000000099", kind: "deposit" }),
    ],
  });
  const res = await f.call({
    action: "invoice_checkout",
    token: "99999999-9999-4999-8999-0000000000f1",
  });
  assertEquals((await res.json()).amount_cents, 3_000);
  const expired = f.stripe("POST", "/checkout/sessions/:id/expire").map((c) =>
    c.url.pathname.split("/").at(-2)
  );
  assertEquals(expired.sort(), ["cs_1Dep1", "cs_1Dep2"]);
  const form = f.stripe("POST", "/checkout/sessions")[0]?.form;
  // a grouped invoice has no single job to tag
  assertEquals(form?.get("metadata[job_id]"), null);
  assertEquals(form?.get("metadata[invoice_id]"), GROUPED);
});

Deno.test("invoice_checkout: ACH debits still clearing are not charged again", async () => {
  const processing = {
    id: "ffffffff-ffff-4fff-8fff-00000000a0c2",
    shop_id: SHOP,
    invoice_id: INVOICE,
    job_id: JOB,
    customer_id: CUSTOMER,
    kind: "payment",
    method: "ach_debit",
    status: "processing",
    amount_cents: 2_345,
    tip_cents: 0,
    refunded_cents: 0,
    stripe_payment_intent_id: "pi_1Ach",
  };
  const f = fixture({ payments: [processing] });
  const res = await f.call(checkout);
  assertEquals((await res.json()).amount_cents, 10_000);
  assertEquals(
    f.stripe("POST", "/checkout/sessions")[0]?.form.get("line_items[0][price_data][unit_amount]"),
    "10000",
  );
  // the whole balance clearing: nothing to pay now
  const covered = fixture({ payments: [{ ...processing, amount_cents: 12_345 }] });
  assertEquals((await errorOf(await covered.call(checkout)))[2], {
    reason: "payment_in_progress",
  });
  // a deposit is capped the same way (its invoice owes 10,000 not yet on its way)
  const dep = fixture({ payments: [{ ...processing, amount_cents: 12_000 }], depositDue: 5_000 });
  assertEquals((await (await dep.call(deposit)).json()).amount_cents, 345);
});
