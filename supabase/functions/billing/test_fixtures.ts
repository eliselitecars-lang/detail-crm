/**
 * Test fixture for `billing` and `billing-webhook`: one shop with staff in
 * every role, the billing RPCs of migration 0101 faked with the contract's
 * rules (docs/BILLING.md; the SQL suite tests the real functions), and a fake
 * PLATFORM Stripe account (customers, Checkout, Customer Portal, the plan
 * catalog, subscriptions) on the same FakeFetch. Test-only.
 */
import { assertEquals } from "@std/assert";
import {
  FakeRpcError,
  FakeSupabase,
  jsonRequest,
  jsonResponse,
  type MemoryLogger,
  memoryLogger,
  type RecordedCall,
  type Row,
  stripeErrorBody,
} from "../_shared/testing/mod.ts";
import { makeHandler } from "./index.ts";

export const SHOP = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
export const OTHER_SHOP = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
export const STRIPE = "https://api.stripe.com/v1";
/** 2026-09-28T12:00:00Z */
export const NOW = Date.UTC(2026, 8, 28, 12, 0, 0);
export const HOUR = 60 * 60 * 1000;

export const USERS = {
  owner: "10000000-0000-4000-8000-000000000001",
  admin: "10000000-0000-4000-8000-000000000002",
  manager: "10000000-0000-4000-8000-000000000003",
  tech: "10000000-0000-4000-8000-000000000004",
  outsider: "10000000-0000-4000-8000-000000000005",
  inactiveOwner: "10000000-0000-4000-8000-000000000006",
} as const;

export type Who = keyof typeof USERS | "anon" | "none";

export const PLAN_MONTHLY = "77777777-7777-4777-8777-000000000001";
export const PLAN_YEARLY = "77777777-7777-4777-8777-000000000002";
export const PLAN_RETIRED = "77777777-7777-4777-8777-000000000003";

/** One shop_billing row (0100), keyed by shop. */
export interface BillingRow {
  shop_id: string;
  stripe_customer_id: string | null;
  stripe_subscription_id: string | null;
  plan_id: string | null;
  status: string;
  trial_ends_at: string | null;
  trial_used: boolean;
  current_period_end: string | null;
  cancel_at_period_end: boolean;
  comp_until: string | null;
  last_event_at: string | null;
}

export function billingRow(shopId: string, overrides: Partial<BillingRow> = {}): BillingRow {
  return {
    shop_id: shopId,
    stripe_customer_id: null,
    stripe_subscription_id: null,
    plan_id: null,
    status: "none",
    trial_ends_at: null,
    trial_used: false,
    current_period_end: null,
    cancel_at_period_end: false,
    comp_until: null,
    last_event_at: null,
    ...overrides,
  };
}

export function planRow(overrides: Row = {}): Row {
  return {
    id: PLAN_MONTHLY,
    stripe_price_id: "price_1Monthly",
    stripe_product_id: "prod_1Studio",
    name: "Studio",
    description: "For one location",
    amount_cents: 4_900,
    currency: "usd",
    interval: "month",
    interval_count: 1,
    max_members: 5,
    features: ["online_booking"],
    sort: 1,
    active: true,
    ...overrides,
  };
}

// ---------------------------------------------------------------------------
// Fake platform Stripe account
// ---------------------------------------------------------------------------

export interface CatalogProduct {
  id: string;
  name: string;
  description?: string | null;
  active?: boolean;
  metadata?: Record<string, string>;
}

export interface CatalogPrice {
  id: string;
  product: string;
  active?: boolean;
  type?: "recurring" | "one_time";
  unit_amount?: number | null;
  currency?: string;
  billing_scheme?: "per_unit" | "tiered";
  recurring?: Record<string, unknown> | null;
}

