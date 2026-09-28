/**
 * billing — shop subscription billing: the PLATFORM operator charges shops
 * for Detail CRM (docs/BILLING.md). Everything here runs on the platform
 * Stripe account: no call carries a Stripe-Account header. How shops charge
 * THEIR customers (Stripe Connect) is the `payments` function and is
 * unrelated.
 *
 *   plans       {}                                  any signed-in user
 *               -> {billing_enabled, plans: [{id, name, description, amount_cents,
 *                   currency, interval, interval_count, max_members, features}]}
 *   checkout    {shop_id, plan_id, request_nonce?}  owner only -> {url}
 *               Stripe Checkout (mode subscription) for the shop's platform
 *               customer (created and linked on first use). Stripe Tax only
 *               with BILLING_AUTOMATIC_TAX=true (off by default). One live
 *               subscription per shop: refused (409 already_subscribed) while
 *               the database OR Stripe has one for the shop's customer (the
 *               webhook may not have arrived yet); the session expires after
 *               about an hour, and every older open checkout of the shop is
 *               expired, so at most one payable link exists at a time.
 *   portal      {shop_id}                           owner only -> {url}
 *               Stripe Customer Portal (plan changes, cancellation, card).
 *   sync_customer  {shop_id}                        owner/admin -> {synced}
 *               Readdresses the shop's platform customer to its CURRENT
 *               owner (call it after transfer_ownership).
 *   sync_plans  {}                                  pg_cron / deploy (x-cron-secret)
 *               -> {upserted, deactivated, skipped, warnings}
 *   sync_customers {}                               pg_cron (x-cron-secret)
 *               -> {checked, updated, failed}
 *
 * The platform customer is where Stripe sends the shop's receipts, renewal
 * notices and failed-payment (dunning) emails, so it must follow the shop's
 * owner: it carries the owner's email and metadata.owner_user_id. checkout,
 * portal and sync_customer update it when the owner (or the owner's email)
 * changed; sync_customers (daily) catches every ownership transfer the
 * client did not report, by comparing metadata.owner_user_id with the
 * shop's current owner.
 *
 * verify_jwt = false (config.toml): pg_cron and the deploy call sync_plans
 * and sync_customers without a Supabase JWT. plans / checkout / portal /
 * sync_customer verify the caller's
 * session here (requireUser) and the role in the shop (requireShopRole), so a
 * missing session is this function's own 401 envelope.
 *
 * Subscription state is written only by `billing-webhook` (Stripe platform
 * events -> service-role RPCs): nothing here marks a shop as subscribed.
 * Prices, plan names, limits and the trial length come from Stripe and the
 * database (set_billing_config); none is hard-coded.
 */
import { z } from "zod";
import { createActionRouter, jsonAction } from "../_shared/actions.ts";
import { requireCronSecret, requireShopRole, requireUser, ROLES } from "../_shared/auth.ts";
import { syncPlans } from "../_shared/billing_plans.ts";
import type { Env } from "../_shared/env.ts";
import { errors, HttpError } from "../_shared/errors.ts";
import { createHandler } from "../_shared/http.ts";
import { withQuery } from "../_shared/links.ts";
import type { Logger } from "../_shared/log.ts";
import { requestNonce, uuid } from "../_shared/schemas.ts";
import { idempotencyKey, type Stripe, stripeFromEnv } from "../_shared/stripe.ts";
import { isStripeError } from "../_shared/stripe_errors.ts";
import { adminClient, type SupabaseClient, userClient } from "../_shared/supabase.ts";

export interface Deps {
  env?: Env;
  /** Tests inject FakeFetch (Supabase + Stripe stubs on one fetch). */
  fetch?: typeof fetch;
  logger?: Logger;
  /** Clock (ms since epoch): trial lead time and the idempotency window. */
  now?: () => number;
}

/** Web page Stripe returns to (web/: Settings > Billing). */
export const BILLING_SETTINGS_PATH = "/app/settings/billing";

/**
 * Stripe's minimum for subscription_data.trial_end is 48 hours from now. The
 * minute on top absorbs the request's own latency, so a trial ending right at
 * the limit is dropped (charged now) instead of Stripe rejecting the session.
 */
export const MIN_TRIAL_LEAD_MS = 48 * 60 * 60 * 1000 + 60 * 1000;

