/**
 * Regression tests for the money review findings: retry-safe refunds and
 * saved-card charges, public checkouts that respect money in flight,
 * declined sheets that stay payable, the sweep's fairness, idempotent
 * replays that show creation-time state, and membership links that were
 * already paid. The Stripe fake here replays the FIRST response under an
 * idempotency key, exactly as Stripe documents.
 */
import { assert, assertEquals } from "@std/assert";
import { jsonRequest, jsonResponse, type Row, stripeErrorBody } from "../_shared/testing/mod.ts";
import { chargeKey, refundKey } from "./staff.ts";
import { type PendingCardRow, SWEEP_BATCH, SWEEP_SLOT_MS, sweepBatch } from "./settle.ts";
import {
  CUSTOMER,
  errorOf,
  fixture,
  type FixtureOptions,
  INVOICE,
  INVOICE_TOKEN,
  JOB,
  JOB_TOKEN,
  MEMBERSHIP,
  NOW,
  PAYMENT,
  SHOP,
  STRIPE,
} from "./test_fixtures.ts";

type F = ReturnType<typeof fixture>;

const refundBody = { action: "refund", shop_id: SHOP, payment_id: PAYMENT };
const sheet = { action: "payment_sheet", shop_id: SHOP, invoice_id: INVOICE };
const checkout = { action: "invoice_checkout", token: INVOICE_TOKEN };
const deposit = { action: "booking_deposit_checkout", token: JOB_TOKEN };
const CRON = "fake-cron-secret-0123456789abcdef";
const MINUTE = 60_000;

let rowSeq = 500;

function cardRow(pi: string, extra: Row = {}): Row {
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
    created_at: new Date(NOW - 5 * MINUTE).toISOString(),
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

function upserts(f: F, pi: string): Array<Record<string, unknown>> {
  return f.rpcCalls
    .filter((c) => c.name === "upsert_stripe_payment" && c.args.p_payment_intent_id === pi)
    .map((c) => c.args);
}

function formMetadata(form: URLSearchParams): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [key, value] of form) {
    const m = /^metadata\[([^\]]+)\]$/.exec(key);
    if (m?.[1]) out[m[1]] = value;
  }
  return out;
}

/**
 * Stripe-faithful creates: a new idempotency key creates a new object (kept
 * in the fixture's state, so list / retrieve / expire / cancel see it); a
 * reused key replays the first response body, whatever happened since.
 */
function replayingStripe(f: F): void {
  const replays = new Map<string, Row>();
  let seq = 0;
  f.db.http.on("POST", `${STRIPE}/checkout/sessions`, (_req, { call }) => {
    const key = `cs:${call.headers.get("idempotency-key") ?? ""}`;
    const cached = replays.get(key);
    if (cached) return jsonResponse(cached);
    seq += 1;
    const id = `cs_test_R${seq}`;
    const session = {
      id,
      object: "checkout.session",
      status: "open",
      mode: call.form.get("mode"),
      customer: call.form.get("customer"),
      metadata: formMetadata(call.form),
      url: `https://checkout.stripe.com/c/pay/${id}`,
      expires_at: 1_900_000_000,
    };
    f.sessions.push({ ...session });
    replays.set(key, { ...session });
    return jsonResponse(session);
  });
  f.db.http.on("POST", `${STRIPE}/payment_intents`, (_req, { call }) => {
    const key = `pi:${call.headers.get("idempotency-key") ?? ""}`;
    const cached = replays.get(key);
    if (cached) return jsonResponse(cached);
    seq += 1;
    const id = `pi_R${seq}`;
    const intent = {
      id,
      object: "payment_intent",
      amount: Number(call.form.get("amount")),
      status: "requires_payment_method",
      client_secret: `${id}_secret_x`,
      latest_charge: null,
      metadata: formMetadata(call.form),
    };
    f.intents[id] = { ...intent };
    replays.set(key, { ...intent });
    return jsonResponse(intent);
  });
}

