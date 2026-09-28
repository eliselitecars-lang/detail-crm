/**
 * 0106 job_checkout_holds: deposit and invoice links are held before their
 * URL is returned, the customer's booking_cancel expires and releases them
 * before public_cancel_booking runs as the caller, and staff
 * cancel_open_payments releases what it expired.
 */
import { assert, assertEquals } from "@std/assert";
import { FakeRpcError } from "../_shared/testing/mod.ts";
import {
  errorOf,
  fixture,
  INVOICE,
  INVOICE_TOKEN,
  JOB,
  JOB_TOKEN,
  SHOP,
  USERS,
} from "./test_fixtures.ts";

const HOLD_UNTIL = new Date(1_900_000_000 * 1000).toISOString();

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

function hold(id: string, jobId = JOB) {
  return { stripe_checkout_session_id: id, shop_id: SHOP, job_id: jobId, expires_at: HOLD_UNTIL };
}

const expiredIds = (f: ReturnType<typeof fixture>) =>
  f.stripe("POST", "/checkout/sessions/:id/expire").map((c) => c.url.pathname.split("/").at(-2));

const cancel = { action: "booking_cancel", token: JOB_TOKEN };

// ---------------------------------------------------------------------------
// holds
// ---------------------------------------------------------------------------

Deno.test("booking_deposit_checkout: the session is held for the job before its URL is returned", async () => {
  const f = fixture();
  const res = await f.call({ action: "booking_deposit_checkout", token: JOB_TOKEN });
  assertEquals(res.status, 200);
  assertEquals((await res.json()).url, "https://checkout.stripe.com/c/pay/cs_test_1");
  const held = f.rpcCalls.filter((c) => c.name === "payments_hold_job_checkout");
  assertEquals(held.map((c) => c.args), [{
    p_shop_id: SHOP,
    p_job_id: JOB,
    p_session_id: "cs_test_1",
    p_expires_at: HOLD_UNTIL,
  }]);
  assertEquals(f.db.table("job_checkout_holds").map((h) => h.stripe_checkout_session_id), [
    "cs_test_1",
  ]);
  assertEquals(
    f.db.requests.filter((r) => r.target === "payments_hold_job_checkout").map((r) => r.role),
    ["service_role"],
  );
});

Deno.test("booking_deposit_checkout: a job closed while the session was created gets no link (409 booking_closed, session expired)", async () => {
  const f = fixture();
  f.db.onRpc("payments_hold_job_checkout", () => {
    throw new FakeRpcError("55000", "this booking is no longer taking payments", {
      hint: "booking_closed",
    });
  });
  const res = await f.call({ action: "booking_deposit_checkout", token: JOB_TOKEN });
  const [status, code, details] = await errorOf(res);
  assertEquals([status, code, details], [409, "conflict", { reason: "booking_closed" }]);
  assertEquals(expiredIds(f), ["cs_test_1"]);
  assertEquals(f.created.cs_test_1?.status, "expired");
});

Deno.test("booking_deposit_checkout: a failed hold is a 500, never a link the cancel cannot see", async () => {
  const f = fixture();
  f.db.onRpc("payments_hold_job_checkout", () => {
    throw new FakeRpcError("XX000", "boom", { status: 500 });
  });
  const res = await f.call({ action: "booking_deposit_checkout", token: JOB_TOKEN });
  assertEquals(res.status, 500);
  assert(!JSON.stringify(await res.json()).includes("checkout.stripe.com"));
});

Deno.test("invoice_checkout: a single-job invoice's link is held for its job", async () => {
  const f = fixture();
  const res = await f.call({ action: "invoice_checkout", token: INVOICE_TOKEN });
  assertEquals(res.status, 200);
  await res.body?.cancel();
  assertEquals(
    f.db.table("job_checkout_holds").map((h) => [h.job_id, h.stripe_checkout_session_id]),
    [
      [JOB, "cs_test_1"],
    ],
  );
});

Deno.test("invoice_checkout: a completed job's invoice stays payable without a hold", async () => {
  const f = fixture({ job: { status: "completed" } });
  const res = await f.call({ action: "invoice_checkout", token: INVOICE_TOKEN });
  assertEquals(res.status, 200);
  assertEquals((await res.json()).url, "https://checkout.stripe.com/c/pay/cs_test_1");
  assertEquals(f.db.table("job_checkout_holds"), []);
  assertEquals(expiredIds(f), []);
});

