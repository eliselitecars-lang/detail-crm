/**
 * Helpers shared by the payments actions: row loaders (service role, always
 * scoped by shop), the shop's connected account, the customer's Stripe
 * customer on that account, amount guards, metadata and error mapping.
 */
import type { Env } from "../_shared/env.ts";
import { errors, HttpError, subscriptionRefusal } from "../_shared/errors.ts";
import type { ActionContext } from "../_shared/actions.ts";
import type { Logger } from "../_shared/log.ts";
import { applicationFeeCents, assertChargeableCents } from "../_shared/money.ts";
import { idempotencyKey, onAccount, type Stripe, stripeFromEnv } from "../_shared/stripe.ts";
import { adminClient, type SupabaseClient } from "../_shared/supabase.ts";

export interface Deps {
  env?: Env;
  /** Tests inject FakeFetch (Supabase + Stripe stubs on one fetch). */
  fetch?: typeof fetch;
  logger?: Logger;
  /** Clock (ms since epoch) for idempotency windows; tests pin it. */
  now?: () => number;
}

/** Per-request dependencies every action receives. */
export interface Services {
  admin: SupabaseClient;
  stripe: Stripe;
  env: Env;
  log: Logger;
  now: number;
}

export function services(deps: Deps, ctx: ActionContext): Services {
  return {
    admin: adminClient({ env: deps.env, fetch: deps.fetch }),
    stripe: deps.fetch
      ? stripeFromEnv(ctx.env, { fetch: deps.fetch, maxNetworkRetries: 0 })
      : stripeFromEnv(ctx.env),
    env: ctx.env,
    log: ctx.log,
    now: deps.now ? deps.now() : Date.now(),
  };
}

// ---------------------------------------------------------------------------
// Database errors
// ---------------------------------------------------------------------------

export interface DbError {
  code?: string;
  message?: string;
  /** The exception's HINT: a machine-readable refusal reason where one is set (0095). */
  hint?: string | null;
}

/**
 * True when the database refused with SQLSTATE `code` and HINT `hint` (the
 * machine-readable reason some RPCs add, e.g. 0095's `already_member`), or —
 * for a database without the HINT yet — when its message matches `legacy`.
 */
export function refusedWith(
  error: DbError,
  code: string,
  hint: string,
  legacy?: RegExp,
): boolean {
  if (error.code !== code) return false;
  if (typeof error.hint === "string" && error.hint.trim() !== "") {
    return error.hint.trim() === hint;
  }
  return legacy !== undefined && legacy.test(error.message ?? "");
}

/** Unexpected database failure -> 500 (details only in logs). */
export function dbFailure(what: string, cause: unknown): Error {
  return new Error(`${what} failed`, { cause });
}

/**
 * Maps a PostgREST error from a money RPC to a stable HttpError. Messages
 * are ours (generic per call site); the database text is only logged —
 * except PT402 (the shop's subscription is inactive, 0102), which is `402
 * payment_required` with the database's neutral sentence.
 */
export function rpcError(what: string, error: DbError, messages: {
  notFound?: string;
  invalid?: string;
  conflict?: string;
  unavailable?: string;
} = {}): Error {
  const paused = subscriptionRefusal(error);
  if (paused) return paused;
  switch (error.code) {
    case "P0002":
    case "PT404": // public RPCs' not-found (HTTP 404; 0042 convention)
      return new HttpError("not_found", messages.notFound ?? "Not found.", { cause: error });
    case "42501":
      return new HttpError("forbidden", "You do not have permission to do that.", { cause: error });
    case "22023":
    case "23514":
      return new HttpError(
        "unprocessable",
        messages.invalid ?? "This request cannot be completed.",
        {
          cause: error,
        },
      );
    case "23505":
      return new HttpError(
        "conflict",
        messages.conflict ?? "This conflicts with an existing record.",
        {
          cause: error,
        },
      );
    case "55000": // object not in prerequisite state (e.g. a feature the shop turned off)
      return new HttpError(
        "conflict",
        messages.unavailable ?? "This is not available right now.",
        { cause: error },
      );
    case "PT429": // public RPCs' abuse limits (HTTP 429)
      return new HttpError(
        "rate_limited",
        "Too many attempts. Please try again later or contact the shop.",
        { cause: error, headers: { "Retry-After": "3600" } },
      );
    default:
      return dbFailure(what, error);
  }
}