/** Identical checkouts without a request_nonce share a key for this long. */
export const IDEMPOTENCY_WINDOW_MS = 10 * 60 * 1000;

/**
 * How long a Checkout link stays payable (Stripe's default is 24 hours; its
 * minimum is 30 minutes). checkoutExpiresAt counts it from the end of the
 * idempotency window, so a link lives between this and this + 10 minutes.
 */
export const CHECKOUT_TTL_MS = 60 * 60 * 1000;

/** Stripe subscription statuses that can never bill again. */
const ENDED_SUBSCRIPTION = new Set<string>(["canceled", "incomplete_expired"]);

const CUSTOMER_ID = /^cus_[A-Za-z0-9]+$/;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const emptyInput = z.object({}).strict();
const checkoutInput = z.object({
  shop_id: uuid,
  plan_id: uuid,
  request_nonce: requestNonce.optional(),
}).strict();
const portalInput = z.object({ shop_id: uuid }).strict();
const syncCustomerInput = z.object({ shop_id: uuid }).strict();

/** billing_checkout_context (0101): the shop's billing facts for the caller. */
export interface CheckoutContext {
  is_owner: boolean;
  shop_name: string;
  owner_email: string | null;
  stripe_customer_id: string | null;
  has_live_subscription: boolean;
  /** The shop's remaining in-app trial end (ISO), or null. */
  trial_end: string | null;
  billing_enabled: boolean;
}

/** What `plans` returns per plan (public_billing_plans; never Stripe ids). */
export interface PublicPlan {
  id: string;
  name: string;
  description: string | null;
  amount_cents: number;
  currency: string;
  interval: string;
  interval_count: number;
  max_members: number | null;
  features: string[];
}

interface Services {
  admin: SupabaseClient;
  stripe: () => Stripe;
  env: Env;
  log: Logger;
  now: number;
}

function dbFailure(what: string, cause: unknown): Error {
  return new Error(`${what} failed`, { cause });
}

/** Maps a PostgREST error of a billing RPC to a client-safe error. */
function rpcError(what: string, error: { code?: string; message?: string }): Error {
  switch (error.code) {
    case "P0002":
      return new HttpError("not_found", "Shop not found.", { cause: error });
    case "42501":
      return new HttpError("forbidden", "You do not have permission to do that.", {
        cause: error,
      });
    case "23505":
      return new HttpError("conflict", "This billing account belongs to another shop.", {
        details: { reason: "customer_conflict" },
        cause: error,
      });
    default:
      return dbFailure(what, error);
  }
}

/**
 * billing_link_customer (0101) raises 23505 in two cases, told apart by its
 * message (there is no HINT): this shop is already linked to a DIFFERENT
 * platform customer ("this shop is already linked to another billing
 * customer" — e.g. a concurrent first checkout linked its own customer
 * first; never silently swapped), or the customer belongs to another shop.
 */
export function linkCustomerError(error: { code?: string; message?: string }): Error {
  if (error.code === "23505" && /already linked/i.test(error.message ?? "")) {
    return new HttpError(
      "conflict",
      "This shop's billing account was just set up by another request. Refresh and try again.",
      { details: { reason: "billing_account_changed" }, cause: error },
    );
  }
  return rpcError("billing_link_customer", error);
}

async function billingEnabled(admin: SupabaseClient): Promise<boolean> {
  const { data, error } = await admin
    .from("platform_config")
    .select("value")
    .eq("key", "billing_enabled")
    .maybeSingle<{ value: string }>();
  if (error) throw dbFailure("platform_config lookup", error);
  return data?.value?.trim().toLowerCase() === "true";
}

function toPublicPlan(row: Record<string, unknown>): PublicPlan {
  return {
    id: String(row.id),
    name: String(row.name),
    description: typeof row.description === "string" ? row.description : null,
    amount_cents: Number(row.amount_cents),
    currency: String(row.currency),
    interval: String(row.interval),
    interval_count: Number(row.interval_count ?? 1),
    max_members: typeof row.max_members === "number" ? row.max_members : null,
    features: Array.isArray(row.features) ? row.features.map(String) : [],
  };
}

