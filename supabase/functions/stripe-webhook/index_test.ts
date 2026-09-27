/**
 * stripe-webhook end to end: signed deliveries -> real handler -> real
 * supabase-js + Stripe SDK against FakeSupabase / FakeFetch. The money RPCs
 * are faked below with the SAME rules as migrations 0011/0013 (idempotent,
 * never downgrade received money, cumulative refunds, subscription status
 * machine); the SQL suite tests the real functions.
 */
import { assert, assertEquals, assertExists } from "@std/assert";
import type { ErrorBody } from "../_shared/http.ts";
import {
  FakeRpcError,
  FakeSupabase,
  FUNCTIONS_BASE,
  jsonResponse,
  memoryLogger,
  type Row,
  signStripePayload,
  stripeErrorBody,
  stripeEvent,
  TEST_ENV,
} from "../_shared/testing/mod.ts";
import { refundStatus } from "./handlers.ts";
import { makeHandler, type WebhookResponse } from "./index.ts";

const SHOP = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const OTHER_SHOP = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const INVOICE = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
const JOB = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
const CUSTOMER = "11111111-1111-4111-8111-111111111111";
const OTHER_CUSTOMER = "22222222-2222-4222-8222-222222222222";
const MEMBERSHIP = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";
const ACCT = "acct_1ShopAccount0";
const OTHER_ACCT = "acct_1OtherShop000";
const STRANGER_ACCT = "acct_1NotConnected0";
const SECRET = TEST_ENV.STRIPE_WEBHOOK_SECRET as string;
const STRIPE = "https://api.stripe.com/v1";
const NOW = new Date("2026-09-27T12:00:00.000Z");
const PAID_AT = 1_790_000_000; // charge.created

// ---------------------------------------------------------------------------
// Fake SQL helpers (rules mirror 0011 / 0013)
// ---------------------------------------------------------------------------

const RECEIVED = ["succeeded", "partially_refunded", "refunded"];

/** payment_refund_status (0012). */
function sqlRefundStatus(amount: number, tip: number, refunded: number): string {
  if (refunded <= 0) return "succeeded";
  return refunded >= amount + tip ? "refunded" : "partially_refunded";
}

function mutate<T>(db: FakeSupabase, table: string, fn: (rows: Row[]) => T): T {
  const rows = db.table(table);
  const result = fn(rows);
  db.seed(table, rows);
  return result;
}

function installMoneyRpcs(db: FakeSupabase): void {
  db.onRpc("upsert_stripe_payment", (a, { role }) => {
    assertEquals(role, "service_role");
    const status = a.p_status as string;
    const amount = a.p_amount_cents as number;
    const tip = (a.p_tip_cents as number | null) ?? 0;
    if (!["pending", "succeeded", "failed", "cancelled"].includes(status)) {
      throw new FakeRpcError("22023", "refund states are applied with apply_stripe_refund");
    }
    if (!["card", "card_present"].includes(a.p_method as string)) {
      throw new FakeRpcError("22023", "Stripe payments are card or card_present");
    }
    if (amount < 0 || tip < 0 || amount + tip <= 0) {
      throw new FakeRpcError("22023", "amount and tip must be non-negative and not both zero");
    }
    return mutate(db, "payments", (rows) => {
      let row = rows.find((r) => r.stripe_payment_intent_id === a.p_payment_intent_id);
      if (!row) {
        // payments_*_fk (0012): every linked record must exist in the shop
        for (
          const [arg, table] of [
            ["p_invoice_id", "invoices"],
            ["p_job_id", "jobs"],
            ["p_customer_id", "customers"],
            ["p_membership_id", "memberships"],
          ] as const
        ) {
          const id = a[arg];
          if (id && !db.table(table).some((r) => r.id === id && r.shop_id === a.p_shop_id)) {
            throw new FakeRpcError(
              "23503",
              `insert or update on table "payments" violates ${table}`,
            );
          }
        }
        if (a.p_membership_id ? a.p_kind !== "membership" : a.p_kind === "membership") {
          throw new FakeRpcError("23514", "payments_membership_kind");
        }
        // payments_before_write: linkage derived from the parents
        let customer = a.p_customer_id as string | null;
        let job = a.p_job_id as string | null;
        const jobRow = db.table("jobs").find((j) => j.id === job && j.shop_id === a.p_shop_id);
        if (jobRow) customer = jobRow.customer_id as string;
        const invoice = db.table("invoices").find((i) =>
          i.id === a.p_invoice_id && i.shop_id === a.p_shop_id
        );
        if (invoice) {
          if (customer && customer !== invoice.customer_id) {
            throw new FakeRpcError("23514", "payment customer does not match the invoice's");
          }
          customer = invoice.customer_id as string;
          job = invoice.job_id as string;
        }
        const membership = db.table("memberships").find((m) =>
          m.id === a.p_membership_id && m.shop_id === a.p_shop_id
        );
        if (membership) customer = membership.customer_id as string;
        if (!customer) throw new FakeRpcError("23502", "customer_id is required");
        row = {
          id: crypto.randomUUID(),
          shop_id: a.p_shop_id,
          invoice_id: a.p_invoice_id ?? null,
          job_id: job,
          customer_id: customer,
          membership_id: a.p_membership_id ?? null,
          kind: a.p_kind,
          method: a.p_method,
          status,
          amount_cents: amount,
          tip_cents: tip,
          refunded_cents: 0,
          stripe_payment_intent_id: a.p_payment_intent_id,
          stripe_charge_id: a.p_charge_id ?? null,
          stripe_checkout_session_id: a.p_checkout_session_id ?? null,
          card_brand: a.p_card_brand ?? null,
          card_last4: a.p_card_last4 ?? null,
          note: null,
          paid_at: status === "succeeded" ? (a.p_paid_at ?? NOW.toISOString()) : null,
        };
        rows.push(row);
        return { ...row };
      }
      if (row.shop_id !== a.p_shop_id) {
        throw new FakeRpcError("22023", "payment intent belongs to another shop");
      }
      const received = RECEIVED.includes(row.status as string);
      const next = received
        ? row.status
        : row.status === "cancelled" && status !== "succeeded"
        ? "cancelled"
        : status;
      Object.assign(row, {
        status: next,
        amount_cents: received ? row.amount_cents : amount,
        tip_cents: received ? row.tip_cents : tip,
        stripe_charge_id: row.stripe_charge_id ?? a.p_charge_id ?? null,
        stripe_checkout_session_id: row.stripe_checkout_session_id ?? a.p_checkout_session_id ??
          null,
        card_brand: row.card_brand ?? a.p_card_brand ?? null,
        card_last4: row.card_last4 ?? a.p_card_last4 ?? null,
        paid_at: next === "succeeded" && !received
          ? (a.p_paid_at ?? NOW.toISOString())
          : row.paid_at,
      });
      return { ...row };
    });
  });

  db.onRpc("apply_stripe_refund", (a) =>
    mutate(db, "payments", (rows) => {
      const row = rows.find((r) => r.stripe_payment_intent_id === a.p_payment_intent_id);
      if (!row) throw new FakeRpcError("P0002", "payment not found");
      const total = (row.amount_cents as number) + (row.tip_cents as number);
      const refunded = a.p_refunded_cents_total as number;
      if (refunded < 0 || refunded > total) {
        throw new FakeRpcError("22023", "refunded total must be between 0 and the charged amount");
      }
      if (!RECEIVED.includes(row.status as string)) {
        throw new FakeRpcError("22023", `a ${row.status} payment cannot be refunded`);
      }
      const next = Math.max(row.refunded_cents as number, refunded);
      row.refunded_cents = next;
      row.status = sqlRefundStatus(row.amount_cents as number, row.tip_cents as number, next);
      return { ...row };
    }));

  db.onRpc("upsert_customer_payment_method", (a) => {
    const customer = db.table("customers").find((c) =>
      c.id === a.p_customer_id && c.shop_id === a.p_shop_id
    );
    if (!customer) throw new FakeRpcError("P0002", "customer not found");
    return mutate(db, "customer_payment_methods", (rows) => {
      const existing = rows.find((r) =>
        r.shop_id === a.p_shop_id && r.stripe_payment_method_id === a.p_stripe_payment_method_id
      );
      if (existing && existing.customer_id !== a.p_customer_id) {
        throw new FakeRpcError("22023", "payment method belongs to another customer");
      }
      const makeDefault = a.p_make_default === true || existing?.is_default === true ||
        !rows.some((r) =>
          r.shop_id === a.p_shop_id && r.customer_id === a.p_customer_id && r.is_default
        );
      if (makeDefault) {
        for (const r of rows) {
          if (r.customer_id === a.p_customer_id && r !== existing) r.is_default = false;
        }
      }
      const values = {
        shop_id: a.p_shop_id,
        customer_id: a.p_customer_id,
        stripe_payment_method_id: a.p_stripe_payment_method_id,
        brand: a.p_brand,
        last4: a.p_last4,
        exp_month: a.p_exp_month,
        exp_year: a.p_exp_year,
        is_default: makeDefault,
      };
      if (existing) {
        Object.assign(existing, values);
        return { ...existing };
      }
      const row = { id: crypto.randomUUID(), ...values };
      rows.push(row);
      return { ...row };
    });
  });

  db.onRpc("sync_stripe_subscription", (a) =>
    mutate(db, "memberships", (rows) => {
      let row = rows.find((m) => m.stripe_subscription_id === a.p_subscription_id);
      if (row && row.shop_id !== a.p_shop_id) {
        throw new FakeRpcError("22023", "subscription belongs to another shop");
      }
      if (!row && a.p_membership_id) {
        row = rows.find((m) => m.id === a.p_membership_id && m.shop_id === a.p_shop_id);
        if (
          row && row.stripe_subscription_id && row.stripe_subscription_id !== a.p_subscription_id
        ) {
          throw new FakeRpcError("22023", "membership is already linked to another subscription");
        }
      }
      if (!row) throw new FakeRpcError("P0002", "membership for subscription not found");
      const status = row.status === "cancelled"
        ? "cancelled"
        : a.p_status === "incomplete" && row.status !== "incomplete"
        ? row.status
        : a.p_status;
      Object.assign(row, {
        stripe_subscription_id: a.p_subscription_id,
        status,
        current_period_end: a.p_current_period_end ?? row.current_period_end,
        cancel_at_period_end: status === "cancelled" ? false : a.p_cancel_at_period_end ?? false,
        started_at: status === "active" || status === "past_due"
          ? row.started_at ?? a.p_now
          : row.started_at,
        cancelled_at: status === "cancelled" ? row.cancelled_at ?? a.p_now : null,
      });
      return { ...row };
    }));
}