/**
 * The customer-facing text of a validation error (22023) raised by one of our
 * own public RPCs (gift_card_order_prepare, membership_join_prepare): those
 * messages are written for the customer ("enter a valid email address"), so
 * a public form can show them. Capitalised, one line, at most 200 characters.
 */
export function publicValidationMessage(error: DbError, fallback: string): string {
  const text = (error.message ?? "").replace(/\s+/g, " ").trim();
  if (!text || text.length > 200) return fallback;
  const sentence = text.charAt(0).toUpperCase() + text.slice(1);
  return /[.!?]$/.test(sentence) ? sentence : `${sentence}.`;
}

// ---------------------------------------------------------------------------
// Rows
// ---------------------------------------------------------------------------

export interface ShopRow {
  id: string;
  name: string;
  currency: string;
  techs_can_collect_payments: boolean;
}

export interface AccountRow {
  shop_id: string;
  stripe_account_id: string;
  charges_enabled: boolean;
}

export interface CustomerRow {
  id: string;
  shop_id: string;
  first_name: string | null;
  last_name: string | null;
  company: string | null;
  email: string | null;
  phone: string | null;
  stripe_customer_id: string | null;
  archived_at: string | null;
}

export interface InvoiceRow {
  id: string;
  shop_id: string;
  number: number;
  job_id: string | null;
  customer_id: string;
  status: "draft" | "open" | "partially_paid" | "paid" | "void";
  balance_cents: number;
  public_token: string;
}

export const INVOICE_COLUMNS =
  "id, shop_id, number, job_id, customer_id, status, balance_cents, public_token";

const CUSTOMER_COLUMNS =
  "id, shop_id, first_name, last_name, company, email, phone, stripe_customer_id, archived_at";

export async function loadShop(admin: SupabaseClient, shopId: string): Promise<ShopRow> {
  const { data, error } = await admin
    .from("shops")
    .select("id, name, currency, techs_can_collect_payments")
    .eq("id", shopId)
    .maybeSingle();
  if (error) throw dbFailure("shops lookup", error);
  if (!data) throw errors.notFound("Shop not found.");
  return data as ShopRow;
}

/**
 * The shop's connected account. `requireCharges` (default) also requires
 * charges_enabled — every new charge / saved card / subscription needs it.
 */
export async function loadAccount(
  admin: SupabaseClient,
  shopId: string,
  { requireCharges = true }: { requireCharges?: boolean } = {},
): Promise<AccountRow> {
  const row = await findAccount(admin, shopId);
  if (!row) {
    throw errors.unprocessable("This shop has not connected Stripe yet.", {
      reason: "stripe_not_connected",
    });
  }
  if (requireCharges && !row.charges_enabled) {
    throw errors.unprocessable("This shop cannot accept card payments yet.", {
      reason: "charges_disabled",
    });
  }
  return row;
}

export async function loadCustomer(
  admin: SupabaseClient,
  shopId: string,
  customerId: string,
): Promise<CustomerRow> {
  const { data, error } = await admin
    .from("customers")
    .select(CUSTOMER_COLUMNS)
    .eq("shop_id", shopId)
    .eq("id", customerId)
    .maybeSingle();
  if (error) throw dbFailure("customers lookup", error);
  if (!data) throw errors.notFound("Customer not found.");
  return data as CustomerRow;
}

/** Invoice of `shopId` by id (staff) — not_found for other shops' ids. */
export async function loadInvoice(
  admin: SupabaseClient,
  shopId: string,
  invoiceId: string,
): Promise<InvoiceRow> {
  const { data, error } = await admin
    .from("invoices")
    .select(INVOICE_COLUMNS)
    .eq("shop_id", shopId)
    .eq("id", invoiceId)
    .maybeSingle();
  if (error) throw dbFailure("invoices lookup", error);
  if (!data) throw errors.notFound("Invoice not found.");
  return data as InvoiceRow;
}