/** upsert_stripe_payment writes the payments table (as the real RPC does). */
function recordingPayments(f: F): void {
  f.db.onRpc("upsert_stripe_payment", (args) => {
    f.rpcCalls.push({ name: "upsert_stripe_payment", args });
    const rows = f.db.table("payments");
    const existing = rows.find((r) => r.stripe_payment_intent_id === args.p_payment_intent_id);
    if (existing) {
      f.db.seed(
        "payments",
        rows.map((r) => r === existing ? { ...r, status: args.p_status } : r),
      );
    } else {
      f.db.seed("payments", [
        ...rows,
        cardRow(String(args.p_payment_intent_id), {
          status: args.p_status,
          amount_cents: args.p_amount_cents,
          tip_cents: args.p_tip_cents,
          created_at: new Date(NOW).toISOString(),
        }),
      ]);
    }
    return { id: "50000000-0000-4000-8000-000000000001", status: args.p_status };
  });
}

function charge(amountRefunded: number): Row {
  return {
    status: "succeeded",
    latest_charge: {
      id: "ch_1Paid",
      object: "charge",
      amount: 10_500,
      amount_refunded: amountRefunded,
      application_fee_amount: null,
    },
  };
}

// ---------------------------------------------------------------------------
// #1 a retry after a FAILED refund creates a real refund
// ---------------------------------------------------------------------------

Deno.test("refund: a retry after the refund failed creates a new refund, never replays the failed one", async () => {
  for (const nonce of [undefined, "refund-nonce-0001"]) {
    const f = fixture();
    const body = { ...refundBody, ...(nonce ? { request_nonce: nonce } : {}) };
    const first = await f.call(body, "admin");
    assertEquals((await first.json()).refund_id, "re_1");
    // The card was closed: the refund failed after Stripe accepted it,
    // charge.amount_refunded went back to 0 and the webhook reversed the row.
    const failed = f.refunds[0];
    if (failed) failed.status = "failed";
    const retry = await f.call(body, "admin");
    assertEquals(retry.status, 200);
    const made = await retry.json();
    assertEquals([made.refund_id, made.refund_status, made.amount_cents], [
      "re_2",
      "succeeded",
      10_500,
    ]);
    const keys = f.stripe("POST", "/refunds").map((c) => c.headers.get("idempotency-key"));
    assertEquals(keys.length, 2);
    assert(keys[0] !== keys[1], "the retry must not reuse the failed refund's key");
    assertEquals(f.refunds.map((r) => r.status), ["failed", "succeeded"]);
  }
});

// ---------------------------------------------------------------------------
// #5 a retry after a SUCCESSFUL refund never refunds twice
// ---------------------------------------------------------------------------

Deno.test("refund: a retry of the same nonce after the refund went through refunds nothing new", async () => {
  const f = fixture();
  const body = { ...refundBody, amount_cents: 5_000, request_nonce: "refund-nonce-0001" };
  const first = await (await f.call(body, "owner")).json();
  assertEquals(first.refunded_cents_total, 5_000);
  // Response lost; Stripe's charge already includes the refund.
  f.intents.pi_1Paid = charge(5_000);
  const retry = await f.call(body, "owner");
  assertEquals(retry.status, 200);
  const again = await retry.json();
  assertEquals([again.refund_id, again.refunded_cents_total], [first.refund_id, 5_000]);
  assertEquals(f.refunds.length, 1);
  // A new attempt (new nonce) is a new refund.
  const second = await (await f.call({ ...body, request_nonce: "refund-nonce-0002" }, "owner"))
    .json();
  assertEquals([second.refund_id, second.refunded_cents_total], ["re_2", 10_000]);
  assertEquals(f.refunds.length, 2);
});

Deno.test("refund: without a nonce a repeat across the 10-minute bucket boundary refunds nothing new (409)", async () => {
  let clock = NOW - 30_000; // the previous idempotency bucket
  const f = fixture({ now: () => clock });
  const body = { ...refundBody, amount_cents: 3_000 };
  const first = await (await f.call(body, "owner")).json();
  f.intents.pi_1Paid = charge(3_000);
  clock = NOW + MINUTE; // next bucket: the key changed
  assertEquals(await errorOf(await f.call(body, "owner")), [409, "conflict", {
    reason: "possible_duplicate_refund",
    refund_id: first.refund_id,
    amount_cents: 3_000,
    refunded_cents_total: 3_000,
  }]);
  assertEquals(f.refunds.length, 1);
  // Long after, the same amount is a deliberate new refund.
  clock = NOW + 11 * MINUTE;
  const later = await (await f.call(body, "owner")).json();
  assertEquals([later.refund_id, later.refunded_cents_total], ["re_2", 6_000]);
});

