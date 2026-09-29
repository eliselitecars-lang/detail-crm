/**
 * erase_customer (owner / admin): a customer's deletion request (0125). The
 * preview is the RPC's dry run (no Stripe call); confirming settles the
 * customer's card attempts, expires their open pages, detaches their saved
 * cards and deletes their Stripe Customer, then runs the RPC. Refusals
 * (membership, money moving, a page just paid) stop before cards or the
 * Stripe Customer are touched.
 */
import { assert, assertEquals, assertMatch } from "@std/assert";
import { FakeRpcError, jsonResponse, type Row, stripeErrorBody } from "../_shared/testing/mod.ts";
import {
  ACCT,
  CUSTOMER,
  errorOf,
  fixture,
  type FixtureOptions,
  INVOICE,
  JOB,
  NOW,
  OTHER_SHOP,
  SHOP,
  STRIPE,
  USERS,
} from "./test_fixtures.ts";

const DUPLICATE = "cccccccc-cccc-4ccc-8ccc-0000000000d1";
const NEIGHBOUR = "cccccccc-cccc-4ccc-8ccc-0000000000e1";
const HOLD_UNTIL = new Date(1_900_000_000 * 1000).toISOString();
const IN_FLIGHT = new Set(["processing"]);
const LIVE_MEMBERSHIP = new Set(["active", "past_due", "incomplete"]);

const erase = { action: "erase_customer", shop_id: SHOP, customer_id: CUSTOMER };
const confirmErase = { ...erase, confirm: true };

type F = ReturnType<typeof fixture>;

/** The 0125 erase_customer RPC over the fixture's tables (service role only). */
function installEraseRpc(f: F, options: { refuse?: string } = {}) {
  f.db.onRpc("erase_customer", (args, ctx) => {
    f.rpcCalls.push({ name: "erase_customer", args });
    if (ctx.role !== "service_role") throw new FakeRpcError("42501", "permission denied");
    const shopId = String(args.p_shop_id);
    const admin = ctx.db.table("shop_members").some((m) =>
      m.shop_id === shopId && m.user_id === args.p_actor && m.active === true &&
      ["owner", "admin"].includes(String(m.role))
    );
    if (!admin) throw new FakeRpcError("42501", "only owners and admins can delete a customer");
    const customers = ctx.db.table("customers");
    const main = customers.find((c) => c.id === args.p_customer_id && c.shop_id === shopId);
    if (!main) throw new FakeRpcError("P0002", "customer not found", { status: 404 });
    const ids = new Set([String(main.id)]);
    for (let grew = true; grew;) {
      grew = false;
      for (const c of customers) {
        if (c.shop_id === shopId && ids.has(String(c.merged_into_id)) && !ids.has(String(c.id))) {
          ids.add(String(c.id));
          grew = true;
        }
      }
    }
    const mine = (row: Row) => row.shop_id === shopId && ids.has(String(row.customer_id));
    const membership = ctx.db.table("memberships").some((m) =>
      mine(m) && LIVE_MEMBERSHIP.has(String(m.status))
    );
    const inFlight = ctx.db.table("payments").filter((p) =>
      mine(p) &&
      (IN_FLIGHT.has(String(p.status)) ||
        (p.status === "pending" && Date.parse(String(p.created_at)) > NOW - 3_600_000))
    ).length;
    const jobIds = new Set(ctx.db.table("jobs").filter(mine).map((j) => j.id));
    const invoiceIds = new Set(ctx.db.table("invoices").filter(mine).map((i) => i.id));
    const now = new Date(NOW).toISOString();
    const holds = ctx.db.table("job_checkout_holds").filter((h) =>
      jobIds.has(h.job_id) && String(h.expires_at) > now
    ).length +
      ctx.db.table("invoice_checkout_holds").filter((h) =>
        invoiceIds.has(h.invoice_id) && String(h.expires_at) > now
      ).length;
    const cards = ctx.db.table("customer_payment_methods").filter(mine).length;
    const records = [...jobIds].length > 0 || [...invoiceIds].length > 0;
    const mode = records || main.erased_at ? "anonymised" : "deleted";
    if (args.p_dry_run === true) {
      return {
        dry_run: true,
        mode,
        erased: main.erased_at !== null && main.erased_at !== undefined,
        membership_active: membership,
        payments_in_progress: inFlight,
        open_checkouts: holds,
        saved_cards: cards,
      };
    }
    const refuse = options.refuse ??
      (membership
        ? "membership_active"
        : inFlight > 0
        ? "payment_in_progress"
        : holds > 0
        ? "checkout_open"
        : cards > 0
        ? "saved_cards"
        : null);
    if (refuse) {
      throw new FakeRpcError("55000", `refused: ${refuse}`, { hint: refuse });
    }
    ctx.db.seed(
      "customers",
      customers.map((c) =>
        ids.has(String(c.id))
          ? { ...c, first_name: "Deleted", stripe_customer_id: null, erased_at: now }
          : c
      ),
    );
    return { mode };
  });
}