/** The invoice must be issued, not void, with a positive balance. */
export function assertPayable(invoice: InvoiceRow): number {
  if (invoice.status === "draft") {
    throw errors.unprocessable("This invoice has not been issued yet.", { reason: "draft" });
  }
  if (invoice.status === "void") {
    throw errors.conflict("This invoice has been voided.", { reason: "void" });
  }
  if (invoice.status === "paid" || invoice.balance_cents <= 0) {
    throw errors.conflict("This invoice is already paid.", { reason: "paid" });
  }
  return invoice.balance_cents;
}

/**
 * Money on its way to the invoice that its balance does not show yet: ACH
 * debits (and other asynchronous methods) recorded `processing` (P-31, in
 * flight for days; 0064 payment_in_flight). Card attempts still open are
 * settled separately (settle.ts).
 */
export async function processingCents(
  admin: SupabaseClient,
  shopId: string,
  invoiceId: string,
): Promise<number> {
  const { data, error } = await admin
    .from("payments")
    .select("amount_cents")
    .eq("shop_id", shopId)
    .eq("invoice_id", invoiceId)
    .eq("status", "processing");
  if (error) throw dbFailure("processing payments lookup", error);
  let total = 0;
  for (const row of (data ?? []) as Array<{ amount_cents: number }>) {
    if (typeof row.amount_cents === "number" && Number.isSafeInteger(row.amount_cents)) {
      total += row.amount_cents;
    }
  }
  return total;
}

/**
 * What can still be paid on the invoice now: its balance less the money
 * processing toward it (the public invoice's `payable`, 0066). 409
 * payment_in_progress when processing payments cover the whole balance.
 */
export async function payableBalance(s: Services, invoice: InvoiceRow): Promise<number> {
  const balance = assertPayable(invoice);
  const available = balance - await processingCents(s.admin, invoice.shop_id, invoice.id);
  if (available <= 0) throw paymentInProgress();
  return available;
}

// ---------------------------------------------------------------------------
// Invoices and their jobs (P-7: an invoice bills one job, or several)
// ---------------------------------------------------------------------------

/**
 * The jobs an invoice bills: its job, or the jobs of a grouped invoice
 * (invoice_jobs; job_id is null on a grouped invoice). A deposit payment of
 * any of them lands on this invoice (payments_before_write).
 */
export async function invoiceJobIds(
  admin: SupabaseClient,
  invoice: Pick<InvoiceRow, "id" | "shop_id" | "job_id">,
): Promise<string[]> {
  if (invoice.job_id) return [invoice.job_id];
  const { data, error } = await admin
    .from("invoice_jobs")
    .select("job_id")
    .eq("shop_id", invoice.shop_id)
    .eq("invoice_id", invoice.id)
    .eq("voided", false);
  if (error) throw dbFailure("invoice_jobs lookup", error);
  return ((data ?? []) as Array<{ job_id: string }>).map((row) => row.job_id);
}

/**
 * The job's live (non-void) invoice, single or grouped, or null. A job has at
 * most one (0061 invoice_jobs_one_live_invoice); a deposit payment of the job
 * is attached to it.
 */
export async function liveInvoiceForJob(
  admin: SupabaseClient,
  shopId: string,
  jobId: string,
): Promise<InvoiceRow | null> {
  const { data, error } = await admin
    .from("invoice_jobs")
    .select("invoice_id")
    .eq("shop_id", shopId)
    .eq("job_id", jobId)
    .eq("voided", false);
  if (error) throw dbFailure("invoice_jobs lookup", error);
  const ids = ((data ?? []) as Array<{ invoice_id: string }>).map((row) => row.invoice_id);
  if (ids.length === 0) return null;
  const found = await admin
    .from("invoices")
    .select(INVOICE_COLUMNS)
    .eq("shop_id", shopId)
    .in("id", ids)
    .neq("status", "void")
    .limit(1)
    .maybeSingle();
  if (found.error) throw dbFailure("job invoice lookup", found.error);
  return (found.data as InvoiceRow | null) ?? null;
}

// ---------------------------------------------------------------------------
// Amounts
// ---------------------------------------------------------------------------

