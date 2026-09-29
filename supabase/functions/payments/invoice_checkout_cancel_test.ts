/**
 * invoice_checkout_cancel (PUBLIC, invoice token): the customer closes the
 * invoice's open /i pay links (back from Stripe with ?canceled=1, or before a
 * gift card) — those links and their holds only, never a deposit link, a
 * staff PaymentSheet or a Terminal payment; 409 payment_in_progress when a
 * link was just paid; nothing open is a 200 that changes nothing.
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
  NOW,
  SHOP,
  STRIPE,
} from "./test_fixtures.ts";

const HOLD_UNTIL = new Date(1_900_000_000 * 1000).toISOString();
const OTHER_INVOICE_SAME_SHOP = "eeeeeeee-eeee-4eee-8eee-0000000000f9";

const close = { action: "invoice_checkout_cancel", token: INVOICE_TOKEN };

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

/** An /i pay link as invoice_checkout tags it (single-job invoice). */
function payLink(id: string, extra: Row = {}): Row {
  return session(id, {
    invoice_id: INVOICE,
    job_id: JOB,
    customer_id: CUSTOMER,
    kind: "payment",
    tip_cents: "0",
    source: "invoice_checkout",
  }, extra);
}

function depositLink(id: string): Row {
  return session(id, {
    job_id: JOB,
    customer_id: CUSTOMER,
    kind: "deposit",
    tip_cents: "0",
    source: "booking_deposit_checkout",
  });
}

function jobHold(id: string): Row {
  return { stripe_checkout_session_id: id, shop_id: SHOP, job_id: JOB, expires_at: HOLD_UNTIL };
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

Deno.test("invoice_checkout_cancel: expires the /i pay link and releases its invoice and job holds", async () => {
  const f = fixture({
    customer: { stripe_customer_id: "cus_1Saved" },
    sessions: [
      payLink("cs_1PayLink"),
      // opened for the invoice's previous customer: found through its hold
      payLink("cs_1Before", { customer: "cus_1Before" }),
    ],
    holds: [jobHold("cs_1PayLink")],
    invoiceHolds: [invoiceHold("cs_1PayLink"), invoiceHold("cs_1Before")],
  });
  const res = await f.call(close);
  assertEquals(res.status, 200);
  assertEquals(await res.json(), { released: 2 });
  assertEquals(expiredIds(f), ["cs_1PayLink", "cs_1Before"]);
  assertEquals([statusOf(f, "cs_1PayLink"), statusOf(f, "cs_1Before")], ["expired", "expired"]);
  assertEquals(heldIds(f), { job: [], invoice: [] });
  for (const call of f.stripe("POST", "/checkout/sessions/:id/expire")) {
    assertEquals(call.headers.get("stripe-account"), ACCT);
    assertMatch(call.headers.get("idempotency-key") ?? "", /^dcrm:checkout_expire:[0-9a-f]{64}$/);
  }
  assertEquals(releases(f), [
    {
      name: "payments_release_job_checkouts",
      args: { p_shop_id: SHOP, p_job_id: JOB, p_session_ids: ["cs_1PayLink", "cs_1Before"] },
    },
    {
      name: "payments_release_invoice_checkouts",
      args: {
        p_shop_id: SHOP,
        p_invoice_id: INVOICE,
        p_session_ids: ["cs_1PayLink", "cs_1Before"],
      },
    },
  ]);
  // Public request: every database call used the service role.
  assert(f.db.requests.every((r) => r.role === "service_role"));
});

Deno.test("invoice_checkout_cancel: staff sheets, Terminal intents, deposit and other links are left alone", async () => {
  const f = fixture({
    customer: { stripe_customer_id: "cus_1Saved" },
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
      payLink("cs_1PayLink"),
      depositLink("cs_1Deposit"),
      // a card-setup link staff texted the customer
      session("cs_1Setup", { customer_id: CUSTOMER, source: "setup_card_link" }, {
        mode: "setup",
      }),
      // a pay link of another invoice of the same customer
      session("cs_1OtherInvoice", {
        invoice_id: OTHER_INVOICE_SAME_SHOP,
        kind: "payment",
        source: "invoice_checkout",
      }),
    ],
    holds: [jobHold("cs_1PayLink"), jobHold("cs_1Deposit")],
    invoiceHolds: [invoiceHold("cs_1PayLink")],
  });
  const res = await f.call(close);
  assertEquals(res.status, 200);
  assertEquals(await res.json(), { released: 1 });
  assertEquals(expiredIds(f), ["cs_1PayLink"]);
  for (const id of ["cs_1Deposit", "cs_1Setup", "cs_1OtherInvoice"]) {
    assertEquals(statusOf(f, id), "open", id);
  }
  // the deposit link keeps its job hold
  assertEquals(heldIds(f), { job: ["cs_1Deposit"], invoice: [] });
  // no PaymentIntent is read, cancelled or charged, and nothing is settled
  assertEquals(
    f.stripeCalls().filter((c) => c.url.pathname.includes("/payment_intents")),
    [],
  );
  assertEquals(
    [f.intents.pi_1Sheet?.status, f.intents.pi_1Reader?.status],
    ["requires_payment_method", "requires_payment_method"],
  );
  assertEquals(
    f.db.table("payments").filter((p) => p.status === "pending").map((p) =>
      p.stripe_payment_intent_id
    ),
    ["pi_1Sheet", "pi_1Reader"],
  );
  assertEquals(f.stripe("POST", "/checkout/sessions"), []);
  assertEquals(f.rpcCalls.some((c) => c.name === "upsert_stripe_payment"), false);
});

