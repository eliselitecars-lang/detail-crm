/**
 * Shared fixture for the payments tests: one shop with a connected account,
 * staff in every role, a customer, a job, an invoice, payments, saved cards,
 * a plan and a membership, plus Stripe stubs on the same FakeFetch.
 * Test-only (never imported by production code).
 */
import type { ErrorBody } from "../_shared/http.ts";
import {
  FakeRpcError,
  FakeSupabase,
  jsonRequest,
  jsonResponse,
  type MemoryLogger,
  memoryLogger,
  preflightRequest,
  type RecordedCall,
  responseJson,
  type Row,
  stripeErrorBody,
} from "../_shared/testing/mod.ts";
import { makeHandler } from "./index.ts";

export const SHOP = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
export const OTHER_SHOP = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
export const CUSTOMER = "cccccccc-cccc-4ccc-8ccc-000000000001";
export const OTHER_CUSTOMER = "cccccccc-cccc-4ccc-8ccc-000000000002";
export const JOB = "dddddddd-dddd-4ddd-8ddd-000000000001";
export const INVOICE = "eeeeeeee-eeee-4eee-8eee-000000000001";
export const OTHER_INVOICE = "eeeeeeee-eeee-4eee-8eee-000000000002";
export const INVOICE_TOKEN = "99999999-9999-4999-8999-000000000001";
export const JOB_TOKEN = "99999999-9999-4999-8999-000000000002";
export const PAYMENT = "ffffffff-ffff-4fff-8fff-000000000001";
export const CASH_PAYMENT = "ffffffff-ffff-4fff-8fff-000000000002";
export const PLAN = "77777777-7777-4777-8777-000000000001";
export const MEMBERSHIP = "88888888-8888-4888-8888-000000000001";
export const ACCT = "acct_1ShopAccount0";
export const STRIPE = "https://api.stripe.com/v1";
export const NOW = Date.UTC(2026, 8, 27, 12, 0, 0);

export const USERS = {
  owner: "10000000-0000-4000-8000-000000000001",
  admin: "10000000-0000-4000-8000-000000000002",
  manager: "10000000-0000-4000-8000-000000000003",
  tech: "10000000-0000-4000-8000-000000000004",
  tech2: "10000000-0000-4000-8000-000000000005",
  outsider: "10000000-0000-4000-8000-000000000006",
} as const;

export const MEMBERS = {
  owner: "20000000-0000-4000-8000-000000000001",
  admin: "20000000-0000-4000-8000-000000000002",
  manager: "20000000-0000-4000-8000-000000000003",
  tech: "20000000-0000-4000-8000-000000000004",
  tech2: "20000000-0000-4000-8000-000000000005",
  outsider: "20000000-0000-4000-8000-000000000006",
} as const;

export type Who = keyof typeof USERS | "anon" | "none";