/**
 * The flag is read with the service role (platform_config has no client
 * grants); the plans as the signed-in caller (public_billing_plans is granted
 * to anon and authenticated), so the database stays the enforcement point.
 */
export async function listPlans(s: Services, caller: SupabaseClient): Promise<{
  billing_enabled: boolean;
  plans: PublicPlan[];
}> {
  if (!(await billingEnabled(s.admin))) return { billing_enabled: false, plans: [] };
  const { data, error } = await caller.rpc("public_billing_plans");
  if (error) throw dbFailure("public_billing_plans", error);
  const rows = Array.isArray(data) ? data as Record<string, unknown>[] : [];
  return { billing_enabled: true, plans: rows.map(toPublicPlan) };
}

async function checkoutContext(
  admin: SupabaseClient,
  shopId: string,
  userId: string | null,
): Promise<CheckoutContext> {
  const { data, error } = await admin.rpc("billing_checkout_context", {
    p_shop_id: shopId,
    p_user_id: userId,
  });
  if (error) throw rpcError("billing_checkout_context", error);
  const row = (Array.isArray(data) ? data[0] : data) as Partial<CheckoutContext> | null;
  if (!row || typeof row !== "object") throw new Error("billing_checkout_context returned nothing");
  return {
    is_owner: row.is_owner === true,
    shop_name: typeof row.shop_name === "string" ? row.shop_name : "",
    owner_email: typeof row.owner_email === "string" && row.owner_email ? row.owner_email : null,
    stripe_customer_id: typeof row.stripe_customer_id === "string" && row.stripe_customer_id
      ? row.stripe_customer_id
      : null,
    has_live_subscription: row.has_live_subscription === true,
    trial_end: typeof row.trial_end === "string" && row.trial_end ? row.trial_end : null,
    billing_enabled: row.billing_enabled === true,
  };
}

/** The caller, verified as the owner of `shopId` (403 for everyone else). */
async function requireOwner(
  s: Services,
  req: Request,
  shopId: string,
): Promise<{ context: CheckoutContext; ownerId: string }> {
  const caller = await requireUser(req, { admin: s.admin });
  await requireShopRole(s.admin, caller, shopId, ROLES.owner);
  const context = await checkoutContext(s.admin, shopId, caller.id);
  // The RPC re-checks ownership (a transfer between the two reads).
  if (!context.is_owner) throw errors.forbidden("Only the shop owner can manage billing.");
  return { context, ownerId: caller.id };
}

/** The shop's current (active) owner's user id, or null (service role). */
async function currentOwnerId(admin: SupabaseClient, shopId: string): Promise<string | null> {
  const { data, error } = await admin
    .from("shop_members")
    .select("user_id")
    .eq("shop_id", shopId)
    .eq("role", "owner")
    .eq("active", true)
    .limit(1);
  if (error) throw dbFailure("shop_members lookup", error);
  return ((data ?? []) as { user_id: string }[])[0]?.user_id ?? null;
}

/**
 * Points the shop's platform customer at its current owner: the owner's
 * email (where Stripe sends receipts and failed-payment emails) and
 * metadata.owner_user_id (what sync_customers compares). true when Stripe
 * was updated; false when it already matched, the customer is gone, or the
 * owner has no email (the address is then left alone).
 */
async function syncCustomerContact(
  s: Services,
  shopId: string,
  customerId: string,
  ownerEmail: string | null,
  ownerId: string | null,
  known?: Stripe.Customer,
): Promise<boolean> {
  let customer: Stripe.Customer | Stripe.DeletedCustomer;
  try {
    customer = known ?? await s.stripe().customers.retrieve(customerId);
  } catch (err) {
    if (isStripeError(err) && (err.code === "resource_missing" || err.statusCode === 404)) {
      s.log.warn("billing_customer_missing", { shop_id: shopId, customer: customerId });
      return false;
    }
    throw err;
  }
  if ("deleted" in customer && customer.deleted) {
    s.log.warn("billing_customer_missing", { shop_id: shopId, customer: customerId });
    return false;
  }
  const current = customer as Stripe.Customer;
  const update: Stripe.CustomerUpdateParams = {};
  if (ownerEmail && current.email !== ownerEmail) update.email = ownerEmail;
  if (ownerId && current.metadata?.owner_user_id !== ownerId) {
    update.metadata = { owner_user_id: ownerId };
  }
  if (update.email === undefined && update.metadata === undefined) return false;
  await s.stripe().customers.update(customerId, update);
  s.log.info("billing_customer_contact_synced", {
    shop_id: shopId,
    customer: customerId,
    email_changed: update.email !== undefined,
  });
  return true;
}