// ---------------------------------------------------------------------------
// Fake Stripe (objects on connected accounts, retrieved by id)
// ---------------------------------------------------------------------------

class FakeStripe {
  readonly objects = new Map<string, Record<string, unknown>>();
  readonly invoicePayments = new Map<string, Record<string, unknown>[]>();

  put(object: Record<string, unknown>): this {
    this.objects.set(object.id as string, object);
    return this;
  }

  install(db: FakeSupabase): void {
    const byId = (resource: string) =>
    (
      _req: Request,
      { params, url }: { params: Record<string, string | undefined>; url: URL },
    ) => {
      const object = this.objects.get(params.id ?? "");
      if (!object) {
        return jsonResponse(
          stripeErrorBody("invalid_request_error", `No such ${resource}`),
          404,
        );
      }
      const expanded = { ...object };
      // expand[]=latest_charge / payment_method (the SDK sends expand[0]=...)
      for (const [key, value] of url.searchParams) {
        if (!key.startsWith("expand")) continue;
        const ref = expanded[value];
        if (typeof ref === "string" && this.objects.has(ref)) {
          expanded[value] = this.objects.get(ref);
        }
      }
      return jsonResponse(expanded);
    };
    for (
      const resource of [
        "payment_intents",
        "charges",
        "payment_methods",
        "setup_intents",
        "subscriptions",
        "invoices",
        "accounts",
      ]
    ) {
      db.http.on("GET", `${STRIPE}/${resource}/:id`, byId(resource));
    }
    db.http.on("GET", `${STRIPE}/invoice_payments`, (_req, { url }) =>
      jsonResponse({
        object: "list",
        url: "/v1/invoice_payments",
        has_more: false,
        data: this.invoicePayments.get(url.searchParams.get("invoice") ?? "") ?? [],
      }));
  }
}

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

function setup(options: { membership?: Partial<Row> } = {}) {
  const db = new FakeSupabase({
    tables: {
      shop_stripe_accounts: [
        {
          shop_id: SHOP,
          stripe_account_id: ACCT,
          charges_enabled: false,
          payouts_enabled: false,
          details_submitted: false,
        },
        {
          shop_id: OTHER_SHOP,
          stripe_account_id: OTHER_ACCT,
          charges_enabled: true,
          payouts_enabled: true,
          details_submitted: true,
        },
      ],
      stripe_events: [],
      payments: [],
      customer_payment_methods: [],
      customers: [
        { id: CUSTOMER, shop_id: SHOP, stripe_customer_id: "cus_1Customer" },
        { id: OTHER_CUSTOMER, shop_id: OTHER_SHOP, stripe_customer_id: "cus_1Other" },
      ],
      invoices: [{ id: INVOICE, shop_id: SHOP, job_id: JOB, customer_id: CUSTOMER }],
      jobs: [{ id: JOB, shop_id: SHOP, customer_id: CUSTOMER }],
      memberships: [{
        id: MEMBERSHIP,
        shop_id: SHOP,
        customer_id: CUSTOMER,
        status: "incomplete",
        stripe_subscription_id: null,
        current_period_end: null,
        cancel_at_period_end: false,
        started_at: null,
        cancelled_at: null,
        ...options.membership,
      }],
    },
    tableOptions: {
      stripe_events: {
        primaryKey: ["id"],
        defaults: () => ({ attempts: 1, processed_at: null, error: null, account: null }),
      },
      shop_stripe_accounts: { primaryKey: ["shop_id"], unique: [["stripe_account_id"]] },
    },
  });
  installMoneyRpcs(db);
  const stripe = new FakeStripe();
  stripe.install(db);
  const logs = memoryLogger();
  const handler = makeHandler({
    env: db.env(),
    fetch: db.http.fetch,
    logger: logs.logger,
    now: () => NOW,
    maxNetworkRetries: 0,
  });
  return { db, stripe, logs, handler };
}

function charge(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    id: "ch_1Charge",
    object: "charge",
    amount: 11_000,
    amount_captured: 11_000,
    amount_refunded: 0,
    captured: true,
    created: PAID_AT,
    payment_intent: "pi_1Invoice",
    payment_method_details: {
      type: "card",
      card: { brand: "visa", last4: "4242", exp_month: 12, exp_year: 2030 },
    },
    ...overrides,
  };
}

function intent(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    id: "pi_1Invoice",
    object: "payment_intent",
    amount: 11_000,
    amount_received: 11_000,
    status: "succeeded",
    currency: "usd",
    customer: "cus_1Customer",
    payment_method: "pm_1Card",
    payment_method_types: ["card"],
    setup_future_usage: null,
    latest_charge: "ch_1Charge",
    metadata: {
      shop_id: SHOP,
      invoice_id: INVOICE,
      job_id: JOB,
      customer_id: CUSTOMER,
      kind: "payment",
      tip_cents: "1000",
    },
    ...overrides,
  };
}

function subscription(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    id: "sub_1Member",
    object: "subscription",
    status: "active",
    cancel_at_period_end: false,
    cancel_at: null,
    canceled_at: null,
    ended_at: null,
    start_date: 1_789_000_000,
    customer: "cus_1Customer",
    metadata: { shop_id: SHOP, membership_id: MEMBERSHIP, customer_id: CUSTOMER },
    items: { object: "list", data: [{ id: "si_1", current_period_end: 1_791_600_000 }] },
    ...overrides,
  };
}

function membershipInvoice(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    id: "in_1Renewal",
    object: "invoice",
    status: "paid",
    amount_paid: 4_900,
    billing_reason: "subscription_cycle",
    parent: {
      type: "subscription_details",
      quote_details: null,
      subscription_details: {
        subscription: "sub_1Member",
        metadata: { shop_id: SHOP, membership_id: MEMBERSHIP },
      },
    },
    ...overrides,
  };
}

let eventCounter = 0;

function event(
  type: string,
  object: Record<string, unknown>,
  options: { id?: string; account?: string | null } = {},
): Record<string, unknown> {
  eventCounter++;
  return stripeEvent({
    id: options.id ?? `evt_1Test${eventCounter}`,
    type,
    object,
    ...(options.account === null ? {} : { account: options.account ?? ACCT }),
  });
}