// ---------------------------------------------------------------------------
// booking_cancel
// ---------------------------------------------------------------------------

Deno.test("booking_cancel: expires and releases the booking's open pages, then cancels as the caller", async () => {
  const f = fixture({
    customer: { stripe_customer_id: "cus_1Saved" },
    sessions: [
      openSession("cs_1Deposit", { job_id: JOB, kind: "deposit" }),
      openSession("cs_1Invoice", { invoice_id: INVOICE, kind: "payment" }),
      openSession("cs_1OtherJob", {
        job_id: "dddddddd-dddd-4ddd-8ddd-00000000000f",
        kind: "deposit",
      }),
      // held for the job but opened for its previous customer
      openSession("cs_1Previous", { job_id: JOB, kind: "deposit" }, { customer: "cus_1Before" }),
    ],
    holds: [hold("cs_1Deposit"), hold("cs_1Previous")],
  });
  const res = await f.call({ ...cancel, reason: "  Car sold  " });
  assertEquals(res.status, 200);
  assertEquals(await res.json(), { booking: { number: 1001, status: "cancelled" } });
  assertEquals(expiredIds(f), ["cs_1Deposit", "cs_1Invoice", "cs_1Previous"]);
  assertEquals(f.sessions.find((x) => x.id === "cs_1OtherJob")?.status, "open");
  const release = f.rpcCalls.find((c) => c.name === "payments_release_job_checkouts");
  assertEquals(release?.args, {
    p_shop_id: SHOP,
    p_job_id: JOB,
    p_session_ids: ["cs_1Deposit", "cs_1Invoice", "cs_1Previous"],
  });
  assertEquals(f.db.table("job_checkout_holds"), []);
  const cancelled = f.rpcCalls.find((c) => c.name === "public_cancel_booking");
  assertEquals(cancelled?.args, {
    p_token: JOB_TOKEN,
    p_reason: "Car sold",
    role: "anon",
    user_id: null,
  });
  // releases strictly before the cancel
  const order = f.rpcCalls.map((c) => c.name);
  assert(order.indexOf("payments_release_job_checkouts") < order.indexOf("public_cancel_booking"));
});

Deno.test("booking_cancel: a page that was just paid refuses the cancel (409 payment_in_progress)", async () => {
  const f = fixture({
    customer: { stripe_customer_id: "cus_1Saved" },
    sessions: [openSession("cs_1Paid", { job_id: JOB, kind: "deposit" }, { status: "complete" })],
    holds: [hold("cs_1Paid")],
  });
  const [status, code, details] = await errorOf(await f.call(cancel));
  assertEquals([status, code, details], [409, "conflict", { reason: "payment_in_progress" }]);
  assertEquals(f.rpcCalls.some((c) => c.name === "public_cancel_booking"), false);
  assertEquals(f.db.table("job_checkout_holds").length, 1);
});

Deno.test("booking_cancel: a page opened meanwhile is the database's checkout_open (409, its message)", async () => {
  const f = fixture();
  // the payments edge held a session after the release: the RPC still sees it
  f.db.onRpc("payments_release_job_checkouts", () => 0);
  f.db.seed("job_checkout_holds", [hold("cs_1Late")]);
  const res = await f.call(cancel, "none");
  // cs_1Late is unknown to Stripe here (treated as closed and released), but
  // the release above is a no-op, so the RPC still sees the hold
  const body = await res.json();
  assertEquals(res.status, 409);
  assertEquals(body.details, { reason: "checkout_open" });
  assert(String(body.error).startsWith("A payment page for this booking is still open"));
});

Deno.test("booking_cancel: nothing is expired when the cancel would be refused anyway", async () => {
  for (const options of [{ cancelAllowed: false }, { depositPending: true }]) {
    const f = fixture({
      ...options,
      customer: { stripe_customer_id: "cus_1Saved" },
      sessions: [openSession("cs_1Deposit", { job_id: JOB, kind: "deposit" })],
      holds: [hold("cs_1Deposit")],
      cancelError: new FakeRpcError(
        "22023",
        "online cancellation closed 24 hours before the appointment; please call the shop",
      ),
    });
    const res = await f.call(cancel);
    assertEquals(res.status, 422);
    assertEquals(
      (await res.json()).error,
      "Online cancellation closed 24 hours before the appointment; please call the shop.",
    );
    assertEquals(expiredIds(f), []);
    assertEquals(f.db.table("job_checkout_holds").length, 1);
  }
});