/** syncCustomerContact where a failure must not block the owner (logged only). */
async function trySyncCustomerContact(
  s: Services,
  shopId: string,
  customerId: string,
  context: CheckoutContext,
  ownerId: string,
): Promise<void> {
  try {
    await syncCustomerContact(s, shopId, customerId, context.owner_email, ownerId);
  } catch (err) {
    s.log.warn("billing_customer_contact_sync_failed", {
      shop_id: shopId,
      customer: customerId,
      error: err instanceof Error ? err.message : String(err),
    });
  }
}

/**
 * subscription_data.trial_end (Unix seconds) for the shop's remaining in-app
 * trial, or null when there is none or it ends too soon for Stripe (then the
 * subscription starts, and is charged, right away).
 */
export function checkoutTrialEnd(trialEnd: string | null, now: number): number | null {
  if (!trialEnd) return null;
  const at = Date.parse(trialEnd);
  if (!Number.isFinite(at) || at - now < MIN_TRIAL_LEAD_MS) return null;
  return Math.floor(at / 1000);
}

/** A request's idempotency part: the client's nonce, else a 10-minute window. */
export function requestPart(nonce: string | undefined, now: number): string {
  return nonce ? `n:${nonce}` : `w:${Math.floor(now / IDEMPOTENCY_WINDOW_MS)}`;
}

/**
 * The session's expires_at (Unix seconds): CHECKOUT_TTL_MS after the end of
 * the current idempotency window, so identical requests in one window send
 * the same parameters (Stripe refuses a reused key with different ones).
 */
export function checkoutExpiresAt(now: number): number {
  const windowEnd = (Math.floor(now / IDEMPOTENCY_WINDOW_MS) + 1) * IDEMPOTENCY_WINDOW_MS;
  return (windowEnd + CHECKOUT_TTL_MS) / 1000;
}

function alreadySubscribed(pending = false): HttpError {
  return errors.conflict(
    pending
      ? "A payment for this shop's subscription is still being confirmed. " +
        "Refresh in a few minutes, or use Manage billing."
      : "This shop already has a subscription. Use Manage billing to change or cancel it.",
    { reason: "already_subscribed" },
  );
}

/**
 * Refuses a checkout while Stripe already has a subscription for the shop's
 * platform customer that can still bill (anything but canceled /
 * incomplete_expired), whatever the database says: a subscription just paid
 * for reaches shop_billing only when its webhook arrives.
 */
async function refuseIfSubscribedInStripe(
  s: Services,
  shopId: string,
  customer: string,
): Promise<void> {
  for await (
    const sub of s.stripe().subscriptions.list({ customer, status: "all", limit: 100 })
  ) {
    if (ENDED_SUBSCRIPTION.has(sub.status)) continue;
    s.log.warn("billing_checkout_refused", {
      shop_id: shopId,
      subscription: sub.id,
      status: sub.status,
    });
    throw alreadySubscribed(sub.status === "incomplete");
  }
}

function isOlder(a: Stripe.Checkout.Session, b: Stripe.Checkout.Session): boolean {
  return a.created < b.created || (a.created === b.created && a.id < b.id);
}

/**
 * Expires every open subscription checkout of the shop created before
 * `current`, so an earlier link left open in another tab or email can no
 * longer start a second subscription. An older one that completed meanwhile
 * did start one: `current` is expired too and the owner gets 409.
 */