function setup(options: FixtureOptions = {}, rpc: { refuse?: string } = {}) {
  const f = fixture({
    customer: { stripe_customer_id: "cus_1Saved" },
    membership: { status: "cancelled" },
    paymentMethods: {
      pm_1Default: { customer: "cus_1Saved" },
      pm_1Other: { customer: "cus_1Saved" },
    },
    ...options,
  });
  installEraseRpc(f, rpc);
  // settle records a cancelled / succeeded attempt on its payment row
  f.db.onRpc("upsert_stripe_payment", (args, ctx) => {
    f.rpcCalls.push({ name: "upsert_stripe_payment", args });
    ctx.db.seed(
      "payments",
      ctx.db.table("payments").map((p) =>
        p.stripe_payment_intent_id === args.p_payment_intent_id
          ? { ...p, status: args.p_status }
          : p
      ),
    );
    return { id: "50000000-0000-4000-8000-000000000001", status: args.p_status };
  });
  f.db.http.on(
    "DELETE",
    `${STRIPE}/customers/:id`,
    (_req, { params }) =>
      params.id === "cus_1Gone"
        ? jsonResponse(stripeErrorBody("invalid_request_error", "No such customer"), 404)
        : jsonResponse({ id: params.id, object: "customer", deleted: true }),
  );
  return f;
}

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

function pendingSheet(id: string, pi: string, extra: Row = {}): Row {
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
    ...extra,
  };
}

const eraseCalls = (f: F) =>
  f.rpcCalls.filter((c) => c.name === "erase_customer").map((c) => c.args.p_dry_run);

const deletedCustomers = (f: F) =>
  f.stripe("DELETE", "/customers/:id").map((c) => c.url.pathname.split("/").at(-1));

Deno.test("erase_customer: without confirm it is the dry run — nothing changes, Stripe is not called", async () => {
  const f = setup({
    sessions: [session("cs_1Pay", { invoice_id: INVOICE, kind: "payment" })],
  });
  const res = await f.call(erase, "owner");
  assertEquals(res.status, 200);
  assertEquals(await res.json(), {
    dry_run: true,
    mode: "anonymised",
    erased: false,
    membership_active: false,
    payments_in_progress: 0,
    open_checkouts: 0,
    saved_cards: 2,
  });
  assertEquals(f.stripeCalls(), []);
  assertEquals(eraseCalls(f), [true]);
  const call = f.rpcCalls.find((c) => c.name === "erase_customer");
  assertEquals(call?.args, {
    p_shop_id: SHOP,
    p_customer_id: CUSTOMER,
    p_actor: USERS.owner,
    p_dry_run: true,
  });
  assertEquals(f.db.table("customer_payment_methods").filter((c) => c.shop_id === SHOP).length, 2);
});