// ---------------------------------------------------------------------------
// A deliberate second refund of the same amount is never silently dropped
// ---------------------------------------------------------------------------

Deno.test("refund: a second same-amount refund without a nonce is 409, never a silent success", async () => {
  let clock = NOW;
  const f = fixture({ now: () => clock });
  const body = { ...refundBody, amount_cents: 2_000 };
  const first = await f.call(body, "owner");
  assertEquals(first.status, 200);
  assertEquals((await first.json()).refund_id, "re_1");
  f.intents.pi_1Paid = charge(2_000);
  // Three minutes later the owner refunds another $20 (a second complaint).
  clock = NOW + 3 * MINUTE;
  const second = await errorOf(await f.call(body, "owner"));
  assertEquals(second.slice(0, 2), [409, "conflict"]);
  assertEquals((second[2] as { reason: string }).reason, "possible_duplicate_refund");
  assertEquals(f.refunds.length, 1);
  // With a fresh nonce it is a new refund; a retry of that nonce is handed back.
  const withNonce = { ...body, request_nonce: "second-refund-0001" };
  const made = await f.call(withNonce, "owner");
  assertEquals(made.status, 200);
  assertEquals((await made.json()).refund_id, "re_2");
  f.intents.pi_1Paid = charge(4_000);
  const retry = await f.call(withNonce, "owner");
  assertEquals(retry.status, 200);
  assertEquals([(await retry.json()).refund_id, f.refunds.length], ["re_2", 2]);
});

Deno.test("refundKey: keys on the attempt and the failed refunds, never on totals", async () => {
  const a = await refundKey(PAYMENT, 5_000, "refund-nonce-0001", NOW, []);
  assertEquals(await refundKey(PAYMENT, 5_000, "refund-nonce-0001", NOW + 9 * 3_600_000, []), a);
  assert(a !== await refundKey(PAYMENT, 5_000, "refund-nonce-0001", NOW, ["re_1Failed"]));
  assert(a !== await refundKey(PAYMENT, 5_000, "refund-nonce-0002", NOW, []));
  assertEquals(
    await refundKey(PAYMENT, undefined, undefined, NOW, ["re_b", "re_a"]),
    await refundKey(PAYMENT, undefined, undefined, NOW, ["re_a", "re_b"]),
  );
});

// ---------------------------------------------------------------------------
// #4 charge_saved_card: a nonce retry after a partial charge is replayed
// ---------------------------------------------------------------------------

Deno.test("charge_saved_card: a retry with the same nonce after the balance dropped reuses the key", async () => {
  const f = fixture({
    customer: { stripe_customer_id: "cus_1Saved" },
    invoice: { balance_cents: 20_000 },
  });
  const body = {
    action: "charge_saved_card",
    shop_id: SHOP,
    invoice_id: INVOICE,
    amount_cents: 10_000,
    request_nonce: "retry-nonce-0001",
  };
  const first = await f.call(body, "manager");
  assertEquals(first.status, 200);
  await first.body?.cancel();
  // The first charge was recorded (balance lowered) but its response was lost.
  f.db.seed(
    "invoices",
    f.db.table("invoices").map((i) => i.id === INVOICE ? { ...i, balance_cents: 10_000 } : i),
  );
  const retry = await f.call(body, "manager");
  assertEquals(retry.status, 200);
  await retry.body?.cancel();
  const keys = f.stripe("POST", "/payment_intents").map((c) => c.headers.get("idempotency-key"));
  assertEquals(keys.length, 2);
  assertEquals(keys[0], keys[1]);
});