/** Stripe's limits as a client-facing 422 (not a 500 RangeError). */
export function chargeable(amountCents: number, currency: string): number {
  try {
    return assertChargeableCents(amountCents, currency);
  } catch (cause) {
    throw new HttpError(
      "unprocessable",
      "This amount cannot be charged by card (Stripe's minimum is $0.50).",
      { details: { reason: "amount_out_of_range", amount_cents: amountCents }, cause },
    );
  }
}

/** A requested partial amount: 0 < amount <= balance (default: the balance). */
export function requestedAmount(requested: number | undefined, balance: number): number {
  if (requested === undefined) return balance;
  if (requested > balance) {
    throw errors.unprocessable("The amount is more than the balance due.", {
      reason: "amount_exceeds_balance",
      balance_cents: balance,
    });
  }
  return requested;
}

/**
 * Tips: whole cents (zod enforces integer/non-negative), at most the amount
 * this attempt actually collects toward the balance. Bounding by the balance
 * instead would let a 1-cent payment carry the whole balance as a fee-free
 * "tip" that never lowers the balance (tips never do, SPEC §4.5), again and
 * again; tied to the collected amount, every tip is matched by an equal
 * payment down of the balance, so the tips on an invoice never exceed it.
 */
export function boundedTip(tip: number | undefined, collectedCents: number): number {
  const value = tip ?? 0;
  if (value > collectedCents) {
    throw errors.unprocessable("The tip cannot be more than the amount being paid.", {
      reason: "tip_too_large",
      max_tip_cents: collectedCents,
    });
  }
  return value;
}

/** Platform fee on the non-tip amount; undefined when none (omit the param). */
export function platformFee(env: Env, amountCents: number): number | undefined {
  const fee = applicationFeeCents(amountCents, env.platformFeeBps());
  return fee > 0 ? fee : undefined;
}

// ---------------------------------------------------------------------------
// Idempotency and metadata
// ---------------------------------------------------------------------------

/** Window during which identical requests without a nonce share a key. */
export const IDEMPOTENCY_WINDOW_MS = 10 * 60 * 1000;

/**
 * The request-specific idempotency part: the client's `request_nonce` when
 * given (a retry reuses it), else a 10-minute time window so double-clicks
 * collapse while a later, deliberate attempt gets a fresh object.
 */
export function requestPart(nonce: string | undefined, now: number): string {
  return nonce ? `n:${nonce}` : `w:${Math.floor(now / IDEMPOTENCY_WINDOW_MS)}`;
}

/**
 * Checkout Sessions opened from a public page (invoice, deposit) close
 * 32 minutes after the end of the request's idempotency window (32–42 min
 * after creation; Stripe's minimum is 30). A short life bounds how long a
 * stale session (old balance, voided invoice, cancelled booking) can still be
 * paid; the page simply opens a new one.
 */
export const PUBLIC_CHECKOUT_TTL_S = 32 * 60;

/**
 * Idempotency part + expires_at for a Checkout Session. The window is always
 * part of the key (even with a nonce) so a replay never sends a different
 * expires_at under the same key.
 */
export function checkoutRequest(
  nonce: string | undefined,
  now: number,
): { part: string; expiresAt: number } {
  const window = Math.floor(now / IDEMPOTENCY_WINDOW_MS);
  return {
    part: nonce ? `n:${nonce}|w:${window}` : `w:${window}`,
    expiresAt: Math.floor(((window + 1) * IDEMPOTENCY_WINDOW_MS) / 1000) + PUBLIC_CHECKOUT_TTL_S,
  };
}

/** Stripe metadata: strings only, null/undefined dropped. */
export function metadata(
  values: Readonly<Record<string, string | number | boolean | null | undefined>>,
): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [key, value] of Object.entries(values)) {
    if (value === null || value === undefined) continue;
    out[key] = String(value);
  }
  return out;
}

// ---------------------------------------------------------------------------
// Stripe customer on the connected account
// ---------------------------------------------------------------------------

function displayName(customer: CustomerRow): string | undefined {
  const person = [customer.first_name, customer.last_name]
    .map((part) => part?.trim())
    .filter(Boolean)
    .join(" ");
  return person || customer.company?.trim() || undefined;
}

function isMissingResource(err: unknown): boolean {
  if (typeof err !== "object" || err === null) return false;
  const e = err as { type?: unknown; code?: unknown; statusCode?: unknown };
  return e.type === "StripeInvalidRequestError" &&
    (e.code === "resource_missing" || e.statusCode === 404);
}

