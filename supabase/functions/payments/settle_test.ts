/**
 * Regression tests: technicians never get saved-card access through
 * payment_sheet, and an abandoned PaymentSheet can never lock an invoice
 * (a new sheet supersedes it, cancel_open_payments releases it, the cron
 * sweep abandons it).
 */
import { assert, assertEquals } from "@std/assert";
import { jsonRequest, jsonResponse, type Row } from "../_shared/testing/mod.ts";
import {
  ACCT,
  CUSTOMER,
  errorOf,
  fixture,
  type FixtureOptions,
  INVOICE,
  JOB,
  NOW,
  SHOP,
  STRIPE,
} from "./test_fixtures.ts";

const sheet = { action: "payment_sheet", shop_id: SHOP, invoice_id: INVOICE };
const release = { action: "cancel_open_payments", shop_id: SHOP, invoice_id: INVOICE };

let rowSeq = 100;

function pendingRow(pi: string, extra: Row = {}): Row {
  rowSeq += 1;
  return {
    id: `ffffffff-ffff-4fff-8fff-${String(rowSeq).padStart(12, "0")}`,
    shop_id: SHOP,
    invoice_id: INVOICE,
    job_id: JOB,
    customer_id: CUSTOMER,
    kind: "payment",
    method: "card",
    status: "pending",
    amount_cents: 12_345,
    tip_cents: 0,
    refunded_cents: 0,
    stripe_payment_intent_id: pi,
    created_at: new Date(NOW - 5 * 60_000).toISOString(),
    ...extra,
  };
}

function sheetIntent(status: string, extra: Row = {}): Row {
  return {
    status,
    amount: 12_345,
    metadata: { shop_id: SHOP, invoice_id: INVOICE, source: "payment_sheet", request_key: "other" },
    ...extra,
  };
}

function withOpenSheet(status = "requires_payment_method", extra: FixtureOptions = {}) {
  return fixture({
    payments: [pendingRow("pi_1Old")],
    intents: { pi_1Old: sheetIntent(status) },
    ...extra,
  });
}

function upserts(f: ReturnType<typeof fixture>, pi: string) {
  return f.rpcCalls.filter((c) =>
    c.name === "upsert_stripe_payment" && c.args.p_payment_intent_id === pi
  )
    .map((c) => c.args);
}

// ---------------------------------------------------------------------------
// #1 technicians: no customer, no ephemeral key, no saved cards
// ---------------------------------------------------------------------------

Deno.test("payment_sheet: a technician's sheet has no Stripe customer and no ephemeral key", async () => {
  const f = fixture({ customer: { stripe_customer_id: "cus_1Saved" } });
  const res = await f.call(sheet, "tech");
  assertEquals(res.status, 200);
  const body = await res.json();
  assertEquals(f.stripe("POST", "/ephemeral_keys").length, 0);
  assertEquals("ephemeral_key_secret" in body, false);
  assertEquals("customer_id" in body, false);
  assertEquals(body.payment_intent_client_secret, "pi_1New_secret_abc");
  const pi = f.stripe("POST", "/payment_intents")[0];
  assertEquals(pi?.form.get("customer"), null);
  assertEquals(pi?.form.get("setup_future_usage"), null);
  // The saved-card customer is never even looked up in Stripe.
  assertEquals(f.stripe("GET", "/customers/:id").length, 0);
  assertEquals(f.stripe("POST", "/customers").length, 0);
});

Deno.test("payment_sheet: manager and technician requests never share an idempotency key", async () => {
  const f = fixture({ customer: { stripe_customer_id: "cus_1Saved" } });
  await (await f.call(sheet, "manager")).body?.cancel();
  await (await f.call(sheet, "tech")).body?.cancel();
  const keys = f.stripe("POST", "/payment_intents").map((c) => c.headers.get("idempotency-key"));
  assertEquals(keys.length, 2);
  assert(keys[0] !== keys[1]);
  assertEquals(f.stripe("POST", "/ephemeral_keys").length, 1);
});

// ---------------------------------------------------------------------------
// #2/#4 abandoned sheets
// ---------------------------------------------------------------------------