async function expireOlderCheckouts(
  s: Services,
  shopId: string,
  customer: string,
  current: Stripe.Checkout.Session,
): Promise<void> {
  const stripe = s.stripe();
  for await (
    const session of stripe.checkout.sessions.list({ customer, status: "open", limit: 100 })
  ) {
    if (
      session.id === current.id || session.status !== "open" ||
      session.mode !== "subscription" || session.metadata?.shop_id !== shopId ||
      !isOlder(session, current)
    ) continue;
    try {
      await stripe.checkout.sessions.expire(session.id, {}, {
        idempotencyKey: await idempotencyKey("billing_checkout_expire", session.id),
      });
      s.log.info("billing_checkout_expired", { shop_id: shopId, session: session.id });
    } catch (err) {
      if (!isStripeError(err) || err.type !== "StripeInvalidRequestError") throw err;
      const now = await stripe.checkout.sessions.retrieve(session.id);
      if (now.status !== "complete") continue;
      s.log.warn("billing_checkout_raced", { shop_id: shopId, session: session.id });
      await stripe.checkout.sessions.expire(current.id, {}, {
        idempotencyKey: await idempotencyKey("billing_checkout_expire", current.id),
      });
      throw alreadySubscribed();
    }
  }
}

function billingUrl(s: Services, checkout?: "success" | "cancelled"): string {
  const url = `${s.env.appBaseUrl()}${BILLING_SETTINGS_PATH}`;
  return checkout ? withQuery(url, { checkout }) : url;
}

/**
 * The shop's platform Stripe customer: the linked one (readdressed to the
 * current owner first), else created and linked now.
 */
async function shopCustomer(
  s: Services,
  shopId: string,
  context: CheckoutContext,
  ownerId: string,
): Promise<string> {
  if (context.stripe_customer_id) {
    await trySyncCustomerContact(s, shopId, context.stripe_customer_id, context, ownerId);
    return context.stripe_customer_id;
  }
  const name = context.shop_name.trim();
  const customer = await s.stripe().customers.create(
    {
      ...(context.owner_email ? { email: context.owner_email } : {}),
      ...(name ? { name } : {}),
      metadata: { shop_id: shopId, owner_user_id: ownerId },
    },
    // Concurrent or retried first checkouts get the same customer.
    {
      idempotencyKey: await idempotencyKey(
        "billing_customer",
        shopId,
        context.owner_email ?? "",
        name,
        ownerId,
      ),
    },
  );
  if (!CUSTOMER_ID.test(customer.id)) throw new Error("Stripe returned an invalid customer id");
  const { error } = await s.admin.rpc("billing_link_customer", {
    p_shop_id: shopId,
    p_stripe_customer_id: customer.id,
  });
  if (error) {
    // The Stripe customer made above stays unused (no subscription, no
    // charge); logged so the operator can tidy it up.
    s.log.warn("billing_customer_not_linked", {
      shop_id: shopId,
      customer: customer.id,
      code: error.code ?? null,
    });
    throw linkCustomerError(error);
  }
  s.log.info("billing_customer_created", { shop_id: shopId, customer: customer.id });
  return customer.id;
}

export async function checkout(
  s: Services,
  req: Request,
  input: z.output<typeof checkoutInput>,
): Promise<{ url: string }> {
  const { context, ownerId } = await requireOwner(s, req, input.shop_id);
  if (!context.billing_enabled) {
    throw errors.unprocessable("Subscriptions are not available yet.", {
      reason: "billing_disabled",
    });
  }
  if (context.has_live_subscription) throw alreadySubscribed();
  const { data: plan, error } = await s.admin
    .from("platform_plans")
    .select("id, stripe_price_id")
    .eq("id", input.plan_id)
    .eq("active", true)
    .maybeSingle<{ id: string; stripe_price_id: string }>();
  if (error) throw dbFailure("platform_plans lookup", error);
  if (!plan) {
    throw new HttpError(
      "not_found",
      "This plan is not available. Refresh to see the current plans.",
      {
        details: { reason: "plan_not_found" },
      },
    );
  }

  // A customer created just now has no subscriptions yet.
  if (context.stripe_customer_id) {
    await refuseIfSubscribedInStripe(s, input.shop_id, context.stripe_customer_id);
  }
  const customer = await shopCustomer(s, input.shop_id, context, ownerId);
  const expiresAt = checkoutExpiresAt(s.now);
  const trialEnd = checkoutTrialEnd(context.trial_end, s.now);
  // Optional Stripe Tax (BILLING_AUTOMATIC_TAX): Checkout collects the address
  // it needs and saves it on the shop's platform customer for renewals.
  const tax = s.env.billingAutomaticTax();
  const session = await s.stripe().checkout.sessions.create(
    {
      mode: "subscription",
      customer,
      line_items: [{ price: plan.stripe_price_id, quantity: 1 }],
      client_reference_id: input.shop_id,
      metadata: { shop_id: input.shop_id },
      subscription_data: {
        metadata: { shop_id: input.shop_id },
        ...(trialEnd !== null ? { trial_end: trialEnd } : {}),
      },
      allow_promotion_codes: true,
      ...(tax ? { automatic_tax: { enabled: true }, customer_update: { address: "auto" } } : {}),
      success_url: billingUrl(s, "success"),
      cancel_url: billingUrl(s, "cancelled"),
      expires_at: expiresAt,
    },
    {
      idempotencyKey: await idempotencyKey(
        "billing_checkout",
        input.shop_id,
        plan.id,
        plan.stripe_price_id,
        customer,
        trialEnd ?? 0,
        tax ? "tax" : "no_tax",
        expiresAt,
        requestPart(input.request_nonce, s.now),
      ),
    },
  );
  if (!session.url) throw new Error("Stripe returned a Checkout Session without a URL");
  await expireOlderCheckouts(s, input.shop_id, customer, session);
  s.log.info("billing_checkout_created", {
    shop_id: input.shop_id,
    plan_id: plan.id,
    session: session.id,
    trial: trialEnd !== null,
  });
  return { url: session.url };
}