/**
 * The customer's Stripe Customer on the shop's connected account: reuses
 * customers.stripe_customer_id when it still exists on that account,
 * otherwise creates one (idempotent per shop/customer/account/previous id)
 * and stores its id via service role.
 */
export async function ensureStripeCustomer(
  s: Services,
  account: AccountRow,
  customer: CustomerRow,
): Promise<string> {
  const existing = customer.stripe_customer_id;
  if (existing) {
    try {
      const found = await s.stripe.customers.retrieve(
        existing,
        {},
        onAccount(account.stripe_account_id),
      );
      if (!("deleted" in found && found.deleted)) return found.id;
    } catch (err) {
      if (!isMissingResource(err)) throw err;
    }
    s.log.warn("stripe_customer_replaced", { shop_id: customer.shop_id, customer_id: customer.id });
  }

  const name = displayName(customer);
  const created = await s.stripe.customers.create(
    {
      ...(name ? { name } : {}),
      ...(customer.email ? { email: customer.email } : {}),
      ...(customer.phone ? { phone: customer.phone } : {}),
      metadata: metadata({ shop_id: customer.shop_id, customer_id: customer.id }),
    },
    onAccount(account.stripe_account_id, {
      idempotencyKey: await idempotencyKey(
        "customer",
        customer.shop_id,
        customer.id,
        account.stripe_account_id,
        existing ?? "none",
      ),
    }),
  );
  const { error } = await s.admin
    .from("customers")
    .update({ stripe_customer_id: created.id })
    .eq("shop_id", customer.shop_id)
    .eq("id", customer.id);
  if (error) throw dbFailure("customers stripe_customer_id update", error);
  return created.id;
}

/** Ephemeral key for the iOS PaymentSheet (customer on the connected account). */
export async function ephemeralKey(
  s: Services,
  account: AccountRow,
  stripeCustomerId: string,
  apiVersion: string,
  part: string,
): Promise<string> {
  const key = await s.stripe.ephemeralKeys.create(
    { customer: stripeCustomerId },
    {
      apiVersion,
      ...onAccount(account.stripe_account_id, {
        idempotencyKey: await idempotencyKey("ephemeral_key", stripeCustomerId, apiVersion, part),
      }),
    },
  );
  if (!key.secret) throw new Error("Stripe returned an ephemeral key without a secret");
  return key.secret;
}

// ---------------------------------------------------------------------------
// Checkout Sessions: one live session per document
// ---------------------------------------------------------------------------

/** Most attempts at a fresh object when idempotent replays return closed ones. */
const MAX_FRESH_ATTEMPTS = 4;

export function paymentInProgress(): HttpError {
  return errors.conflict("A payment for this is already being processed. Refresh in a moment.", {
    reason: "payment_in_progress",
  });
}

/**
 * Creates a Checkout Session under `scope`/`parts` and returns it only while
 * it is really open. Stripe's idempotency layer replays the FIRST response
 * stored under a key (creation-time state: open, with its url) for 24 hours,
 * so the replayed body never says the session was expired since (a newer
 * link superseded it) or completed. The session is therefore re-read after
 * every create: an expired one is replaced under a key chained on its id, a
 * completed one means the money is on its way (409).
 */
export async function createCheckoutSession(
  s: Services,
  account: AccountRow,
  params: Stripe.Checkout.SessionCreateParams,
  scope: string,
  parts: ReadonlyArray<string | number>,
): Promise<Stripe.Checkout.Session & { url: string }> {
  const chain: string[] = [];
  for (let attempt = 0; attempt < MAX_FRESH_ATTEMPTS; attempt++) {
    const created = await s.stripe.checkout.sessions.create(
      params,
      onAccount(account.stripe_account_id, {
        idempotencyKey: await idempotencyKey(scope, ...parts, ...chain),
      }),
    );
    const current = await s.stripe.checkout.sessions.retrieve(
      created.id,
      {},
      onAccount(account.stripe_account_id),
    );
    if (current.status === "complete") throw paymentInProgress();
    if (current.status === "expired") {
      chain.push(`after:${created.id}`);
      continue;
    }
    const url = current.url ?? created.url;
    if (!url) throw new Error("Stripe returned a Checkout Session without a URL");
    return { ...current, url, expires_at: current.expires_at ?? created.expires_at };
  }
  throw errors.conflict("This payment link keeps changing. Refresh and try again.", {
    reason: "checkout_superseded",
  });
}

