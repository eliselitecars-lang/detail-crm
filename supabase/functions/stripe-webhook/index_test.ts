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
import { adminClient } from "../_shared/supabase.ts";
import { disputeNoteLine, withDisputeLine } from "./handlers.ts";
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
    if (!["pending", "processing", "succeeded", "failed", "cancelled"].includes(status)) {
      throw new FakeRpcError("22023", "refund states are applied with apply_stripe_refund");
    }
    // 0064: the Stripe-backed methods
    if (!["card", "card_present", "ach_debit", "bnpl"].includes(a.p_method as string)) {
      throw new FakeRpcError("22023", "Stripe payments are card, card_present, ach_debit or bnpl");
    }
    const methodType = a.p_stripe_method_type === null || a.p_stripe_method_type === undefined
      ? null
      : String(a.p_stripe_method_type).trim().toLowerCase() || null;
    if (methodType !== null && !/^[a-z][a-z0-9_]{0,39}$/.test(methodType)) {
      throw new FakeRpcError("22023", "invalid Stripe payment method type");
    }
    if (amount < 0 || tip < 0 || amount + tip <= 0) {
      throw new FakeRpcError("22023", "amount and tip must be non-negative and not both zero");
    }
    return mutate(db, "payments", (rows) => {
      let row = rows.find((r) => r.stripe_payment_intent_id === a.p_payment_intent_id);
      if (!row) {
        // 0013: links to records that no longer exist in the shop are
        // dropped (a membership charge without its membership becomes a
        // plain payment); nothing left at all is P0002.
        const exists = (table: string, id: unknown) =>
          id !== null && id !== undefined &&
          db.table(table).some((r) => r.id === id && r.shop_id === a.p_shop_id);
        if (!exists("invoices", a.p_invoice_id)) a.p_invoice_id = null;
        if (!exists("jobs", a.p_job_id)) a.p_job_id = null;
        if (!exists("memberships", a.p_membership_id)) {
          a.p_membership_id = null;
          if (a.p_kind === "membership") a.p_kind = "payment";
        }
        if (!exists("customers", a.p_customer_id)) a.p_customer_id = null;
        if (!a.p_invoice_id && !a.p_job_id && !a.p_membership_id && !a.p_customer_id) {
          throw new FakeRpcError(
            "P0002",
            "none of the payment's invoice, job, membership or customer exists in this shop",
          );
        }
        // payments_before_write (0012) runs BEFORE the foreign keys are
        // checked: linkage is derived from the parents that exist, and a
        // supplied value contradicting one is 23514.
        let customer = a.p_customer_id as string | null;
        let job = a.p_job_id as string | null;
        let invoiceId = a.p_invoice_id as string | null;
        if (!invoiceId && job) {
          invoiceId = (db.table("invoices").find((i) =>
            i.job_id === job && i.shop_id === a.p_shop_id && i.status !== "void"
          )?.id as string | undefined) ?? null;
        }
        const invoice = db.table("invoices").find((i) =>
          i.id === invoiceId && i.shop_id === a.p_shop_id
        );
        const jobRow = db.table("jobs").find((j) => j.id === job && j.shop_id === a.p_shop_id);
        if (invoiceId) {
          if (!invoice) {
            // a missing invoice skips the derivation; its foreign key fails below
          } else if (job && job !== invoice.job_id) {
            throw new FakeRpcError("23514", "payment job does not match the invoice's job");
          } else if (customer && customer !== invoice.customer_id) {
            throw new FakeRpcError(
              "23514",
              "payment customer does not match the invoice's customer",
            );
          } else {
            customer = invoice.customer_id as string;
            job = invoice.job_id as string;
          }
        } else if (jobRow) {
          if (customer && customer !== jobRow.customer_id) {
            throw new FakeRpcError("23514", "payment customer does not match the job's customer");
          }
          customer = jobRow.customer_id as string;
        }
        const membership = db.table("memberships").find((m) =>
          m.id === a.p_membership_id && m.shop_id === a.p_shop_id
        );
        if (membership) {
          if (customer && customer !== membership.customer_id) {
            throw new FakeRpcError(
              "23514",
              "payment customer does not match the membership's customer",
            );
          }
          customer = membership.customer_id as string;
        }
        // payments_*_fk (0012): every linked record must exist in the shop
        for (
          const [id, table] of [
            [invoiceId, "invoices"],
            [job, "jobs"],
            [customer, "customers"],
            [a.p_membership_id, "memberships"],
          ] as const
        ) {
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
        if (!customer) throw new FakeRpcError("23502", "customer_id is required");
        row = {
          id: crypto.randomUUID(),
          shop_id: a.p_shop_id,
          invoice_id: invoiceId,
          job_id: job,
          customer_id: customer,
          membership_id: a.p_membership_id ?? null,
          kind: a.p_kind,
          method: a.p_method,
          status,
          amount_cents: amount,
          tip_cents: tip,
          refunded_cents: 0,
          disputed_cents: 0,
          stripe_payment_intent_id: a.p_payment_intent_id,
          stripe_charge_id: a.p_charge_id ?? null,
          stripe_checkout_session_id: a.p_checkout_session_id ?? null,
          card_brand: a.p_card_brand ?? null,
          card_last4: a.p_card_last4 ?? null,
          stripe_method_type: methodType,
          note: null,
          paid_at: status === "succeeded" ? (a.p_paid_at ?? NOW.toISOString()) : null,
        };
        rows.push(row);
        return { ...row };
      }
      if (row.shop_id !== a.p_shop_id) {
        throw new FakeRpcError("22023", "payment intent belongs to another shop");
      }
      // 0064 state machine: received money is never downgraded; a cancelled
      // row only turns succeeded; a late pending / processing never reopens
      // a failure; processing never regresses to pending. (The SQL also keeps
      // a declined card-less sheet pending; the webhook itself records such a
      // decline as pending, which the tests below assert on the RPC call.)
      const received = RECEIVED.includes(row.status as string);
      const next = received
        ? row.status
        : row.status === "cancelled" && status !== "succeeded"
        ? "cancelled"
        : row.status === "failed" && (status === "pending" || status === "processing")
        ? "failed"
        : row.status === "processing" && status === "pending"
        ? "processing"
        : status;
      Object.assign(row, {
        status: next,
        amount_cents: received ? row.amount_cents : amount,
        tip_cents: received ? row.tip_cents : tip,
        method: received ? row.method : a.p_method,
        stripe_method_type: received
          ? (row.stripe_method_type ?? methodType)
          : (methodType ?? row.stripe_method_type ?? null),
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
      // 0095: the card's Stripe customer must be the saved card's own (a
      // merge moved it) or, for a new card, this customer's
      if (
        a.p_stripe_customer_id !== undefined && a.p_stripe_customer_id !== null &&
        a.p_stripe_customer_id !== (existing?.stripe_customer_id ?? customer.stripe_customer_id)
      ) {
        throw new FakeRpcError("22023", "payment method belongs to another Stripe customer");
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
      // 0074 trigger: a new card records the owning customer's Stripe customer
      const row = {
        id: crypto.randomUUID(),
        ...values,
        stripe_customer_id: customer.stripe_customer_id ?? null,
      };
      rows.push(row);
      return { ...row };
    });
  });

  // remove_customer_payment_method (0011): the newest remaining card of the
  // customer becomes the default when the default is removed.
  db.onRpc("remove_customer_payment_method", (a, { role }) => {
    assertEquals(role, "service_role");
    return mutate(db, "customer_payment_methods", (rows) => {
      const i = rows.findIndex((r) =>
        r.shop_id === a.p_shop_id && r.stripe_payment_method_id === a.p_stripe_payment_method_id
      );
      if (i < 0) return false;
      const [removed] = rows.splice(i, 1);
      if (removed?.is_default) {
        const next = rows.filter((r) =>
          r.shop_id === a.p_shop_id && r.customer_id === removed.customer_id
        ).at(-1);
        if (next) next.is_default = true;
      }
      return true;
    });
  });

  db.onRpc("notify_shop_staff", (a, { role }) => {
    assertEquals(role, "service_role");
    // 0031: every deep-link id must belong to the shop
    for (
      const [id, table] of [
        [a.p_job_id, "jobs"],
        [a.p_customer_id, "customers"],
        [a.p_quote_id, "quotes"],
        [a.p_invoice_id, "invoices"],
      ] as const
    ) {
      if (id && !db.table(table).some((r) => r.id === id && r.shop_id === a.p_shop_id)) {
        throw new FakeRpcError("P0002", `${table} row not found in this shop`);
      }
    }
    return 1;
  });

  // set_stripe_refund_total (0093): compare-and-set on refunded_cents.
  db.onRpc("set_stripe_refund_total", (a, { role }) => {
    assertEquals(role, "service_role");
    return mutate(db, "payments", (rows) => {
      const row = rows.find((r) =>
        r.stripe_payment_intent_id === a.p_payment_intent_id && r.shop_id === a.p_shop_id
      );
      if (!row) throw new FakeRpcError("P0002", "payment not found");
      if (!RECEIVED.includes(row.status as string)) {
        throw new FakeRpcError("22023", "a payment that was not received has no refunds");
      }
      const total = a.p_refunded_cents_total as number;
      if (total < 0 || total > (row.amount_cents as number) + (row.tip_cents as number)) {
        throw new FakeRpcError("22023", "refunded total out of range");
      }
      if (row.refunded_cents !== a.p_expected_refunded_cents) {
        throw new FakeRpcError("40001", "refund total changed concurrently");
      }
      row.refunded_cents = total;
      row.status = sqlRefundStatus(row.amount_cents as number, row.tip_cents as number, total);
      return { ...row };
    });
  });

  // apply_stripe_dispute (0093): lost -> what it took back; won-ish -> 0.
  db.onRpc("apply_stripe_dispute", (a, { role }) => {
    assertEquals(role, "service_role");
    return mutate(db, "payments", (rows) => {
      const row = rows.find((r) =>
        r.stripe_payment_intent_id === a.p_payment_intent_id && r.shop_id === a.p_shop_id
      );
      if (!row) throw new FakeRpcError("P0002", "payment not found");
      const status = String(a.p_dispute_status ?? "").trim().toLowerCase();
      if (!status) throw new FakeRpcError("22023", "dispute status is required");
      if (status === "lost") {
        const open = (row.amount_cents as number) + (row.tip_cents as number) -
          (row.refunded_cents as number);
        row.disputed_cents = Math.max(Math.min(a.p_amount_cents as number, open), 0);
      } else if (["won", "warning_closed", "funds_reinstated"].includes(status)) {
        row.disputed_cents = 0;
      }
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
        "disputes",
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

function setup(options: { membership?: Partial<Row>; tables?: Record<string, Row[]> } = {}) {
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
      gift_card_orders: [],
      ...options.tables,
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

/** A card saved on (attached to) the shop customer's Stripe customer. */
function paymentMethod(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    id: "pm_1Card",
    object: "payment_method",
    type: "card",
    customer: "cus_1Customer",
    card: { brand: "visa", last4: "4242", exp_month: 12, exp_year: 2030 },
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

/** A pending attempt recorded by the payments function (sheet / saved card). */
function trackAttempt(db: FakeSupabase, pi: string, overrides: Row = {}): Row {
  const row: Row = {
    id: crypto.randomUUID(),
    shop_id: SHOP,
    invoice_id: INVOICE,
    job_id: JOB,
    customer_id: CUSTOMER,
    membership_id: null,
    kind: "payment",
    method: "card",
    status: "pending",
    amount_cents: 10_000,
    tip_cents: 1_000,
    refunded_cents: 0,
    stripe_payment_intent_id: pi,
    stripe_charge_id: null,
    stripe_checkout_session_id: null,
    card_brand: null,
    card_last4: null,
    note: null,
    paid_at: null,
    ...overrides,
  };
  db.seed("payments", [...db.table("payments"), row]);
  return row;
}

/** Calls a faked RPC directly, as the service role. */
async function adminRpc(db: FakeSupabase, fn: string, args: Record<string, unknown>) {
  return await adminClient({ env: db.env(), fetch: db.http.fetch }).rpc(fn, args);
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
  stripe.put(pi).put(charge()).put(paymentMethod());
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
    // recorded on insert (0074 trigger): the Stripe customer the card is on
    stripe_customer_id: "cus_1Customer",
    is_default: true,
  }]);
});

Deno.test("payment_intent.payment_failed / canceled update a tracked attempt to failed / cancelled", async () => {
  const { db, handler } = setup();
  trackAttempt(db, "pi_1Failed");
  trackAttempt(db, "pi_1Canceled");
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

Deno.test("payment_intent.payment_failed / canceled never create a payment row (nothing was received)", async () => {
  // A declined public booking deposit (Checkout) or an abandoned intent: a
  // payments row would be a money record that blocks deleting the booking and
  // its customer (ON DELETE RESTRICT) and changing the job's customer.
  const { db, stripe, logs, handler } = setup();
  const deposit = {
    shop_id: SHOP,
    job_id: JOB,
    customer_id: CUSTOMER,
    kind: "deposit",
    tip_cents: "0",
    source: "booking_deposit_checkout",
  };
  const attempts: [string, Record<string, unknown>][] = [
    ["payment_intent.payment_failed", {
      id: "pi_1Declined",
      status: "requires_payment_method",
      last_payment_error: { type: "card_error", code: "card_declined" },
    }],
    ["payment_intent.canceled", { id: "pi_1Abandoned", status: "canceled" }],
    // a declined PaymentSheet intent nobody recorded is not tracked either
    ["payment_intent.payment_failed", {
      id: "pi_1UntrackedSheet",
      status: "requires_payment_method",
      metadata: { ...(intent().metadata as Row), source: "payment_sheet" },
    }],
  ];
  for (const [type, pi] of attempts) {
    const res = await ok(
      await deliver(
        handler,
        event(type, intent({ amount_received: 0, latest_charge: null, metadata: deposit, ...pi })),
      ),
    );
    assertEquals(res.result, "ignored");
  }
  assertEquals(db.table("payments"), []);
  assertEquals(rpcCalls(db, "upsert_stripe_payment").length, 0);
  assertEquals(
    logs.events("stripe_event_ignored").filter((e) => e.reason === "no_money_received").length,
    3,
  );
  // The customer then pays with another card: recorded as usual.
  const paid = intent({ id: "pi_1Declined", metadata: deposit });
  stripe.put(paid).put(charge({ payment_intent: "pi_1Declined" }));
  await ok(await deliver(handler, event("payment_intent.succeeded", paid)));
  assertEquals(payment(db, "pi_1Declined").status, "succeeded");
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
  trackAttempt(db, "pi_1Sheet");
  trackAttempt(db, "pi_1SavedCard");
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
  trackAttempt(db, "pi_1Invoice");
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
  stripe.put(pi).put(charge()).put(paymentMethod());
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

Deno.test("checkout.session.completed (payment): unpaid, debit clearing -> processing (in flight)", async () => {
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
  assertEquals([row.status, row.paid_at, row.amount_cents], ["processing", null, 10_000]);
  // later success upgrades it
  stripe.put(intent()).put(charge());
  await ok(await deliver(handler, event("payment_intent.succeeded", intent())));
  assertEquals(payment(db).status, "succeeded");
});

Deno.test("checkout.session.completed (payment): unpaid, bank account still unverified -> pending", async () => {
  const { db, stripe, handler } = setup();
  const pi = intent({
    status: "requires_action",
    amount_received: 0,
    latest_charge: null,
    payment_method_types: ["card", "us_bank_account"],
  });
  stripe.put(pi);
  await ok(
    await deliver(
      handler,
      event("checkout.session.completed", {
        id: "cs_1Verify",
        object: "checkout.session",
        mode: "payment",
        payment_status: "unpaid",
        payment_intent: "pi_1Invoice",
        metadata: pi.metadata,
      }),
    ),
  );
  assertEquals(payment(db).status, "pending");
  // micro-deposits verified: the debit starts clearing, then settles
  const clearing = charge({
    status: "pending",
    payment_method_details: { type: "us_bank_account", us_bank_account: { last4: "6789" } },
  });
  stripe.put(clearing);
  const processing = intent({
    status: "processing",
    amount_received: 0,
    payment_method_types: ["card", "us_bank_account"],
  });
  stripe.put(processing);
  await ok(await deliver(handler, event("payment_intent.processing", processing)));
  assertEquals(
    [payment(db).status, payment(db).method, payment(db).stripe_method_type],
    ["processing", "ach_debit", "us_bank_account"],
  );
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

Deno.test("ACH: a bank debit is recorded as ach_debit with its account's last4 (no note)", async () => {
  const { db, stripe, logs, handler } = setup();
  stripe.put(intent()).put(charge({
    payment_method_details: { type: "us_bank_account", us_bank_account: { last4: "6789" } },
  }));
  await ok(await deliver(handler, event("payment_intent.succeeded", intent())));
  const row = payment(db);
  assertEquals(
    [row.status, row.method, row.stripe_method_type, row.card_brand, row.card_last4, row.note],
    ["succeeded", "ach_debit", "us_bank_account", null, "6789", null],
  );
  assertEquals(logs.events("stripe_unmapped_payment_method").length, 0);
});

Deno.test("BNPL: pay-later providers are recorded as bnpl with their Stripe type", async () => {
  for (const type of ["affirm", "klarna", "afterpay_clearpay", "zip"]) {
    const { db, stripe, handler } = setup();
    stripe.put(intent()).put(charge({ payment_method_details: { type, [type]: {} } }));
    await ok(await deliver(handler, event("payment_intent.succeeded", intent())));
    const row = payment(db);
    assertEquals(
      [row.method, row.stripe_method_type, row.card_last4, row.note],
      ["bnpl", type, null, null],
      type,
    );
  }
});

Deno.test("unmapped Stripe methods are stored as card with a note; cards get none", async () => {
  const { db, stripe, logs, handler } = setup();
  stripe.put(intent()).put(charge({ payment_method_details: { type: "cashapp", cashapp: {} } }));
  await ok(await deliver(handler, event("payment_intent.succeeded", intent())));
  const row = payment(db);
  assertEquals([row.method, row.stripe_method_type], ["card", "cashapp"]);
  assert(String(row.note).includes("cashapp (recorded as card)"), String(row.note));
  assertEquals(logs.events("stripe_unmapped_payment_method")[0]?.payment_method_type, "cashapp");
  // A card charge carries no such note, and its type is recorded.
  const cardDb = setup();
  cardDb.stripe.put(intent()).put(charge());
  await ok(await deliver(cardDb.handler, event("payment_intent.succeeded", intent())));
  assertEquals([payment(cardDb.db).note, payment(cardDb.db).stripe_method_type], [null, "card"]);
});

Deno.test("ACH through Checkout: processing -> async_payment_succeeded records the money", async () => {
  const { db, stripe, handler } = setup();
  const pi = intent({
    status: "processing",
    amount_received: 0,
    payment_method_types: ["card", "us_bank_account"],
  });
  const clearing = charge({
    status: "pending",
    payment_method_details: { type: "us_bank_account", us_bank_account: { last4: "6789" } },
  });
  stripe.put(pi).put(clearing);
  const session = {
    id: "cs_1Ach",
    object: "checkout.session",
    mode: "payment",
    payment_status: "unpaid",
    payment_intent: "pi_1Invoice",
    metadata: pi.metadata,
  };
  await ok(await deliver(handler, event("checkout.session.completed", session)));
  const row = payment(db);
  assertEquals(
    [row.status, row.method, row.card_last4, row.stripe_method_type, row.note],
    ["processing", "ach_debit", "6789", "us_bank_account", null],
  );
  // a late pending report never moves it back
  await ok(await deliver(handler, event("payment_intent.processing", pi)));
  assertEquals(payment(db).status, "processing");
  // the debit settles
  stripe.put(intent({ payment_method_types: ["card", "us_bank_account"] })).put(
    charge({ payment_method_details: clearing.payment_method_details }),
  );
  const result = await ok(
    await deliver(
      handler,
      event("checkout.session.async_payment_succeeded", { ...session, payment_status: "paid" }),
    ),
  );
  assertEquals(result.result, "applied");
  assertEquals(
    [payment(db).status, payment(db).method, payment(db).paid_at !== null],
    ["succeeded", "ach_debit", true],
  );
});

Deno.test("ACH: a debit returned after processing becomes failed and stays ach_debit", async () => {
  const { db, stripe, handler } = setup();
  const types = ["card", "us_bank_account"];
  const returned = charge({
    status: "failed",
    payment_method_details: { type: "us_bank_account", us_bank_account: { last4: "6789" } },
  });
  stripe.put(returned);
  const processing = intent({
    status: "processing",
    amount_received: 0,
    payment_method_types: types,
  });
  await ok(await deliver(handler, event("payment_intent.processing", processing)));
  assertEquals([payment(db).status, payment(db).method], ["processing", "ach_debit"]);

  const failed = intent({
    status: "requires_payment_method",
    amount_received: 0,
    payment_method_types: types,
    last_payment_error: { code: "bank_account_restricted" },
  });
  stripe.put(failed);
  const result = await ok(await deliver(handler, event("payment_intent.payment_failed", failed)));
  assertEquals(result.result, "applied");
  const row = payment(db);
  assertEquals([row.status, row.method, row.paid_at], ["failed", "ach_debit", null]);
  // a late processing / pending report never reopens it
  await ok(await deliver(handler, event("payment_intent.processing", processing)));
  assertEquals(payment(db).status, "failed");
});

Deno.test("ACH through Checkout: async_payment_failed fails the tracked payment only", async () => {
  const { db, stripe, handler } = setup();
  const types = ["card", "us_bank_account"];
  const failedIntent = intent({
    status: "requires_payment_method",
    amount_received: 0,
    payment_method_types: types,
    latest_charge: "ch_1Charge",
  });
  stripe.put(failedIntent).put(charge({
    status: "failed",
    payment_method_details: { type: "us_bank_account", us_bank_account: { last4: "6789" } },
  }));
  const session = {
    id: "cs_1Ach",
    object: "checkout.session",
    mode: "payment",
    payment_status: "unpaid",
    payment_intent: "pi_1Invoice",
    metadata: failedIntent.metadata,
  };
  // nothing tracked: no row is created for money that never arrived
  const ignored = await ok(
    await deliver(handler, event("checkout.session.async_payment_failed", session)),
  );
  assertEquals(ignored.result, "ignored");
  assertEquals(db.table("payments").length, 0);
  // tracked (processing): it fails
  trackAttempt(db, "pi_1Invoice", {
    status: "processing",
    method: "ach_debit",
    tip_cents: 1_000,
    stripe_checkout_session_id: "cs_1Ach",
  });
  const result = await ok(
    await deliver(handler, event("checkout.session.async_payment_failed", session)),
  );
  assertEquals(result.result, "applied");
  assertEquals([payment(db).status, payment(db).method], ["failed", "ach_debit"]);
});

Deno.test("payment_intent.processing records the money in flight (created when untracked)", async () => {
  const { db, stripe, handler } = setup();
  const pi = intent({
    status: "processing",
    amount_received: 0,
    payment_method_types: ["us_bank_account"],
    latest_charge: null,
  });
  stripe.put(pi);
  const result = await ok(await deliver(handler, event("payment_intent.processing", pi)));
  assertEquals(result.result, "applied");
  const row = payment(db);
  assertEquals(
    [row.status, row.method, row.stripe_method_type, row.amount_cents, row.tip_cents],
    ["processing", "ach_debit", "us_bank_account", 10_000, 1_000],
  );
  // never on another shop's intent
  const other = setup();
  const foreign = intent({
    status: "processing",
    metadata: { shop_id: OTHER_SHOP, invoice_id: INVOICE },
  });
  other.stripe.put(foreign);
  const mismatch = await ok(
    await deliver(other.handler, event("payment_intent.processing", foreign)),
  );
  assertEquals(mismatch.result, "ignored");
  assertEquals(other.db.table("payments").length, 0);
});

Deno.test("Checkout cards are saved from the card options' setup_future_usage (P-31)", async () => {
  const { db, stripe, handler } = setup();
  stripe.put(paymentMethod()).put(charge());
  const pi = intent({
    setup_future_usage: null,
    payment_method_types: ["card", "us_bank_account", "affirm"],
    payment_method_options: { card: { setup_future_usage: "off_session" } },
  });
  stripe.put(pi);
  await ok(await deliver(handler, event("payment_intent.succeeded", pi)));
  assertEquals(db.table("customer_payment_methods")[0]?.stripe_payment_method_id, "pm_1Card");
  // a bank debit is never saved as a card
  const achDb = setup();
  achDb.stripe.put(paymentMethod({ type: "us_bank_account", card: null })).put(charge({
    payment_method_details: { type: "us_bank_account", us_bank_account: { last4: "6789" } },
  })).put(pi);
  await ok(await deliver(achDb.handler, event("payment_intent.succeeded", pi)));
  assertEquals(achDb.db.table("customer_payment_methods").length, 0);
  assertEquals(payment(achDb.db).method, "ach_debit");
});

Deno.test("a Link payment on a card-saving link is recorded but flagged: no card on file", async () => {
  const { db, stripe, logs, handler } = setup();
  stripe.put(paymentMethod({ type: "link", card: null, link: { email: "ada@example.com" } }))
    .put(charge({ payment_method_details: { type: "link", link: { country: "US" } } }));
  const pi = intent({
    payment_method_types: ["card", "link"],
    payment_method_options: { card: { setup_future_usage: "off_session" } },
  });
  stripe.put(pi);
  await ok(await deliver(handler, event("payment_intent.succeeded", pi)));
  // the money is recorded as a card payment (Link pays with a card) ...
  assertEquals(payment(db).status, "succeeded");
  assertEquals(payment(db).method, "card");
  // ... but nothing is saved as the card on file, and that is logged
  assertEquals(db.table("customer_payment_methods").length, 0);
  assertEquals(rpcCalls(db, "upsert_customer_payment_method").length, 0);
  const flagged = logs.events("stripe_card_not_saved");
  assertEquals(flagged.length, 1);
  assertEquals(flagged[0]?.reason, "link_payment");
  assertEquals(flagged[0]?.level, "warn");
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

Deno.test("customer.subscription.updated: records the price Stripe bills, not the plan's", async () => {
  const { db, stripe, handler } = setup();
  const billed = subscription({
    items: {
      object: "list",
      data: [{
        id: "si_1",
        quantity: 1,
        current_period_end: 1_791_600_000,
        price: {
          id: "price_1Old",
          unit_amount: 5000,
          recurring: { interval: "month", interval_count: 1 },
        },
      }],
    },
  });
  stripe.put(billed);
  await ok(await deliver(handler, event("customer.subscription.updated", billed)));
  const call = rpcCalls(db, "sync_stripe_subscription")[0];
  assertEquals(
    [call?.p_price_id, call?.p_price_cents, call?.p_interval, call?.p_interval_count],
    ["price_1Old", 5000, "month", 1],
  );
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
      customer: "cus_1Customer",
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
    customer: "cus_1Customer",
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
    customer: "cus_1Customer",
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

// ---------------------------------------------------------------------------
// A job whose customer changed while its deposit link was open
// ---------------------------------------------------------------------------

const NEW_CUSTOMER = "33333333-3333-4333-8333-333333333333";

/**
 * The deposit Checkout was opened for CUSTOMER (metadata), then staff moved
 * the job to NEW_CUSTOMER (allowed: no invoice / payment yet). The fake's
 * payments_before_write raises 23514 exactly like 0012 does.
 */
function customerChangedSetup(options: { invoiceFor?: string; payerDeleted?: boolean } = {}) {
  const ctx = setup();
  const { db, stripe } = ctx;
  db.seed("jobs", [{ id: JOB, shop_id: SHOP, customer_id: NEW_CUSTOMER }]);
  db.seed(
    "invoices",
    options.invoiceFor
      ? [{ id: INVOICE, shop_id: SHOP, job_id: JOB, customer_id: options.invoiceFor }]
      : [],
  );
  db.seed("customers", [
    ...(options.payerDeleted
      ? []
      : [{ id: CUSTOMER, shop_id: SHOP, stripe_customer_id: "cus_1Customer" }]),
    { id: NEW_CUSTOMER, shop_id: SHOP, stripe_customer_id: null },
    { id: OTHER_CUSTOMER, shop_id: OTHER_SHOP, stripe_customer_id: "cus_1Other" },
  ]);
  const pi = intent({
    id: "pi_1Deposit",
    amount: 5_000,
    amount_received: 5_000,
    latest_charge: "ch_1Deposit",
    setup_future_usage: "off_session",
    metadata: {
      shop_id: SHOP,
      job_id: JOB,
      customer_id: CUSTOMER,
      kind: "deposit",
      tip_cents: "0",
      source: "booking_deposit_checkout",
    },
  });
  stripe.put(pi).put(paymentMethod()).put(
    charge({ id: "ch_1Deposit", amount: 5_000, amount_captured: 5_000, payment_intent: pi.id }),
  );
  return { ...ctx, pi };
}

Deno.test("customer changed: the fake raises 23514 like payments_before_write (0012)", async () => {
  const { db } = customerChangedSetup();
  const { error } = await adminRpc(db, "upsert_stripe_payment", {
    p_shop_id: SHOP,
    p_payment_intent_id: "pi_1Probe",
    p_status: "succeeded",
    p_amount_cents: 5_000,
    p_kind: "deposit",
    p_method: "card",
    p_job_id: JOB,
    p_customer_id: CUSTOMER,
  });
  assertEquals(error?.code, "23514");
});

Deno.test("customer changed: a deposit paid through the old customer's link is recorded, not failed forever", async () => {
  const { db, logs, handler, pi } = customerChangedSetup();
  const session = depositSession(pi);
  const res = await ok(await deliver(handler, event("checkout.session.completed", session)));
  assertEquals(res.result, "applied");
  const row = payment(db, "pi_1Deposit");
  // Kept with the payer (whose card paid), unapplied, like 0012 does for
  // money that arrives for a void invoice of a job that changed customer.
  assertEquals(
    [row.status, row.kind, row.customer_id, row.job_id, row.invoice_id, row.amount_cents],
    ["succeeded", "deposit", CUSTOMER, null, null, 5_000],
  );
  assert(String(row.note).includes("moved to another customer"), String(row.note));
  assertEquals(logs.events("stripe_payment_relinked")[0]?.changed, "job");
  // the payer's card is saved for the payer
  assertEquals(db.table("customer_payment_methods")[0]?.customer_id, CUSTOMER);

  // The intent event and Stripe's redelivery of the session find the row.
  await ok(await deliver(handler, event("payment_intent.succeeded", pi)));
  await ok(await deliver(handler, event("checkout.session.completed", session)));
  assertEquals(db.table("payments").length, 1);
  assertEquals(payment(db, "pi_1Deposit").note, row.note);
});

Deno.test("customer changed: an invoice created for the new customer in between (invoice branch 23514)", async () => {
  const { db, handler, pi } = customerChangedSetup({ invoiceFor: NEW_CUSTOMER });
  await ok(await deliver(handler, event("payment_intent.succeeded", pi)));
  const row = payment(db, "pi_1Deposit");
  assertEquals([row.customer_id, row.job_id, row.invoice_id], [CUSTOMER, null, null]);
  assert(String(row.note).includes("moved to another customer"), String(row.note));
});

Deno.test("customer changed: a refund arriving first records the deposit too", async () => {
  const { db, stripe, handler, pi } = customerChangedSetup();
  const refunded = charge({
    id: "ch_1Deposit",
    amount: 5_000,
    amount_captured: 5_000,
    amount_refunded: 5_000,
    refunded: true,
    payment_intent: pi.id,
  });
  stripe.put(refunded);
  const res = await ok(await deliver(handler, event("charge.refunded", refunded)));
  assertEquals(res.result, "applied");
  assertEquals(
    [payment(db, "pi_1Deposit").status, payment(db, "pi_1Deposit").customer_id],
    ["refunded", CUSTOMER],
  );
});

Deno.test("customer changed: a payer no longer in the CRM leaves the deposit on the job", async () => {
  // e.g. the duplicate customer the public form created was merged into the
  // job's new customer and deleted; the Stripe customer maps to nobody.
  const { db, handler, pi } = customerChangedSetup({ payerDeleted: true });
  await ok(await deliver(handler, event("checkout.session.completed", depositSession(pi))));
  const row = payment(db, "pi_1Deposit");
  assertEquals([row.status, row.customer_id, row.job_id], ["succeeded", NEW_CUSTOMER, JOB]);
  assert(String(row.note).includes("check who paid"), String(row.note));
});

Deno.test("customer changed: a deleted payer's saved card is never stored as the job's new customer's", async () => {
  // The deposit link was opened for CUSTOMER (cus_1Customer, setup_future_usage),
  // the job moved to NEW_CUSTOMER and CUSTOMER was deleted before paying. The
  // money falls to the job (and so to NEW_CUSTOMER), but pm_1Card belongs to
  // cus_1Customer: it must not become NEW_CUSTOMER's card on file.
  const { db, logs, handler, pi } = customerChangedSetup({ payerDeleted: true });
  const res = await ok(
    await deliver(handler, event("checkout.session.completed", depositSession(pi))),
  );
  assertEquals(res.result, "applied");
  assertEquals(payment(db, "pi_1Deposit").customer_id, NEW_CUSTOMER);
  assertEquals(db.table("customer_payment_methods"), []);
  assertEquals(rpcCalls(db, "upsert_customer_payment_method").length, 0);
  assertEquals(mismatches(logs), 1);
  // the intent event (same card) does not save it either
  await ok(await deliver(handler, event("payment_intent.succeeded", pi)));
  assertEquals(db.table("customer_payment_methods"), []);
  assertEquals(mismatches(logs), 2);
});

Deno.test("customer changed: the new customer's own Stripe customer and default card are kept", async () => {
  const { db, handler, pi } = customerChangedSetup({ payerDeleted: true });
  db.seed(
    "customers",
    db.table("customers").map((c) =>
      c.id === NEW_CUSTOMER ? { ...c, stripe_customer_id: "cus_1NewCustomer" } : c
    ),
  );
  db.seed("customer_payment_methods", [{
    id: crypto.randomUUID(),
    shop_id: SHOP,
    customer_id: NEW_CUSTOMER,
    stripe_payment_method_id: "pm_1NewOwn",
    brand: "mastercard",
    last4: "4444",
    exp_month: 1,
    exp_year: 2031,
    is_default: true,
  }]);
  await ok(await deliver(handler, event("payment_intent.succeeded", pi)));
  assertEquals(payment(db, "pi_1Deposit").customer_id, NEW_CUSTOMER);
  assertEquals(
    db.table("customer_payment_methods").map((r) => [
      r.customer_id,
      r.stripe_payment_method_id,
      r.is_default,
    ]),
    [[NEW_CUSTOMER, "pm_1NewOwn", true]],
  );
});

Deno.test("card save: a setup intent whose card is attached to another Stripe customer is ignored", async () => {
  const { db, stripe, logs, handler } = setup();
  stripe.put(paymentMethod({ id: "pm_1Elsewhere", customer: "cus_1Somebody" }));
  const res = await ok(
    await deliver(
      handler,
      event("setup_intent.succeeded", {
        id: "seti_1Elsewhere",
        object: "setup_intent",
        status: "succeeded",
        customer: "cus_1Somebody",
        payment_method: "pm_1Elsewhere",
        metadata: { shop_id: SHOP, customer_id: CUSTOMER },
      }),
    ),
  );
  assertEquals(res.result, "ignored");
  assertEquals(mismatches(logs), 1);
  assertEquals(db.table("customer_payment_methods"), []);
});

Deno.test("card save: a card a merge moved is refreshed on its own Stripe customer (0095)", async () => {
  const { db, stripe, logs, handler } = setup();
  // pm_1Merged was saved on the duplicate's Stripe customer, then the
  // duplicate was merged into CUSTOMER (whose own Stripe customer differs)
  db.seed("customer_payment_methods", [{
    id: crypto.randomUUID(),
    shop_id: SHOP,
    customer_id: CUSTOMER,
    stripe_payment_method_id: "pm_1Merged",
    stripe_customer_id: "cus_1Duplicate",
    brand: "visa",
    last4: "4242",
    exp_month: 1,
    exp_year: 2027,
    is_default: true,
  }]);
  const setupIntent = (id: string, pm: string) => ({
    id,
    object: "setup_intent",
    status: "succeeded",
    customer: "cus_1Duplicate",
    payment_method: pm,
    metadata: { shop_id: SHOP, customer_id: CUSTOMER },
  });
  // Stripe updated the card (new expiry): the re-save refreshes the row
  stripe.put(paymentMethod({
    id: "pm_1Merged",
    customer: "cus_1Duplicate",
    card: { brand: "visa", last4: "4242", exp_month: 6, exp_year: 2031 },
  }));
  const res = await ok(
    await deliver(
      handler,
      event("setup_intent.succeeded", setupIntent("seti_1Merged", "pm_1Merged")),
    ),
  );
  assertEquals(res.result, "applied");
  assertEquals(mismatches(logs), 0);
  const call = rpcCalls(db, "upsert_customer_payment_method")[0];
  assertEquals([call?.p_customer_id, call?.p_stripe_customer_id], [CUSTOMER, "cus_1Duplicate"]);
  assertEquals(
    db.table("customer_payment_methods").map((r) => [
      r.customer_id,
      r.stripe_payment_method_id,
      r.stripe_customer_id,
      r.exp_month,
      r.exp_year,
      r.is_default,
    ]),
    [[CUSTOMER, "pm_1Merged", "cus_1Duplicate", 6, 2031, true]],
  );
  // a NEW card on that other Stripe customer is still not CUSTOMER's
  stripe.put(paymentMethod({ id: "pm_1Fresh", customer: "cus_1Duplicate" }));
  const fresh = await ok(
    await deliver(
      handler,
      event("setup_intent.succeeded", setupIntent("seti_1Fresh", "pm_1Fresh")),
    ),
  );
  assertEquals(fresh.result, "ignored");
  assertEquals(mismatches(logs), 1);
  assertEquals(rpcCalls(db, "upsert_customer_payment_method").length, 1);
  assertEquals(db.table("customer_payment_methods").length, 1);
});

function mismatches(logs: ReturnType<typeof memoryLogger>): number {
  return logs.events("stripe_event_ignored").filter((e) =>
    e.reason === "payment_method_customer_mismatch"
  ).length;
}

Deno.test("customer changed: a 23514 without a changed parent is still retried (500)", async () => {
  const { db, stripe, handler } = setup();
  stripe.put(intent()).put(charge());
  db.onRpc("upsert_stripe_payment", () => {
    throw new FakeRpcError("23514", "violates check constraint");
  });
  const res = await deliver(handler, event("payment_intent.succeeded", intent()));
  assertEquals(res.status, 500);
  assertEquals((await res.json() as ErrorBody).code, "internal_error");
  assertEquals(rpcCalls(db, "upsert_stripe_payment").length, 1);
});

// ---------------------------------------------------------------------------
// payment_method.detached / customer.deleted
// ---------------------------------------------------------------------------

function saveCards(db: FakeSupabase, cards: [pm: string, isDefault: boolean][]): void {
  db.seed(
    "customer_payment_methods",
    cards.map(([pm, isDefault]) => ({
      id: crypto.randomUUID(),
      shop_id: SHOP,
      customer_id: CUSTOMER,
      stripe_payment_method_id: pm,
      brand: "visa",
      last4: "4242",
      exp_month: 12,
      exp_year: 2030,
      is_default: isDefault,
    })),
  );
}

Deno.test("payment_method.detached removes the saved card; the newest remaining card becomes default", async () => {
  const { db, handler } = setup();
  saveCards(db, [["pm_1Card", true], ["pm_1Older", false], ["pm_1Newer", false]]);
  const detached = paymentMethod({ customer: null });
  const res = await ok(await deliver(handler, event("payment_method.detached", detached)));
  assertEquals(res.result, "applied");
  assertEquals(rpcCalls(db, "remove_customer_payment_method"), [{
    p_shop_id: SHOP,
    p_stripe_payment_method_id: "pm_1Card",
  }]);
  assertEquals(
    db.table("customer_payment_methods").map((r) => [r.stripe_payment_method_id, r.is_default]),
    [["pm_1Older", false], ["pm_1Newer", true]],
  );
  // a card the CRM never saved (or a replay) is acknowledged
  const again = await ok(await deliver(handler, event("payment_method.detached", detached)));
  assertEquals(again.result, "ignored");
  // another account's event only ever touches that account's shop
  await ok(
    await deliver(
      handler,
      event("payment_method.detached", paymentMethod({ id: "pm_1Older", customer: null }), {
        account: OTHER_ACCT,
      }),
    ),
  );
  assertEquals(rpcCalls(db, "remove_customer_payment_method").at(-1)?.p_shop_id, OTHER_SHOP);
  assertEquals(db.table("customer_payment_methods").length, 2);
  // unknown connected account: nothing is called
  const stranger = await ok(
    await deliver(handler, event("payment_method.detached", detached, { account: STRANGER_ACCT })),
  );
  assertEquals(stranger.result, "ignored");
  assertEquals(rpcCalls(db, "remove_customer_payment_method").length, 3);
});

Deno.test("payment_method.detached: a late setup_intent.succeeded never re-saves the removed card", async () => {
  const { db, stripe, handler } = setup();
  const si = {
    id: "seti_1Late",
    object: "setup_intent",
    status: "succeeded",
    customer: "cus_1Customer",
    payment_method: "pm_1Card",
    metadata: { shop_id: SHOP, customer_id: CUSTOMER },
  };
  // Stripe already shows the card detached when the (retried) event is processed.
  stripe.put(paymentMethod({ customer: null }));
  const res = await ok(await deliver(handler, event("setup_intent.succeeded", si)));
  assertEquals(res.result, "ignored");
  assertEquals(db.table("customer_payment_methods"), []);
  assertEquals(rpcCalls(db, "upsert_customer_payment_method").length, 0);
});

Deno.test("payment_method.detached: a late deposit success records the money but not the removed card", async () => {
  const { db, stripe, handler } = setup();
  const pi = intent({ setup_future_usage: "off_session" });
  stripe.put(pi).put(charge()).put(paymentMethod({ customer: null }));
  await ok(await deliver(handler, event("payment_intent.succeeded", pi)));
  assertEquals(payment(db).status, "succeeded");
  assertEquals(db.table("customer_payment_methods"), []);
  // a payment method Stripe no longer has at all is treated the same way
  const { db: db2, stripe: stripe2, handler: handler2 } = setup();
  stripe2.put(pi).put(charge());
  await ok(await deliver(handler2, event("payment_intent.succeeded", pi)));
  assertEquals([payment(db2).status, db2.table("customer_payment_methods")], ["succeeded", []]);
});

Deno.test("customer.deleted removes the cards of that Stripe customer, keeping cards attached elsewhere", async () => {
  const { db, stripe, handler } = setup();
  saveCards(db, [["pm_1Card", true], ["pm_1Moved", false]]);
  stripe.put(paymentMethod({ customer: null })).put(
    paymentMethod({ id: "pm_1Moved", customer: "cus_1Replacement" }),
  );
  const res = await ok(
    await deliver(
      handler,
      event("customer.deleted", { id: "cus_1Customer", object: "customer", deleted: true }),
    ),
  );
  assertEquals(res.result, "applied");
  assertEquals(
    db.table("customer_payment_methods").map((r) => [r.stripe_payment_method_id, r.is_default]),
    [["pm_1Moved", true]],
  );
  // a Stripe customer the shop does not know is acknowledged
  const unknown = await ok(
    await deliver(handler, event("customer.deleted", { id: "cus_1Nobody", object: "customer" })),
  );
  assertEquals(unknown.result, "ignored");
});

// ---------------------------------------------------------------------------
// charge.dispute.*
// ---------------------------------------------------------------------------

const DUE_BY = Date.UTC(2026, 9, 12, 23, 59, 59) / 1000;

function dispute(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    id: "dp_1Dispute",
    object: "dispute",
    amount: 11_000,
    currency: "usd",
    charge: "ch_1Charge",
    payment_intent: "pi_1Invoice",
    reason: "product_not_received",
    status: "needs_response",
    evidence_details: { due_by: DUE_BY },
    ...overrides,
  };
}

async function paidInvoice(ctx: ReturnType<typeof setup>): Promise<void> {
  ctx.stripe.put(intent()).put(charge());
  await ok(await deliver(ctx.handler, event("payment_intent.succeeded", intent())));
}

Deno.test("charge.dispute.created flags the payment and notifies owners/admins", async () => {
  const ctx = setup();
  const { db, stripe, logs, handler } = ctx;
  await paidInvoice(ctx);
  stripe.put(dispute());
  const res = await ok(await deliver(handler, event("charge.dispute.created", dispute())));
  assertEquals(res.result, "applied");
  const row = payment(db);
  assertEquals(
    row.note,
    "Stripe dispute (product not received, $110.00): open. Submit evidence in the Stripe " +
      "dashboard by 2026-10-12.",
  );
  assertEquals(rpcCalls(db, "notify_shop_staff"), [{
    p_shop_id: SHOP,
    p_roles: ["owner", "admin"],
    p_kind: "payment_received",
    p_title: "A card payment was disputed",
    p_body: row.note,
    p_job_id: JOB,
    p_customer_id: CUSTOMER,
    p_invoice_id: INVOICE,
  }]);
  // an open dispute records no outcome yet
  assertEquals(rpcCalls(db, "apply_stripe_dispute")[0]?.p_dispute_status, "needs_response");
  assertEquals(payment(db).disputed_cents, 0);
  assertEquals(logs.events("stripe_dispute")[0]?.dispute_status, "needs_response");
  // the dispute was read on the shop's connected account
  assertEquals(
    db.http.callsTo("GET", `${STRIPE}/disputes/:id`)[0]?.headers.get("stripe-account"),
    ACCT,
  );
  // a replay / an update without a state change notifies nobody again
  const same = await ok(await deliver(handler, event("charge.dispute.updated", dispute())));
  assertEquals(same.result, "ignored");
  assertEquals(rpcCalls(db, "notify_shop_staff").length, 1);
  // the money itself is unchanged while the dispute is open
  assertEquals([payment(db).status, payment(db).refunded_cents], ["succeeded", 0]);
});

Deno.test("charge.dispute.closed (lost) replaces the flag, logs an error and notifies again", async () => {
  const ctx = setup();
  const { db, stripe, logs, handler } = ctx;
  await paidInvoice(ctx);
  stripe.put(dispute());
  await ok(await deliver(handler, event("charge.dispute.created", dispute())));
  stripe.put(dispute({ status: "under_review" }));
  await ok(await deliver(handler, event("charge.dispute.updated", dispute())));
  assert(String(payment(db).note).includes("under review"));
  assertEquals(rpcCalls(db, "notify_shop_staff").length, 1); // no alert for "under review"

  stripe.put(dispute({ status: "lost" }));
  const res = await ok(await deliver(handler, event("charge.dispute.closed", dispute())));
  assertEquals(res.result, "applied");
  const note = String(payment(db).note);
  assert(note.startsWith("Stripe dispute (product not received, $110.00): LOST."), note);
  assertEquals(note.split("\n").length, 1); // one dispute line, replaced in place
  assertEquals(rpcCalls(db, "notify_shop_staff").at(-1)?.p_title, "Dispute lost: money taken back");
  assertEquals(logs.events("stripe_dispute_lost").length, 1);
  // the outcome is recorded (what it took back, bounded by the charge);
  // the balance-relevant fields are untouched
  assertEquals(rpcCalls(db, "apply_stripe_dispute").at(-1), {
    p_shop_id: SHOP,
    p_payment_intent_id: "pi_1Invoice",
    p_dispute_status: "lost",
    p_amount_cents: 11_000,
  });
  assertEquals(
    [payment(db).disputed_cents, payment(db).status, payment(db).refunded_cents],
    [11_000, "succeeded", 0],
  );
  // funds_withdrawn for the same lost dispute changes nothing more
  await ok(await deliver(handler, event("charge.dispute.funds_withdrawn", dispute())));
  assertEquals(rpcCalls(db, "notify_shop_staff").length, 2);
  assertEquals(payment(db).disputed_cents, 11_000);
});

Deno.test("charge.dispute.funds_reinstated / won clears a lost dispute's amount (current state wins)", async () => {
  const ctx = setup();
  const { db, stripe, handler } = ctx;
  await paidInvoice(ctx);
  stripe.put(dispute({ status: "lost" }));
  await ok(await deliver(handler, event("charge.dispute.closed", dispute())));
  assertEquals(payment(db).disputed_cents, 11_000);
  // A late funds_withdrawn (withdrawn when the dispute opened) after the
  // issuer reversed its decision: Stripe's current state decides.
  stripe.put(dispute({ status: "won" }));
  await ok(await deliver(handler, event("charge.dispute.funds_withdrawn", dispute())));
  assertEquals(payment(db).disputed_cents, 0);
  await ok(await deliver(handler, event("charge.dispute.funds_reinstated", dispute())));
  assertEquals(payment(db).disputed_cents, 0);
  assertEquals(rpcCalls(db, "apply_stripe_dispute").map((c) => c.p_dispute_status), [
    "lost",
    "won",
    "won",
  ]);
});

Deno.test("charge.dispute.*: a refunded part is never counted as lost again", async () => {
  const ctx = setup();
  const { db, stripe, handler } = ctx;
  await paidInvoice(ctx);
  db.seed(
    "payments",
    db.table("payments").map((r) => ({
      ...r,
      refunded_cents: 4_000,
      status: "partially_refunded",
    })),
  );
  stripe.put(dispute({ status: "lost" }));
  await ok(await deliver(handler, event("charge.dispute.closed", dispute())));
  assertEquals(payment(db).disputed_cents, 7_000);
});

Deno.test("charge.dispute.*: out of order, a late 'created' after the close applies the current state", async () => {
  const ctx = setup();
  const { db, stripe, handler } = ctx;
  await paidInvoice(ctx);
  stripe.put(dispute({ status: "won" }));
  await ok(await deliver(handler, event("charge.dispute.closed", dispute({ status: "won" }))));
  await ok(await deliver(handler, event("charge.dispute.created", dispute())));
  assert(String(payment(db).note).includes("won."), String(payment(db).note));
  assertEquals(rpcCalls(db, "notify_shop_staff").map((c) => c.p_title), ["Dispute won"]);
});

Deno.test("charge.dispute.*: other notes on the payment are kept; a charge-only dispute is matched", async () => {
  const ctx = setup();
  const { db, stripe, handler } = ctx;
  await paidInvoice(ctx);
  db.seed("payments", db.table("payments").map((r) => ({ ...r, note: "Paid at the door" })));
  const byCharge = dispute({ payment_intent: null });
  stripe.put(byCharge);
  await ok(await deliver(handler, event("charge.dispute.created", byCharge)));
  const lines = String(payment(db).note).split("\n");
  assertEquals(lines[0], "Paid at the door");
  assert(lines[1]?.startsWith("Stripe dispute"), lines[1]);
});

Deno.test("charge.dispute.*: unknown payments and accounts are acknowledged without writes", async () => {
  const { db, stripe, logs, handler } = setup();
  stripe.put(dispute({ payment_intent: "pi_1Unknown", charge: "ch_1Unknown" }));
  const unknown = await ok(
    await deliver(
      handler,
      event("charge.dispute.created", dispute({ payment_intent: "pi_1Unknown" })),
    ),
  );
  assertEquals(unknown.result, "ignored");
  assertEquals(logs.events("stripe_dispute_unmatched").length, 1);
  const stranger = await ok(
    await deliver(handler, event("charge.dispute.created", dispute(), { account: STRANGER_ACCT })),
  );
  assertEquals(stranger.result, "ignored");
  assertEquals(rpcCalls(db, "notify_shop_staff").length, 0);
  assertEquals(db.table("payments"), []);
});

Deno.test("disputeNoteLine / withDisputeLine: bounded, replace in place, no personal data", () => {
  const line = disputeNoteLine({
    amount: 5_000,
    currency: "usd",
    status: "warning_needs_response",
    reason: "fraudulent",
    evidence_details: { due_by: null },
  });
  assertEquals(
    line,
    "Stripe dispute (fraudulent, $50.00): open. Submit evidence in the Stripe dashboard.",
  );
  assertEquals(withDisputeLine(null, line), line);
  assertEquals(
    withDisputeLine(`a\n${line}`, "Stripe dispute (x): won."),
    "a\nStripe dispute (x): won.",
  );
  const long = withDisputeLine("n".repeat(2_000), line);
  assertEquals(long.length, 1_000);
  assert(long.endsWith(line));
});

// ---------------------------------------------------------------------------
// Saved cards: the SQL helper checks the Stripe customer too (0011)
// ---------------------------------------------------------------------------

Deno.test("saved cards are stored with the Stripe customer they are attached to", async () => {
  const { db, stripe, handler } = setup();
  stripe.put(paymentMethod());
  await ok(
    await deliver(
      handler,
      event("setup_intent.succeeded", {
        id: "seti_1Card",
        object: "setup_intent",
        status: "succeeded",
        customer: "cus_1Customer",
        payment_method: "pm_1Card",
        metadata: { shop_id: SHOP, customer_id: CUSTOMER },
      }),
    ),
  );
  assertEquals(
    rpcCalls(db, "upsert_customer_payment_method")[0]?.p_stripe_customer_id,
    "cus_1Customer",
  );
  assertEquals(db.table("customer_payment_methods").length, 1);
});

// ---------------------------------------------------------------------------
// Sibling PaymentSheets once the invoice is paid
// ---------------------------------------------------------------------------

function openSheet(id: string, status: string, source = "payment_sheet"): Row {
  return {
    id,
    object: "payment_intent",
    amount: 11_000,
    status,
    metadata: { shop_id: SHOP, invoice_id: INVOICE, source },
  };
}

function seedSheetRows(db: FakeSupabase, ids: string[]): void {
  db.seed(
    "payments",
    ids.map((pi, i) => ({
      id: `p-sheet-${i}`,
      shop_id: SHOP,
      customer_id: CUSTOMER,
      invoice_id: INVOICE,
      job_id: JOB,
      membership_id: null,
      status: "pending",
      kind: "payment",
      method: "card",
      amount_cents: 11_000,
      tip_cents: 0,
      refunded_cents: 0,
      disputed_cents: 0,
      stripe_payment_intent_id: pi,
    })),
  );
}

function sheetSetup(balanceCents: number) {
  const ctx = setup();
  ctx.db.seed("invoices", [{
    id: INVOICE,
    shop_id: SHOP,
    job_id: JOB,
    customer_id: CUSTOMER,
    status: balanceCents > 0 ? "partially_paid" : "paid",
    balance_cents: balanceCents,
  }]);
  seedSheetRows(ctx.db, ["pi_1SheetA", "pi_1SheetB", "pi_1SheetBusy", "pi_1Checkout"]);
  ctx.stripe
    .put(openSheet("pi_1SheetA", "requires_payment_method"))
    .put(openSheet("pi_1SheetB", "requires_confirmation"))
    .put(openSheet("pi_1SheetBusy", "requires_action"))
    .put(openSheet("pi_1Checkout", "requires_payment_method", "invoice_checkout"))
    .put(intent())
    .put(charge());
  const cancels: Array<{ id: string; key: string | null; account: string | null }> = [];
  ctx.db.http.on("POST", `${STRIPE}/payment_intents/:id/cancel`, (req, { params }) => {
    const found = ctx.stripe.objects.get(params.id ?? "");
    cancels.push({
      id: params.id ?? "",
      key: req.headers.get("idempotency-key"),
      account: req.headers.get("stripe-account"),
    });
    if (found) found.status = "canceled";
    return jsonResponse({ ...found, status: "canceled" });
  });
  return { ...ctx, cancels };
}

Deno.test("a payment that settles the invoice cancels its other waiting PaymentSheets", async () => {
  const { db, handler, cancels, logs } = sheetSetup(0);
  const res = await ok(await deliver(handler, event("payment_intent.succeeded", intent())));
  assertEquals(res.result, "applied");
  // Only the sheets still waiting for a card; 3DS in progress and other
  // flows' intents are left to the payments sweep.
  assertEquals(cancels.map((c) => c.id), ["pi_1SheetA", "pi_1SheetB"]);
  for (const c of cancels) {
    assertEquals(c.account, ACCT);
    assert(c.key?.startsWith("dcrm:sheet_cancel:"), String(c.key));
  }
  const status = (pi: string) => payment(db, pi).status;
  assertEquals(
    ["pi_1SheetA", "pi_1SheetB", "pi_1SheetBusy", "pi_1Checkout"].map(status),
    ["cancelled", "cancelled", "pending", "pending"],
  );
  assertEquals(logs.events("sibling_sheet_cancelled").length, 2);
});

Deno.test("sheets stay open while the invoice still has a balance", async () => {
  const { db, handler, cancels } = sheetSetup(2_500);
  await ok(await deliver(handler, event("payment_intent.succeeded", intent())));
  assertEquals(cancels, []);
  assertEquals(payment(db, "pi_1SheetA").status, "pending");
});

Deno.test("a sheet that cannot be cancelled never fails the delivery (the money is recorded)", async () => {
  const { db, handler, logs } = sheetSetup(0);
  db.http.on(
    "POST",
    `${STRIPE}/payment_intents/:id/cancel`,
    () => jsonResponse(stripeErrorBody("api_error", "Stripe is down"), 500),
  );
  const res = await ok(await deliver(handler, event("payment_intent.succeeded", intent())));
  assertEquals(res.result, "applied");
  assertEquals(payment(db).status, "succeeded");
  assertEquals(payment(db, "pi_1SheetA").status, "pending");
  assertEquals(logs.events("sibling_sheet_cancel_failed").length, 2);
});

// ---------------------------------------------------------------------------
// Unlinkable money (upsert_stripe_payment P0002)
// ---------------------------------------------------------------------------

Deno.test("P0002 with every named record gone and no known payer is acknowledged, not retried", async () => {
  const { db, stripe, logs, handler } = setup();
  db.seed("invoices", []);
  db.seed("jobs", []);
  const pi = intent({
    customer: "cus_1Unknown",
    metadata: {
      shop_id: SHOP,
      invoice_id: INVOICE,
      job_id: JOB,
      customer_id: "44444444-4444-4444-8444-444444444444",
      kind: "payment",
      tip_cents: "0",
    },
  });
  stripe.put(pi).put(charge());
  const res = await ok(await deliver(handler, event("payment_intent.succeeded", pi)));
  assertEquals([res.result, res.handled], ["ignored", true]);
  assertEquals(db.table("payments"), []);
  assertEquals(logs.events("stripe_payment_unlinkable")[0]?.deleted, [
    "invoice",
    "job",
    "customer",
  ]);
});

Deno.test("P0002 while the named records exist is a real failure: retried (500)", async () => {
  const { db, stripe, handler } = setup();
  stripe.put(intent()).put(charge());
  db.onRpc("upsert_stripe_payment", () => {
    throw new FakeRpcError("P0002", "shop not found");
  });
  const res = await deliver(handler, event("payment_intent.succeeded", intent()));
  assertEquals(res.status, 500);
  await res.body?.cancel();
});

// ---------------------------------------------------------------------------
// Online gift card sales (P-13): gift_card_order_paid / _refunded, never payments
// ---------------------------------------------------------------------------

const ORDER = "60000000-0000-4000-8000-000000000001";

function giftSetup(orderShop = SHOP) {
  const ctx = setup({
    tables: {
      gift_card_orders: [{
        id: ORDER,
        shop_id: orderShop,
        status: "pending",
        gift_card_id: null,
        price_cents: 9_000,
        stripe_checkout_session_id: "cs_1Gift",
      }],
    },
  });
  // 0095 rules: the pending order of the session expires once; paid ones never
  ctx.db.onRpc("gift_card_order_expired", (a, { role }) => {
    assertEquals(role, "service_role");
    if (!/^cs_[A-Za-z0-9_]+$/.test(String(a.p_session_id))) {
      throw new FakeRpcError("22023", "invalid Checkout Session id");
    }
    return mutate(ctx.db, "gift_card_orders", (rows) => {
      const order = rows.find((o) => o.stripe_checkout_session_id === a.p_session_id);
      if (!order) throw new FakeRpcError("P0002", "gift card order not found");
      const changed = order.status === "pending";
      if (changed) order.status = "expired";
      return { order_id: order.id, status: order.status, changed };
    });
  });
  // 0066 rules: issue once per order (replays hand back the card), amount must match
  ctx.db.onRpc("gift_card_order_paid", (a, { role }) => {
    assertEquals(role, "service_role");
    return mutate(ctx.db, "gift_card_orders", (rows) => {
      const order = rows.find((o) => o.id === a.p_order_id);
      if (!order) throw new FakeRpcError("P0002", "gift card order not found");
      if (order.gift_card_id) {
        return { gift_card_id: order.gift_card_id, last4: "WXYZ", first_time: false };
      }
      if (a.p_amount_received_cents !== order.price_cents) {
        throw new FakeRpcError("22023", "the amount received does not match the order price");
      }
      order.gift_card_id = "61000000-0000-4000-8000-000000000001";
      order.status = "paid";
      return { gift_card_id: order.gift_card_id, last4: "WXYZ", first_time: true };
    });
  });
  ctx.db.onRpc("gift_card_order_refunded", (a, { role }) => {
    assertEquals(role, "service_role");
    return mutate(ctx.db, "gift_card_orders", (rows) => {
      const order = rows.find((o) => o.gift_card_id);
      if (!order) {
        throw new FakeRpcError("P0002", `gift card for intent ${a.p_payment_intent_id} not found`);
      }
      order.refunded_cents = a.p_refunded_total_cents;
      return { gift_card_id: order.gift_card_id, removed_cents: 1_000, unrecovered_cents: 0 };
    });
  });
  return ctx;
}

function giftIntent(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return intent({
    id: "pi_1Gift",
    amount: 9_000,
    amount_received: 9_000,
    customer: null,
    latest_charge: "ch_1Gift",
    metadata: { shop_id: SHOP, gift_card_order_id: ORDER, kind: "gift_card" },
    ...overrides,
  });
}

Deno.test("gift card sale: checkout.session.completed issues the card once, never a payment", async () => {
  const { db, stripe, handler } = giftSetup();
  const pi = giftIntent();
  stripe.put(pi).put(charge({ id: "ch_1Gift", amount: 9_000, payment_intent: "pi_1Gift" }));
  const session = {
    id: "cs_1Gift",
    object: "checkout.session",
    mode: "payment",
    payment_status: "paid",
    payment_intent: "pi_1Gift",
    metadata: pi.metadata,
  };
  const first = await ok(await deliver(handler, event("checkout.session.completed", session)));
  assertEquals(first.result, "applied");
  assertEquals(rpcCalls(db, "gift_card_order_paid")[0], {
    p_order_id: ORDER,
    p_payment_intent_id: "pi_1Gift",
    p_amount_received_cents: 9_000,
  });
  // payment_intent.succeeded for the same sale: the card is not issued twice
  const again = await ok(await deliver(handler, event("payment_intent.succeeded", pi)));
  assertEquals(again.result, "applied");
  assertEquals(db.table("gift_card_orders")[0]?.status, "paid");
  assertEquals(rpcCalls(db, "upsert_stripe_payment").length, 0);
  assertEquals(db.table("payments").length, 0);
});

Deno.test("gift card sale: failures, other shops and mismatched amounts never issue a card", async () => {
  // declined / cancelled: nothing
  const declined = giftSetup();
  declined.stripe.put(giftIntent({ status: "requires_payment_method", amount_received: 0 }));
  const failed = await ok(
    await deliver(
      declined.handler,
      event("payment_intent.payment_failed", giftIntent({ status: "requires_payment_method" })),
    ),
  );
  assertEquals(failed.result, "ignored");
  assertEquals(rpcCalls(declined.db, "gift_card_order_paid").length, 0);

  // an order of another shop named in this shop's intent
  const foreign = giftSetup(OTHER_SHOP);
  foreign.stripe.put(charge({ id: "ch_1Gift", amount: 9_000, payment_intent: "pi_1Gift" }));
  const res = await ok(
    await deliver(foreign.handler, event("payment_intent.succeeded", giftIntent())),
  );
  assertEquals(res.result, "ignored");
  assertEquals(rpcCalls(foreign.db, "gift_card_order_paid").length, 0);

  // the amount received does not match the order: logged for staff, acknowledged
  const odd = giftSetup();
  odd.stripe.put(charge({ id: "ch_1Gift", amount: 5_000, payment_intent: "pi_1Gift" }));
  const mismatch = await ok(
    await deliver(
      odd.handler,
      event("payment_intent.succeeded", giftIntent({ amount_received: 5_000 })),
    ),
  );
  assertEquals(mismatch.result, "ignored");
  assertEquals(odd.logs.events("gift_card_order_unpaid")[0]?.code, "22023");
  assertEquals(odd.db.table("payments").length, 0);
});

Deno.test("gift card sale: a refund in Stripe takes the value off the card", async () => {
  const { db, stripe, handler } = giftSetup();
  const pi = giftIntent();
  stripe.put(pi).put(charge({ id: "ch_1Gift", amount: 9_000, payment_intent: "pi_1Gift" }));
  await ok(await deliver(handler, event("payment_intent.succeeded", pi)));
  stripe.put(charge({
    id: "ch_1Gift",
    amount: 9_000,
    amount_refunded: 3_000,
    payment_intent: "pi_1Gift",
  }));
  const res = await ok(
    await deliver(
      handler,
      event("charge.refunded", charge({ id: "ch_1Gift", payment_intent: "pi_1Gift" })),
    ),
  );
  assertEquals(res.result, "applied");
  assertEquals(rpcCalls(db, "gift_card_order_refunded")[0], {
    p_payment_intent_id: "pi_1Gift",
    p_refunded_total_cents: 3_000,
  });
  assertEquals(rpcCalls(db, "apply_stripe_refund").length, 0);
  assertEquals(db.table("payments").length, 0);
});

Deno.test("gift card sale: a refund that arrives before the sale issues the card first", async () => {
  const { db, stripe, handler } = giftSetup();
  stripe.put(giftIntent()).put(charge({
    id: "ch_1Gift",
    amount: 9_000,
    amount_refunded: 9_000,
    payment_intent: "pi_1Gift",
  }));
  const res = await ok(
    await deliver(
      handler,
      event("charge.refunded", charge({ id: "ch_1Gift", payment_intent: "pi_1Gift" })),
    ),
  );
  assertEquals(res.result, "applied");
  assertEquals(rpcCalls(db, "gift_card_order_paid").length, 1);
  assertEquals(rpcCalls(db, "gift_card_order_refunded")[0]?.p_refunded_total_cents, 9_000);
});

function expiredGiftSession(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    id: "cs_1Gift",
    object: "checkout.session",
    mode: "payment",
    status: "expired",
    payment_status: "unpaid",
    payment_intent: null,
    metadata: { shop_id: SHOP, gift_card_order_id: ORDER, kind: "gift_card" },
    ...overrides,
  };
}

/** The reason of the last acknowledged-without-changes event. */
function lastIgnored(logs: ReturnType<typeof memoryLogger>): unknown {
  return logs.events("stripe_event_ignored").at(-1)?.reason;
}

Deno.test("gift card sale: an expired Checkout expires its pending order, once", async () => {
  const { db, logs, handler } = giftSetup();
  const first = await ok(
    await deliver(handler, event("checkout.session.expired", expiredGiftSession())),
  );
  assertEquals([first.handled, first.result], [true, "applied"]);
  assertEquals(logs.events("stripe_event_applied").at(-1)?.detail, "gift_card_order_expired");
  assertEquals(rpcCalls(db, "gift_card_order_expired"), [{ p_session_id: "cs_1Gift" }]);
  assertEquals(db.table("gift_card_orders")[0]?.status, "expired");
  // another delivery of the same expiry (a new event id) changes nothing
  const again = await ok(
    await deliver(handler, event("checkout.session.expired", expiredGiftSession())),
  );
  assertEquals([again.result, lastIgnored(logs)], ["ignored", "gift_card_order_not_pending"]);
  assertEquals(db.table("gift_card_orders")[0]?.status, "expired");
  assertEquals(db.table("payments").length, 0);
});

Deno.test("gift card sale: an expiry never touches a paid order", async () => {
  const { db, stripe, logs, handler } = giftSetup();
  const pi = giftIntent();
  stripe.put(pi).put(charge({ id: "ch_1Gift", amount: 9_000, payment_intent: "pi_1Gift" }));
  await ok(await deliver(handler, event("payment_intent.succeeded", pi)));
  const res = await ok(
    await deliver(handler, event("checkout.session.expired", expiredGiftSession())),
  );
  assertEquals([res.result, lastIgnored(logs)], ["ignored", "gift_card_order_not_pending"]);
  assertEquals(db.table("gift_card_orders")[0]?.status, "paid");
});

Deno.test("checkout.session.expired: other sessions, other shops and unknown orders are acknowledged", async () => {
  // an invoice pay link: nothing was recorded, nothing to expire
  const invoiceLink = giftSetup();
  const link = await ok(
    await deliver(
      invoiceLink.handler,
      event(
        "checkout.session.expired",
        expiredGiftSession({
          id: "cs_1Invoice",
          metadata: { shop_id: SHOP, invoice_id: INVOICE, kind: "payment" },
        }),
      ),
    ),
  );
  assertEquals([link.result, lastIgnored(invoiceLink.logs)], ["ignored", "nothing_to_expire"]);
  // metadata naming another shop
  const foreignMeta = giftSetup();
  const mismatch = await ok(
    await deliver(
      foreignMeta.handler,
      event(
        "checkout.session.expired",
        expiredGiftSession({
          metadata: { shop_id: OTHER_SHOP, gift_card_order_id: ORDER, kind: "gift_card" },
        }),
      ),
    ),
  );
  assertEquals([mismatch.result, lastIgnored(foreignMeta.logs)], ["ignored", "shop_mismatch"]);
  // this shop's session naming another shop's order
  const foreignOrder = giftSetup(OTHER_SHOP);
  const notOurs = await ok(
    await deliver(foreignOrder.handler, event("checkout.session.expired", expiredGiftSession())),
  );
  assertEquals([notOurs.result, lastIgnored(foreignOrder.logs)], [
    "ignored",
    "gift_card_order_not_found",
  ]);
  assertEquals(foreignOrder.db.table("gift_card_orders")[0]?.status, "pending");
  // an unknown connected account
  const unknown = giftSetup();
  const stranger = await ok(
    await deliver(
      unknown.handler,
      event("checkout.session.expired", expiredGiftSession(), { account: "acct_1Stranger" }),
    ),
  );
  assertEquals([stranger.result, lastIgnored(unknown.logs)], ["ignored", "unknown_account"]);
  for (const f of [invoiceLink, foreignMeta, foreignOrder, unknown]) {
    assertEquals(rpcCalls(f.db, "gift_card_order_expired").length, 0);
  }
  // the order never recorded this session (P0002): acknowledged, not retried
  const unsaved = giftSetup();
  unsaved.db.seed(
    "gift_card_orders",
    unsaved.db.table("gift_card_orders").map((o) => ({ ...o, stripe_checkout_session_id: null })),
  );
  const missing = await ok(
    await deliver(unsaved.handler, event("checkout.session.expired", expiredGiftSession())),
  );
  assertEquals([missing.result, lastIgnored(unsaved.logs)], [
    "ignored",
    "gift_card_order_not_found",
  ]);
  assertEquals(rpcCalls(unsaved.db, "gift_card_order_expired").length, 1);
  assertEquals(unsaved.db.table("gift_card_orders")[0]?.status, "pending");
});

// ---------------------------------------------------------------------------
// Terminal / Tap to Pay (P-6)
// ---------------------------------------------------------------------------

function terminalIntent(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return intent({
    id: "pi_1Tap",
    customer: null,
    payment_method_types: ["card_present"],
    latest_charge: "ch_1Tap",
    metadata: {
      ...(intent().metadata as Record<string, string>),
      source: "terminal",
      channel: "terminal",
    },
    ...overrides,
  });
}

Deno.test("terminal: a tapped card is recorded card_present with its brand and last4", async () => {
  const { db, stripe, handler } = setup();
  trackAttempt(db, "pi_1Tap", { method: "card_present" });
  stripe.put(terminalIntent()).put(charge({
    id: "ch_1Tap",
    payment_intent: "pi_1Tap",
    payment_method_details: {
      type: "card_present",
      card_present: { brand: "mastercard", last4: "0005", exp_month: 1, exp_year: 2030 },
    },
  }));
  await ok(await deliver(handler, event("payment_intent.succeeded", terminalIntent())));
  const row = payment(db, "pi_1Tap");
  assertEquals(
    [row.status, row.method, row.card_brand, row.card_last4, row.stripe_method_type, row.tip_cents],
    ["succeeded", "card_present", "mastercard", "0005", "card_present", 1_000],
  );
  // Interac (Canada) is in person too
  const interac = setup();
  interac.stripe.put(terminalIntent()).put(charge({
    id: "ch_1Tap",
    payment_intent: "pi_1Tap",
    payment_method_details: {
      type: "interac_present",
      interac_present: { brand: "interac", last4: "1234" },
    },
  }));
  await ok(await deliver(interac.handler, event("payment_intent.succeeded", terminalIntent())));
  assertEquals(payment(interac.db, "pi_1Tap").method, "card_present");
});

Deno.test("terminal: a declined tap stays open (pending), like a declined PaymentSheet", async () => {
  const { db, handler } = setup();
  trackAttempt(db, "pi_1Tap", { method: "card_present" });
  const declined = terminalIntent({
    status: "requires_payment_method",
    amount_received: 0,
    latest_charge: null,
    last_payment_error: { type: "card_error", code: "card_declined" },
  });
  const res = await ok(await deliver(handler, event("payment_intent.payment_failed", declined)));
  assertEquals(res.result, "applied");
  assertEquals(rpcCalls(db, "upsert_stripe_payment")[0]?.p_status, "pending");
  assertEquals(rpcCalls(db, "upsert_stripe_payment")[0]?.p_method, "card_present");
  assertEquals(payment(db, "pi_1Tap").status, "pending");
});

Deno.test("terminal: a reader intent still waiting is cancelled once the invoice is paid elsewhere", async () => {
  const { db, stripe, handler } = setup();
  db.seed("invoices", [{
    id: INVOICE,
    shop_id: SHOP,
    job_id: JOB,
    customer_id: CUSTOMER,
    status: "paid",
    balance_cents: 0,
  }]);
  trackAttempt(db, "pi_1Tap", { method: "card_present" });
  stripe.put(
    terminalIntent({ status: "requires_payment_method", amount_received: 0, latest_charge: null }),
  );
  db.http.on(
    "POST",
    `${STRIPE}/payment_intents/:id/cancel`,
    (_req, { params }) =>
      jsonResponse({ id: params.id, object: "payment_intent", status: "canceled" }),
  );
  stripe.put(intent()).put(charge());
  await ok(await deliver(handler, event("payment_intent.succeeded", intent())));
  assertEquals(db.http.callsTo("POST", `${STRIPE}/payment_intents/pi_1Tap/cancel`).length, 1);
  assertEquals(payment(db, "pi_1Tap").status, "cancelled");
});

// ---------------------------------------------------------------------------
// Weekly memberships (P-23) and merged customers (P-20)
// ---------------------------------------------------------------------------

Deno.test("subscriptions: weekly billing terms are recorded on the membership", async () => {
  const { db, stripe, handler } = setup();
  const weekly = subscription({
    items: {
      object: "list",
      data: [{
        id: "si_1",
        current_period_end: 1_791_600_000,
        quantity: 1,
        price: {
          id: "price_1Weekly",
          unit_amount: 1_500,
          recurring: { interval: "week", interval_count: 2 },
        },
      }],
    },
  });
  stripe.put(weekly);
  await ok(await deliver(handler, event("customer.subscription.updated", weekly)));
  const sync = rpcCalls(db, "sync_stripe_subscription")[0];
  assertEquals(
    [sync?.p_price_id, sync?.p_price_cents, sync?.p_interval, sync?.p_interval_count],
    ["price_1Weekly", 1_500, "week", 2],
  );
});

Deno.test("merged customer: money from a link opened before the merge goes to the survivor", async () => {
  const MERGED = "33333333-3333-4333-8333-333333333333";
  const { db, stripe, logs, handler } = setup({
    tables: {
      customers: [
        { id: CUSTOMER, shop_id: SHOP, stripe_customer_id: "cus_1Customer", merged_into_id: null },
        { id: MERGED, shop_id: SHOP, stripe_customer_id: null, merged_into_id: CUSTOMER },
        { id: OTHER_CUSTOMER, shop_id: OTHER_SHOP, stripe_customer_id: "cus_1Other" },
      ],
    },
  });
  // a deposit link opened for the duplicate; the job moved to the survivor
  const pi = intent({
    metadata: { shop_id: SHOP, job_id: JOB, customer_id: MERGED, kind: "deposit", tip_cents: "0" },
  });
  stripe.put(pi).put(charge());
  const res = await ok(await deliver(handler, event("payment_intent.succeeded", pi)));
  assertEquals(res.result, "applied");
  const row = payment(db);
  assertEquals([row.customer_id, row.job_id, row.note], [CUSTOMER, JOB, null]);
  assertEquals(rpcCalls(db, "upsert_stripe_payment")[0]?.p_customer_id, CUSTOMER);
  assertEquals(logs.events("stripe_payment_merged_customer")[0]?.to_customer, CUSTOMER);
});

Deno.test("customer.deleted: cards a merge moved to another customer go with their Stripe customer", async () => {
  const { db, stripe, handler } = setup();
  // pm_1Merged was saved on the duplicate's Stripe customer, then merged into CUSTOMER
  db.seed("customer_payment_methods", [{
    id: crypto.randomUUID(),
    shop_id: SHOP,
    customer_id: CUSTOMER,
    stripe_payment_method_id: "pm_1Merged",
    stripe_customer_id: "cus_1Duplicate",
    is_default: true,
  }, {
    id: crypto.randomUUID(),
    shop_id: SHOP,
    customer_id: CUSTOMER,
    stripe_payment_method_id: "pm_1Own",
    stripe_customer_id: "cus_1Customer",
    is_default: false,
  }]);
  stripe.put(paymentMethod({ id: "pm_1Merged", customer: null }));
  const res = await ok(
    await deliver(
      handler,
      event("customer.deleted", { id: "cus_1Duplicate", object: "customer", deleted: true }),
    ),
  );
  assertEquals(res.result, "applied");
  assertEquals(
    db.table("customer_payment_methods").map((r) => r.stripe_payment_method_id),
    ["pm_1Own"],
  );
});