Deno.test("payment_sheet: a new sheet cancels the invoice's abandoned sheet first", async () => {
  const f = withOpenSheet();
  const res = await f.call(sheet, "manager");
  assertEquals(res.status, 200);
  await res.body?.cancel();
  const cancel = f.stripe("POST", "/payment_intents/pi_1Old/cancel")[0];
  assertEquals(cancel?.headers.get("stripe-account"), ACCT);
  assertEquals(cancel?.form.get("cancellation_reason"), "abandoned");
  assertEquals(upserts(f, "pi_1Old").map((a) => a.p_status), ["cancelled"]);
  assertEquals(upserts(f, "pi_1New").map((a) => a.p_status), ["pending"]);
});

Deno.test("payment_sheet: a payment already processing blocks a second sheet (409)", async () => {
  const f = withOpenSheet("processing");
  assertEquals((await errorOf(await f.call(sheet, "manager"))).slice(0, 3), [
    409,
    "conflict",
    { reason: "payment_in_progress" },
  ]);
  assertEquals(f.stripe("POST", "/payment_intents").length, 0);
  assertEquals(f.stripe("POST", "/payment_intents/:id/cancel").length, 0);
});

Deno.test("payment_sheet: an earlier sheet that already succeeded is recorded and the rest is charged", async () => {
  const f = fixture({
    payments: [pendingRow("pi_1Old", { amount_cents: 5_000 })],
    intents: {
      pi_1Old: sheetIntent("succeeded", {
        amount: 5_000,
        latest_charge: { id: "ch_1Old", object: "charge", created: 1_790_000_000 },
      }),
    },
  });
  f.db.onRpc("upsert_stripe_payment", (args) => {
    f.rpcCalls.push({ name: "upsert_stripe_payment", args });
    if (args.p_status === "succeeded") {
      // invoices_compute: the recorded money lowers the balance.
      f.db.seed(
        "invoices",
        f.db.table("invoices").map((i) => i.id === INVOICE ? { ...i, balance_cents: 7_345 } : i),
      );
    }
    return { id: "50000000-0000-4000-8000-000000000001", status: args.p_status };
  });
  const res = await f.call(sheet, "manager");
  assertEquals((await res.json()).amount_cents, 7_345);
  const recorded = upserts(f, "pi_1Old")[0];
  assertEquals(recorded?.p_status, "succeeded");
  assertEquals(recorded?.p_amount_cents, 5_000);
  assertEquals(recorded?.p_charge_id, "ch_1Old");
  assertEquals(f.stripe("POST", "/payment_intents")[0]?.form.get("amount"), "7345");
});

Deno.test("payment_sheet: a retry of the same request keeps its own intent", async () => {
  const f = fixture();
  await (await f.call({ ...sheet, request_nonce: "nonce-0001" }, "manager")).body?.cancel();
  const key = f.stripe("POST", "/payment_intents")[0]?.headers.get("idempotency-key") ?? "";
  assertEquals(f.stripe("POST", "/payment_intents")[0]?.form.get("metadata[request_key]"), key);
  // The first response was lost: the row and intent exist when the retry arrives.
  f.db.seed("payments", [...f.db.table("payments"), pendingRow("pi_1New")]);
  f.intents.pi_1New = sheetIntent("requires_payment_method", {
    metadata: { shop_id: SHOP, source: "payment_sheet", request_key: key },
  });
  const res = await f.call({ ...sheet, request_nonce: "nonce-0001" }, "manager");
  assertEquals((await res.json()).payment_intent_id, "pi_1New");
  assertEquals(f.stripe("POST", "/payment_intents/:id/cancel").length, 0);
  const keys = f.stripe("POST", "/payment_intents").map((c) => c.headers.get("idempotency-key"));
  assertEquals(keys, [key, key]);
  // The kept intent was looked up (not blindly re-created or cancelled).
  assert(f.stripe("GET", "/payment_intents/pi_1New").length >= 1);
});

Deno.test("payment_sheet: an idempotent replay of a cancelled intent gets a fresh one", async () => {
  // Stripe replays the creation-time body (requires_payment_method) under
  // the key; the intent itself was cancelled since (a newer sheet).
  const f = fixture({ intents: { pi_1Cancelled: sheetIntent("canceled") } });
  f.db.http.once("POST", `${STRIPE}/payment_intents`, () =>
    jsonResponse({
      id: "pi_1Cancelled",
      object: "payment_intent",
      status: "requires_payment_method",
      client_secret: "pi_1Cancelled_secret",
    }));
  const res = await f.call(sheet, "manager");
  assertEquals((await res.json()).payment_intent_id, "pi_1New");
  const keys = f.stripe("POST", "/payment_intents").map((c) => c.headers.get("idempotency-key"));
  assertEquals(keys.length, 2);
  assert(keys[0] !== keys[1]);
  assertEquals(upserts(f, "pi_1Cancelled").length, 0);
});