Deno.test("erase_customer: settles, expires pages, detaches cards, deletes the Stripe Customer, then erases", async () => {
  const f = setup({
    payments: [pendingSheet("ffffffff-ffff-4fff-8fff-0000000000a1", "pi_1Sheet")],
    intents: {
      pi_1Sheet: {
        status: "requires_payment_method",
        amount: 12_345,
        metadata: { shop_id: SHOP, invoice_id: INVOICE, source: "payment_sheet" },
      },
    },
    sessions: [
      session("cs_1Pay", { invoice_id: INVOICE, kind: "payment" }),
      session("cs_1Setup", { customer_id: CUSTOMER }, { mode: "setup" }),
      // another shop's session on the same Stripe customer id: not ours
      session("cs_1Foreign", {}, { metadata: { shop_id: OTHER_SHOP } }),
      // opened for the job's previous customer: found through its hold
      session("cs_1Before", { job_id: JOB, kind: "deposit" }, { customer: "cus_1Before" }),
    ],
    holds: [{
      stripe_checkout_session_id: "cs_1Before",
      shop_id: SHOP,
      job_id: JOB,
      expires_at: HOLD_UNTIL,
    }],
  });
  const res = await f.call(confirmErase, "admin");
  assertEquals(res.status, 200);
  assertEquals(await res.json(), {
    erased: true,
    mode: "anonymised",
    payments_cancelled: 1,
    sessions_expired: 3,
    cards_removed: 2,
    stripe_customers_deleted: 1,
  });
  // the sheet was cancelled and recorded
  assertEquals(f.intents.pi_1Sheet?.status, "canceled");
  // every page of this shop's customer is closed and released
  assertEquals(
    ["cs_1Pay", "cs_1Setup", "cs_1Before", "cs_1Foreign"].map((id) =>
      f.sessions.find((x) => x.id === id)?.status
    ),
    ["expired", "expired", "expired", "open"],
  );
  assertEquals(f.db.table("job_checkout_holds"), []);
  // cards detached in Stripe, then removed from the CRM
  assertEquals(
    [f.paymentMethods.pm_1Default?.customer, f.paymentMethods.pm_1Other?.customer],
    [null, null],
  );
  assertEquals(
    f.db.table("customer_payment_methods").filter((c) => c.customer_id === CUSTOMER),
    [],
  );
  // the Stripe Customer is deleted on the connected account, idempotently
  assertEquals(deletedCustomers(f), ["cus_1Saved"]);
  const del = f.stripe("DELETE", "/customers/:id")[0];
  assertEquals(del?.headers.get("stripe-account"), ACCT);
  assertMatch(del?.headers.get("idempotency-key") ?? "", /^dcrm:customer_delete:/);
  // dry run first, the real erase last (after every Stripe change)
  assertEquals(eraseCalls(f), [true, false]);
  const last = f.db.requests.filter((r) => r.kind === "rpc").at(-1);
  assertEquals(last?.target, "erase_customer");
  assert(f.db.requests.every((r) => r.target !== "erase_customer" || r.role === "service_role"));
  assertEquals(f.db.table("customers").find((c) => c.id === CUSTOMER)?.stripe_customer_id, null);
  // the log carries ids and counts, never the customer's details
  const logged = JSON.stringify(f.logs.records);
  assert(logged.includes("customer_erased"));
  for (const secret of ["Ada", "Lovelace", "ada@example.com", "+12055550123"]) {
    assert(!logged.includes(secret), `log contains ${secret}`);
  }
});

Deno.test("erase_customer: an active membership refuses before anything changes", async () => {
  const f = setup({ membership: { status: "active", stripe_subscription_id: "sub_1Live" } });
  assertEquals(await errorOf(await f.call(confirmErase, "owner")), [409, "conflict", {
    reason: "membership_active",
  }]);
  assertEquals(f.stripeCalls(), []);
  assertEquals(eraseCalls(f), [true]);
});

Deno.test("erase_customer: money still moving refuses before cards or the Stripe Customer are touched", async () => {
  // an ACH debit still clearing
  const clearing = setup({
    payments: [pendingSheet("ffffffff-ffff-4fff-8fff-0000000000b1", "pi_1Ach", {
      status: "processing",
      method: "ach_debit",
    })],
  });
  assertEquals(await errorOf(await clearing.call(confirmErase, "owner")), [409, "conflict", {
    reason: "payment_in_progress",
  }]);
  // a sheet whose intent is processing
  const processing = setup({
    payments: [pendingSheet("ffffffff-ffff-4fff-8fff-0000000000b2", "pi_1Busy")],
    intents: {
      pi_1Busy: {
        status: "processing",
        amount: 12_345,
        metadata: { shop_id: SHOP, invoice_id: INVOICE, source: "payment_sheet" },
      },
    },
  });
  assertEquals((await errorOf(await processing.call(confirmErase, "owner")))[2], {
    reason: "payment_in_progress",
  });
  // a pay page that was just paid (the other page is still closed)
  const paid = setup({
    sessions: [
      session("cs_1Paid", { invoice_id: INVOICE, kind: "payment" }, { status: "complete" }),
      session("cs_1Open", { invoice_id: INVOICE, kind: "payment" }),
    ],
    invoiceHolds: [{
      stripe_checkout_session_id: "cs_1Paid",
      shop_id: SHOP,
      invoice_id: INVOICE,
      expires_at: HOLD_UNTIL,
    }],
  });
  assertEquals((await errorOf(await paid.call(confirmErase, "owner")))[2], {
    reason: "payment_in_progress",
  });
  assertEquals(paid.sessions.find((x) => x.id === "cs_1Open")?.status, "expired");
  assertEquals(paid.db.table("invoice_checkout_holds").length, 1);
  for (const f of [clearing, processing, paid]) {
    assertEquals(f.stripe("POST", "/payment_methods/:id/detach"), []);
    assertEquals(deletedCustomers(f), []);
    assertEquals(eraseCalls(f), [true]);
    assertEquals(
      f.db.table("customer_payment_methods").filter((c) => c.shop_id === SHOP).length,
      2,
    );
  }
});