export function recurringPrice(
  id: string,
  product: string,
  unitAmount: number,
  interval: "day" | "week" | "month" | "year" = "month",
  overrides: Partial<CatalogPrice> = {},
): CatalogPrice {
  return {
    id,
    product,
    active: true,
    type: "recurring",
    unit_amount: unitAmount,
    currency: "usd",
    billing_scheme: "per_unit",
    recurring: { interval, interval_count: 1, usage_type: "licensed", meter: null },
    ...overrides,
  };
}

/**
 * The platform account's catalog (products + prices lists, paginated like
 * Stripe), subscriptions by id, and the Customer / Checkout / Portal
 * endpoints. Stripe-Account headers are recorded (platform calls send none).
 */
export class FakePlatformStripe {
  products: CatalogProduct[] = [];
  prices: CatalogPrice[] = [];
  readonly subscriptions = new Map<string, Row>();
  /** Checkout Sessions created (or seeded), in creation order. */
  readonly sessions: Row[] = [];
  /** Invoices (GET /invoices filters by subscription and status). */
  invoices: Row[] = [];
  /** Invoice payments (GET /invoice_payments filters by invoice). */
  invoicePayments: Row[] = [];
  /** Refunds created (POST /refunds), with the form's target and reason. */
  readonly refunds: Row[] = [];
  /** Page size of list answers (tests pagination). */
  pageSize = 100;
  /** When set, POST /billing_portal/sessions answers this Stripe error. */
  portalError: { status: number; body: Record<string, unknown> } | null = null;
  /** When set, GET /products answers this error (a Stripe outage mid-sync). */
  listError: { status: number; body: Record<string, unknown> } | null = null;
  customersCreated = 0;
  /** Platform customers by id (created through POST /customers, or seeded). */
  readonly customers = new Map<string, Row>();

  putCustomer(customer: Row): Row {
    const row: Row = { object: "customer", email: null, name: null, metadata: {}, ...customer };
    this.customers.set(row.id as string, row);
    return row;
  }

  putSubscription(sub: Row): this {
    this.subscriptions.set(sub.id as string, sub);
    return this;
  }

  /** A Checkout Session as Stripe stores it (open, subscription mode). */
  putSession(session: Row): Row {
    const row = {
      object: "checkout.session",
      mode: "subscription",
      status: "open",
      created: Math.floor(NOW / 1000) - 3600,
      url: `https://checkout.stripe.com/c/pay/${session.id}`,
      ...session,
    };
    this.sessions.push(row);
    return row;
  }

