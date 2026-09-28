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
 *               with BILLING_AUTOMATIC_TAX=true (off by default).
 *   portal      {shop_id}                           owner only -> {url}
 *               Stripe Customer Portal (plan changes, cancellation, card).
 *   sync_plans  {}                                  pg_cron / deploy (x-cron-secret)
 *               -> {upserted, deactivated, skipped, warnings}
 *
 * verify_jwt = false (config.toml): pg_cron and the deploy call sync_plans
 * without a Supabase JWT. plans / checkout / portal verify the caller's
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

const CUSTOMER_ID = /^cus_[A-Za-z0-9]+$/;

const emptyInput = z.object({}).strict();
const checkoutInput = z.object({
  shop_id: uuid,
  plan_id: uuid,
  request_nonce: requestNonce.optional(),
}).strict();
const portalInput = z.object({ shop_id: uuid }).strict();

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
        cause: error,
      });
    default:
      return dbFailure(what, error);
  }
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
  userId: string,
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
async function requireOwner(s: Services, req: Request, shopId: string): Promise<CheckoutContext> {
  const caller = await requireUser(req, { admin: s.admin });
  await requireShopRole(s.admin, caller, shopId, ROLES.owner);
  const context = await checkoutContext(s.admin, shopId, caller.id);
  // The RPC re-checks ownership (a transfer between the two reads).
  if (!context.is_owner) throw errors.forbidden("Only the shop owner can manage billing.");
  return context;
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

function billingUrl(s: Services, checkout?: "success" | "cancelled"): string {
  const url = `${s.env.appBaseUrl()}${BILLING_SETTINGS_PATH}`;
  return checkout ? withQuery(url, { checkout }) : url;
}

/** The shop's platform Stripe customer: the linked one, else created and linked now. */
async function shopCustomer(
  s: Services,
  shopId: string,
  context: CheckoutContext,
): Promise<string> {
  if (context.stripe_customer_id) return context.stripe_customer_id;
  const name = context.shop_name.trim();
  const customer = await s.stripe().customers.create(
    {
      ...(context.owner_email ? { email: context.owner_email } : {}),
      ...(name ? { name } : {}),
      metadata: { shop_id: shopId },
    },
    // Concurrent or retried first checkouts get the same customer.
    {
      idempotencyKey: await idempotencyKey(
        "billing_customer",
        shopId,
        context.owner_email ?? "",
        name,
      ),
    },
  );
  if (!CUSTOMER_ID.test(customer.id)) throw new Error("Stripe returned an invalid customer id");
  const { error } = await s.admin.rpc("billing_link_customer", {
    p_shop_id: shopId,
    p_stripe_customer_id: customer.id,
  });
  if (error) throw rpcError("billing_link_customer", error);
  s.log.info("billing_customer_created", { shop_id: shopId, customer: customer.id });
  return customer.id;
}

export async function checkout(
  s: Services,
  req: Request,
  input: z.output<typeof checkoutInput>,
): Promise<{ url: string }> {
  const context = await requireOwner(s, req, input.shop_id);
  if (!context.billing_enabled) {
    throw errors.unprocessable("Subscriptions are not available yet.", {
      reason: "billing_disabled",
    });
  }
  if (context.has_live_subscription) {
    throw errors.conflict(
      "This shop already has a subscription. Use Manage billing to change or cancel it.",
      { reason: "already_subscribed" },
    );
  }
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

  const customer = await shopCustomer(s, input.shop_id, context);
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
        requestPart(input.request_nonce, s.now),
      ),
    },
  );
  if (!session.url) throw new Error("Stripe returned a Checkout Session without a URL");
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
  const context = await requireOwner(s, req, input.shop_id);
  if (!context.stripe_customer_id) {
    throw errors.conflict("This shop has no billing account yet. Choose a plan first.", {
      reason: "no_billing_account",
    });
  }
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