Deno.test("cancel_open_payments: releases the invoice (sheet cancelled, pay + deposit links expired)", async () => {
  const session = (id: string, metadata: Row, status = "open") => ({
    id,
    object: "checkout.session",
    status,
    mode: "payment",
    customer: "cus_1Saved",
    metadata: { shop_id: SHOP, ...metadata },
  });
  const f = withOpenSheet("requires_action", {
    customer: { stripe_customer_id: "cus_1Saved" },
    sessions: [
      session("cs_1Invoice", { invoice_id: INVOICE, kind: "payment" }),
      session("cs_1Deposit", { job_id: JOB, kind: "deposit" }),
      session("cs_1OtherInvoice", {
        invoice_id: "eeeeeeee-eeee-4eee-8eee-00000000000f",
        kind: "payment",
      }),
      session("cs_1OtherDeposit", {
        job_id: "dddddddd-dddd-4ddd-8ddd-00000000000f",
        kind: "deposit",
      }),
    ],
  });
  const res = await f.call(release, "tech");
  assertEquals(await res.json(), {
    invoice_id: INVOICE,
    job_id: JOB,
    cancelled: 1,
    succeeded: 0,
    in_progress: 0,
    sessions_expired: 2,
  });
  // The job's deposit link pays toward this invoice too (payments_before_write).
  assertEquals(f.sessions.map((x) => x.status), ["expired", "expired", "open", "open"]);
  assertEquals(
    f.stripe("POST", "/checkout/sessions/cs_1Invoice/expire")[0]?.headers.get("stripe-account"),
    ACCT,
  );
  assertEquals(upserts(f, "pi_1Old").map((a) => a.p_status), ["cancelled"]);
  assertEquals(f.intents.pi_1Old?.status, "canceled");
});

Deno.test("cancel_open_payments: processing payments and intents of other flows are left alone", async () => {
  const f = fixture({
    payments: [pendingRow("pi_1Busy"), pendingRow("pi_1Checkout")],
    intents: {
      pi_1Busy: sheetIntent("processing"),
      pi_1Checkout: sheetIntent("requires_action", {
        metadata: { shop_id: SHOP, source: "invoice_checkout" },
      }),
    },
  });
  const body = await (await f.call(release, "manager")).json();
  assertEquals([body.cancelled, body.in_progress], [0, 2]);
  assertEquals(f.stripe("POST", "/payment_intents/:id/cancel").length, 0);
  assertEquals(f.rpcCalls.filter((c) => c.name === "upsert_stripe_payment").length, 0);
});

Deno.test("cancel_open_payments: a customer who confirms at the same moment wins", async () => {
  const f = withOpenSheet();
  // Stripe refuses the cancel because the intent succeeded meanwhile.
  f.db.http.once("POST", `${STRIPE}/payment_intents/pi_1Old/cancel`, () => {
    const intent = f.intents.pi_1Old;
    if (intent) intent.status = "succeeded";
    return jsonResponse({
      error: {
        type: "invalid_request_error",
        message: "cannot cancel",
        code: "payment_intent_unexpected_state",
      },
    }, 400);
  });
  const body = await (await f.call(release, "manager")).json();
  assertEquals([body.cancelled, body.succeeded], [0, 1]);
  assertEquals(upserts(f, "pi_1Old").map((a) => a.p_status), ["succeeded"]);
});

Deno.test("cancel_open_payments: same callers as payment_sheet", async () => {
  const f = withOpenSheet();
  assertEquals((await errorOf(await f.call(release, "tech2")))[1], "forbidden");
  assertEquals((await errorOf(await f.call(release, "outsider")))[1], "forbidden");
  assertEquals((await errorOf(await f.call(release, "none")))[1], "unauthorized");
  const off = withOpenSheet("requires_payment_method", {
    shop: { techs_can_collect_payments: false },
  });
  assertEquals((await errorOf(await off.call(release, "tech")))[1], "forbidden");
  for (const x of [f, off]) assertEquals(x.stripeCalls().length, 0);
});