Deno.test("invoice_checkout_cancel: a link that was paid or whose payment is processing is 409 payment_in_progress", async () => {
  for (const extra of [{ payment_status: "paid" }, { payment_status: "unpaid" }]) {
    const f = fixture({
      customer: { stripe_customer_id: "cus_1Saved" },
      sessions: [
        payLink("cs_1Paid", { status: "complete", ...extra }),
        payLink("cs_1Open"),
      ],
      holds: [jobHold("cs_1Paid"), jobHold("cs_1Open")],
      invoiceHolds: [invoiceHold("cs_1Paid"), invoiceHold("cs_1Open")],
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
    // the other link is closed; the paid one keeps its holds (its payment row releases them)
    assertEquals(statusOf(f, "cs_1Open"), "expired");
    assertEquals(heldIds(f), { job: ["cs_1Paid"], invoice: ["cs_1Paid"] });
  }
});

Deno.test("invoice_checkout_cancel: an open link Stripe will not expire (payment being confirmed) is 409 and stays held", async () => {
  const f = fixture({
    customer: { stripe_customer_id: "cus_1Saved" },
    sessions: [payLink("cs_1Confirming")],
    holds: [jobHold("cs_1Confirming")],
    invoiceHolds: [invoiceHold("cs_1Confirming")],
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
  assertEquals(heldIds(f), { job: ["cs_1Confirming"], invoice: ["cs_1Confirming"] });
  assertEquals(releases(f), []);
});

Deno.test("invoice_checkout_cancel: nothing open is a 200 that changes nothing", async () => {
  // a deposit link and its hold are not this invoice's pay links
  const f = fixture({
    customer: { stripe_customer_id: "cus_1Saved" },
    sessions: [depositLink("cs_1Deposit")],
    holds: [jobHold("cs_1Deposit")],
  });
  const res = await f.call(close);
  assertEquals(res.status, 200);
  assertEquals(await res.json(), { released: 0 });
  assertEquals(expiredIds(f), []);
  assertEquals(statusOf(f, "cs_1Deposit"), "open");
  assertEquals(heldIds(f), { job: ["cs_1Deposit"], invoice: [] });
  assertEquals(releases(f), []);
  assertEquals(f.db.requests.filter((r) => r.method !== "GET"), []);

  // No Stripe customer and no hold: not even a Stripe call.
  const fresh = fixture();
  const quiet = await fresh.call(close);
  assertEquals([quiet.status, await quiet.json()], [200, { released: 0 }]);
  assertEquals(fresh.stripeCalls(), []);

  // A shop without Stripe has no pages to close.
  const none = fixture({ account: null, invoiceHolds: [invoiceHold("cs_1PayLink")] });
  const res2 = await none.call(close);
  assertEquals([res2.status, await res2.json()], [200, { released: 0 }]);
  assertEquals(none.stripeCalls(), []);
  assertEquals(heldIds(none), { job: [], invoice: ["cs_1PayLink"] });
});

Deno.test("invoice_checkout_cancel: tokens and invoice states", async () => {
  const f = fixture();
  assertEquals(
    (await errorOf(
      await f.call({ ...close, token: "99999999-9999-4999-8999-00000000abcd" }),
    )).slice(0, 2),
    [404, "not_found"],
  );
  assertEquals(
    (await errorOf(await f.call({ ...close, token: "not-a-token" }))).slice(0, 2),
    [400, "validation_failed"],
  );
  // strict body: nothing but the token
  assertEquals(
    (await errorOf(await f.call({ ...close, tip_cents: 100 }))).slice(0, 2),
    [400, "validation_failed"],
  );
  assertEquals(f.stripeCalls(), []);
  // drafts are not published
  const draft = fixture({
    invoice: { status: "draft" },
    customer: { stripe_customer_id: "cus_1Saved" },
    sessions: [payLink("cs_1PayLink")],
  });
  assertEquals((await errorOf(await draft.call(close))).slice(0, 2), [404, "not_found"]);
  assertEquals(draft.stripeCalls(), []);
  // a paid or void invoice may still have a page to close
  for (const invoice of [{ status: "paid", balance_cents: 0 }, { status: "void" }]) {
    const closed = fixture({
      invoice,
      customer: { stripe_customer_id: "cus_1Saved" },
      sessions: [payLink("cs_1PayLink")],
      invoiceHolds: [invoiceHold("cs_1PayLink")],
    });
    const res = await closed.call(close);
    assertEquals([res.status, await res.json()], [200, { released: 1 }]);
    assertEquals(heldIds(closed), { job: [], invoice: [] });
  }
});

Deno.test("invoice_checkout_cancel: repeating it is harmless; stale and unknown holds are released", async () => {
  const f = fixture({
    customer: { stripe_customer_id: "cus_1Saved" },
    sessions: [
      payLink("cs_1PayLink"),
      // expired in Stripe already (e.g. from the dashboard): only its hold is left
      payLink("cs_1Stale", { status: "expired" }),
    ],
    holds: [jobHold("cs_1PayLink")],
    // cs_1Gone: Stripe does not know it on this account
    invoiceHolds: [invoiceHold("cs_1PayLink"), invoiceHold("cs_1Stale"), invoiceHold("cs_1Gone")],
  });
  const first = await f.call(close);
  assertEquals([first.status, await first.json()], [200, { released: 3 }]);
  assertEquals(heldIds(f), { job: [], invoice: [] });
  assertEquals(statusOf(f, "cs_1PayLink"), "expired");
  const expireCalls = f.stripe("POST", "/checkout/sessions/:id/expire").length;
  const releaseCalls = releases(f).length;

  const again = await f.call(close);
  assertEquals([again.status, await again.json()], [200, { released: 0 }]);
  assertEquals(f.stripe("POST", "/checkout/sessions/:id/expire").length, expireCalls);
  assertEquals(releases(f).length, releaseCalls);
  assertEquals(heldIds(f), { job: [], invoice: [] });
});