/**
 * Stripe answers a portal session without a saved default Customer Portal
 * configuration (Dashboard -> Settings -> Billing -> Customer portal) with an
 * invalid_request_error naming the portal settings.
 */
export function isPortalNotConfigured(err: unknown): boolean {
  if (!isStripeError(err) || err.type !== "StripeInvalidRequestError") return false;
  return /customer portal settings|portal configuration|default configuration|settings\/billing\/portal/i
    .test(err.message ?? "");
}

export async function portal(
  s: Services,
  req: Request,
  input: z.output<typeof portalInput>,
): Promise<{ url: string }> {
  // Deliberately not gated on billing_enabled: a shop keeps managing (and
  // cancelling) an existing subscription whatever the platform flag says.
  const { context, ownerId } = await requireOwner(s, req, input.shop_id);
  if (!context.stripe_customer_id) {
    throw errors.conflict("This shop has no billing account yet. Choose a plan first.", {
      reason: "no_billing_account",
    });
  }
  // A new owner managing billing gets Stripe's emails from now on.
  await trySyncCustomerContact(s, input.shop_id, context.stripe_customer_id, context, ownerId);
  let session: Stripe.BillingPortal.Session;
  try {
    session = await s.stripe().billingPortal.sessions.create({
      customer: context.stripe_customer_id,
      return_url: billingUrl(s),
    });
  } catch (err) {
    if (isPortalNotConfigured(err)) {
      throw new HttpError(
        "service_unavailable",
        "Billing management is not set up yet. Please contact support.",
        { details: { reason: "portal_not_configured" }, cause: err },
      );
    }
    throw err;
  }
  if (!session.url) throw new Error("Stripe returned a billing portal session without a URL");
  return { url: session.url };
}

/**
 * sync_customer: after an ownership transfer the client asks for the shop's
 * platform customer to follow the new owner. Owner or admin (the former
 * owner is an admin once the transfer is done); nothing else changes.
 */
export async function syncCustomer(
  s: Services,
  req: Request,
  input: z.output<typeof syncCustomerInput>,
): Promise<{ synced: boolean }> {
  const caller = await requireUser(req, { admin: s.admin });
  await requireShopRole(s.admin, caller, input.shop_id, ROLES.adminPlus);
  const context = await checkoutContext(s.admin, input.shop_id, caller.id);
  if (!context.stripe_customer_id) return { synced: false };
  const ownerId = await currentOwnerId(s.admin, input.shop_id);
  return {
    synced: await syncCustomerContact(
      s,
      input.shop_id,
      context.stripe_customer_id,
      context.owner_email,
      ownerId,
    ),
  };
}

export interface CustomerSyncSummary {
  checked: number;
  updated: number;
  failed: number;
}

/**
 * sync_customers (daily): every platform customer tagged with a shop
 * (metadata.shop_id) whose metadata.owner_user_id is not that shop's current
 * owner (an ownership transfer, or a customer created before this field
 * existed) is readdressed, provided it is the customer the shop is linked to
 * (billing_checkout_context). Customers of the platform account that belong
 * to no shop are never touched.
 */