Deno.test("chargeKey: the nonce alone scopes a charge; without one the balance and window do", async () => {
  const at = (balance: number, nonce?: string, now = NOW) =>
    chargeKey(INVOICE, "pm_1Default", 10_000, { nonce, balance, now });
  assertEquals(await at(20_000, "retry-nonce-0001"), await at(10_000, "retry-nonce-0001"));
  assertEquals(
    await at(20_000, "retry-nonce-0001"),
    await at(20_000, "retry-nonce-0001", NOW + 3_600_000),
  );
  assert(await at(20_000) !== await at(10_000));
  assert(await at(20_000) !== await at(20_000, "retry-nonce-0001"));
});

// ---------------------------------------------------------------------------
// #2 / #7 / #10 public checkouts respect money in flight
// ---------------------------------------------------------------------------

Deno.test("invoice_checkout: a card payment still processing blocks a second full-balance link (409)", async () => {
  const f = fixture({
    payments: [cardRow("pi_1Busy")],
    intents: { pi_1Busy: sheetIntent("processing") },
  });
  assertEquals((await errorOf(await f.call(checkout, "anon"))).slice(0, 3), [
    409,
    "conflict",
    { reason: "payment_in_progress" },
  ]);
  assertEquals(f.stripe("POST", "/checkout/sessions").length, 0);
  // Same answer for an async Checkout payment the webhook recorded as pending.
  const async = fixture({
    payments: [cardRow("pi_1Ach")],
    intents: {
      pi_1Ach: {
        status: "processing",
        metadata: { shop_id: SHOP, source: "invoice_checkout" },
      },
    },
  });
  assertEquals((await errorOf(await async.call(checkout)))[2], { reason: "payment_in_progress" });
  assertEquals(async.stripe("POST", "/checkout/sessions").length, 0);
});

Deno.test("invoice_checkout: an open PaymentSheet is cancelled before the pay link is created", async () => {
  const f = fixture({
    payments: [cardRow("pi_1Sheet")],
    intents: { pi_1Sheet: sheetIntent("requires_payment_method") },
  });
  const res = await f.call(checkout);
  assertEquals(res.status, 200);
  assertEquals((await res.json()).amount_cents, 12_345);
  assertEquals(f.intents.pi_1Sheet?.status, "canceled");
  assertEquals(upserts(f, "pi_1Sheet").map((a) => a.p_status), ["cancelled"]);
  const cancelAt = f.stripeCalls().findIndex((c) => c.url.pathname.endsWith("/cancel"));
  const createAt = f.stripeCalls().findIndex((c) =>
    c.method === "POST" && c.url.pathname === "/v1/checkout/sessions"
  );
  assert(cancelAt >= 0 && cancelAt < createAt, "the sheet is cancelled before the link exists");
});

Deno.test("invoice_checkout: a sheet that already took the money is recorded and only the rest is charged", async () => {
  const f = fixture({
    payments: [cardRow("pi_1Done", { amount_cents: 5_000 })],
    intents: {
      pi_1Done: sheetIntent("succeeded", {
        latest_charge: { id: "ch_1Done", object: "charge", created: 1_790_000_000 },
      }),
    },
  });
  f.db.onRpc("upsert_stripe_payment", (args) => {
    f.rpcCalls.push({ name: "upsert_stripe_payment", args });
    f.db.seed(
      "invoices",
      f.db.table("invoices").map((i) => i.id === INVOICE ? { ...i, balance_cents: 7_345 } : i),
    );
    return { id: "50000000-0000-4000-8000-000000000001", status: args.p_status };
  });
  const res = await f.call(checkout);
  assertEquals((await res.json()).amount_cents, 7_345);
  assertEquals(upserts(f, "pi_1Done").map((a) => a.p_status), ["succeeded"]);
});

Deno.test("booking_deposit_checkout: a deposit payment in flight blocks a second deposit link (409)", async () => {
  const processing = fixture({
    payments: [cardRow("pi_1Dep", { kind: "deposit", invoice_id: null, amount_cents: 5_000 })],
    intents: {
      pi_1Dep: { status: "processing", metadata: { shop_id: SHOP, source: "deposit_checkout" } },
    },
  });
  assertEquals((await errorOf(await processing.call(deposit)))[2], {
    reason: "payment_in_progress",
  });
  assertEquals(processing.stripe("POST", "/checkout/sessions").length, 0);

  // The database still reports a pending payment the settle could not see.
  const pending = fixture({ depositPending: true });
  assertEquals((await errorOf(await pending.call(deposit))).slice(0, 3), [
    409,
    "conflict",
    { reason: "payment_in_progress" },
  ]);
  assertEquals(pending.stripe("POST", "/checkout/sessions").length, 0);
});