  install(db: FakeSupabase): void {
    const http = db.http;
    const page = <T extends { id: string }>(items: T[], url: URL, path: string) => {
      const after = url.searchParams.get("starting_after");
      const start = after ? items.findIndex((i) => i.id === after) + 1 : 0;
      const limit = Math.min(Number(url.searchParams.get("limit") ?? 10), this.pageSize);
      const data = items.slice(start, start + limit);
      return jsonResponse({
        object: "list",
        url: path,
        has_more: start + limit < items.length,
        data,
      });
    };
    http.on("GET", `${STRIPE}/products`, (_req, { url }) => {
      if (this.listError) return jsonResponse(this.listError.body, this.listError.status);
      const active = url.searchParams.get("active");
      const items = this.products
        .map((p) => ({
          object: "product",
          active: true,
          description: null,
          metadata: {},
          ...p,
        }))
        .filter((p) => active === null || String(p.active) === active);
      return page(items, url, "/v1/products");
    });
    http.on("GET", `${STRIPE}/prices`, (_req, { url }) => {
      const product = url.searchParams.get("product");
      const active = url.searchParams.get("active");
      const type = url.searchParams.get("type");
      const items = this.prices
        .map((p) => ({ object: "price", active: true, type: "recurring", ...p }))
        .filter((p) =>
          (product === null || p.product === product) &&
          (active === null || String(p.active) === active) &&
          (type === null || p.type === type)
        );
      return page(items, url, "/v1/prices");
    });
    http.on("GET", `${STRIPE}/subscriptions/:id`, (_req, { params }) => {
      const sub = this.subscriptions.get(params.id ?? "");
      if (!sub) {
        return jsonResponse(
          stripeErrorBody("invalid_request_error", "No such subscription", {
            code: "resource_missing",
          }),
          404,
        );
      }
      return jsonResponse(sub);
    });
    const metadataOf = (form: URLSearchParams) => {
      const metadata: Record<string, string> = {};
      for (const [key, value] of form) {
        const m = /^metadata\[([^\]]+)\]$/.exec(key);
        if (m?.[1]) metadata[m[1]] = value;
      }
      return metadata;
    };
    const noSuchCustomer = () =>
      jsonResponse(
        stripeErrorBody("invalid_request_error", "No such customer", { code: "resource_missing" }),
        404,
      );
    http.on("POST", `${STRIPE}/customers`, (_req, { call }) => {
      this.customersCreated++;
      return jsonResponse(this.putCustomer({
        id: "cus_1NewShop",
        email: call.form.get("email"),
        name: call.form.get("name"),
        metadata: metadataOf(call.form),
      }));
    });
    http.on(
      "GET",
      `${STRIPE}/customers`,
      (_req, { url }) =>
        page([...this.customers.values()] as Array<Row & { id: string }>, url, "/v1/customers"),
    );
    http.on("GET", `${STRIPE}/customers/:id`, (_req, { params }) => {
      const found = this.customers.get(params.id ?? "");
      return found ? jsonResponse(found) : noSuchCustomer();
    });
    http.on("POST", `${STRIPE}/customers/:id`, (_req, { params, call }) => {
      const found = this.customers.get(params.id ?? "");
      if (!found) return noSuchCustomer();
      const email = call.form.get("email");
      if (email !== null) found.email = email;
      found.metadata = { ...(found.metadata as Row), ...metadataOf(call.form) };
      return jsonResponse(found);
    });
    http.on("GET", `${STRIPE}/subscriptions`, (_req, { url }) => {
      const customer = url.searchParams.get("customer");
      const status = url.searchParams.get("status");
      const items = [...this.subscriptions.values()].filter((sub) =>
        (customer === null || sub.customer === customer) &&
        (status === "all" ||
          (status === null ? sub.status !== "canceled" : sub.status === status))
      );
      return page(items as Array<Row & { id: string }>, url, "/v1/subscriptions");
    });
    http.on("DELETE", `${STRIPE}/subscriptions/:id`, (_req, { params }) => {
      const sub = this.subscriptions.get(params.id ?? "");
      if (!sub) {
        return jsonResponse(
          stripeErrorBody("invalid_request_error", "No such subscription", {
            code: "resource_missing",
          }),
          404,
        );
      }
      if (sub.status === "canceled") {
        return jsonResponse(
          stripeErrorBody("invalid_request_error", "This subscription is already canceled."),
          400,
        );
      }
      sub.status = "canceled";
      return jsonResponse(sub);
    });
    http.on("GET", `${STRIPE}/invoices`, (_req, { url }) => {
      const sub = url.searchParams.get("subscription");
      const status = url.searchParams.get("status");
      const items = this.invoices.filter((inv) =>
        (sub === null || inv.subscription === sub) && (status === null || inv.status === status)
      );
      return page(items as Array<Row & { id: string }>, url, "/v1/invoices");
    });
    http.on("GET", `${STRIPE}/invoice_payments`, (_req, { url }) => {
      const invoice = url.searchParams.get("invoice");
      const items = this.invoicePayments.filter((p) => p.invoice === invoice);
      return page(items as Array<Row & { id: string }>, url, "/v1/invoice_payments");
    });
    http.on("POST", `${STRIPE}/refunds`, (_req, { call }) => {
      const target = call.form.get("payment_intent") ?? call.form.get("charge");
      const payment = this.invoicePayments.find((p) => {
        const pay = p.payment as Row | undefined;
        return pay?.payment_intent === target || pay?.charge === target;
      });
      const refund = {
        id: `re_${this.refunds.length + 1}Dup`,
        object: "refund",
        amount: (payment?.amount_paid as number | undefined) ?? 0,
        status: "succeeded",
        payment_intent: call.form.get("payment_intent"),
        charge: call.form.get("charge"),
        reason: call.form.get("reason"),
        idempotency_key: call.headers.get("idempotency-key"),
      };
      this.refunds.push(refund);
      return jsonResponse(refund);
    });
    http.on("POST", `${STRIPE}/checkout/sessions`, (_req, { call }) => {
      const n = this.sessions.length + 1;
      const metadata: Record<string, string> = {};
      for (const [key, value] of call.form) {
        const m = /^metadata\[([^\]]+)\]$/.exec(key);
        if (m?.[1]) metadata[m[1]] = value;
      }
      return jsonResponse(this.putSession({
        id: `cs_test_${n}Billing`,
        customer: call.form.get("customer"),
        metadata,
        created: Math.floor(NOW / 1000) + n,
        expires_at: Number(call.form.get("expires_at")),
      }));
    });
    http.on("GET", `${STRIPE}/checkout/sessions`, (_req, { url }) => {
      const customer = url.searchParams.get("customer");
      const status = url.searchParams.get("status");
      const items = this.sessions.filter((x) =>
        (customer === null || x.customer === customer) && (status === null || x.status === status)
      );
      return page(items as Array<Row & { id: string }>, url, "/v1/checkout/sessions");
    });
    http.on("GET", `${STRIPE}/checkout/sessions/:id`, (_req, { params }) => {
      const found = this.sessions.find((x) => x.id === params.id);
      return found
        ? jsonResponse(found)
        : jsonResponse(stripeErrorBody("invalid_request_error", "No such checkout.session"), 404);
    });
    http.on("POST", `${STRIPE}/checkout/sessions/:id/expire`, (_req, { params }) => {
      const found = this.sessions.find((x) => x.id === params.id);
      if (!found || found.status !== "open") {
        return jsonResponse(
          stripeErrorBody("invalid_request_error", "Only open sessions can be expired."),
          400,
        );
      }
      found.status = "expired";
      return jsonResponse({ ...found, url: null });
    });
    http.on("POST", `${STRIPE}/billing_portal/sessions`, () => {
      if (this.portalError) return jsonResponse(this.portalError.body, this.portalError.status);
      return jsonResponse({
        id: "bps_1Billing",
        object: "billing_portal.session",
        url: "https://billing.stripe.com/p/session/test_1Billing",
      });
    });
  }
}