export interface FixtureOptions {
  env?: Record<string, string | undefined>;
  shop?: Row;
  account?: Row | null;
  customer?: Row;
  invoice?: Row;
  job?: Row;
  plan?: Row;
  membership?: Row;
  cards?: Row[];
  depositDue?: number;
  /** Extra payments rows (e.g. pending PaymentSheet rows). */
  payments?: Row[];
  /** Checkout Sessions on the connected account (GET list / expire). */
  sessions?: Row[];
  /** PaymentIntents GET /payment_intents/:id answers with (by id). */
  intents?: Record<string, Row>;
  /** Subscription statuses GET /subscriptions/:id answers with (default active). */
  subscriptions?: Record<string, string>;
  /** public_get_booking deposit.payment_pending. */
  depositPending?: boolean;
  /** Refunds on the connected account (GET /refunds lists them; POST adds). */
  refunds?: Row[];
  /** Payment methods on the connected account (GET / detach), by id. */
  paymentMethods?: Record<string, Row>;
  /** The handler's clock (default: NOW). Stripe objects created get it too. */
  now?: () => number;
  /** Extra invoice_jobs rows (grouped invoices). */
  invoiceJobs?: Row[];
  /** shop_terminal_locations rows. */
  terminalLocations?: Row[];
  /** quotes rows (quote deposits). */
  quotes?: Row[];
  /** Extra invoices (e.g. a grouped invoice). */
  extraInvoices?: Row[];
  /** Extra jobs. */
  extraJobs?: Row[];
  /** shop_sms_numbers rows (delete_shop releases the self-serve ones). */
  smsNumbers?: Row[];
  /** sms_number_releases rows (the 0093 worklist). */
  smsReleases?: Row[];
  /** job_checkout_holds rows (0106: open Checkout Sessions of a job). */
  holds?: Row[];
  /** invoice_checkout_holds rows (0109: open Checkout Sessions of an invoice). */
  invoiceHolds?: Row[];
  /** public_get_booking cancellation.allowed (default true). */
  cancelAllowed?: boolean;
  /** public_cancel_booking raises this instead of cancelling. */
  cancelError?: FakeRpcError;
}

export interface Fixture {
  db: FakeSupabase;
  logs: MemoryLogger;
  /** The raw handler (for non-JSON requests: preflight, wrong method). */
  handler: (req: Request) => Promise<Response>;
  preflight(origin: string): Promise<Response>;
  rpcCalls: Array<{ name: string; args: Record<string, unknown> }>;
  call(body: Record<string, unknown>, who?: Who): Promise<Response>;
  stripe(method: string, path: string): RecordedCall[];
  stripeCalls(): RecordedCall[];
  /** The fake Stripe state (mutated by expire / cancel calls). */
  sessions: Row[];
  intents: Record<string, Row>;
  /** Checkout Sessions created through POST (GET /checkout/sessions/:id reads them). */
  created: Record<string, Row>;
  refunds: Row[];
  paymentMethods: Record<string, Row>;
}

function member(key: keyof typeof USERS, shopId: string, role: string): Row {
  return {
    id: MEMBERS[key],
    shop_id: shopId,
    user_id: USERS[key],
    role,
    display_name: key,
    active: true,
  };
}