// ---------------------------------------------------------------------------
// #11 declined (failed) sheets stay payable until cancelled
// ---------------------------------------------------------------------------

function declinedSheet(extra: FixtureOptions = {}, created = NOW - 5 * MINUTE) {
  return fixture({
    payments: [cardRow("pi_Declined1", {
      status: "failed",
      created_at: new Date(created).toISOString(),
    })],
    intents: { pi_Declined1: sheetIntent("requires_payment_method") },
    ...extra,
  });
}

Deno.test("payment_sheet / invoice_checkout: a declined sheet still confirmable is cancelled first", async () => {
  for (const [body, who] of [[sheet, "manager"], [checkout, "none"]] as const) {
    const f = declinedSheet();
    const res = await f.call(body, who);
    assertEquals(res.status, 200);
    await res.body?.cancel();
    assertEquals(f.stripe("POST", "/payment_intents/pi_Declined1/cancel").length, 1);
    assertEquals(f.intents.pi_Declined1?.status, "canceled");
    assertEquals(upserts(f, "pi_Declined1").map((a) => a.p_status), ["cancelled"]);
  }
});

Deno.test("cancel_open_payments / sweep: a declined sheet is released; a dead one never blocks", async () => {
  const f = declinedSheet();
  const released = await (await f.call({
    action: "cancel_open_payments",
    shop_id: SHOP,
    invoice_id: INVOICE,
  }, "manager")).json();
  assertEquals([released.cancelled, released.in_progress], [1, 0]);

  const swept = declinedSheet({}, NOW - 60 * MINUTE);
  const counts = await (await swept.handler(sweepRequest())).json();
  assertEquals([counts.checked, counts.cancelled], [1, 1]);
  assertEquals(swept.intents.pi_Declined1?.status, "canceled");

  // A declined attempt whose intent can no longer be paid is left alone.
  const dead = declinedSheet({ intents: { pi_Declined1: sheetIntent("canceled") } });
  const res = await dead.call(sheet, "manager");
  assertEquals(res.status, 200);
  await res.body?.cancel();
  assertEquals(upserts(dead, "pi_Declined1").length, 0);
});

// ---------------------------------------------------------------------------
// #3 / #8 / #13 the sweep is never starved by rows that stay pending
// ---------------------------------------------------------------------------

function sweepRequest(): Request {
  return jsonRequest("payments", { action: "sweep_payment_sheets" }, {
    headers: { "x-cron-secret": CRON },
  });
}

function stuckRows(count: number, age = 3 * 24 * 60 * MINUTE) {
  const payments: Row[] = [];
  const intents: Record<string, Row> = {};
  for (let i = 0; i < count; i++) {
    const pi = `pi_1Stuck${i}`;
    payments.push(cardRow(pi, { created_at: new Date(NOW - age).toISOString() }));
    intents[pi] = { status: "processing", metadata: { shop_id: SHOP } };
  }
  return { payments, intents };
}

Deno.test("sweep_payment_sheets: 25 rows that never settle do not hide a newly abandoned sheet", async () => {
  const stuck = stuckRows(25);
  const f = fixture({
    payments: [
      ...stuck.payments,
      cardRow("pi_1Abandoned", { created_at: new Date(NOW - 60 * MINUTE).toISOString() }),
    ],
    intents: { ...stuck.intents, pi_1Abandoned: sheetIntent("requires_payment_method") },
  });
  const counts = await (await f.handler(sweepRequest())).json();
  assertEquals(counts.checked, SWEEP_BATCH);
  assertEquals(counts.cancelled, 1);
  assertEquals(f.intents.pi_1Abandoned?.status, "canceled");
});