// ---------------------------------------------------------------------------
// Fake billing RPCs (0101 contract)
// ---------------------------------------------------------------------------

export interface BillingState {
  billing: Map<string, BillingRow>;
  /** billing_payment_failed calls that notified an owner. */
  notifications: Array<{ shop_id: string; kind: string; at: string }>;
  /** Owner email per shop (auth.users of the owner). */
  ownerEmails: Record<string, string | null>;
  shopNames: Record<string, string>;
  /** Users already given the in-app trial (0120 billing_trial_grants; default none). */
  trialUsedBy?: string[];
}

/** 0101 billing_checkout_context has_live_subscription / billing_apply_subscription v_live. */
const LIVE = new Set(["trialing", "active", "past_due", "unpaid", "paused"]);
/** 0101 billing_apply_subscription v_ended. */
const ENDED = new Set(["canceled", "incomplete_expired"]);
const STATUSES = new Set([
  "trialing",
  "active",
  "past_due",
  "canceled",
  "unpaid",
  "incomplete",
  "incomplete_expired",
  "paused",
]);

function requireService(role: string): void {
  if (role !== "service_role") {
    throw new FakeRpcError("42501", "permission denied (service_role only)", { status: 403 });
  }
}

export function installBillingRpcs(
  db: FakeSupabase,
  state: BillingState,
  now: () => number,
): void {
  const enabled = () =>
    db.table("platform_config").some((r) => r.key === "billing_enabled" && r.value === "true");

  db.onRpc("billing_checkout_context", (a, { role }) => {
    requireService(role);
    const shopId = a.p_shop_id as string;
    const row = state.billing.get(shopId);
    if (!row || !(shopId in state.shopNames)) throw new FakeRpcError("P0002", "shop not found");
    const isOwner = db.table("shop_members").some((m) =>
      m.shop_id === shopId && m.user_id === a.p_user_id && m.role === "owner" && m.active === true
    );
    const trialLive = row.trial_ends_at !== null && Date.parse(row.trial_ends_at) > now() &&
      !row.trial_used;
    return {
      is_owner: isOwner,
      shop_name: state.shopNames[shopId],
      owner_email: state.ownerEmails[shopId] ?? null,
      stripe_customer_id: row.stripe_customer_id,
      has_live_subscription: row.stripe_subscription_id !== null && LIVE.has(row.status),
      trial_end: trialLive ? row.trial_ends_at : null,
      billing_enabled: enabled(),
    };
  });

  db.onRpc("billing_link_customer", (a, { role }) => {
    requireService(role);
    const shopId = a.p_shop_id as string;
    const customer = a.p_stripe_customer_id as string;
    const row = state.billing.get(shopId);
    if (!row) throw new FakeRpcError("P0002", "shop not found");
    if (row.stripe_customer_id === customer) return undefined;
    if (row.stripe_customer_id !== null) {
      throw new FakeRpcError("23505", "this shop is already linked to another billing customer", {
        status: 409,
      });
    }
    for (const other of state.billing.values()) {
      if (other.shop_id !== shopId && other.stripe_customer_id === customer) {
        throw new FakeRpcError("23505", "this billing customer belongs to another shop", {
          status: 409,
        });
      }
    }
    row.stripe_customer_id = customer;
    return undefined;
  });

  db.onRpc("billing_apply_subscription", (a, { role }) => {
    requireService(role);
    const row = [...state.billing.values()].find((r) =>
      r.stripe_customer_id === a.p_stripe_customer_id
    );
    if (!row) return { shop_id: null, applied: false };
    if (!STATUSES.has(a.p_status as string)) throw new FakeRpcError("22023", "unknown status");
    const created = a.p_event_created as string;
    if (row.last_event_at !== null && Date.parse(created) < Date.parse(row.last_event_at)) {
      return { shop_id: row.shop_id, applied: false };
    }
    const status = a.p_status as string;
    const subId = a.p_subscription_id as string;
    // another subscription replaces the shop's only when it can be current
    if (
      row.stripe_subscription_id !== null && row.stripe_subscription_id !== subId &&
      (ENDED.has(status) || (status === "incomplete" && LIVE.has(row.status)))
    ) {
      return { shop_id: row.shop_id, applied: false };
    }
    for (const other of state.billing.values()) {
      if (other.shop_id !== row.shop_id && other.stripe_subscription_id === subId) {
        throw new FakeRpcError("23505", "this subscription belongs to another shop", {
          status: 409,
        });
      }
    }
    const plan = db.table("platform_plans").find((p) => p.stripe_price_id === a.p_price_id);
    row.stripe_subscription_id = subId;
    row.plan_id = (plan?.id as string | undefined) ?? null;
    row.status = status;
    const trialEnd = (a.p_trial_end as string | null) ?? null;
    row.trial_ends_at = trialEnd ?? row.trial_ends_at;
    row.trial_used = row.trial_used || trialEnd !== null || status === "trialing";
    row.current_period_end = (a.p_current_period_end as string | null) ?? row.current_period_end;
    row.cancel_at_period_end = !ENDED.has(status) && a.p_cancel_at_period_end === true;
    row.last_event_at = created;
    return { shop_id: row.shop_id, applied: true };
  });

  db.onRpc("billing_payment_failed", (a, { role }) => {
    requireService(role);
    const row = [...state.billing.values()].find((r) =>
      r.stripe_customer_id === a.p_stripe_customer_id
    );
    if (!row) throw new FakeRpcError("P0002", "unknown billing customer");
    state.notifications.push({
      shop_id: row.shop_id,
      kind: "billing_payment_failed",
      at: a.p_event_created as string,
    });
    return undefined;
  });

  db.onRpc("billing_upsert_plan", (a, { role }) => {
    requireService(role);
    const rows = db.table("platform_plans");
    let row = rows.find((p) => p.stripe_price_id === a.p_stripe_price_id);
    const values = {
      stripe_price_id: a.p_stripe_price_id,
      stripe_product_id: a.p_stripe_product_id,
      name: a.p_name,
      description: a.p_description,
      amount_cents: a.p_amount_cents,
      currency: a.p_currency,
      interval: a.p_interval,
      interval_count: a.p_interval_count,
      max_members: a.p_max_members,
      features: a.p_features,
      sort: a.p_sort,
      active: a.p_active,
    };
    if (row) Object.assign(row, values);
    else {
      row = { id: crypto.randomUUID(), ...values };
      rows.push(row);
    }
    db.seed("platform_plans", rows);
    return row.id;
  });

  db.onRpc("billing_deactivate_plans_except", (a, { role }) => {
    requireService(role);
    const keep = new Set(a.p_active_price_ids as string[]);
    const rows = db.table("platform_plans");
    let count = 0;
    for (const row of rows) {
      if (row.active === true && !keep.has(row.stripe_price_id as string)) {
        row.active = false;
        count++;
      }
    }
    db.seed("platform_plans", rows);
    return count;
  });

  const publicPlans = () => {
    if (!enabled()) return [];
    return db.table("platform_plans")
      .filter((p) => p.active === true)
      .sort((x, y) =>
        (x.sort as number) - (y.sort as number) ||
        (x.amount_cents as number) - (y.amount_cents as number)
      )
      .map((p) => ({
        id: p.id,
        name: p.name,
        description: p.description,
        amount_cents: p.amount_cents,
        currency: p.currency,
        interval: p.interval,
        interval_count: p.interval_count,
        max_members: p.max_members,
        features: p.features,
      }));
  };
  db.onRpc("public_billing_plans", () => publicPlans());
  // 0131: the plans plus the trial of a person's first shop (once per person, 0120).
  db.onRpc("public_billing_offer", (_a, { userId }) => {
    const configured = Number(
      db.table("platform_config").find((r) => r.key === "billing_trial_days")?.value ?? "0",
    );
    const days = enabled() ? configured : 0;
    return {
      plans: publicPlans(),
      trial_days: days,
      trial_available: userId === null
        ? null
        : days > 0 && !(state.trialUsedBy ?? []).includes(userId),
    };
  });
}