export function fixture(options: FixtureOptions = {}): Fixture {
  const rpcCalls: Fixture["rpcCalls"] = [];
  const record = (name: string, args: Record<string, unknown>) => rpcCalls.push({ name, args });
  const depositDue = options.depositDue ?? 5_000;
  const invoices: Row[] = [
    ...(options.extraInvoices ?? []),
    {
      id: INVOICE,
      shop_id: SHOP,
      number: 2001,
      job_id: JOB,
      customer_id: CUSTOMER,
      status: "partially_paid",
      balance_cents: 12_345,
      public_token: INVOICE_TOKEN,
      ...options.invoice,
    },
    {
      id: OTHER_INVOICE,
      shop_id: OTHER_SHOP,
      number: 1,
      job_id: null,
      customer_id: OTHER_CUSTOMER,
      status: "open",
      balance_cents: 5_000,
      public_token: "99999999-9999-4999-8999-000000000009",
    },
  ];
  // 0063: every single-job invoice has its invoice_jobs row (voided with it).
  const invoiceJobs: Row[] = invoices.filter((i) => i.job_id).map((i, n) => ({
    id: `31000000-0000-4000-8000-00000000000${n + 1}`,
    shop_id: i.shop_id,
    invoice_id: i.id,
    job_id: i.job_id,
    voided: i.status === "void",
  }));

  const db = new FakeSupabase({
    env: { PLATFORM_FEE_BPS: "250", ...options.env },
    users: {
      "tok-owner": { id: USERS.owner, email: "owner@example.com" },
      "tok-admin": { id: USERS.admin, email: "admin@example.com" },
      "tok-manager": { id: USERS.manager, email: "manager@example.com" },
      "tok-tech": { id: USERS.tech, email: "tech@example.com" },
      "tok-tech2": { id: USERS.tech2, email: "tech2@example.com" },
      "tok-outsider": { id: USERS.outsider, email: "outsider@example.com" },
      "tok-anon": { id: "10000000-0000-4000-8000-000000000099", is_anonymous: true },
    },
    tables: {
      shop_members: [
        member("owner", SHOP, "owner"),
        member("admin", SHOP, "admin"),
        member("manager", SHOP, "manager"),
        member("tech", SHOP, "technician"),
        member("tech2", SHOP, "technician"),
        member("outsider", OTHER_SHOP, "owner"),
      ],
      shops: [
        {
          id: SHOP,
          name: "Shine Co",
          slug: "shine-co",
          currency: "usd",
          techs_can_collect_payments: true,
          ...options.shop,
        },
        {
          id: OTHER_SHOP,
          name: "Other",
          slug: "other",
          currency: "usd",
          techs_can_collect_payments: true,
        },
      ],
      shop_stripe_accounts: options.account === null ? [] : [{
        shop_id: SHOP,
        stripe_account_id: ACCT,
        charges_enabled: true,
        ...options.account,
      }],
      customers: [
        {
          id: CUSTOMER,
          shop_id: SHOP,
          first_name: "Ada",
          last_name: "Lovelace",
          company: null,
          email: "ada@example.com",
          phone: "+12055550123",
          stripe_customer_id: null,
          archived_at: null,
          portal_user_id: null,
          ...options.customer,
        },
        {
          id: OTHER_CUSTOMER,
          shop_id: OTHER_SHOP,
          first_name: "Other",
          last_name: null,
          company: null,
          email: null,
          phone: null,
          stripe_customer_id: null,
          archived_at: null,
        },
      ],
      jobs: [{
        id: JOB,
        shop_id: SHOP,
        number: 1001,
        customer_id: CUSTOMER,
        status: "scheduled",
        public_token: JOB_TOKEN,
        ...options.job,
      }, ...(options.extraJobs ?? [])],
      job_assignments: [{
        id: "30000000-0000-4000-8000-000000000001",
        shop_id: SHOP,
        job_id: JOB,
        member_id: MEMBERS.tech,
      }],
      invoices,
      invoice_jobs: [...invoiceJobs, ...(options.invoiceJobs ?? [])],
      shop_terminal_locations: options.terminalLocations ?? [],
      gift_card_orders: [],
      // 0100: the shop's platform subscription (delete_shop cancels it)
      shop_billing: [],
      // 0089 / 0093: text numbers (delete_shop releases self-serve ones)
      shop_sms_numbers: options.smsNumbers ?? [],
      sms_number_releases: options.smsReleases ?? [],
      quotes: options.quotes ?? [],
      job_checkout_holds: options.holds ?? [],
      invoice_checkout_holds: options.invoiceHolds ?? [],
      payments: [
        {
          id: PAYMENT,
          shop_id: SHOP,
          invoice_id: INVOICE,
          method: "card",
          status: "succeeded",
          amount_cents: 10_000,
          tip_cents: 500,
          refunded_cents: 0,
          stripe_payment_intent_id: "pi_1Paid",
        },
        {
          id: CASH_PAYMENT,
          shop_id: SHOP,
          invoice_id: INVOICE,
          method: "cash",
          status: "succeeded",
          amount_cents: 2_000,
          tip_cents: 0,
          refunded_cents: 0,
          stripe_payment_intent_id: null,
        },
        ...(options.payments ?? []),
      ],
      customer_payment_methods: options.cards ?? [
        {
          id: "40000000-0000-4000-8000-000000000001",
          shop_id: SHOP,
          customer_id: CUSTOMER,
          stripe_payment_method_id: "pm_1Default",
          brand: "visa",
          last4: "4242",
          is_default: true,
        },
        {
          id: "40000000-0000-4000-8000-000000000002",
          shop_id: SHOP,
          customer_id: CUSTOMER,
          stripe_payment_method_id: "pm_1Other",
          brand: "mastercard",
          last4: "5555",
          is_default: false,
        },
        {
          id: "40000000-0000-4000-8000-000000000003",
          shop_id: OTHER_SHOP,
          customer_id: OTHER_CUSTOMER,
          stripe_payment_method_id: "pm_1Foreign",
          brand: "visa",
          last4: "1111",
          is_default: true,
        },
      ],
      membership_plans: [{
        id: PLAN,
        shop_id: SHOP,
        name: "Monthly Wash",
        description: "Two washes a month",
        price_cents: 4_900,
        interval: "month",
        interval_count: 1,
        active: true,
        archived_at: null,
        stripe_product_id: null,
        stripe_price_id: null,
        ...options.plan,
      }],
      memberships: [{
        id: MEMBERSHIP,
        shop_id: SHOP,
        plan_id: PLAN,
        customer_id: CUSTOMER,
        vehicle_id: null,
        status: "incomplete",
        stripe_subscription_id: null,
        cancel_at_period_end: false,
        current_period_end: null,
        ...options.membership,
      }],
    },
    rpc: {
      upsert_stripe_payment: (args) => {
        record("upsert_stripe_payment", args);
        return { id: "50000000-0000-4000-8000-000000000001", status: args.p_status };
      },
      apply_stripe_refund: (args) => {
        record("apply_stripe_refund", args);
        const total = Number(args.p_refunded_cents_total);
        return { id: PAYMENT, status: total >= 10_500 ? "refunded" : "partially_refunded" };
      },
      public_get_booking: (args) => {
        record("public_get_booking", args);
        // 0042: a public RPC's not-found is PT404 (HTTP 404)
        if (args.p_token !== JOB_TOKEN) {
          throw new FakeRpcError("PT404", "booking not found", { status: 404 });
        }
        return {
          deposit: {
            required_cents: 5_000,
            due_cents: depositDue,
            payment_pending: options.depositPending ?? false,
          },
          cancellation: { allowed: options.cancelAllowed ?? true },
        };
      },
      // 0106: record an open Checkout Session of a job (service role).
      payments_hold_job_checkout: (args, ctx) => {
        record("payments_hold_job_checkout", args);
        const job = ctx.db.table("jobs").find((j) =>
          j.id === args.p_job_id && j.shop_id === args.p_shop_id
        );
        if (!job) throw new FakeRpcError("P0002", "job not found", { status: 404 });
        if (["cancelled", "no_show", "completed"].includes(String(job.status))) {
          throw new FakeRpcError("55000", "this booking is no longer taking payments", {
            hint: "booking_closed",
          });
        }
        const holds = ctx.db.table("job_checkout_holds")
          .filter((h) => h.stripe_checkout_session_id !== args.p_session_id);
        holds.push({
          stripe_checkout_session_id: args.p_session_id,
          shop_id: args.p_shop_id,
          job_id: args.p_job_id,
          expires_at: args.p_expires_at,
        });
        ctx.db.seed("job_checkout_holds", holds);
        return undefined;
      },
      payments_release_job_checkouts: (args, ctx) => {
        record("payments_release_job_checkouts", args);
        const ids = args.p_session_ids as string[] | null;
        const rows = ctx.db.table("job_checkout_holds");
        const kept = rows.filter((h) =>
          !(h.shop_id === args.p_shop_id && h.job_id === args.p_job_id &&
            (ids === null || ids.includes(String(h.stripe_checkout_session_id))))
        );
        ctx.db.seed("job_checkout_holds", kept);
        // 0109 body: the sessions' invoice holds go too
        if (ids !== null) {
          ctx.db.seed(
            "invoice_checkout_holds",
            ctx.db.table("invoice_checkout_holds").filter((h) =>
              !(h.shop_id === args.p_shop_id && ids.includes(String(h.stripe_checkout_session_id)))
            ),
          );
        }
        return rows.length - kept.length;
      },
      // 0109: hold an invoice pay link (service role) under the invoice lock.
      payments_hold_invoice_checkout: (args, ctx) => {
        record("payments_hold_invoice_checkout", args);
        const invoice = ctx.db.table("invoices").find((i) =>
          i.id === args.p_invoice_id && i.shop_id === args.p_shop_id
        );
        if (!invoice) throw new FakeRpcError("P0002", "invoice not found", { status: 404 });
        const due = Number(invoice.balance_cents ?? 0);
        if (!["open", "partially_paid"].includes(String(invoice.status)) || due <= 0) {
          throw new FakeRpcError("55000", "this invoice is no longer taking this payment", {
            hint: "invoice_closed",
          });
        }
        if (
          args.p_amount_cents !== undefined && args.p_amount_cents !== null &&
          Number(args.p_amount_cents) > due
        ) {
          throw new FakeRpcError(
            "55000",
            "this invoice's balance changed; reload it and try again",
            {
              hint: "balance_changed",
            },
          );
        }
        // invoice_bills_only_cancelled_jobs: every billed job cancelled
        const billed = ctx.db.table("invoice_jobs")
          .filter((ij) => ij.invoice_id === invoice.id && !ij.voided)
          .map((ij) => ctx.db.table("jobs").find((j) => j.id === ij.job_id));
        if (billed.length > 0 && billed.every((j) => j?.status === "cancelled")) {
          throw new FakeRpcError("55000", "the appointment on this invoice was cancelled", {
            hint: "booking_cancelled",
          });
        }
        const holds = ctx.db.table("invoice_checkout_holds")
          .filter((h) => h.stripe_checkout_session_id !== args.p_session_id);
        holds.push({
          stripe_checkout_session_id: args.p_session_id,
          shop_id: args.p_shop_id,
          invoice_id: args.p_invoice_id,
          expires_at: args.p_expires_at,
        });
        ctx.db.seed("invoice_checkout_holds", holds);
        return undefined;
      },
      payments_release_invoice_checkouts: (args, ctx) => {
        record("payments_release_invoice_checkouts", args);
        const ids = args.p_session_ids as string[] | null;
        const rows = ctx.db.table("invoice_checkout_holds");
        const kept = rows.filter((h) =>
          !(h.shop_id === args.p_shop_id && h.invoice_id === args.p_invoice_id &&
            (ids === null || ids.includes(String(h.stripe_checkout_session_id))))
        );
        ctx.db.seed("invoice_checkout_holds", kept);
        return rows.length - kept.length;
      },
      // 0106 body: refuses while a hold of the job is live, else cancels.
      public_cancel_booking: (args, ctx) => {
        record("public_cancel_booking", { ...args, role: ctx.role, user_id: ctx.userId });
        if (options.cancelError) throw options.cancelError;
        const jobs = ctx.db.table("jobs");
        const job = jobs.find((j) => j.public_token === args.p_token);
        if (!job) throw new FakeRpcError("PT404", "booking not found", { status: 404 });
        const now = new Date(NOW).toISOString();
        if (
          ctx.db.table("job_checkout_holds").some((h) =>
            h.job_id === job.id && String(h.expires_at) > now
          )
        ) {
          throw new FakeRpcError(
            "55000",
            "a payment page for this booking is still open; please close it and try again in a few minutes, or call the shop",
            { hint: "checkout_open" },
          );
        }
        ctx.db.seed("jobs", jobs.map((j) => j.id === job.id ? { ...j, status: "cancelled" } : j));
        return { booking: { number: job.number, status: "cancelled" } };
      },
      sync_stripe_subscription: (args) => {
        record("sync_stripe_subscription", args);
        return { status: args.p_status, cancel_at_period_end: args.p_cancel_at_period_end };
      },
      // 0011: deletes the saved card (service role); false when not saved.
      remove_customer_payment_method: (args, ctx) => {
        record("remove_customer_payment_method", args);
        const rows = ctx.db.table("customer_payment_methods");
        const kept = rows.filter((r) =>
          !(r.shop_id === args.p_shop_id &&
            r.stripe_payment_method_id === args.p_stripe_payment_method_id)
        );
        ctx.db.seed("customer_payment_methods", kept);
        return kept.length !== rows.length;
      },
    },
  });

  const sessions = options.sessions ?? [];
  const intents = options.intents ?? {};
  const created: Record<string, Row> = {};
  const refunds = options.refunds ?? [];
  const paymentMethods = options.paymentMethods ?? {};
  const now = options.now ?? (() => NOW);
  installStripe(
    db,
    { sessions, intents, created, refunds, paymentMethods, now },
    options.subscriptions ?? {},
  );

  const logs = memoryLogger();
  const handler = makeHandler({
    env: db.env(),
    fetch: db.http.fetch,
    logger: logs.logger,
    now,
  });
  const tokens: Record<Who, string | undefined> = {
    owner: "tok-owner",
    admin: "tok-admin",
    manager: "tok-manager",
    tech: "tok-tech",
    tech2: "tok-tech2",
    outsider: "tok-outsider",
    anon: "tok-anon",
    none: undefined,
  };
  return {
    db,
    logs,
    handler,
    preflight: (origin) => handler(preflightRequest("payments", origin)),
    rpcCalls,
    call: (body, who = "none") => {
      const token = tokens[who];
      return handler(jsonRequest("payments", body, token ? { token } : {}));
    },
    stripe: (method, path) => db.http.callsTo(method, `${STRIPE}${path}`),
    stripeCalls: () => db.http.calls.filter((c) => c.url.hostname === "api.stripe.com"),
    sessions,
    intents,
    created,
    refunds,
    paymentMethods,
  };
}