Deno.test("sweep_payment_sheets: an old abandoned sheet among many stuck rows is reached within a few runs", async () => {
  const stuck = stuckRows(60);
  let clock = NOW;
  const f = fixture({
    now: () => clock,
    payments: [
      ...stuck.payments,
      // Went stale long ago (not "new"): only the rotation can reach it.
      cardRow("pi_1OldAbandoned", {
        created_at: new Date(NOW - 2 * 24 * 60 * MINUTE).toISOString(),
      }),
    ],
    intents: { ...stuck.intents, pi_1OldAbandoned: sheetIntent("requires_payment_method") },
  });
  const runs = Math.ceil(61 / SWEEP_BATCH);
  for (let run = 0; run < runs; run++) {
    await (await f.handler(sweepRequest())).body?.cancel();
    clock += SWEEP_SLOT_MS;
  }
  assertEquals(f.intents.pi_1OldAbandoned?.status, "canceled");
});

Deno.test("sweepBatch: consecutive runs cover every candidate; new stale rows go first", () => {
  const row = (i: number, ageMin: number): PendingCardRow => ({
    id: `ffffffff-ffff-4fff-8fff-${String(i).padStart(12, "0")}`,
    shop_id: SHOP,
    invoice_id: INVOICE,
    job_id: JOB,
    customer_id: CUSTOMER,
    kind: "payment",
    method: "card",
    status: "pending",
    amount_cents: 100,
    tip_cents: 0,
    stripe_payment_intent_id: `pi_${i}`,
    created_at: new Date(NOW - ageMin * MINUTE).toISOString(),
  });
  for (const n of [26, 61, 100, 257]) {
    const rows = Array.from({ length: n }, (_, i) => row(i, 3 * 24 * 60));
    const seen = new Set<string>();
    const runs = Math.ceil(n / SWEEP_BATCH);
    for (let run = 0; run < runs; run++) {
      const batch = sweepBatch(rows, NOW + run * SWEEP_SLOT_MS);
      assertEquals(batch.length, SWEEP_BATCH);
      assertEquals(new Set(batch.map((r) => r.id)).size, SWEEP_BATCH);
      for (const r of batch) seen.add(r.id);
    }
    assertEquals(seen.size, n, `${n} candidates covered in ${runs} runs`);
  }
  // Rows that went stale since the last runs are always in the next batch.
  const old = Array.from({ length: 100 }, (_, i) => row(i, 3 * 24 * 60));
  const fresh = [row(1_000, 35), row(1_001, 45)];
  const batch = sweepBatch([...old, ...fresh], NOW);
  assertEquals(batch.slice(0, 2).map((r) => r.stripe_payment_intent_id), ["pi_1000", "pi_1001"]);
});

// ---------------------------------------------------------------------------
// #6 idempotent replays show creation-time state
// ---------------------------------------------------------------------------

Deno.test("invoice_checkout: tip A, tip B, tip A again never returns the expired first link", async () => {
  const f = fixture({ customer: { stripe_customer_id: "cus_1Saved" } });
  replayingStripe(f);
  const urls: string[] = [];
  for (const tip of [0, 500, 0]) {
    const res = await f.call({ ...checkout, tip_cents: tip });
    assertEquals(res.status, 200);
    urls.push((await res.json()).url);
  }
  const last = urls[2]?.split("/").pop();
  assert(last && last !== urls[0]?.split("/").pop(), "the first (expired) link is not reused");
  assertEquals(f.sessions.find((x) => x.id === last)?.status, "open");
  // Exactly one payable link for the invoice: the one handed out.
  assertEquals(f.sessions.filter((x) => x.status === "open").map((x) => x.id), [last]);
});

Deno.test("payment_sheet: amount X, then Y, then X again gets a confirmable intent, not the cancelled one", async () => {
  const f = fixture();
  replayingStripe(f);
  recordingPayments(f);
  const ids: string[] = [];
  for (const amount of [5_000, 6_000, 5_000]) {
    const res = await f.call({ ...sheet, amount_cents: amount }, "manager");
    assertEquals(res.status, 200);
    const body = await res.json();
    ids.push(body.payment_intent_id);
    assertEquals(body.payment_intent_client_secret, `${body.payment_intent_id}_secret_x`);
  }
  assert(ids[2] !== ids[0], "the cancelled first intent is not handed back");
  assertEquals(f.intents[ids[0] ?? ""]?.status, "canceled");
  assertEquals(f.intents[ids[1] ?? ""]?.status, "canceled");
  assertEquals(f.intents[ids[2] ?? ""]?.status, "requires_payment_method");
});