async function deliver(
  handler: (req: Request) => Promise<Response>,
  body: Record<string, unknown> | string,
  options: { secret?: string; signature?: string | null; method?: string } = {},
): Promise<Response> {
  const payload = typeof body === "string" ? body : JSON.stringify(body);
  const headers = new Headers({ "content-type": "application/json" });
  const signature = options.signature === undefined
    ? await signStripePayload(payload, options.secret ?? SECRET)
    : options.signature;
  if (signature !== null) headers.set("stripe-signature", signature);
  return await handler(
    new Request(`${FUNCTIONS_BASE}/stripe-webhook`, {
      method: options.method ?? "POST",
      headers,
      body: options.method === "GET" ? undefined : payload,
    }),
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

function payment(db: FakeSupabase, pi = "pi_1Invoice"): Row {
  const row = db.table("payments").find((p) => p.stripe_payment_intent_id === pi);
  assertExists(row, `payment for ${pi}`);
  return row;
}

function ledger(db: FakeSupabase, id: string): Row | undefined {
  return db.table("stripe_events").find((e) => e.id === id);
}

function stripeCalls(db: FakeSupabase) {
  return db.http.calls.filter((c) => c.url.hostname === "api.stripe.com");
}

// ---------------------------------------------------------------------------
// Signature, method, unknown types
// ---------------------------------------------------------------------------

Deno.test("webhook: a bad or missing signature is 400 and nothing is recorded", async () => {
  const { db, stripe, handler } = setup();
  stripe.put(intent()).put(charge());
  const body = event("payment_intent.succeeded", intent());

  const wrong = await deliver(handler, body, { secret: "whsec_SomeoneElse0000000000" });
  assertEquals(wrong.status, 400);
  assertEquals((await wrong.json() as ErrorBody).code, "invalid_signature");

  const missing = await deliver(handler, body, { signature: null });
  assertEquals(missing.status, 400);
  assertEquals((await missing.json() as ErrorBody).code, "invalid_signature");

  // signed payload altered after signing
  const payload = JSON.stringify(body);
  const signature = await signStripePayload(payload, SECRET);
  const tampered = await deliver(handler, payload.replace("11000", "99000"), { signature });
  assertEquals(tampered.status, 400);

  // stale timestamp (outside the 5 minute tolerance)
  const stale = await signStripePayload(payload, SECRET, Math.floor(Date.now() / 1000) - 3600);
  assertEquals((await deliver(handler, body, { signature: stale })).status, 400);

  assertEquals(db.table("stripe_events"), []);
  assertEquals(db.table("payments"), []);
  assertEquals(stripeCalls(db).length, 0);
});

Deno.test("webhook: only POST is accepted", async () => {
  const { handler } = setup();
  const res = await deliver(handler, "", { method: "GET", signature: null });
  assertEquals(res.status, 405);
  await res.body?.cancel();
});

Deno.test("webhook: unknown event types are acknowledged without side effects", async () => {
  const { db, handler } = setup();
  const res = await deliver(
    handler,
    event("customer.created", { id: "cus_1New", object: "customer" }),
  );
  assertEquals(await ok(res), { received: true, handled: false, duplicate: false, result: null });
  assertEquals(db.table("stripe_events"), []);
  assertEquals(db.requests.length, 0);
});

// ---------------------------------------------------------------------------
// payment_intent.*
// ---------------------------------------------------------------------------

Deno.test("payment_intent.succeeded records the payment: DB-linked, tip split, card from charge", async () => {
  const { db, stripe, handler } = setup();
  stripe.put(intent()).put(charge());
  const body = event("payment_intent.succeeded", intent(), { id: "evt_1Succeeded" });
  const res = await ok(await deliver(handler, body));
  assertEquals(res, { received: true, handled: true, duplicate: false, result: "applied" });

  const row = payment(db);
  assertEquals(
    {
      shop_id: row.shop_id,
      invoice_id: row.invoice_id,
      job_id: row.job_id,
      customer_id: row.customer_id,
      kind: row.kind,
      method: row.method,
      status: row.status,
      amount_cents: row.amount_cents,
      tip_cents: row.tip_cents,
      stripe_charge_id: row.stripe_charge_id,
      card_brand: row.card_brand,
      card_last4: row.card_last4,
      paid_at: row.paid_at,
    },
    {
      shop_id: SHOP,
      invoice_id: INVOICE,
      job_id: JOB,
      customer_id: CUSTOMER,
      kind: "payment",
      method: "card",
      status: "succeeded",
      amount_cents: 10_000,
      tip_cents: 1_000,
      stripe_charge_id: "ch_1Charge",
      card_brand: "visa",
      card_last4: "4242",
      paid_at: new Date(PAID_AT * 1000).toISOString(),
    },
  );
  // the charge was read on the shop's connected account
  const chargeCall = db.http.callsTo("GET", `${STRIPE}/charges/:id`)[0];
  assertEquals(chargeCall?.headers.get("stripe-account"), ACCT);
  // every DB call is service_role
  assert(db.requests.every((r) => r.role === "service_role"));
  // the ledger marks it processed
  const entry = ledger(db, "evt_1Succeeded");
  assertEquals([entry?.account, entry?.processed_at, entry?.error], [
    ACCT,
    NOW.toISOString(),
    null,
  ]);
});

Deno.test("payment_intent.succeeded: a metadata tip beyond the charge is ignored", async () => {
  const { db, stripe, logs, handler } = setup();
  const pi = intent({ metadata: { ...intent().metadata as Row, tip_cents: "50000" } });
  stripe.put(pi).put(charge());
  await ok(await deliver(handler, event("payment_intent.succeeded", pi)));
  assertEquals([payment(db).amount_cents, payment(db).tip_cents], [11_000, 0]);
  assertEquals(logs.events("stripe_tip_ignored").length, 1);
});

Deno.test("payment_intent.succeeded with setup_future_usage saves the card (first = default)", async () => {
  const { db, stripe, handler } = setup();
  const pi = intent({
    setup_future_usage: "off_session",
    metadata: {
      shop_id: SHOP,
      job_id: JOB,
      customer_id: CUSTOMER,
      kind: "deposit",
      tip_cents: "0",
    },
  });
  stripe.put(pi).put(charge());
  await ok(await deliver(handler, event("payment_intent.succeeded", pi)));
  assertEquals(payment(db).kind, "deposit");
  assertEquals(db.table("customer_payment_methods").map(({ id: _id, ...r }) => r), [{
    shop_id: SHOP,
    customer_id: CUSTOMER,
    stripe_payment_method_id: "pm_1Card",
    brand: "visa",
    last4: "4242",
    exp_month: 12,
    exp_year: 2030,
    is_default: true,
  }]);
});

Deno.test("payment_intent.payment_failed / canceled record failed / cancelled payments", async () => {
  const { db, handler } = setup();
  const failed = intent({
    id: "pi_1Failed",
    status: "requires_payment_method",
    amount_received: 0,
    latest_charge: null,
  });
  await ok(await deliver(handler, event("payment_intent.payment_failed", failed)));
  assertEquals([payment(db, "pi_1Failed").status, payment(db, "pi_1Failed").paid_at], [
    "failed",
    null,
  ]);

  const canceled = intent({
    id: "pi_1Canceled",
    status: "canceled",
    amount_received: 0,
    latest_charge: null,
  });
  await ok(await deliver(handler, event("payment_intent.canceled", canceled)));
  assertEquals(payment(db, "pi_1Canceled").status, "cancelled");
  // no charge lookups for failures
  assertEquals(db.http.callsTo("GET", `${STRIPE}/charges/:id`).length, 0);
});

Deno.test("payment_intent.payment_failed: a declined PaymentSheet intent stays open (pending) until settled", async () => {
  const { db, logs, handler } = setup();
  const sheetMetadata = {
    ...(intent().metadata as Record<string, string>),
    source: "payment_sheet",
  };
  const declined = intent({
    id: "pi_1Sheet",
    status: "requires_payment_method",
    amount_received: 0,
    latest_charge: null,
    metadata: sheetMetadata,
    last_payment_error: {
      type: "card_error",
      code: "card_declined",
      decline_code: "insufficient_funds",
    },
  });
  // payment_sheet recorded the attempt as pending when it created the intent
  const first = await ok(await deliver(handler, event("payment_intent.payment_failed", declined)));
  assertEquals(first.result, "applied");
  // Still confirmable with another card: pending, so payment_sheet supersession,
  // cancel_open_payments and the stale-sheet sweep (which select pending rows)
  // still cancel it in Stripe.
  assertEquals([payment(db, "pi_1Sheet").status, payment(db, "pi_1Sheet").paid_at], [
    "pending",
    null,
  ]);
  assertEquals(logs.events("stripe_payment_declined_open")[0]?.decline_code, "insufficient_funds");
  assertEquals(rpcCalls(db, "upsert_stripe_payment")[0]?.p_status, "pending");

  // Settled (cancelled) by the sweep / a newer sheet: a late decline never reopens it.
  await ok(
    await deliver(
      handler,
      event("payment_intent.canceled", { ...declined, status: "canceled" }),
    ),
  );
  assertEquals(payment(db, "pi_1Sheet").status, "cancelled");
  await ok(await deliver(handler, event("payment_intent.payment_failed", declined)));
  assertEquals(payment(db, "pi_1Sheet").status, "cancelled");

  // Other flows (Checkout, charge_saved_card) still record the decline as failed.
  const saved = intent({
    id: "pi_1SavedCard",
    status: "requires_payment_method",
    amount_received: 0,
    latest_charge: null,
    metadata: { ...sheetMetadata, source: "charge_saved_card" },
  });
  await ok(await deliver(handler, event("payment_intent.payment_failed", saved)));
  assertEquals(payment(db, "pi_1SavedCard").status, "failed");
});

Deno.test("payment_intent.payment_failed: a declined sheet later confirmed with another card is recorded", async () => {
  const { db, stripe, handler } = setup();
  const metadata = { ...(intent().metadata as Record<string, string>), source: "payment_sheet" };
  await ok(
    await deliver(
      handler,
      event(
        "payment_intent.payment_failed",
        intent({
          status: "requires_payment_method",
          amount_received: 0,
          latest_charge: null,
          metadata,
        }),
      ),
    ),
  );
  assertEquals(payment(db).status, "pending");
  stripe.put(intent({ metadata })).put(charge());
  await ok(await deliver(handler, event("payment_intent.succeeded", intent({ metadata }))));
  assertEquals([payment(db).status, payment(db).amount_cents], ["succeeded", 10_000]);
  assertEquals(db.table("payments").length, 1);
});

Deno.test("payment_intent.*: an intent without our metadata is not a CRM payment", async () => {
  const { db, handler } = setup();
  const res = await ok(
    await deliver(handler, event("payment_intent.succeeded", intent({ metadata: {} }))),
  );
  assertEquals(res.result, "ignored");
  assertEquals(rpcCalls(db, "upsert_stripe_payment").length, 0);
});

// ---------------------------------------------------------------------------
// Tenant isolation
// ---------------------------------------------------------------------------

Deno.test("isolation: metadata naming another shop than event.account's is rejected", async () => {
  const { db, stripe, logs, handler } = setup();
  const foreign = intent({
    metadata: { shop_id: OTHER_SHOP, customer_id: OTHER_CUSTOMER, kind: "payment" },
  });
  stripe.put(foreign).put(charge());
  const res = await ok(await deliver(handler, event("payment_intent.succeeded", foreign)));
  assertEquals(res.result, "ignored");
  assertEquals(rpcCalls(db, "upsert_stripe_payment").length, 0);
  assertEquals(db.table("payments"), []);
  const warn = logs.events("stripe_event_ignored").find((r) => r.reason === "shop_mismatch");
  assertExists(warn);
  assertEquals(warn.level, "warn");

  // the same applies to every object type: checkout, setup intents, subscriptions
  for (
    const [type, object] of [
      ["checkout.session.completed", {
        id: "cs_1Foreign",
        object: "checkout.session",
        mode: "payment",
        payment_status: "paid",
        payment_intent: "pi_1Invoice",
        metadata: { shop_id: OTHER_SHOP },
      }],
      ["setup_intent.succeeded", {
        id: "seti_1Foreign",
        object: "setup_intent",
        status: "succeeded",
        payment_method: "pm_1Card",
        customer: "cus_1Other",
        metadata: { shop_id: OTHER_SHOP, customer_id: OTHER_CUSTOMER },
      }],
      ["customer.subscription.updated", subscription({ metadata: { shop_id: OTHER_SHOP } })],
    ] as const
  ) {
    const r = await ok(await deliver(handler, event(type, object as Record<string, unknown>)));
    assertEquals(r.result, "ignored", type);
  }
  assertEquals(db.table("customer_payment_methods"), []);
  assertEquals(db.table("memberships")[0]?.stripe_subscription_id, null);
  assertEquals(stripeCalls(db).length, 0);
});

Deno.test("isolation: events of unknown or missing connected accounts are ignored", async () => {
  const { db, stripe, handler } = setup();
  stripe.put(intent()).put(charge());
  const stranger = await ok(
    await deliver(handler, event("payment_intent.succeeded", intent(), { account: STRANGER_ACCT })),
  );
  assertEquals(stranger.result, "ignored");
  const platform = await ok(
    await deliver(handler, event("payment_intent.succeeded", intent(), { account: null })),
  );
  assertEquals(platform.result, "ignored");
  assertEquals(db.table("payments"), []);
  // both deliveries are still recorded (and processed) in the ledger
  assertEquals(db.table("stripe_events").every((e) => e.processed_at !== null), true);
});

Deno.test("isolation: a refund for another shop's payment intent is ignored", async () => {
  const { db, handler } = setup();
  db.seed("payments", [{
    id: "p-other",
    shop_id: OTHER_SHOP,
    customer_id: OTHER_CUSTOMER,
    status: "succeeded",
    kind: "payment",
    amount_cents: 5_000,
    tip_cents: 0,
    refunded_cents: 0,
    stripe_payment_intent_id: "pi_1Invoice",
  }]);
  const res = await ok(
    await deliver(handler, event("charge.refunded", charge({ amount_refunded: 5_000 }))),
  );
  assertEquals(res.result, "ignored");
  assertEquals(rpcCalls(db, "apply_stripe_refund").length, 0);
  assertEquals(payment(db).refunded_cents, 0);
});

// ---------------------------------------------------------------------------
// Idempotency
// ---------------------------------------------------------------------------

Deno.test("idempotency: a replay of a processed event is acknowledged without re-running", async () => {
  const { db, stripe, handler } = setup();
  stripe.put(intent()).put(charge());
  const body = event("payment_intent.succeeded", intent(), { id: "evt_1Replay" });
  assertEquals((await ok(await deliver(handler, body))).duplicate, false);
  const replay = await ok(await deliver(handler, body));
  assertEquals(replay, { received: true, handled: true, duplicate: true, result: null });
  assertEquals(rpcCalls(db, "upsert_stripe_payment").length, 1);
  assertEquals(db.table("payments").length, 1);
  assertEquals(ledger(db, "evt_1Replay")?.attempts, 1);
});

Deno.test("idempotency: a failed attempt answers 500 and the redelivery is processed", async () => {
  const { db, stripe, logs, handler } = setup();
  stripe.put(intent()).put(charge());
  // First attempt: the database times out inside the RPC.
  const real = db.table("payments");
  let calls = 0;
  const outage = replaceRpc(db, "upsert_stripe_payment", () => {
    calls++;
    throw new FakeRpcError("57014", "canceling statement due to statement timeout", {
      status: 500,
    });
  });
  const body = event("payment_intent.succeeded", intent(), { id: "evt_1Retry" });
  const first = await deliver(handler, body);
  assertEquals(first.status, 500);
  const err = await first.json() as ErrorBody;
  assertEquals(err.code, "internal_error");
  assert(!JSON.stringify(err).includes("statement timeout"), "internals must not leak");
  assertEquals(calls, 1);
  assertEquals(db.table("payments"), real);
  const failed = ledger(db, "evt_1Retry");
  assertEquals(failed?.processed_at, null);
  assert(String(failed?.error).includes("upsert_stripe_payment failed (57014)"));
  assertExists(logs.events("request_failed")[0]);

  // Stripe redelivers the same event: it runs again and succeeds.
  outage.restore();
  const retry = await ok(await deliver(handler, body));
  assertEquals(retry, { received: true, handled: true, duplicate: false, result: "applied" });
  const done = ledger(db, "evt_1Retry");
  assertEquals([done?.attempts, done?.processed_at, done?.error], [2, NOW.toISOString(), null]);
  assertEquals(payment(db).status, "succeeded");

  // ...and only now is it a duplicate.
  assertEquals((await ok(await deliver(handler, body))).duplicate, true);
});

Deno.test("idempotency: a Stripe outage while processing is a 500 (retried), not a 5xx leak", async () => {
  const { db, stripe, handler } = setup();
  stripe.put(intent());
  db.http.once(
    "GET",
    `${STRIPE}/charges/:id`,
    () => jsonResponse(stripeErrorBody("api_error", "Stripe internal detail"), 500),
  );
  stripe.put(charge());
  const body = event("payment_intent.succeeded", intent(), { id: "evt_1StripeDown" });
  const first = await deliver(handler, body);
  assertEquals(first.status, 500);
  const err = await first.json() as ErrorBody;
  assertEquals(err.code, "internal_error");
  assert(!JSON.stringify(err).includes("Stripe internal detail"));
  assertEquals(ledger(db, "evt_1StripeDown")?.processed_at, null);
  await ok(await deliver(handler, body));
  assertEquals(payment(db).card_last4, "4242");
});

/** Replaces an RPC handler until `restore()` puts the fake SQL helper back. */
function replaceRpc(
  db: FakeSupabase,
  fn: string,
  handler: Parameters<FakeSupabase["onRpc"]>[1],
): { restore(): void } {
  db.onRpc(fn, handler);
  return {
    restore() {
      installMoneyRpcs(db);
    },
  };
}

// ---------------------------------------------------------------------------
// Out-of-order delivery
// ---------------------------------------------------------------------------

Deno.test("out of order: failure / pending after success never downgrade the payment", async () => {
  const { db, stripe, handler } = setup();
  stripe.put(intent()).put(charge());
  await ok(await deliver(handler, event("payment_intent.succeeded", intent())));
  // An older payment_failed (first card declined) arrives late.
  await ok(
    await deliver(
      handler,
      event(
        "payment_intent.payment_failed",
        intent({ status: "requires_payment_method", amount: 9_999, amount_received: 0 }),
      ),
    ),
  );
  // A checkout completion reporting the payment as still processing.
  await ok(
    await deliver(
      handler,
      event("checkout.session.completed", {
        id: "cs_1Late",
        object: "checkout.session",
        mode: "payment",
        payment_status: "unpaid",
        payment_intent: "pi_1Invoice",
        amount_total: 11_000,
        metadata: intent().metadata,
      }),
    ),
  );
  const row = payment(db);
  assertEquals([row.status, row.amount_cents, row.tip_cents], ["succeeded", 10_000, 1_000]);
  assertEquals(db.table("payments").length, 1);
});

Deno.test("out of order: a refund before the success records the payment, then refunds", async () => {
  const { db, stripe, handler } = setup();
  stripe.put(intent()).put(charge({ amount_refunded: 3_000 }));
  const refund = await ok(
    await deliver(handler, event("charge.refunded", charge({ amount_refunded: 3_000 }))),
  );
  assertEquals(refund.result, "applied");
  let row = payment(db);
  assertEquals(
    [row.status, row.amount_cents, row.tip_cents, row.refunded_cents],
    ["partially_refunded", 10_000, 1_000, 3_000],
  );
  // the intent was read on the connected account to find our metadata
  assertEquals(
    db.http.callsTo("GET", `${STRIPE}/payment_intents/:id`)[0]?.headers.get("stripe-account"),
    ACCT,
  );

  // An older refund event (cumulative 1,000) arrives late: the charge is
  // re-read, so Stripe's current total (3,000) is what gets applied.
  await ok(await deliver(handler, event("charge.refunded", charge({ amount_refunded: 1_000 }))));
  // The success event arrives last: no downgrade, refund kept.
  await ok(await deliver(handler, event("payment_intent.succeeded", intent())));
  row = payment(db);
  assertEquals([row.status, row.refunded_cents], ["partially_refunded", 3_000]);

  // A full refund completes it.
  stripe.put(charge({ amount_refunded: 11_000 }));
  await ok(await deliver(handler, event("charge.refunded", charge({ amount_refunded: 11_000 }))));
  row = payment(db);
  assertEquals([row.status, row.refunded_cents], ["refunded", 11_000]);
  assertEquals(
    rpcCalls(db, "apply_stripe_refund").map((a) => a.p_refunded_cents_total),
    [3_000, 3_000, 3_000, 11_000],
  );
  // every charge read happened on the connected account
  const chargeReads = db.http.callsTo("GET", `${STRIPE}/charges/:id`);
  assert(chargeReads.length >= 3);
  assert(chargeReads.every((c) => c.headers.get("stripe-account") === ACCT));
});

Deno.test("charge.refunded for a charge that is not a CRM payment is ignored", async () => {
  const { db, stripe, handler } = setup();
  stripe.put(intent({ id: "pi_1Dashboard", metadata: {} })).put(
    charge({ payment_intent: "pi_1Dashboard", amount_refunded: 500 }),
  );
  const res = await ok(
    await deliver(
      handler,
      event("charge.refunded", charge({ payment_intent: "pi_1Dashboard", amount_refunded: 500 })),
    ),
  );
  assertEquals(res.result, "ignored");
  assertEquals(db.table("payments"), []);
});

// ---------------------------------------------------------------------------
// Failed refunds (refunded total goes DOWN in Stripe)
// ---------------------------------------------------------------------------

function refundObject(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    id: "re_1Refund",
    object: "refund",
    amount: 5_000,
    charge: "ch_1Charge",
    payment_intent: "pi_1Invoice",
    status: "failed",
    failure_reason: "expired_or_canceled_card",
    ...overrides,
  };
}

/** A received card payment the staff refund action already counted a refund on. */
function seedRefunded(db: FakeSupabase, refunded: number, overrides: Partial<Row> = {}): void {
  db.seed("payments", [{
    id: "p-refunded",
    shop_id: SHOP,
    customer_id: CUSTOMER,
    invoice_id: INVOICE,
    job_id: JOB,
    membership_id: null,
    status: sqlRefundStatus(10_000, 1_000, refunded),
    kind: "payment",
    method: "card",
    amount_cents: 10_000,
    tip_cents: 1_000,
    refunded_cents: refunded,
    stripe_payment_intent_id: "pi_1Invoice",
    stripe_charge_id: "ch_1Charge",
    paid_at: NOW.toISOString(),
    ...overrides,
  }]);
}

for (const type of ["refund.failed", "refund.updated", "charge.refund.updated"]) {
  Deno.test(`${type}: a refund that failed after it was counted is reversed`, async () => {
    const { db, stripe, logs, handler } = setup();
    // The staff action recorded a pending 5,000 refund; it then failed and
    // Stripe gave the money back (charge.amount_refunded 5,000 -> 0).
    seedRefunded(db, 5_000);
    stripe.put(charge({ amount_refunded: 0 }));
    const res = await ok(await deliver(handler, event(type, refundObject())));
    assertEquals(res.result, "applied");
    const row = payment(db);
    assertEquals([row.status, row.refunded_cents], ["succeeded", 0]);
    // the up-only RPC is not the tool for this; the charge was re-read on the account
    assertEquals(rpcCalls(db, "apply_stripe_refund").length, 0);
    assertEquals(
      db.http.callsTo("GET", `${STRIPE}/charges/:id`)[0]?.headers.get("stripe-account"),
      ACCT,
    );
    assertEquals(logs.events("stripe_refund_reversed").length, 1);
  });
}

Deno.test("refund.failed: only the failed refund is given back; earlier refunds stay", async () => {
  const { db, stripe, handler } = setup();
  // 3,000 refunded (succeeded) + 5,000 (pending, then failed) = 8,000 counted.
  seedRefunded(db, 8_000);
  stripe.put(charge({ amount_refunded: 3_000 }));
  const res = await ok(await deliver(handler, event("refund.failed", refundObject())));
  assertEquals(res.result, "applied");
  const row = payment(db);
  assertEquals([row.status, row.refunded_cents], ["partially_refunded", 3_000]);
  // the raise-only RPC ran with Stripe's total and left the higher value alone
  assertEquals(
    rpcCalls(db, "apply_stripe_refund").map((a) => a.p_refunded_cents_total),
    [3_000],
  );
});

Deno.test("refund.failed: a failed FULL refund turns the payment back into a received one", async () => {
  const { db, stripe, handler } = setup();
  seedRefunded(db, 11_000);
  assertEquals(payment(db).status, "refunded");
  stripe.put(charge({ amount_refunded: 0 }));
  await ok(await deliver(handler, event("refund.failed", refundObject({ amount: 11_000 }))));
  const row = payment(db);
  assertEquals([row.status, row.refunded_cents, row.amount_cents, row.tip_cents], [
    "succeeded",
    0,
    10_000,
    1_000,
  ]);
});

Deno.test("out of order: a stale charge.refunded after the refund failed does not re-apply it", async () => {
  const { db, stripe, handler } = setup();
  seedRefunded(db, 5_000);
  stripe.put(charge({ amount_refunded: 0 }));
  await ok(await deliver(handler, event("refund.failed", refundObject())));
  assertEquals(payment(db).refunded_cents, 0);
  // charge.refunded for the (now failed) refund is delivered late / retried:
  // its snapshot still says 5,000, Stripe's current total is 0.
  const late = await ok(
    await deliver(handler, event("charge.refunded", charge({ amount_refunded: 5_000 }))),
  );
  assertEquals(late.result, "ignored");
  assertEquals([payment(db).status, payment(db).refunded_cents], ["succeeded", 0]);
  assertEquals(rpcCalls(db, "apply_stripe_refund").length, 0);
  // and the success event afterwards changes nothing either
  stripe.put(intent());
  await ok(await deliver(handler, event("payment_intent.succeeded", intent())));
  assertEquals([payment(db).status, payment(db).refunded_cents], ["succeeded", 0]);
});

Deno.test("refund.updated for a refund that did not fail leaves the total as Stripe reports it", async () => {
  const { db, stripe, handler } = setup();
  seedRefunded(db, 5_000);
  stripe.put(charge({ amount_refunded: 5_000 }));
  const res = await ok(
    await deliver(handler, event("refund.updated", refundObject({ status: "succeeded" }))),
  );
  assertEquals(res.result, "applied");
  assertEquals([payment(db).status, payment(db).refunded_cents], ["partially_refunded", 5_000]);
});

Deno.test("isolation: a failed refund on another shop's payment is ignored before any Stripe call", async () => {
  const { db, handler } = setup();
  seedRefunded(db, 5_000, { shop_id: OTHER_SHOP, customer_id: OTHER_CUSTOMER, invoice_id: null });
  const res = await ok(await deliver(handler, event("refund.failed", refundObject())));
  assertEquals(res.result, "ignored");
  assertEquals(stripeCalls(db).length, 0);
  assertEquals(payment(db).refunded_cents, 5_000);
});

Deno.test("refund events not tied to a charge / payment intent are ignored", async () => {
  const { db, handler } = setup();
  seedRefunded(db, 5_000);
  const noIntent = await ok(
    await deliver(handler, event("refund.failed", refundObject({ payment_intent: null }))),
  );
  assertEquals(noIntent.result, "ignored");
  const noCharge = await ok(
    await deliver(handler, event("refund.failed", refundObject({ charge: null }))),
  );
  assertEquals(noCharge.result, "ignored");
  assertEquals(stripeCalls(db).length, 0);
  assertEquals(payment(db).refunded_cents, 5_000);
});

Deno.test("a charge re-read that names another payment intent is ignored", async () => {
  const { db, stripe, handler } = setup();
  seedRefunded(db, 5_000);
  stripe.put(charge({ amount_refunded: 0, payment_intent: "pi_1SomethingElse" }));
  const res = await ok(await deliver(handler, event("refund.failed", refundObject())));
  assertEquals(res.result, "ignored");
  assertEquals(payment(db).refunded_cents, 5_000);
});

Deno.test("refund reversal is a compare-and-set: a concurrent change fails the delivery for a retry", async () => {
  const { db, stripe, handler } = setup();
  seedRefunded(db, 8_000);
  stripe.put(charge({ amount_refunded: 3_000 }));
  // Between our read and our write another writer (e.g. the staff refund
  // action) raises the stored total.
  db.onRpc("apply_stripe_refund", () =>
    mutate(db, "payments", (rows) => {
      const row = rows.find((r) => r.stripe_payment_intent_id === "pi_1Invoice");
      assertExists(row);
      const snapshot = { ...row };
      row.refunded_cents = 9_000;
      return snapshot;
    }));
  const body = event("refund.failed", refundObject(), { id: "evt_1RaceRefund" });
  const res = await deliver(handler, body);
  assertEquals(res.status, 500);
  assertEquals((await res.json() as ErrorBody).code, "internal_error");
  // nothing overwritten; the ledger keeps the event unprocessed so Stripe retries
  assertEquals(payment(db).refunded_cents, 9_000);
  assertEquals(ledger(db, "evt_1RaceRefund")?.processed_at, null);
});

Deno.test("refundStatus mirrors payment_refund_status", () => {
  for (const refunded of [0, 1, 10_999, 11_000]) {
    assertEquals(refundStatus(10_000, 1_000, refunded), sqlRefundStatus(10_000, 1_000, refunded));
  }
  assertEquals(refundStatus(10_000, 1_000, 0), "succeeded");
  assertEquals(refundStatus(10_000, 1_000, 1), "partially_refunded");
  assertEquals(refundStatus(10_000, 1_000, 10_999), "partially_refunded");
  assertEquals(refundStatus(10_000, 1_000, 11_000), "refunded");
});

Deno.test("out of order: an updated snapshot delivered after deletion never revives a membership", async () => {
  const { db, stripe, handler } = setup({
    membership: { status: "active", stripe_subscription_id: "sub_1Member", started_at: "x" },
  });
  const canceled = subscription({
    status: "canceled",
    canceled_at: 1_790_500_000,
    ended_at: 1_790_500_000,
  });
  stripe.put(canceled);
  await ok(await deliver(handler, event("customer.subscription.deleted", canceled)));
  // A stale "active" update arrives late; the handler re-reads Stripe (canceled).
  const stale = await ok(
    await deliver(handler, event("customer.subscription.updated", subscription())),
  );
  assertEquals(stale.result, "applied");
  const m = db.table("memberships")[0];
  assertEquals([m?.status, m?.cancelled_at], [
    "cancelled",
    new Date(1_790_500_000_000).toISOString(),
  ]);
  assertEquals(
    db.http.callsTo("GET", `${STRIPE}/subscriptions/:id`)[0]?.headers.get("stripe-account"),
    ACCT,
  );
});

// ---------------------------------------------------------------------------
// checkout.session.completed
// ---------------------------------------------------------------------------

Deno.test("checkout.session.completed (payment): paid -> succeeded with the session id; card saved", async () => {
  const { db, stripe, handler } = setup();
  const pi = intent({ setup_future_usage: "off_session" });
  stripe.put(pi).put(charge());
  const session = {
    id: "cs_test_1Invoice",
    object: "checkout.session",
    mode: "payment",
    payment_status: "paid",
    payment_intent: "pi_1Invoice",
    amount_total: 11_000,
    customer: "cus_1Customer",
    metadata: pi.metadata,
  };
  const res = await ok(await deliver(handler, event("checkout.session.completed", session)));
  assertEquals(res.result, "applied");
  const row = payment(db);
  assertEquals(
    [row.status, row.stripe_checkout_session_id, row.amount_cents, row.tip_cents, row.card_last4],
    ["succeeded", "cs_test_1Invoice", 10_000, 1_000, "4242"],
  );
  const piCall = db.http.callsTo("GET", `${STRIPE}/payment_intents/:id`)[0];
  assertEquals(piCall?.headers.get("stripe-account"), ACCT);
  assertEquals(piCall?.url.searchParams.get("expand[0]"), "latest_charge");
  assertEquals(db.table("customer_payment_methods")[0]?.stripe_payment_method_id, "pm_1Card");
});

Deno.test("checkout.session.completed (payment): unpaid (async method) -> pending", async () => {
  const { db, stripe, handler } = setup();
  const pi = intent({ status: "processing", amount_received: 0, latest_charge: null });
  stripe.put(pi);
  await ok(
    await deliver(
      handler,
      event("checkout.session.completed", {
        id: "cs_1Pending",
        object: "checkout.session",
        mode: "payment",
        payment_status: "unpaid",
        payment_intent: "pi_1Invoice",
        metadata: pi.metadata,
      }),
    ),
  );
  const row = payment(db);
  assertEquals([row.status, row.paid_at, row.amount_cents], ["pending", null, 10_000]);
  // later success upgrades it
  stripe.put(intent()).put(charge());
  await ok(await deliver(handler, event("payment_intent.succeeded", intent())));
  assertEquals(payment(db).status, "succeeded");
});

const DELETED_JOB = "99999999-9999-4999-8999-999999999999";

function depositSession(pi: Record<string, unknown>, id = "cs_1Deposit"): Record<string, unknown> {
  return {
    id,
    object: "checkout.session",
    mode: "payment",
    payment_status: "paid",
    payment_intent: pi.id,
    amount_total: pi.amount,
    customer: "cus_1Customer",
    metadata: pi.metadata,
  };
}

function deletedJobDeposit(metadata: Record<string, string> = {}): Record<string, unknown> {
  return intent({
    id: "pi_1Deposit",
    amount: 5_000,
    amount_received: 5_000,
    latest_charge: "ch_1Deposit",
    metadata: {
      shop_id: SHOP,
      job_id: DELETED_JOB,
      customer_id: CUSTOMER,
      kind: "deposit",
      tip_cents: "0",
      source: "booking_deposit_checkout",
      ...metadata,
    },
  });
}

Deno.test("deleted job: a deposit paid after its booking was deleted is kept as the customer's unapplied payment", async () => {
  const { db, stripe, logs, handler } = setup();
  const pi = deletedJobDeposit();
  stripe.put(pi).put(
    charge({
      id: "ch_1Deposit",
      amount: 5_000,
      amount_captured: 5_000,
      payment_intent: "pi_1Deposit",
    }),
  );

  const res = await ok(
    await deliver(handler, event("checkout.session.completed", depositSession(pi))),
  );
  assertEquals(res.result, "applied");
  const row = payment(db, "pi_1Deposit");
  assertEquals(
    [row.status, row.kind, row.job_id, row.invoice_id, row.customer_id, row.amount_cents],
    ["succeeded", "deposit", null, null, CUSTOMER, 5_000],
  );
  assert(String(row.note).includes("deleted job"), String(row.note));
  assertEquals(logs.events("stripe_payment_relinked")[0]?.deleted, ["job"]);

  // Redeliveries / the intent event find the row: no duplicate, note kept.
  await ok(await deliver(handler, event("payment_intent.succeeded", pi)));
  assertEquals(db.table("payments").length, 1);

  // ...and refunds of it (which record the payment first) work too.
  stripe.put(charge({
    id: "ch_1Deposit",
    amount: 5_000,
    amount_captured: 5_000,
    amount_refunded: 5_000,
    refunded: true,
    payment_intent: "pi_1Deposit",
  }));
  const refunded = await ok(
    await deliver(
      handler,
      event("charge.refunded", charge({ id: "ch_1Deposit", payment_intent: "pi_1Deposit" })),
    ),
  );
  assertEquals(refunded.result, "applied");
  assertEquals(payment(db, "pi_1Deposit").status, "refunded");
});

Deno.test("deleted job: a refund arriving first still records the deposit (no FK retry loop)", async () => {
  const { db, stripe, handler } = setup();
  const pi = deletedJobDeposit();
  const refundedCharge = charge({
    id: "ch_1Deposit",
    amount: 5_000,
    amount_captured: 5_000,
    amount_refunded: 2_000,
    payment_intent: "pi_1Deposit",
  });
  stripe.put(pi).put(refundedCharge);
  const res = await ok(await deliver(handler, event("charge.refunded", refundedCharge)));
  assertEquals(res.result, "applied");
  const row = payment(db, "pi_1Deposit");
  assertEquals([row.status, row.job_id, row.refunded_cents], ["partially_refunded", null, 2_000]);
});

Deno.test("deleted job: without customer_id the payer is found by Stripe customer; unknown payer is acknowledged", async () => {
  const { db, stripe, logs, handler } = setup();
  const pi = deletedJobDeposit({ customer_id: "" });
  stripe.put(pi).put(
    charge({
      id: "ch_1Deposit",
      amount: 5_000,
      amount_captured: 5_000,
      payment_intent: "pi_1Deposit",
    }),
  );
  await ok(await deliver(handler, event("payment_intent.succeeded", pi)));
  assertEquals(payment(db, "pi_1Deposit").customer_id, CUSTOMER);

  // Job AND customer deleted, Stripe customer unknown: nothing to attach the
  // money to. Acknowledged (a retry can never succeed) and logged as an error.
  const orphan = deletedJobDeposit({ customer_id: "44444444-4444-4444-8444-444444444444" });
  orphan.id = "pi_1Orphan";
  orphan.customer = "cus_1Unknown";
  orphan.latest_charge = "ch_1Orphan";
  stripe.put(orphan).put(
    charge({
      id: "ch_1Orphan",
      amount: 5_000,
      amount_captured: 5_000,
      payment_intent: "pi_1Orphan",
    }),
  );
  const res = await ok(await deliver(handler, event("payment_intent.succeeded", orphan)));
  assertEquals([res.result, res.handled], ["ignored", true]);
  assertEquals(
    db.table("payments").some((p) => p.stripe_payment_intent_id === "pi_1Orphan"),
    false,
  );
  assertEquals(logs.events("stripe_payment_unlinkable")[0]?.deleted, ["job", "customer"]);
});

Deno.test("deleted job: an FK error while every linked record exists is still retried (500)", async () => {
  const { db, stripe, handler } = setup();
  stripe.put(intent()).put(charge());
  db.onRpc("upsert_stripe_payment", () => {
    throw new FakeRpcError("23503", "violates foreign key constraint");
  });
  const res = await deliver(handler, event("payment_intent.succeeded", intent()));
  assertEquals(res.status, 500);
  assertEquals((await res.json() as ErrorBody).code, "internal_error");
});

Deno.test("non-card Stripe methods are flagged on the row (stored as card, the only Stripe method)", async () => {
  const { db, stripe, logs, handler } = setup();
  stripe.put(intent()).put(charge({
    payment_method_details: { type: "us_bank_account", us_bank_account: { last4: "6789" } },
  }));
  await ok(await deliver(handler, event("payment_intent.succeeded", intent())));
  const row = payment(db);
  assertEquals([row.status, row.method, row.card_brand, row.card_last4], [
    "succeeded",
    "card",
    null,
    null,
  ]);
  assert(String(row.note).includes("us bank account"), String(row.note));
  assertEquals(logs.events("stripe_non_card_payment")[0]?.payment_method_type, "us_bank_account");
  // A card charge carries no such note.
  const cardDb = setup();
  cardDb.stripe.put(intent()).put(charge());
  await ok(await deliver(cardDb.handler, event("payment_intent.succeeded", intent())));
  assertEquals(payment(cardDb.db).note, null);
});

Deno.test("checkout.session.completed (setup): the card is saved; the first card is default", async () => {
  const { db, stripe, handler } = setup();
  stripe.put({
    id: "pm_1Saved",
    object: "payment_method",
    type: "card",
    customer: "cus_1Customer",
    card: { brand: "amex", last4: "0005", exp_month: 3, exp_year: 2031, fingerprint: "secret" },
  }).put({
    id: "seti_1Setup",
    object: "setup_intent",
    status: "succeeded",
    customer: "cus_1Customer",
    payment_method: "pm_1Saved",
    metadata: { shop_id: SHOP, customer_id: CUSTOMER },
  });
  const res = await ok(
    await deliver(
      handler,
      event("checkout.session.completed", {
        id: "cs_1Setup",
        object: "checkout.session",
        mode: "setup",
        payment_status: "no_payment_required",
        setup_intent: "seti_1Setup",
        metadata: { shop_id: SHOP, customer_id: CUSTOMER },
      }),
    ),
  );
  assertEquals(res.result, "applied");
  const saved = db.table("customer_payment_methods");
  assertEquals(saved.length, 1);
  assertEquals(
    [
      saved[0]?.brand,
      saved[0]?.last4,
      saved[0]?.exp_month,
      saved[0]?.exp_year,
      saved[0]?.is_default,
    ],
    ["amex", "0005", 3, 2031, true],
  );
  assert(!JSON.stringify(saved).includes("fingerprint"));
  const siCall = db.http.callsTo("GET", `${STRIPE}/setup_intents/:id`)[0];
  assertEquals(siCall?.headers.get("stripe-account"), ACCT);
});

Deno.test("checkout.session.completed (subscription): links the subscription to the membership", async () => {
  const { db, stripe, handler } = setup();
  stripe.put(subscription());
  const res = await ok(
    await deliver(
      handler,
      event("checkout.session.completed", {
        id: "cs_1Membership",
        object: "checkout.session",
        mode: "subscription",
        payment_status: "paid",
        subscription: "sub_1Member",
        metadata: { shop_id: SHOP, membership_id: MEMBERSHIP },
      }),
    ),
  );
  assertEquals(res.result, "applied");
  const m = db.table("memberships")[0];
  assertEquals(
    [m?.stripe_subscription_id, m?.status, m?.current_period_end, m?.started_at],
    [
      "sub_1Member",
      "active",
      new Date(1_791_600_000_000).toISOString(),
      new Date(1_789_000_000_000).toISOString(),
    ],
  );
  assertEquals(rpcCalls(db, "sync_stripe_subscription")[0]?.p_membership_id, MEMBERSHIP);
});

// ---------------------------------------------------------------------------
// setup_intent.succeeded
// ---------------------------------------------------------------------------

Deno.test("setup_intent.succeeded saves the card; later cards are not default", async () => {
  const { db, stripe, handler } = setup();
  for (const [pm, last4] of [["pm_1First", "1111"], ["pm_1Second", "2222"]] as const) {
    stripe.put({
      id: pm,
      object: "payment_method",
      type: "card",
      card: { brand: "visa", last4, exp_month: 1, exp_year: 2029 },
    });
    await ok(
      await deliver(
        handler,
        event("setup_intent.succeeded", {
          id: `seti_1${last4}`,
          object: "setup_intent",
          status: "succeeded",
          customer: "cus_1Customer",
          payment_method: pm,
          metadata: { shop_id: SHOP, customer_id: CUSTOMER },
        }),
      ),
    );
  }
  const saved = db.table("customer_payment_methods");
  assertEquals(
    saved.map((r) => [r.stripe_payment_method_id, r.is_default]),
    [["pm_1First", true], ["pm_1Second", false]],
  );
  assert(
    db.http.callsTo("GET", `${STRIPE}/payment_methods/:id`).every((c) =>
      c.headers.get("stripe-account") === ACCT
    ),
  );
});

Deno.test("setup_intent.succeeded maps the Stripe customer when metadata has no customer_id", async () => {
  const { db, stripe, handler } = setup();
  stripe.put({
    id: "pm_1Mapped",
    object: "payment_method",
    type: "card",
    card: { brand: "visa", last4: "9999", exp_month: 5, exp_year: 2030 },
  });
  const si = {
    id: "seti_1Mapped",
    object: "setup_intent",
    status: "succeeded",
    customer: "cus_1Customer",
    payment_method: "pm_1Mapped",
    metadata: { shop_id: SHOP },
  };
  await ok(await deliver(handler, event("setup_intent.succeeded", si)));
  assertEquals(db.table("customer_payment_methods")[0]?.customer_id, CUSTOMER);

  // a Stripe customer of another shop never maps into this one
  const res = await ok(
    await deliver(
      handler,
      event("setup_intent.succeeded", { ...si, id: "seti_1Other", customer: "cus_1Other" }),
    ),
  );
  assertEquals(res.result, "ignored");
  assertEquals(db.table("customer_payment_methods").length, 1);
});

Deno.test("setup_intent.succeeded: a non-card method or a foreign customer id is ignored", async () => {
  const { db, stripe, handler } = setup();
  stripe.put({ id: "pm_1Bank", object: "payment_method", type: "us_bank_account" });
  const bank = await ok(
    await deliver(
      handler,
      event("setup_intent.succeeded", {
        id: "seti_1Bank",
        object: "setup_intent",
        status: "succeeded",
        payment_method: "pm_1Bank",
        metadata: { shop_id: SHOP, customer_id: CUSTOMER },
      }),
    ),
  );
  assertEquals(bank.result, "ignored");

  stripe.put({
    id: "pm_1Card2",
    object: "payment_method",
    type: "card",
    card: { brand: "visa", last4: "1234", exp_month: 1, exp_year: 2030 },
  });
  // customer_id of another shop: the SQL helper refuses it (P0002) -> ignored, not retried
  const foreign = await ok(
    await deliver(
      handler,
      event("setup_intent.succeeded", {
        id: "seti_1ForeignCustomer",
        object: "setup_intent",
        status: "succeeded",
        payment_method: "pm_1Card2",
        metadata: { shop_id: SHOP, customer_id: OTHER_CUSTOMER },
      }),
    ),
  );
  assertEquals(foreign.result, "ignored");
  assertEquals(db.table("customer_payment_methods"), []);
});

// ---------------------------------------------------------------------------
// Subscriptions
// ---------------------------------------------------------------------------

Deno.test("customer.subscription.*: statuses map (trialing->active, unpaid->past_due, canceled->cancelled)", async () => {
  const { db, stripe, handler } = setup();
  const steps: Array<[string, Record<string, unknown>, string, boolean]> = [
    ["customer.subscription.created", { status: "incomplete" }, "incomplete", false],
    ["customer.subscription.updated", { status: "trialing" }, "active", false],
    ["customer.subscription.updated", { status: "unpaid" }, "past_due", false],
    [
      "customer.subscription.updated",
      { status: "active", cancel_at_period_end: true },
      "active",
      true,
    ],
    [
      "customer.subscription.deleted",
      { status: "canceled", ended_at: 1_790_900_000 },
      "cancelled",
      false,
    ],
  ];
  for (const [type, change, expected, cancelFlag] of steps) {
    const sub = subscription(change);
    stripe.put(sub);
    const res = await ok(await deliver(handler, event(type, sub)));
    assertEquals(res.result, "applied", type);
    const m = db.table("memberships")[0];
    assertEquals(
      [m?.status, m?.cancel_at_period_end],
      [expected, cancelFlag],
      `${type} ${JSON.stringify(change)}`,
    );
  }
  const m = db.table("memberships")[0];
  assertEquals(m?.stripe_subscription_id, "sub_1Member");
  assertEquals(m?.cancelled_at, new Date(1_790_900_000_000).toISOString());
  assertEquals(m?.current_period_end, new Date(1_791_600_000_000).toISOString());
  const statuses = rpcCalls(db, "sync_stripe_subscription").map((a) => a.p_status);
  assertEquals(statuses, ["incomplete", "active", "past_due", "active", "cancelled"]);
});

Deno.test("customer.subscription.*: a subscription with no membership is acknowledged, not retried", async () => {
  const { db, stripe, handler } = setup();
  const sub = subscription({ id: "sub_1Unknown", metadata: { shop_id: SHOP } });
  stripe.put(sub);
  const res = await ok(await deliver(handler, event("customer.subscription.updated", sub)));
  assertEquals(res.result, "ignored");
  assertEquals(db.table("memberships")[0]?.stripe_subscription_id, null);
});

// ---------------------------------------------------------------------------
// invoice.paid / invoice.payment_failed
// ---------------------------------------------------------------------------

Deno.test("invoice.paid records a membership payment for the invoice's payment intent", async () => {
  const { db, stripe, handler } = setup({
    membership: { status: "active", stripe_subscription_id: "sub_1Member", started_at: "x" },
  });
  const pi = intent({
    id: "pi_1Renewal",
    amount: 4_900,
    amount_received: 4_900,
    latest_charge: "ch_1Renewal",
    metadata: {},
  });
  stripe.put(pi).put(
    charge({
      id: "ch_1Renewal",
      amount: 4_900,
      amount_captured: 4_900,
      payment_intent: "pi_1Renewal",
    }),
  );
  stripe.invoicePayments.set("in_1Renewal", [{
    id: "inpay_1",
    object: "invoice_payment",
    status: "paid",
    amount_paid: 4_900,
    invoice: "in_1Renewal",
    payment: { type: "payment_intent", payment_intent: "pi_1Renewal" },
    status_transitions: { paid_at: PAID_AT },
  }]);
  const res = await ok(await deliver(handler, event("invoice.paid", membershipInvoice())));
  assertEquals(res.result, "applied");
  const row = payment(db, "pi_1Renewal");
  assertEquals(
    [
      row.kind,
      row.membership_id,
      row.customer_id,
      row.amount_cents,
      row.tip_cents,
      row.status,
      row.card_last4,
    ],
    ["membership", MEMBERSHIP, CUSTOMER, 4_900, 0, "succeeded", "4242"],
  );
  const listCall = db.http.callsTo("GET", `${STRIPE}/invoice_payments`)[0];
  assertEquals(listCall?.headers.get("stripe-account"), ACCT);
  assertEquals(listCall?.url.searchParams.get("invoice"), "in_1Renewal");

  // The intent's own success event (no metadata) does not record it twice.
  const dup = await ok(await deliver(handler, event("payment_intent.succeeded", pi)));
  assertEquals(dup.result, "ignored");
  // A refund of the membership charge applies to the recorded row.
  stripe.put(
    charge({
      id: "ch_1Renewal",
      amount: 4_900,
      amount_captured: 4_900,
      payment_intent: "pi_1Renewal",
      amount_refunded: 4_900,
    }),
  );
  await ok(
    await deliver(
      handler,
      event(
        "charge.refunded",
        charge({
          id: "ch_1Renewal",
          amount: 4_900,
          payment_intent: "pi_1Renewal",
          amount_refunded: 4_900,
        }),
      ),
    ),
  );
  assertEquals(payment(db, "pi_1Renewal").status, "refunded");
  assertEquals(db.table("payments").length, 1);
});

Deno.test("invoice.paid before the subscription was linked links it first", async () => {
  const { db, stripe, handler } = setup();
  stripe.put(subscription());
  stripe.put(
    intent({
      id: "pi_1First",
      amount: 4_900,
      amount_received: 4_900,
      latest_charge: null,
      metadata: {},
    }),
  );
  const invoice = membershipInvoice({
    id: "in_1First",
    billing_reason: "subscription_create",
    payments: {
      object: "list",
      has_more: false,
      data: [{
        id: "inpay_2",
        object: "invoice_payment",
        status: "paid",
        amount_paid: 4_900,
        payment: { type: "payment_intent", payment_intent: "pi_1First" },
        status_transitions: { paid_at: PAID_AT },
      }],
    },
  });
  const res = await ok(await deliver(handler, event("invoice.paid", invoice)));
  assertEquals(res.result, "applied");
  assertEquals(db.table("memberships")[0]?.stripe_subscription_id, "sub_1Member");
  const row = payment(db, "pi_1First");
  assertEquals([row.kind, row.membership_id, row.paid_at], [
    "membership",
    MEMBERSHIP,
    new Date(PAID_AT * 1000).toISOString(),
  ]);
  // embedded payments were used: no list call
  assertEquals(db.http.callsTo("GET", `${STRIPE}/invoice_payments`).length, 0);
});

Deno.test("invoice.paid for a non-subscription invoice is ignored", async () => {
  const { db, handler } = setup();
  const res = await ok(
    await deliver(handler, event("invoice.paid", membershipInvoice({ parent: null }))),
  );
  assertEquals(res.result, "ignored");
  assertEquals(db.requests.filter((r) => r.kind === "rpc").length, 0);
});

Deno.test("invoice.payment_failed marks the membership past_due", async () => {
  const { db, stripe, handler } = setup({
    membership: { status: "active", stripe_subscription_id: "sub_1Member", started_at: "x" },
  });
  stripe.put(subscription({ status: "past_due" }));
  const res = await ok(
    await deliver(handler, event("invoice.payment_failed", membershipInvoice({ status: "open" }))),
  );
  assertEquals(res.result, "applied");
  assertEquals(db.table("memberships")[0]?.status, "past_due");
});

Deno.test("invoice.payment_failed: still-unpaid invoice -> past_due even if Stripe reads active", async () => {
  const { db, stripe, handler } = setup({
    membership: { status: "active", stripe_subscription_id: "sub_1Member", started_at: "x" },
  });
  stripe.put(subscription({ status: "active", cancel_at_period_end: true }));
  stripe.put(membershipInvoice({ status: "open" }));
  await ok(
    await deliver(handler, event("invoice.payment_failed", membershipInvoice({ status: "open" }))),
  );
  const m = db.table("memberships")[0];
  assertEquals([m?.status, m?.cancel_at_period_end], ["past_due", true]);

  // once the invoice has been paid by a retry, a late failure event changes nothing
  stripe.put(membershipInvoice({ status: "paid" }));
  db.seed("memberships", [{ ...m, status: "active" }]);
  await ok(
    await deliver(handler, event("invoice.payment_failed", membershipInvoice({ status: "open" }))),
  );
  assertEquals(db.table("memberships")[0]?.status, "active");
});

// ---------------------------------------------------------------------------
// account.updated
// ---------------------------------------------------------------------------

Deno.test("account.updated refreshes the shop's Connect flags from Stripe's current account", async () => {
  const { db, stripe, handler } = setup();
  stripe.put({
    id: ACCT,
    object: "account",
    charges_enabled: true,
    payouts_enabled: true,
    details_submitted: true,
  });
  // the delivered snapshot is older (charges disabled); the current account wins
  const res = await ok(
    await deliver(
      handler,
      event("account.updated", {
        id: ACCT,
        object: "account",
        charges_enabled: false,
        payouts_enabled: false,
        details_submitted: true,
      }),
    ),
  );
  assertEquals(res.result, "applied");
  const row = db.table("shop_stripe_accounts").find((r) => r.shop_id === SHOP);
  assertEquals(
    [row?.charges_enabled, row?.payouts_enabled, row?.details_submitted],
    [true, true, true],
  );
  // the other shop is untouched
  const other = db.table("shop_stripe_accounts").find((r) => r.shop_id === OTHER_SHOP);
  assertEquals(other?.stripe_account_id, OTHER_ACCT);
});

Deno.test("account.updated for an account that is not the event's, or unknown, is ignored", async () => {
  const { db, stripe, handler } = setup();
  const mismatch = await ok(
    await deliver(
      handler,
      event("account.updated", { id: OTHER_ACCT, object: "account", charges_enabled: false }),
    ),
  );
  assertEquals(mismatch.result, "ignored");
  stripe.put({ id: STRANGER_ACCT, object: "account", charges_enabled: true });
  const unknown = await ok(
    await deliver(
      handler,
      event("account.updated", { id: STRANGER_ACCT, object: "account" }, {
        account: STRANGER_ACCT,
      }),
    ),
  );
  assertEquals(unknown.result, "ignored");
  assertEquals(
    db.table("shop_stripe_accounts").find((r) => r.shop_id === OTHER_SHOP)?.charges_enabled,
    true,
  );
});