export async function syncCustomers(s: Services): Promise<CustomerSyncSummary> {
  const summary: CustomerSyncSummary = { checked: 0, updated: 0, failed: 0 };
  const page: Stripe.Customer[] = [];
  const flush = async () => {
    const batch = page.splice(0, page.length);
    if (batch.length === 0) return;
    const shopIds = [...new Set(batch.map((c) => c.metadata.shop_id as string))];
    const { data, error } = await s.admin
      .from("shop_members")
      .select("shop_id, user_id")
      .in("shop_id", shopIds)
      .eq("role", "owner")
      .eq("active", true);
    if (error) throw dbFailure("shop_members lookup", error);
    const owners = new Map(
      ((data ?? []) as { shop_id: string; user_id: string }[]).map((r) => [r.shop_id, r.user_id]),
    );
    for (const customer of batch) {
      summary.checked += 1;
      const shopId = customer.metadata.shop_id as string;
      const ownerId = owners.get(shopId) ?? null;
      if (!ownerId || customer.metadata.owner_user_id === ownerId) continue;
      try {
        const context = await checkoutContext(s.admin, shopId, null);
        // Not the shop's billing customer (an unlinked leftover): leave it.
        if (context.stripe_customer_id !== customer.id) continue;
        if (
          await syncCustomerContact(s, shopId, customer.id, context.owner_email, ownerId, customer)
        ) {
          summary.updated += 1;
        }
      } catch (err) {
        if (err instanceof HttpError && err.status === 404) continue; // shop deleted
        summary.failed += 1;
        s.log.warn("billing_customer_contact_sync_failed", {
          shop_id: shopId,
          customer: customer.id,
          error: err instanceof Error ? err.message : String(err),
        });
      }
    }
  };
  for await (const customer of s.stripe().customers.list({ limit: 100 })) {
    const shopId = customer.metadata?.shop_id;
    if (typeof shopId !== "string" || !UUID_RE.test(shopId)) continue;
    page.push(customer);
    if (page.length >= 100) await flush();
  }
  await flush();
  s.log.info("billing_customers_synced", { ...summary });
  return summary;
}

export function makeHandler(deps: Deps = {}): (req: Request) => Promise<Response> {
  let stripeClient: Stripe | undefined;
  const services = (ctx: { env: Env; log: Logger }): Services => ({
    admin: adminClient({ env: deps.env, fetch: deps.fetch }),
    stripe: () =>
      stripeClient ??= deps.fetch
        ? stripeFromEnv(ctx.env, { fetch: deps.fetch, maxNetworkRetries: 0 })
        : stripeFromEnv(ctx.env),
    env: ctx.env,
    log: ctx.log,
    now: deps.now ? deps.now() : Date.now(),
  });

  const router = createActionRouter({
    plans: jsonAction(emptyInput, async (_input, ctx) => {
      const s = services(ctx);
      await requireUser(ctx.req, { admin: s.admin });
      return await listPlans(s, userClient(ctx.req, { env: ctx.env, fetch: deps.fetch }));
    }),
    checkout: jsonAction(checkoutInput, (input, ctx) => checkout(services(ctx), ctx.req, input)),
    portal: jsonAction(portalInput, (input, ctx) => portal(services(ctx), ctx.req, input)),
    sync_customer: jsonAction(
      syncCustomerInput,
      (input, ctx) => syncCustomer(services(ctx), ctx.req, input),
    ),
    sync_customers: jsonAction(emptyInput, async (_input, ctx) => {
      requireCronSecret(ctx.req, ctx.env.cronSecret());
      return await syncCustomers(services(ctx));
    }),
    sync_plans: jsonAction(emptyInput, async (_input, ctx) => {
      requireCronSecret(ctx.req, ctx.env.cronSecret());
      const s = services(ctx);
      return await syncPlans({ stripe: s.stripe(), admin: s.admin, log: ctx.log });
    }),
  });
  return createHandler(
    { name: "billing", env: deps.env, logger: deps.logger },
    (req, ctx) => router(req, ctx),
  );
}

if (import.meta.main) Deno.serve(makeHandler());