// ---------------------------------------------------------------------------
// #9 / #12 membership links that were already paid
// ---------------------------------------------------------------------------

function paidMembershipLink(subscriptionStatus: string, membership: Row = {}) {
  return fixture({
    customer: { stripe_customer_id: "cus_1Saved" },
    plan: { stripe_product_id: "prod_1Old", stripe_price_id: "price_1Stored" },
    membership,
    sessions: [{
      id: "cs_1PaidLink",
      object: "checkout.session",
      status: "complete",
      mode: "subscription",
      customer: "cus_1Saved",
      subscription: "sub_1NotLinkedYet",
      metadata: { shop_id: SHOP, membership_id: MEMBERSHIP, kind: "membership" },
    }],
    subscriptions: { sub_1NotLinkedYet: subscriptionStatus },
  });
}

Deno.test("membership_checkout: a link already paid (webhook not in yet) blocks a second link", async () => {
  const body = { action: "membership_checkout", shop_id: SHOP, membership_id: MEMBERSHIP };
  const f = paidMembershipLink("active");
  assertEquals((await errorOf(await f.call(body, "manager"))).slice(0, 3), [
    409,
    "conflict",
    { reason: "membership_checkout_completed" },
  ]);
  assertEquals(f.stripe("POST", "/checkout/sessions").length, 0);
  // That subscription already ended: a new link is fine.
  const ended = paidMembershipLink("incomplete_expired");
  const res = await ended.call(body, "manager");
  assertEquals(res.status, 200);
  await res.body?.cancel();
});

Deno.test("membership_cancel: a membership cancelled directly while its link was paid stops that billing", async () => {
  const f = paidMembershipLink("active", { status: "cancelled" });
  const res = await f.call(
    { action: "membership_cancel", shop_id: SHOP, membership_id: MEMBERSHIP },
    "manager",
  );
  assertEquals(res.status, 200);
  assertEquals((await res.json()).stopped_subscriptions, 1);
  assertEquals(
    f.stripe("DELETE", "/subscriptions/:id").map((c) => c.url.pathname),
    ["/v1/subscriptions/sub_1NotLinkedYet"],
  );
});

// ---------------------------------------------------------------------------
// payment_sheet tips are bounded by the amount collected, not the balance
// ---------------------------------------------------------------------------

Deno.test("payment_sheet: a tip larger than the amount collected is refused (no fee-free balance as tip)", async () => {
  const f = fixture();
  for (const who of ["tech", "manager"] as const) {
    assertEquals(
      await errorOf(await f.call({ ...sheet, amount_cents: 1, tip_cents: 12_345 }, who)),
      [422, "unprocessable", { reason: "tip_too_large", max_tip_cents: 1 }],
    );
    assertEquals(
      (await errorOf(await f.call({ ...sheet, amount_cents: 5_000, tip_cents: 5_001 }, who)))[2],
      { reason: "tip_too_large", max_tip_cents: 5_000 },
    );
  }
  assertEquals(f.stripe("POST", "/payment_intents").length, 0);
  // Up to the amount collected is fine; the fee is on the amount, as before.
  const ok = await f.call({ ...sheet, amount_cents: 5_000, tip_cents: 5_000 }, "tech");
  assertEquals(ok.status, 200);
  const made = await ok.json();
  assertEquals([made.amount_cents, made.tip_cents], [5_000, 5_000]);
  const pi = f.stripe("POST", "/payment_intents")[0];
  assertEquals(pi?.form.get("amount"), "10000");
  assertEquals(pi?.form.get("application_fee_amount"), "125");
  assertEquals(pi?.form.get("metadata[tip_cents]"), "5000");
});

// ---------------------------------------------------------------------------
// The job's deposit link is one instrument with its invoice's links
// ---------------------------------------------------------------------------