Deno.test("erase_customer: the RPC's refusals are 409 with their reason", async () => {
  for (const reason of ["checkout_open", "saved_cards", "payment_in_progress"]) {
    const f = setup({}, { refuse: reason });
    assertEquals(await errorOf(await f.call(confirmErase, "owner")), [409, "conflict", {
      reason,
    }], reason);
    assertEquals(eraseCalls(f), [true, false]);
  }
});

Deno.test("erase_customer: owners and admins only; the customer must be the shop's", async () => {
  for (const who of ["manager", "tech", "outsider"] as const) {
    const f = setup();
    assertEquals((await errorOf(await f.call(confirmErase, who)))[0], 403, who);
    assertEquals(f.stripeCalls(), [], who);
    assertEquals(eraseCalls(f), [], who);
  }
  const f = setup();
  assertEquals((await errorOf(await f.call(confirmErase, "none"))).slice(0, 2), [
    401,
    "unauthorized",
  ]);
  const unknown = await f.call(
    { ...confirmErase, customer_id: "cccccccc-cccc-4ccc-8ccc-00000000dead" },
    "owner",
  );
  assertEquals((await errorOf(unknown)).slice(0, 2), [404, "not_found"]);
  assertEquals(f.stripeCalls(), []);
  assertEquals((await errorOf(await f.call({ ...erase, extra: 1 }, "owner")))[0], 400);
});

Deno.test("erase_customer: merged duplicates go with the customer; a shared Stripe Customer is kept", async () => {
  const f = setup({
    cards: [{
      id: "40000000-0000-4000-8000-0000000000d1",
      shop_id: SHOP,
      customer_id: CUSTOMER,
      stripe_payment_method_id: "pm_1Moved",
      // moved by the merge: still attached to the duplicate's Stripe customer
      stripe_customer_id: "cus_1Dup",
      brand: "visa",
      last4: "4242",
      is_default: true,
    }],
    paymentMethods: { pm_1Moved: { customer: "cus_1Dup" } },
    sessions: [
      session("cs_1DupLink", { invoice_id: INVOICE, kind: "payment" }, { customer: "cus_1Dup" }),
    ],
  });
  f.db.seed("customers", [
    ...f.db.table("customers"),
    {
      id: DUPLICATE,
      shop_id: SHOP,
      first_name: "Ada",
      last_name: "L",
      merged_into_id: CUSTOMER,
      stripe_customer_id: "cus_1Dup",
      archived_at: "2026-09-01T00:00:00Z",
    },
    // another person of the shop who (somehow) shares the main Stripe customer
    { id: NEIGHBOUR, shop_id: SHOP, first_name: "Bo", stripe_customer_id: "cus_1Saved" },
  ]);
  const res = await f.call(confirmErase, "owner");
  assertEquals(res.status, 200);
  const body = await res.json();
  assertEquals([body.cards_removed, body.sessions_expired, body.stripe_customers_deleted], [
    1,
    1,
    1,
  ]);
  assertEquals(f.paymentMethods.pm_1Moved?.customer, null);
  assertEquals(f.sessions.find((x) => x.id === "cs_1DupLink")?.status, "expired");
  assertEquals(deletedCustomers(f), ["cus_1Dup"]);
  assert(JSON.stringify(f.logs.records).includes("stripe_customer_shared"));
  assertEquals(
    f.db.table("customers").filter((c) => c.erased_at).map((c) => c.id).sort(),
    [CUSTOMER, DUPLICATE].sort(),
  );
});

Deno.test("erase_customer: a Stripe Customer already gone and a shop without Stripe", async () => {
  const gone = setup({ customer: { stripe_customer_id: "cus_1Gone" }, cards: [] });
  const res = await gone.call(confirmErase, "owner");
  assertEquals(res.status, 200);
  assertEquals((await res.json()).stripe_customers_deleted, 0);
  assertEquals(deletedCustomers(gone), ["cus_1Gone"]);
  assertEquals(eraseCalls(gone), [true, false]);

  const noStripe = setup({ account: null, cards: [] });
  const quiet = await noStripe.call(confirmErase, "owner");
  assertEquals(await quiet.json(), {
    erased: true,
    mode: "anonymised",
    payments_cancelled: 0,
    sessions_expired: 0,
    cards_removed: 0,
    stripe_customers_deleted: 0,
  });
  assertEquals(noStripe.stripeCalls(), []);
});