Deno.test("booking_cancel: the RPC's payment_in_progress refusal keeps its reason", async () => {
  const f = fixture({
    cancelError: new FakeRpcError(
      "55000",
      "a payment for this booking is still going through; please try again once it has finished, or call the shop",
      { hint: "payment_in_progress" },
    ),
  });
  const [status, code, details] = await errorOf(await f.call(cancel));
  assertEquals([status, code, details], [409, "conflict", { reason: "payment_in_progress" }]);
});

Deno.test("booking_cancel: a technician of the shop is refused before any page is touched", async () => {
  const f = fixture({
    customer: { stripe_customer_id: "cus_1Saved" },
    sessions: [openSession("cs_1Deposit", { job_id: JOB, kind: "deposit" })],
    holds: [hold("cs_1Deposit")],
  });
  const [status, code] = await errorOf(await f.call(cancel, "tech"));
  assertEquals([status, code], [403, "forbidden"]);
  assertEquals(expiredIds(f), []);
  assertEquals(f.rpcCalls.some((c) => c.name === "public_cancel_booking"), false);
});

Deno.test("booking_cancel: a technician who is the booking's own customer, and managers, cancel as themselves", async () => {
  const own = fixture({ customer: { portal_user_id: USERS.tech } });
  assertEquals((await own.call(cancel, "tech")).status, 200);
  assertEquals(
    own.rpcCalls.find((c) => c.name === "public_cancel_booking")?.args.user_id,
    USERS.tech,
  );
  const manager = fixture();
  assertEquals((await manager.call(cancel, "manager")).status, 200);
  const args = manager.rpcCalls.find((c) => c.name === "public_cancel_booking")?.args;
  assertEquals([args?.role, args?.user_id], ["authenticated", USERS.manager]);
  // an outsider (another shop's owner) is just a customer here: the RPC decides
  const outsider = fixture();
  assertEquals((await outsider.call(cancel, "outsider")).status, 200);
});

Deno.test("booking_cancel: unknown token 404; a shop without Stripe cancels without touching Stripe", async () => {
  const f = fixture();
  const [status] = await errorOf(
    await f.call({ ...cancel, token: "99999999-9999-4999-8999-0000000000aa" }),
  );
  assertEquals(status, 404);
  const none = fixture({ account: null });
  assertEquals((await none.call(cancel)).status, 200);
  assertEquals(none.stripeCalls(), []);
});

// ---------------------------------------------------------------------------
// staff cancel_open_payments
// ---------------------------------------------------------------------------

Deno.test("cancel_open_payments (job): expired pages and the job's other holds are released", async () => {
  const f = fixture({
    customer: { stripe_customer_id: "cus_1Saved" },
    sessions: [
      openSession("cs_1Deposit", { job_id: JOB, kind: "deposit" }),
      openSession("cs_1Previous", { job_id: JOB, kind: "deposit" }, { customer: "cus_1Before" }),
      openSession("cs_1Paid", { job_id: JOB, kind: "deposit" }, {
        customer: "cus_1Before",
        status: "complete",
      }),
    ],
    holds: [hold("cs_1Deposit"), hold("cs_1Previous"), hold("cs_1Paid")],
  });
  const res = await f.call(
    { action: "cancel_open_payments", shop_id: SHOP, job_id: JOB },
    "manager",
  );
  assertEquals(res.status, 200);
  assertEquals((await res.json()).sessions_expired, 2);
  assertEquals(expiredIds(f), ["cs_1Deposit", "cs_1Previous", "cs_1Paid"]);
  // the paid page keeps its hold (its payment row releases it)
  assertEquals(f.db.table("job_checkout_holds").map((h) => h.stripe_checkout_session_id), [
    "cs_1Paid",
  ]);
});

Deno.test("cancel_open_payments (invoice): the pages it expired no longer hold the job", async () => {
  const f = fixture({
    customer: { stripe_customer_id: "cus_1Saved" },
    sessions: [openSession("cs_1Invoice", {
      invoice_id: INVOICE,
      kind: "payment",
    })],
    holds: [hold("cs_1Invoice"), hold("cs_1Unrelated")],
  });
  const res = await f.call(
    { action: "cancel_open_payments", shop_id: SHOP, invoice_id: INVOICE },
    "manager",
  );
  assertEquals(res.status, 200);
  await res.body?.cancel();
  assertEquals(f.db.table("job_checkout_holds").map((h) => h.stripe_checkout_session_id), [
    "cs_1Unrelated",
  ]);
});