Deno.test("charge_saved_card: an open sheet is cancelled before the saved card is charged", async () => {
  const f = withOpenSheet("requires_payment_method", {
    customer: { stripe_customer_id: "cus_1Saved" },
  });
  const res = await f.call(
    { action: "charge_saved_card", shop_id: SHOP, invoice_id: INVOICE },
    "manager",
  );
  assertEquals(res.status, 200);
  await res.body?.cancel();
  assertEquals(upserts(f, "pi_1Old").map((a) => a.p_status), ["cancelled"]);
  const busy = withOpenSheet("processing", { customer: { stripe_customer_id: "cus_1Saved" } });
  assertEquals(
    (await errorOf(
      await busy.call(
        { action: "charge_saved_card", shop_id: SHOP, invoice_id: INVOICE },
        "manager",
      ),
    ))[2],
    { reason: "payment_in_progress" },
  );
  assertEquals(busy.stripe("POST", "/payment_intents").length, 0);
});

// ---------------------------------------------------------------------------
// sweep_payment_sheets (pg_cron)
// ---------------------------------------------------------------------------

function sweepRequest(secret?: string): Request {
  return jsonRequest("payments", { action: "sweep_payment_sheets" }, {
    headers: secret ? { "x-cron-secret": secret } : {},
  });
}

Deno.test("sweep_payment_sheets: abandons stale unconfirmed sheets, leaves fresh and processing ones", async () => {
  const hourAgo = new Date(NOW - 60 * 60_000).toISOString();
  const f = fixture({
    payments: [
      pendingRow("pi_1Stale", { created_at: hourAgo }),
      pendingRow("pi_1Fresh"),
      pendingRow("pi_1Busy", { created_at: hourAgo }),
      pendingRow("pi_1Member", { created_at: hourAgo, kind: "membership" }),
    ],
    intents: {
      pi_1Stale: sheetIntent("requires_payment_method"),
      pi_1Fresh: sheetIntent("requires_payment_method"),
      pi_1Busy: sheetIntent("processing"),
      pi_1Member: sheetIntent("requires_payment_method"),
    },
  });
  const res = await f.handler(sweepRequest("fake-cron-secret-0123456789abcdef"));
  assertEquals(await res.json(), {
    checked: 2,
    succeeded: 0,
    cancelled: 1,
    in_progress: 1,
    unchanged: 0,
    failed: 0,
  });
  assertEquals(f.intents.pi_1Stale?.status, "canceled");
  assertEquals(f.intents.pi_1Fresh?.status, "requires_payment_method");
  assertEquals(f.intents.pi_1Member?.status, "requires_payment_method");
  assertEquals(upserts(f, "pi_1Stale").map((a) => a.p_status), ["cancelled"]);
});

Deno.test("sweep_payment_sheets: requires the cron secret", async () => {
  const f = withOpenSheet();
  for (const secret of [undefined, "wrong-secret-0123456789abcdef"]) {
    const res = await f.handler(sweepRequest(secret));
    assertEquals(res.status, 401);
    await res.body?.cancel();
  }
  const staff = await f.call({ action: "sweep_payment_sheets" }, "owner");
  assertEquals(staff.status, 401);
  await staff.body?.cancel();
  assertEquals(f.stripeCalls().length, 0);
});

Deno.test("sweep_payment_sheets: one failing row never stops the batch", async () => {
  const hourAgo = new Date(NOW - 60 * 60_000).toISOString();
  const f = fixture({
    payments: [
      pendingRow("pi_1Broken", { created_at: hourAgo }),
      pendingRow("pi_1Stale", { created_at: hourAgo }),
    ],
    intents: { pi_1Stale: sheetIntent("requires_payment_method") },
  });
  f.db.http.once(
    "GET",
    `${STRIPE}/payment_intents/pi_1Broken`,
    () => jsonResponse({ error: { type: "api_error", message: "stripe down" } }, 500),
  );
  const body = await (await f.handler(sweepRequest("fake-cron-secret-0123456789abcdef"))).json();
  assertEquals([body.failed, body.cancelled], [1, 1]);
});