/** The Stripe customer's Checkout Sessions on the connected account (newest first). */
export async function customerSessions(
  s: Services,
  account: AccountRow,
  stripeCustomer: string,
  status: "open" | "complete",
): Promise<Stripe.Checkout.Session[]> {
  const list = await s.stripe.checkout.sessions.list(
    { customer: stripeCustomer, status, limit: 100 },
    onAccount(account.stripe_account_id),
  );
  return list.data ?? [];
}

/**
 * Expires the customer's open Checkout Sessions that `match` (except
 * `keepId`), so an older link can no longer be paid. A session that closed
 * in the meantime (completed or expired) is skipped, unless
 * `refuseCompleted`: then one that was just paid means the money is on its
 * way and the caller must not charge again (409 payment_in_progress).
 * Returns the expired ids.
 */
export async function expireOpenSessions(
  s: Services,
  account: AccountRow,
  stripeCustomer: string,
  match: (session: Stripe.Checkout.Session) => boolean,
  keepId?: string,
  options: { refuseCompleted?: boolean } = {},
): Promise<string[]> {
  const expired: string[] = [];
  for (const session of await customerSessions(s, account, stripeCustomer, "open")) {
    if (session.id === keepId || session.status !== "open" || !match(session)) continue;
    try {
      await s.stripe.checkout.sessions.expire(
        session.id,
        {},
        onAccount(account.stripe_account_id, {
          idempotencyKey: await idempotencyKey("checkout_expire", session.id),
        }),
      );
      expired.push(session.id);
    } catch (err) {
      // Only open sessions can be expired: it completed or expired meanwhile.
      if (!isInvalidRequest(err)) throw err;
      if (options.refuseCompleted) {
        const current = await s.stripe.checkout.sessions.retrieve(
          session.id,
          {},
          onAccount(account.stripe_account_id),
        );
        if (current.status === "complete") throw paymentInProgress();
      }
      s.log.warn("checkout_expire_skipped", { shop_id: account.shop_id, session: session.id });
    }
  }
  return expired;
}

export function isInvalidRequest(err: unknown): boolean {
  return typeof err === "object" && err !== null &&
    (err as { type?: unknown }).type === "StripeInvalidRequestError";
}

export type SessionMatch = (session: Stripe.Checkout.Session) => boolean;

const invoiceLinks = (shopId: string, invoiceId: string): SessionMatch => (session) =>
  session.mode === "payment" && session.metadata?.shop_id === shopId &&
  session.metadata?.invoice_id === invoiceId && session.metadata?.kind === "payment";

const depositLinks = (shopId: string, jobIds: ReadonlyArray<string>): SessionMatch => {
  const jobs = new Set(jobIds);
  return (session) =>
    session.mode === "payment" && session.metadata?.shop_id === shopId &&
    jobs.has(session.metadata?.job_id ?? "") && session.metadata?.kind === "deposit";
};