/** `metadata[key]=value` form fields as an object. */
function formMetadata(form: URLSearchParams): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [key, value] of form) {
    const m = /^metadata\[([^\]]+)\]$/.exec(key);
    if (m?.[1]) out[m[1]] = value;
  }
  return out;
}

interface StripeState {
  sessions: Row[];
  intents: Record<string, Row>;
  created: Record<string, Row>;
  refunds: Row[];
  paymentMethods: Record<string, Row>;
  now: () => number;
}

function installStripe(
  db: FakeSupabase,
  { sessions, intents, created, refunds, paymentMethods, now }: StripeState,
  subscriptions: Record<string, string>,
): void {
  const http = db.http;
  const noSuchPaymentMethod = (id: string | undefined) =>
    jsonResponse(
      stripeErrorBody("invalid_request_error", `No such PaymentMethod: '${id}'`, {
        code: "resource_missing",
        param: "id",
      }),
      404,
    );
  http.on("GET", `${STRIPE}/payment_methods/:id`, (_req, { params }) => {
    const pm = paymentMethods[params.id ?? ""];
    return pm
      ? jsonResponse({ id: params.id, object: "payment_method", type: "card", ...pm })
      : noSuchPaymentMethod(params.id);
  });
  http.on("POST", `${STRIPE}/payment_methods/:id/detach`, (_req, { params }) => {
    const pm = paymentMethods[params.id ?? ""];
    if (!pm) return noSuchPaymentMethod(params.id);
    if (!pm.customer) {
      return jsonResponse(
        stripeErrorBody(
          "invalid_request_error",
          "The payment method you provided is not attached to a customer so detachment is impossible.",
        ),
        400,
      );
    }
    pm.customer = null;
    return jsonResponse({ id: params.id, object: "payment_method", type: "card", ...pm });
  });
  http.on("GET", `${STRIPE}/checkout/sessions/:id`, (_req, { params }) => {
    const found = sessions.find((x) => x.id === params.id) ?? created[params.id ?? ""];
    return found
      ? jsonResponse({ object: "checkout.session", ...found })
      : jsonResponse(stripeErrorBody("invalid_request_error", "No such checkout.session"), 404);
  });
  http.on("GET", `${STRIPE}/checkout/sessions`, (_req, { url }) => {
    const status = url.searchParams.get("status");
    const customer = url.searchParams.get("customer");
    return jsonResponse({
      object: "list",
      has_more: false,
      data: sessions.filter((x) =>
        (!status || x.status === status) && (!customer || x.customer === customer)
      ),
    });
  });
  http.on("POST", `${STRIPE}/checkout/sessions/:id/expire`, (_req, { params }) => {
    const found = sessions.find((x) => x.id === params.id) ?? created[params.id ?? ""];
    if (!found || found.status !== "open") {
      return jsonResponse(
        stripeErrorBody("invalid_request_error", "Only open sessions can be expired."),
        400,
      );
    }
    found.status = "expired";
    return jsonResponse({ ...found, object: "checkout.session", url: null });
  });
  http.on("POST", `${STRIPE}/payment_intents/:id/cancel`, (_req, { params }) => {
    const found = intents[params.id ?? ""];
    if (
      !found ||
      !["requires_payment_method", "requires_confirmation", "requires_action"].includes(
        String(found.status),
      )
    ) {
      return jsonResponse(
        stripeErrorBody("invalid_request_error", "You cannot cancel this PaymentIntent."),
        400,
      );
    }
    found.status = "canceled";
    return jsonResponse({ id: params.id, object: "payment_intent", ...found });
  });
  // Subscriptions changed through POST / DELETE: GET answers their current
  // state (Stripe's), while a POST replays the first response stored under
  // its idempotency key without applying the change again.
  const subscriptionState = new Map<string, Row>();
  const subscriptionReplays = new Map<string, Row>();
  http.on(
    "GET",
    `${STRIPE}/subscriptions/:id`,
    (_req, { params }) => {
      const current = subscriptionState.get(params.id ?? "");
      if (current) return jsonResponse({ ...current });
      return jsonResponse({
        id: params.id,
        object: "subscription",
        status: subscriptions[params.id ?? ""] ?? "active",
        cancel_at_period_end: false,
        items: { object: "list", data: [] },
      });
    },
  );
  http.on(
    "GET",
    `${STRIPE}/customers/:id`,
    (_req, { params }) => jsonResponse({ id: params.id, object: "customer" }),
  );
  http.on(
    "POST",
    `${STRIPE}/customers`,
    () => jsonResponse({ id: "cus_1New", object: "customer" }),
  );
  http.on("POST", `${STRIPE}/checkout/sessions`, (_req, { call }) => {
    const session = {
      id: "cs_test_1",
      object: "checkout.session",
      status: "open",
      mode: call.form.get("mode"),
      customer: call.form.get("customer"),
      metadata: formMetadata(call.form),
      url: "https://checkout.stripe.com/c/pay/cs_test_1",
      expires_at: 1_900_000_000,
    };
    created[session.id] ??= session;
    return jsonResponse(session);
  });
  http.on("POST", `${STRIPE}/payment_intents`, (_req, { call }) => {
    const confirmed = call.form.get("confirm") === "true";
    const intent = {
      id: "pi_1New",
      object: "payment_intent",
      amount: Number(call.form.get("amount")),
      status: confirmed ? "succeeded" : "requires_payment_method",
      client_secret: "pi_1New_secret_abc",
      latest_charge: confirmed ? "ch_1New" : null,
      metadata: formMetadata(call.form),
    };
    intents[intent.id] ??= intent;
    return jsonResponse(intent);
  });
  http.on("POST", `${STRIPE}/ephemeral_keys`, () =>
    jsonResponse({
      id: "ephkey_1",
      object: "ephemeral_key",
      secret: "ek_test_secret",
      created: 1,
      expires: 2,
      livemode: false,
    }));
  http.on(
    "POST",
    `${STRIPE}/setup_intents`,
    () =>
      jsonResponse({ id: "seti_1", object: "setup_intent", client_secret: "seti_1_secret_abc" }),
  );
  http.on(
    "GET",
    `${STRIPE}/payment_intents/:id`,
    (_req, { params }) =>
      intents[params.id ?? ""]
        ? jsonResponse({ id: params.id, object: "payment_intent", ...intents[params.id ?? ""] })
        : jsonResponse({
          id: params.id,
          object: "payment_intent",
          status: "succeeded",
          latest_charge: {
            id: "ch_1Paid",
            object: "charge",
            amount: 10_500,
            amount_refunded: 0,
            application_fee_amount: null,
          },
        }),
  );
  http.on("GET", `${STRIPE}/refunds`, (_req, { url }) => {
    const charge = url.searchParams.get("charge");
    return jsonResponse({
      object: "list",
      has_more: false,
      data: refunds.filter((r) => !charge || !r.charge || r.charge === charge),
    });
  });
  // Stripe's idempotency layer: the first response under a key is replayed.
  const replays = new Map<string, Row>();
  http.on("POST", `${STRIPE}/refunds`, (_req, { call }) => {
    const key = call.headers.get("idempotency-key") ?? "";
    const replay = replays.get(key);
    if (replay) return jsonResponse(replay);
    const refund = {
      id: `re_${refunds.length + 1}`,
      object: "refund",
      status: "succeeded",
      amount: Number(call.form.get("amount")),
      created: Math.floor(now() / 1000),
      payment_intent: call.form.get("payment_intent"),
      metadata: formMetadata(call.form),
    };
    refunds.push({ ...refund });
    if (key) replays.set(key, { ...refund });
    return jsonResponse(refund);
  });
  http.on("GET", `${STRIPE}/prices/:id`, (_req, { params }) =>
    jsonResponse({
      id: params.id,
      object: "price",
      active: true,
      currency: "usd",
      unit_amount: 4_900,
      recurring: { interval: "month", interval_count: 1 },
    }));
  http.on("POST", `${STRIPE}/prices`, () => jsonResponse({ id: "price_1New", object: "price" }));
  http.on(
    "GET",
    `${STRIPE}/products/:id`,
    (_req, { params }) => jsonResponse({ id: params.id, object: "product" }),
  );
  http.on("POST", `${STRIPE}/products`, () => jsonResponse({ id: "prod_1New", object: "product" }));
  const subscription = (id: string, status: string, atPeriodEnd: boolean): Row => {
    const row = {
      id,
      object: "subscription",
      status,
      cancel_at_period_end: atPeriodEnd,
      items: { object: "list", data: [{ id: "si_1", current_period_end: 1_900_000_000 }] },
    };
    subscriptionState.set(id, row);
    return { ...row };
  };
  http.on(
    "POST",
    `${STRIPE}/subscriptions/:id`,
    (_req, { params, call }) => {
      const key = call.headers.get("idempotency-key") ?? "";
      const replay = subscriptionReplays.get(key);
      if (replay) return jsonResponse({ ...replay });
      const row = subscription(
        params.id ?? "",
        "active",
        call.form.get("cancel_at_period_end") === "true",
      );
      if (key) subscriptionReplays.set(key, row);
      return jsonResponse(row);
    },
  );
  http.on(
    "DELETE",
    `${STRIPE}/subscriptions/:id`,
    (_req, { params }) => jsonResponse(subscription(params.id ?? "", "canceled", false)),
  );
}

/** Status + error code of a response (consumes the body). */
export async function errorOf(res: Response): Promise<[number, string, unknown]> {
  const body = await responseJson<ErrorBody>(res);
  return [res.status, body.code, body.details];
}
