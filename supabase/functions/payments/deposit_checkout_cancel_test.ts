/**
 * deposit_checkout_cancel (PUBLIC, booking token or invoice token): the
 * customer closes the job's open deposit links (back from Stripe with
 * ?canceled=1 on /booking or /q, or from /i before a gift card) — those
 * links and their job holds only, never an invoice pay link, a staff
 * PaymentSheet or a Terminal payment; 409 payment_in_progress when a link was
 * just paid; nothing open is a 200 that changes nothing.
 */
import { assert, assertEquals, assertMatch } from "@std/assert";
import { jsonResponse, type Row, stripeErrorBody } from "../_shared/testing/mod.ts";
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

const HOLD_UNTIL = new Date(1_900_000_000 * 1000).toISOString();
const OTHER_JOB = "dddddddd-dddd-4ddd-8ddd-0000000000f2";
const QUOTE = "70000000-0000-4000-8000-000000000001";

const close = { action: "deposit_checkout_cancel", token: JOB_TOKEN };
const closeFromInvoice = { action: "deposit_checkout_cancel", invoice_token: INVOICE_TOKEN };

function session(id: string, metadata: Record<string, string>, extra: Row = {}): Row {
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

/** A deposit link as booking_deposit_checkout tags it. */
function depositLink(id: string, extra: Row = {}, jobId = JOB): Row {
  return session(id, {
    job_id: jobId,
    customer_id: CUSTOMER,
    kind: "deposit",
    tip_cents: "0",
    source: "booking_deposit_checkout",
  }, extra);
}

/** A deposit link as quote_deposit_checkout tags it (the /q page). */
function quoteDepositLink(id: string): Row {
  return session(id, {
    job_id: JOB,
    customer_id: CUSTOMER,
    kind: "deposit",
    tip_cents: "0",
    source: "quote_deposit_checkout",
    quote_id: QUOTE,
  });
}

/** An /i pay link as invoice_checkout tags it (single-job invoice). */
function payLink(id: string): Row {
  return session(id, {
    invoice_id: INVOICE,
    job_id: JOB,
    customer_id: CUSTOMER,
    kind: "payment",
    tip_cents: "0",
    source: "invoice_checkout",
  });
}

function jobHold(id: string, jobId = JOB): Row {
  return { stripe_checkout_session_id: id, shop_id: SHOP, job_id: jobId, expires_at: HOLD_UNTIL };
}

function invoiceHold(id: string): Row {
  return {
    stripe_checkout_session_id: id,
    shop_id: SHOP,
    invoice_id: INVOICE,
    expires_at: HOLD_UNTIL,
  };
}

function pendingPayment(id: string, pi: string): Row {
  return {
    id,
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
  };
}

const heldIds = (f: ReturnType<typeof fixture>) => ({
  job: f.db.table("job_checkout_holds").map((h) => h.stripe_checkout_session_id),
  invoice: f.db.table("invoice_checkout_holds").map((h) => h.stripe_checkout_session_id),
});

const expiredIds = (f: ReturnType<typeof fixture>) =>
  f.stripe("POST", "/checkout/sessions/:id/expire").map((c) => c.url.pathname.split("/").at(-2));

const statusOf = (f: ReturnType<typeof fixture>, id: string) =>
  f.sessions.find((x) => x.id === id)?.status;

const releases = (f: ReturnType<typeof fixture>) =>
  f.rpcCalls.filter((c) => c.name.startsWith("payments_release_"));

Deno.test("deposit_checkout_cancel: expires the booking's deposit links and releases their job holds", async () => {
  const f = fixture({
    customer: { stripe_customer_id: "cus_1Saved" },
    sessions: [
      depositLink("cs_1Deposit"),
      quoteDepositLink("cs_1QuoteDeposit"),
      // opened for the booking's previous customer: found through its hold
      depositLink("cs_1Before", { customer: "cus_1Before" }),
    ],
    holds: [jobHold("cs_1Deposit"), jobHold("cs_1QuoteDeposit"), jobHold("cs_1Before")],
  });
  const res = await f.call(close);
  assertEquals(res.status, 200);
  assertEquals(await res.json(), { released: 3 });
  assertEquals(expiredIds(f), ["cs_1Deposit", "cs_1QuoteDeposit", "cs_1Before"]);
  for (const id of ["cs_1Deposit", "cs_1QuoteDeposit", "cs_1Before"]) {
    assertEquals(statusOf(f, id), "expired", id);
  }
  assertEquals(heldIds(f), { job: [], invoice: [] });
  for (const call of f.stripe("POST", "/checkout/sessions/:id/expire")) {
    assertEquals(call.headers.get("stripe-account"), ACCT);
    assertMatch(call.headers.get("idempotency-key") ?? "", /^dcrm:checkout_expire:[0-9a-f]{64}$/);
  }
  assertEquals(releases(f), [{
    name: "payments_release_job_checkouts",
    args: {
      p_shop_id: SHOP,
      p_job_id: JOB,
      p_session_ids: ["cs_1Deposit", "cs_1QuoteDeposit", "cs_1Before"],
    },
  }]);
  // Public request: every database call used the service role.
  assert(f.db.requests.every((r) => r.role === "service_role"));
});

Deno.test("deposit_checkout_cancel: invoice pay links, staff sheets, Terminal intents and other links are left alone", async () => {
  const f = fixture({
    customer: { stripe_customer_id: "cus_1Saved" },
    extraJobs: [{
      id: OTHER_JOB,
      shop_id: SHOP,
      number: 1002,
      customer_id: CUSTOMER,
      status: "scheduled",
      public_token: "99999999-9999-4999-8999-0000000000f2",
    }],
    payments: [
      pendingPayment("ffffffff-ffff-4fff-8fff-0000000000a1", "pi_1Sheet"),
      pendingPayment("ffffffff-ffff-4fff-8fff-0000000000a2", "pi_1Reader"),
    ],
    intents: {
      pi_1Sheet: {
        status: "requires_payment_method",
        amount: 12_345,
        metadata: { shop_id: SHOP, invoice_id: INVOICE, source: "payment_sheet" },
      },
      pi_1Reader: {
        status: "requires_payment_method",
        amount: 12_345,
        metadata: { shop_id: SHOP, invoice_id: INVOICE, source: "terminal" },
      },
    },
    sessions: [
      depositLink("cs_1Deposit"),
      payLink("cs_1PayLink"),
      // another booking of the same customer
      depositLink("cs_1OtherJob", {}, OTHER_JOB),
      // a card-setup link staff texted the customer
      session("cs_1Setup", { customer_id: CUSTOMER, source: "setup_card_link" }, {
        mode: "setup",
      }),
    ],
    // the /i pay link holds the job AND the invoice
    holds: [jobHold("cs_1Deposit"), jobHold("cs_1PayLink"), jobHold("cs_1OtherJob", OTHER_JOB)],
    invoiceHolds: [invoiceHold("cs_1PayLink")],
  });
  const res = await f.call(close);
  assertEquals(res.status, 200);
  assertEquals(await res.json(), { released: 1 });
  assertEquals(expiredIds(f), ["cs_1Deposit"]);
  for (const id of ["cs_1PayLink", "cs_1OtherJob", "cs_1Setup"]) {
    assertEquals(statusOf(f, id), "open", id);
  }
  // the pay link keeps its job and invoice holds; the other booking its own
  assertEquals(heldIds(f), { job: ["cs_1PayLink", "cs_1OtherJob"], invoice: ["cs_1PayLink"] });
  // the pay link was never even read: its invoice hold marks it as an /i link
  assertEquals(
    f.stripe("GET", "/checkout/sessions/:id").map((c) => c.url.pathname.split("/").at(-1)),
    [],
  );
  // no PaymentIntent is read, cancelled or charged, and nothing is settled
  assertEquals(
    f.stripeCalls().filter((c) => c.url.pathname.includes("/payment_intents")),
    [],
  );
  assertEquals(
    [f.intents.pi_1Sheet?.status, f.intents.pi_1Reader?.status],
    ["requires_payment_method", "requires_payment_method"],
  );
  assertEquals(f.stripe("POST", "/checkout/sessions"), []);
  assertEquals(f.rpcCalls.some((c) => c.name === "upsert_stripe_payment"), false);
  assertEquals(releases(f).map((c) => c.name), ["payments_release_job_checkouts"]);
  assertEquals(releases(f)[0]?.args.p_session_ids, ["cs_1Deposit"]);
});

Deno.test("deposit_checkout_cancel: a held session that is not a deposit link is left alone", async () => {
  // a job hold without an invoice hold whose session Stripe says is something else
  const f = fixture({
    customer: { stripe_customer_id: "cus_1Saved" },
    sessions: [{ ...payLink("cs_1Unheld"), customer: "cus_1Before" }],
    holds: [jobHold("cs_1Unheld")],
  });
  const res = await f.call(close);
  assertEquals([res.status, await res.json()], [200, { released: 0 }]);
  assertEquals(expiredIds(f), []);
  assertEquals(statusOf(f, "cs_1Unheld"), "open");
  assertEquals(heldIds(f), { job: ["cs_1Unheld"], invoice: [] });
  assertEquals(releases(f), []);
});

Deno.test("deposit_checkout_cancel: a link that was paid or whose payment is processing is 409 payment_in_progress", async () => {
  for (const extra of [{ payment_status: "paid" }, { payment_status: "unpaid" }]) {
    const f = fixture({
      customer: { stripe_customer_id: "cus_1Saved" },
      sessions: [
        depositLink("cs_1Paid", { status: "complete", ...extra }),
        depositLink("cs_1Open"),
      ],
      holds: [jobHold("cs_1Paid"), jobHold("cs_1Open")],
    });
    const res = await f.call(close);
    const body = await res.json();
    assertEquals([res.status, body.code, body.details], [409, "conflict", {
      reason: "payment_in_progress",
    }]);
    assertEquals(
      body.error,
      "Your card payment is already going through, so the payment page can't be closed. Refresh in a moment to see it.",
    );
    // the other link is closed; the paid one keeps its hold (its payment row releases it)
    assertEquals(statusOf(f, "cs_1Open"), "expired");
    assertEquals(heldIds(f), { job: ["cs_1Paid"], invoice: [] });
    assertEquals(releases(f)[0]?.args.p_session_ids, ["cs_1Open"]);
  }
});

Deno.test("deposit_checkout_cancel: an open link Stripe will not expire (payment being confirmed) is 409 and stays held", async () => {
  const f = fixture({
    customer: { stripe_customer_id: "cus_1Saved" },
    sessions: [depositLink("cs_1Confirming")],
    holds: [jobHold("cs_1Confirming")],
  });
  f.db.http.on(
    "POST",
    `${STRIPE}/checkout/sessions/:id/expire`,
    () =>
      jsonResponse(
        stripeErrorBody("invalid_request_error", "This session's payment is being processed."),
        400,
      ),
  );
  const [status, code, details] = await errorOf(await f.call(close));
  assertEquals([status, code, details], [409, "conflict", { reason: "payment_in_progress" }]);
  assertEquals(statusOf(f, "cs_1Confirming"), "open");
  assertEquals(heldIds(f), { job: ["cs_1Confirming"], invoice: [] });
  assertEquals(releases(f), []);
});

Deno.test("deposit_checkout_cancel: nothing open is a 200 that changes nothing", async () => {
  // the /i pay link and its holds are not the booking's deposit links
  const f = fixture({
    customer: { stripe_customer_id: "cus_1Saved" },
    sessions: [payLink("cs_1PayLink")],
    holds: [jobHold("cs_1PayLink")],
    invoiceHolds: [invoiceHold("cs_1PayLink")],
  });
  const res = await f.call(close);
  assertEquals(res.status, 200);
  assertEquals(await res.json(), { released: 0 });
  assertEquals(expiredIds(f), []);
  assertEquals(statusOf(f, "cs_1PayLink"), "open");
  assertEquals(heldIds(f), { job: ["cs_1PayLink"], invoice: ["cs_1PayLink"] });
  assertEquals(releases(f), []);
  assertEquals(f.db.requests.filter((r) => r.method !== "GET"), []);

  // No Stripe customer and no hold: not even a Stripe call.
  const fresh = fixture();
  const quiet = await fresh.call(close);
  assertEquals([quiet.status, await quiet.json()], [200, { released: 0 }]);
  assertEquals(fresh.stripeCalls(), []);

  // A shop without Stripe has no pages to close.
  const none = fixture({ account: null, holds: [jobHold("cs_1Deposit")] });
  const res2 = await none.call(close);
  assertEquals([res2.status, await res2.json()], [200, { released: 0 }]);
  assertEquals(none.stripeCalls(), []);
  assertEquals(heldIds(none), { job: ["cs_1Deposit"], invoice: [] });
});

Deno.test("deposit_checkout_cancel: from the invoice page, the deposit links of the jobs it bills", async () => {
  const f = fixture({
    customer: { stripe_customer_id: "cus_1Saved" },
    sessions: [depositLink("cs_1Deposit"), payLink("cs_1PayLink")],
    holds: [jobHold("cs_1Deposit"), jobHold("cs_1PayLink")],
    invoiceHolds: [invoiceHold("cs_1PayLink")],
  });
  const res = await f.call(closeFromInvoice);
  assertEquals([res.status, await res.json()], [200, { released: 1 }]);
  assertEquals(expiredIds(f), ["cs_1Deposit"]);
  assertEquals(statusOf(f, "cs_1PayLink"), "open");
  assertEquals(heldIds(f), { job: ["cs_1PayLink"], invoice: ["cs_1PayLink"] });

  // drafts are not published; unknown tokens are 404
  const draft = fixture({
    invoice: { status: "draft" },
    customer: { stripe_customer_id: "cus_1Saved" },
    sessions: [depositLink("cs_1Deposit")],
  });
  assertEquals((await errorOf(await draft.call(closeFromInvoice))).slice(0, 2), [
    404,
    "not_found",
  ]);
  assertEquals(draft.stripeCalls(), []);
  assertEquals(
    (await errorOf(
      await f.call({ ...closeFromInvoice, invoice_token: "99999999-9999-4999-8999-00000000abcd" }),
    )).slice(0, 2),
    [404, "not_found"],
  );
});

Deno.test("deposit_checkout_cancel: tokens and bodies", async () => {
  const f = fixture({
    customer: { stripe_customer_id: "cus_1Saved" },
    sessions: [depositLink("cs_1Deposit")],
  });
  assertEquals(
    (await errorOf(
      await f.call({ ...close, token: "99999999-9999-4999-8999-00000000abcd" }),
    )).slice(0, 2),
    [404, "not_found"],
  );
  for (
    const body of [
      { ...close, token: "not-a-token" },
      // strict body: one token, nothing else
      { ...close, request_nonce: "abc-12345" },
      { ...close, invoice_token: INVOICE_TOKEN },
      { action: "deposit_checkout_cancel" },
    ]
  ) {
    assertEquals((await errorOf(await f.call(body))).slice(0, 2), [400, "validation_failed"]);
  }
  assertEquals(f.stripeCalls(), []);
  // a closed booking may still have a page to close
  for (const status of ["cancelled", "completed"]) {
    const closed = fixture({
      job: { status },
      customer: { stripe_customer_id: "cus_1Saved" },
      sessions: [depositLink("cs_1Deposit")],
      holds: [jobHold("cs_1Deposit")],
    });
    const res = await closed.call(close);
    assertEquals([res.status, await res.json()], [200, { released: 1 }]);
    assertEquals(heldIds(closed), { job: [], invoice: [] });
  }
});

Deno.test("deposit_checkout_cancel: repeating it is harmless; stale and unknown holds are released", async () => {
  const f = fixture({
    customer: { stripe_customer_id: "cus_1Saved" },
    sessions: [
      depositLink("cs_1Deposit"),
      // expired in Stripe already (e.g. from the dashboard): only its hold is left
      depositLink("cs_1Stale", { status: "expired" }),
    ],
    // cs_1Gone: Stripe does not know it on this account
    holds: [jobHold("cs_1Deposit"), jobHold("cs_1Stale"), jobHold("cs_1Gone")],
  });
  const first = await f.call(close);
  assertEquals([first.status, await first.json()], [200, { released: 3 }]);
  assertEquals(heldIds(f), { job: [], invoice: [] });
  assertEquals(statusOf(f, "cs_1Deposit"), "expired");
  // only the open one needed an expire call
  assertEquals(expiredIds(f), ["cs_1Deposit"]);
  const expireCalls = f.stripe("POST", "/checkout/sessions/:id/expire").length;
  const releaseCalls = releases(f).length;

  const again = await f.call(close);
  assertEquals([again.status, await again.json()], [200, { released: 0 }]);
  assertEquals(f.stripe("POST", "/checkout/sessions/:id/expire").length, expireCalls);
  assertEquals(releases(f).length, releaseCalls);
  assertEquals(heldIds(f), { job: [], invoice: [] });
});