/** Metadata matchers for the sessions each action creates. */
export const sessionFor = {
  invoice: invoiceLinks,
  /** Deposit links (booking and quote deposits) of the job. */
  deposit: (shopId: string, jobId: string): SessionMatch => depositLinks(shopId, [jobId]),
  /** Deposit links of any of these jobs (the jobs a grouped invoice bills). */
  deposits: (shopId: string, jobIds: ReadonlyArray<string>): SessionMatch =>
    depositLinks(shopId, jobIds),
  /**
   * Invoice pay links that pay toward the job: those tagged with the job
   * (invoice_checkout tags a single-job invoice's job_id) and, when the job
   * has a live invoice (single or grouped), that invoice's links.
   */
  jobInvoices: (shopId: string, jobId: string, liveInvoiceId: string | null): SessionMatch => {
    const live = liveInvoiceId ? invoiceLinks(shopId, liveInvoiceId) : null;
    return (session) =>
      (session.mode === "payment" && session.metadata?.shop_id === shopId &&
        session.metadata?.job_id === jobId && session.metadata?.kind === "payment") ||
      (live !== null && live(session));
  },
  /**
   * Every open instrument that pays toward the invoice: its own pay links
   * and the deposit links of the jobs it bills (one job, or every job of a
   * grouped invoice). A deposit payment is attached to the job's invoice
   * (payments_before_write), so a deposit link left open after the balance
   * was collected would overpay the invoice by the deposit.
   */
  invoiceOrDeposit: (
    shopId: string,
    invoice: { id: string },
    jobIds: ReadonlyArray<string>,
  ): SessionMatch => {
    const own = invoiceLinks(shopId, invoice.id);
    const deposit = jobIds.length > 0 ? depositLinks(shopId, jobIds) : null;
    return (session) => own(session) || (deposit !== null && deposit(session));
  },
  membership: (shopId: string, membershipId: string) => (session: Stripe.Checkout.Session) =>
    session.mode === "subscription" && session.metadata?.shop_id === shopId &&
    session.metadata?.membership_id === membershipId,
};

// ---------------------------------------------------------------------------
// Public pages and shops by slug
// ---------------------------------------------------------------------------

/**
 * A public web page under APP_BASE_URL (SPEC §6 routes), e.g.
 * appPage(base, "gift", slug, "done") -> https://app/gift/<slug>/done.
 * Segments are URL-encoded.
 */
export function appPage(baseUrl: string, ...segments: string[]): string {
  if (segments.length === 0 || segments.some((part) => part === "")) {
    throw new TypeError("page segments must not be empty");
  }
  return `${baseUrl.replace(/\/+$/, "")}/${segments.map(encodeURIComponent).join("/")}`;
}

/** A shop slug as typed in a public URL (the RPCs lower-case and trim it). */
export const SLUG_RE = /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,62}[A-Za-z0-9])?$/;

/** The shop with this public slug (404 when none). */
export async function loadShopBySlug(admin: SupabaseClient, slug: string): Promise<
  ShopRow & {
    slug: string;
  }
> {
  const { data, error } = await admin
    .from("shops")
    .select("id, name, currency, techs_can_collect_payments, slug")
    .eq("slug", slug.trim().toLowerCase())
    .maybeSingle();
  if (error) throw dbFailure("shops lookup", error);
  if (!data) throw errors.notFound("Shop not found.");
  return data as ShopRow & { slug: string };
}

/**
 * Payment method options of the public Checkout links (P-31): the card is
 * saved for charge-card-on-file through the CARD options, never the
 * intent's top-level setup_future_usage, which would hide every method that
 * cannot be saved (pay-later) and restrict the rest. With no
 * payment_method_types the connected account's enabled methods apply
 * (dynamic payment methods): cards and wallets always, US bank debits (ACH)
 * and pay-later providers when the shop turned them on in Stripe.
 */
export const SAVE_CARD_OPTIONS: Stripe.Checkout.SessionCreateParams.PaymentMethodOptions = {
  card: { setup_future_usage: "off_session" },
};

/**
 * Wallet options of the same links: Link is not offered. A Link payment is
 * its own payment method type ("link"), which the card options above do not
 * save, and the CRM's card on file is card-only (charge_saved_card confirms
 * with payment_method_types ['card']). With Link shown, a customer paying
 * through it would leave no card on file, so the deposit's "card on file"
 * would silently be missing when staff later charge it. Apple Pay / Google
 * Pay stay: they produce card payment methods and are saved as cards.
 */
export const NO_LINK_WALLET: Stripe.Checkout.SessionCreateParams.WalletOptions = {
  link: { display: "never" },
};

/** The shop's connected account, or null when Stripe was never connected. */
export async function findAccount(
  admin: SupabaseClient,
  shopId: string,
): Promise<AccountRow | null> {
  const { data, error } = await admin
    .from("shop_stripe_accounts")
    .select("shop_id, stripe_account_id, charges_enabled")
    .eq("shop_id", shopId)
    .maybeSingle();
  if (error) throw dbFailure("shop_stripe_accounts lookup", error);
  return (data as AccountRow | null) ?? null;
}