Deno.test("cancel_open_payments: a sheet whose card attempt failed can still be released later", async () => {
  const f = withOpenSheet("processing");
  assertEquals((await (await f.call(release, "manager")).json()).in_progress, 1);
  // The attempt was declined: the intent is back to requires_payment_method.
  const intent = f.intents.pi_1Old;
  if (intent) intent.status = "requires_payment_method";
  assertEquals((await (await f.call(release, "manager")).json()).cancelled, 1);
  assertEquals(upserts(f, "pi_1Old").map((a) => a.p_status), ["cancelled"]);
});

// ---------------------------------------------------------------------------
// cancel_open_payments by job (before a job is cancelled or changes customer)
// ---------------------------------------------------------------------------

const releaseJob = { action: "cancel_open_payments", shop_id: SHOP, job_id: JOB };

function jobSessions(): Row[] {
  const session = (id: string, metadata: Row) => ({
    id,
    object: "checkout.session",
    status: "open",
    mode: "payment",
    customer: "cus_1Saved",
    metadata: { shop_id: SHOP, ...metadata },
  });
  return [
    session("cs_1Deposit", { job_id: JOB, kind: "deposit" }),
    session("cs_1Invoice", { invoice_id: INVOICE, job_id: JOB, kind: "payment" }),
    session("cs_1OtherDeposit", {
      job_id: "dddddddd-dddd-4ddd-8ddd-00000000000f",
      kind: "deposit",
    }),
  ];
}

Deno.test("cancel_open_payments (job): the job's sheets, deposit links and invoice links are released", async () => {
  const f = withOpenSheet("requires_payment_method", {
    customer: { stripe_customer_id: "cus_1Saved" },
    sessions: jobSessions(),
  });
  const res = await f.call(releaseJob, "manager");
  assertEquals(await res.json(), {
    invoice_id: INVOICE,
    job_id: JOB,
    cancelled: 1,
    succeeded: 0,
    in_progress: 0,
    sessions_expired: 2,
  });
  assertEquals(f.sessions.map((x) => x.status), ["expired", "expired", "open"]);
  assertEquals(upserts(f, "pi_1Old").map((a) => a.p_status), ["cancelled"]);
});

Deno.test("cancel_open_payments (job): without an invoice only the deposit links go; processing money is reported", async () => {
  const f = fixture({
    customer: { stripe_customer_id: "cus_1Saved" },
    invoice: { job_id: null },
    sessions: jobSessions(),
    payments: [pendingRow("pi_1Busy", { invoice_id: null, kind: "deposit" })],
    intents: { pi_1Busy: sheetIntent("processing") },
  });
  const body = await (await f.call(releaseJob, "tech")).json();
  assertEquals(body, {
    invoice_id: null,
    job_id: JOB,
    cancelled: 0,
    succeeded: 0,
    in_progress: 1,
    sessions_expired: 1,
  });
  assertEquals(f.sessions.map((x) => x.status), ["expired", "open", "open"]);
});

Deno.test("cancel_open_payments (job): caller rules and input", async () => {
  const f = fixture({ customer: { stripe_customer_id: "cus_1Saved" } });
  // tech2 is not assigned to the job; techs may collect only on their jobs.
  assertEquals((await errorOf(await f.call(releaseJob, "tech2")))[1], "forbidden");
  const noCollect = fixture({ shop: { techs_can_collect_payments: false } });
  assertEquals((await errorOf(await noCollect.call(releaseJob, "tech")))[1], "forbidden");
  assertEquals((await errorOf(await f.call(releaseJob, "outsider")))[1], "forbidden");
  assertEquals(
    (await errorOf(
      await f.call({ ...releaseJob, job_id: "dddddddd-dddd-4ddd-8ddd-00000000000f" }, "manager"),
    )).slice(0, 2),
    [404, "not_found"],
  );
  for (
    const body of [
      { action: "cancel_open_payments", shop_id: SHOP },
      { ...releaseJob, invoice_id: INVOICE },
    ]
  ) {
    assertEquals((await errorOf(await f.call(body, "manager")))[1], "validation_failed");
  }
  // A shop without Stripe has nothing to release.
  const noStripe = fixture({ account: null });
  assertEquals(await (await noStripe.call(releaseJob, "manager")).json(), {
    invoice_id: INVOICE,
    job_id: JOB,
    cancelled: 0,
    succeeded: 0,
    in_progress: 0,
    sessions_expired: 0,
  });
});