// ---------------------------------------------------------------------------
// Fixture
// ---------------------------------------------------------------------------

export interface FixtureOptions {
  billingEnabled?: boolean;
  /** platform_config billing_trial_days (default 14; null: not set). */
  trialDays?: number | null;
  /** Users already given the in-app trial (default: the owner, whose SHOP had it). */
  trialUsedBy?: string[];
  /** shop_billing overrides for SHOP. */
  billing?: Partial<BillingRow>;
  plans?: Row[];
  env?: Record<string, string | undefined>;
  ownerEmail?: string | null;
}

export interface Fixture {
  db: FakeSupabase;
  stripe: FakePlatformStripe;
  state: BillingState;
  logs: MemoryLogger;
  handler: (req: Request) => Promise<Response>;
  call(
    body: Record<string, unknown>,
    who?: Who,
    headers?: Record<string, string>,
  ): Promise<Response>;
  stripeCalls(method?: string, path?: string): RecordedCall[];
  rpcCalls(name: string): Record<string, unknown>[];
}

function member(key: keyof typeof USERS, shopId: string, role: string, active = true): Row {
  return {
    id: `2${USERS[key].slice(1)}`,
    shop_id: shopId,
    user_id: USERS[key],
    role,
    display_name: key,
    active,
  };
}