function depositSession(id: string, jobId = JOB): Row {
  return {
    id,
    object: "checkout.session",
    status: "open",
    mode: "payment",
    customer: "cus_1Saved",
    metadata: { shop_id: SHOP, job_id: jobId, customer_id: CUSTOMER, kind: "deposit" },
  };
}

const OTHER_JOB = "dddddddd-dddd-4ddd-8ddd-00000000000f";
const chargeCard = { action: "charge_saved_card", shop_id: SHOP, invoice_id: INVOICE };

Deno.test("payment_sheet / charge_saved_card: the job's open deposit link is expired before charging", async () => {
  for (
    const [body, who] of [[sheet, "manager"], [sheet, "tech"], [chargeCard, "manager"]] as const
  ) {
    const f = fixture({
      customer: { stripe_customer_id: "cus_1Saved" },
      sessions: [depositSession("cs_test_Dep"), depositSession("cs_test_OtherDep", OTHER_JOB)],
    });
    const res = await f.call(body, who);
    assertEquals(res.status, 200, `${body.action} as ${who}`);
    await res.body?.cancel();
    assertEquals(f.sessions.map((x) => x.status), ["expired", "open"]);
    assertEquals(f.stripe("POST", "/checkout/sessions/cs_test_Dep/expire").length, 1);
    // Expired before the charge was created.
    const calls = f.stripeCalls().map((c) => `${c.method} ${c.url.pathname}`);
    assert(
      calls.indexOf("POST /v1/checkout/sessions/cs_test_Dep/expire") <
        calls.indexOf("POST /v1/payment_intents"),
    );
  }
});

Deno.test("payment_sheet / charge_saved_card: a deposit link paid meanwhile is 409, nothing charged", async () => {
  for (const body of [sheet, chargeCard]) {
    const f = fixture({
      customer: { stripe_customer_id: "cus_1Saved" },
      sessions: [depositSession("cs_test_Dep")],
    });
    // Listed as open, completed before the expire reached Stripe.
    f.db.http.once("POST", `${STRIPE}/checkout/sessions/cs_test_Dep/expire`, () => {
      const found = f.sessions[0];
      if (found) found.status = "complete";
      return jsonResponse(
        stripeErrorBody("invalid_request_error", "Only open sessions can be expired."),
        400,
      );
    });
    assertEquals((await errorOf(await f.call(body, "manager"))).slice(0, 3), [
      409,
      "conflict",
      { reason: "payment_in_progress" },
    ]);
    assertEquals(f.stripe("POST", "/payment_intents").length, 0);
  }
});

Deno.test("payment_sheet: an invoice without a job leaves deposit links alone", async () => {
  const f = fixture({
    customer: { stripe_customer_id: "cus_1Saved" },
    invoice: { job_id: null },
    sessions: [depositSession("cs_test_Dep")],
  });
  const res = await f.call(sheet, "manager");
  assertEquals(res.status, 200);
  await res.body?.cancel();
  assertEquals(f.sessions[0]?.status, "open");
});

Deno.test("invoice_checkout / booking_deposit_checkout: the other kind's link paid meanwhile is 409, no new link", async () => {
  const cases = [
    { body: checkout, session: depositSession("cs_test_Dep") },
    {
      body: deposit,
      session: {
        ...depositSession("cs_test_Inv"),
        metadata: { shop_id: SHOP, invoice_id: INVOICE, job_id: JOB, kind: "payment" },
      },
    },
  ];
  for (const { body, session } of cases) {
    const f = fixture({ customer: { stripe_customer_id: "cus_1Saved" }, sessions: [session] });
    f.db.http.once("POST", `${STRIPE}/checkout/sessions/${session.id}/expire`, () => {
      const found = f.sessions[0];
      if (found) found.status = "complete";
      return jsonResponse(
        stripeErrorBody("invalid_request_error", "Only open sessions can be expired."),
        400,
      );
    });
    assertEquals((await errorOf(await f.call(body))).slice(0, 3), [
      409,
      "conflict",
      { reason: "payment_in_progress" },
    ]);
    assertEquals(f.stripe("POST", "/checkout/sessions").length, 0, body.action);
  }
});