export function fixture(options: FixtureOptions = {}): Fixture {
  const db = new FakeSupabase({
    env: options.env,
    users: {
      "tok-owner": { id: USERS.owner, email: "owner@shine.example.com" },
      "tok-admin": { id: USERS.admin, email: "admin@shine.example.com" },
      "tok-manager": { id: USERS.manager, email: "manager@shine.example.com" },
      "tok-tech": { id: USERS.tech, email: "tech@shine.example.com" },
      "tok-outsider": { id: USERS.outsider, email: "owner@other.example.com" },
      "tok-inactiveOwner": { id: USERS.inactiveOwner, email: "former@shine.example.com" },
      "tok-anon": { id: "10000000-0000-4000-8000-000000000099", is_anonymous: true },
    },
    tables: {
      shop_members: [
        member("owner", SHOP, "owner"),
        member("admin", SHOP, "admin"),
        member("manager", SHOP, "manager"),
        member("tech", SHOP, "technician"),
        member("outsider", OTHER_SHOP, "owner"),
        member("inactiveOwner", SHOP, "owner", false),
      ],
      platform_config: [
        ...(options.billingEnabled === false ? [] : [{ key: "billing_enabled", value: "true" }]),
        ...(options.trialDays === null
          ? []
          : [{ key: "billing_trial_days", value: String(options.trialDays ?? 14) }]),
      ],
      platform_plans: options.plans ?? [
        planRow(),
        planRow({
          id: PLAN_YEARLY,
          stripe_price_id: "price_1Yearly",
          amount_cents: 49_000,
          interval: "year",
          sort: 2,
        }),
        planRow({ id: PLAN_RETIRED, stripe_price_id: "price_1Retired", active: false }),
      ],
      stripe_events: [],
    },
    tableOptions: {
      platform_config: { primaryKey: ["key"] },
      stripe_events: {
        primaryKey: ["id"],
        defaults: () => ({ attempts: 1, processed_at: null, error: null, account: null }),
      },
    },
  });
  const state: BillingState = {
    billing: new Map([
      [SHOP, billingRow(SHOP, options.billing)],
      [OTHER_SHOP, billingRow(OTHER_SHOP)],
    ]),
    notifications: [],
    ownerEmails: {
      [SHOP]: options.ownerEmail === undefined ? "owner@shine.example.com" : options.ownerEmail,
      [OTHER_SHOP]: "owner@other.example.com",
    },
    shopNames: { [SHOP]: "Shine Co", [OTHER_SHOP]: "Other Shop" },
    trialUsedBy: options.trialUsedBy ?? [USERS.owner, USERS.outsider],
  };
  installBillingRpcs(db, state, () => NOW);
  const stripe = new FakePlatformStripe();
  stripe.install(db);
  const logs = memoryLogger();
  const handler = makeHandler({
    env: db.env(options.env),
    fetch: db.http.fetch,
    logger: logs.logger,
    now: () => NOW,
  });
  return {
    db,
    stripe,
    state,
    logs,
    handler,
    call: (body, who = "owner", headers = {}) =>
      handler(
        jsonRequest("billing", body, {
          ...(who === "none" ? {} : { token: `tok-${who}` }),
          headers,
        }),
      ),
    stripeCalls: (method, path) =>
      db.http.calls.filter((c) =>
        c.url.hostname === "api.stripe.com" &&
        (method === undefined || c.method === method) &&
        (path === undefined || c.url.pathname === `/v1${path}`)
      ),
    rpcCalls: (name) =>
      db.http.calls
        .filter((c) => c.method === "POST" && c.url.pathname === `/rest/v1/rpc/${name}`)
        .map((c) => c.json as Record<string, unknown>),
  };
}

/** [status, code, details] of an error envelope (asserting its shape). */
export async function errorOf(res: Response): Promise<[number, string, unknown]> {
  const body = await res.json() as Record<string, unknown>;
  assertEquals(typeof body.error, "string", JSON.stringify(body));
  assertEquals(typeof body.request_id, "string", JSON.stringify(body));
  return [res.status, body.code as string, body.details];
}
