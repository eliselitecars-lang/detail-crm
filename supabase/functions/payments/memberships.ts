/**
 * Membership billing (manager+):
 *   membership_checkout  Checkout (mode subscription) link for an incomplete
 *                        membership; the plan's Product/Price live on the
 *                        shop's connected account and are created lazily.
 *   membership_checkout  (a new link expires the membership's older open links)
 *   membership_cancel    cancel now, or at the end of the paid period. A
 *                        never-billed membership's open links are expired
 *                        first; a cancelled membership that Stripe still
 *                        bills (link completed after the cancel) is stopped.
 * Subscription state is written back with sync_stripe_subscription (the
 * webhook remains the source of truth and replays are harmless).
 */
import { z } from "zod";
import { requireShopRole, requireUser, ROLES } from "../_shared/auth.ts";
import { errors } from "../_shared/errors.ts";
import { links, withQuery } from "../_shared/links.ts";
import { requestNonce, uuid } from "../_shared/schemas.ts";
import { idempotencyKey, onAccount, type Stripe } from "../_shared/stripe.ts";
import {
  type AccountRow,
  chargeable,
  createCheckoutSession,
  customerSessions,
  dbFailure,
  ensureStripeCustomer,
  expireOpenSessions,
  findAccount,
  loadAccount,
  loadCustomer,
  loadShop,
  metadata,
  requestPart,
  rpcError,
  type Services,
  sessionFor,
  type ShopRow,
} from "./lib.ts";

export const membershipCheckoutInput = z.object({
  shop_id: uuid,
  membership_id: uuid,
  request_nonce: requestNonce.optional(),
}).strict();

export const membershipCancelInput = z.object({
  shop_id: uuid,
  membership_id: uuid,
  at_period_end: z.boolean().optional(),
}).strict();

export type MembershipStatus = "incomplete" | "active" | "past_due" | "cancelled";

export interface MembershipRow {
  id: string;
  shop_id: string;
  plan_id: string;
  customer_id: string;
  vehicle_id: string | null;
  status: MembershipStatus;
  stripe_subscription_id: string | null;
  cancel_at_period_end: boolean;
  current_period_end: string | null;
}

interface PlanRow {
  id: string;
  shop_id: string;
  name: string;
  description: string | null;
  price_cents: number;
  interval: "month" | "year";
  interval_count: number;
  active: boolean;
  archived_at: string | null;
  stripe_product_id: string | null;
  stripe_price_id: string | null;
}

/** Stripe subscription status -> membership_status (SPEC §4.5). */
export function membershipStatusOf(status: Stripe.Subscription.Status): MembershipStatus {
  switch (status) {
    case "active":
    case "trialing":
      return "active";
    case "past_due":
    case "unpaid":
    case "paused":
      return "past_due";
    case "canceled":
    case "incomplete_expired":
      return "cancelled";
    default:
      return "incomplete";
  }
}

/** Latest period end across the subscription's items (API 2025+ keeps it per item). */
export function periodEndOf(subscription: Stripe.Subscription): string | null {
  const ends = (subscription.items?.data ?? [])
    .map((item) => item.current_period_end)
    .filter((value): value is number => typeof value === "number");
  return ends.length ? new Date(Math.max(...ends) * 1000).toISOString() : null;
}

export const MEMBERSHIP_COLUMNS =
  "id, shop_id, plan_id, customer_id, vehicle_id, status, stripe_subscription_id, cancel_at_period_end, current_period_end";

async function loadMembership(
  s: Services,
  shopId: string,
  membershipId: string,
): Promise<MembershipRow> {
  const { data, error } = await s.admin
    .from("memberships")
    .select(MEMBERSHIP_COLUMNS)
    .eq("shop_id", shopId)
    .eq("id", membershipId)
    .maybeSingle();
  if (error) throw dbFailure("memberships lookup", error);
  if (!data) throw errors.notFound("Membership not found.");
  return data as MembershipRow;
}

async function loadPlan(s: Services, shopId: string, planId: string): Promise<PlanRow> {
  const { data, error } = await s.admin
    .from("membership_plans")
    .select(
      "id, shop_id, name, description, price_cents, interval, interval_count, active, archived_at, stripe_product_id, stripe_price_id",
    )
    .eq("shop_id", shopId)
    .eq("id", planId)
    .maybeSingle();
  if (error) throw dbFailure("membership_plans lookup", error);
  if (!data) throw errors.notFound("Membership plan not found.");
  return data as PlanRow;
}

function isMissing(err: unknown): boolean {
  if (typeof err !== "object" || err === null) return false;
  const e = err as { type?: unknown; code?: unknown };
  return e.type === "StripeInvalidRequestError" && e.code === "resource_missing";
}

function priceMatches(price: Stripe.Price, plan: PlanRow, currency: string): boolean {
  return price.active &&
    price.unit_amount === plan.price_cents &&
    price.currency === currency &&
    price.recurring?.interval === plan.interval &&
    price.recurring?.interval_count === plan.interval_count;
}

/**
 * The plan's recurring Price on the connected account. Reuses the stored
 * price while it still matches the plan's current terms; otherwise creates a
 * new Price (Stripe prices are immutable; existing subscribers keep theirs)
 * and stores the ids via service role — only if the plan's terms are still
 * the ones the price was made for.
 */
async function ensurePlanPrice(
  s: Services,
  account: AccountRow,
  shop: ShopRow,
  plan: PlanRow,
): Promise<string> {
  const onAcct = onAccount(account.stripe_account_id);
  if (plan.stripe_price_id) {
    try {
      const price = await s.stripe.prices.retrieve(plan.stripe_price_id, {}, onAcct);
      if (priceMatches(price, plan, shop.currency)) return price.id;
    } catch (err) {
      if (!isMissing(err)) throw err;
    }
  }

  let productId: string | null = null;
  if (plan.stripe_product_id) {
    try {
      const product = await s.stripe.products.retrieve(plan.stripe_product_id, {}, onAcct);
      if (!("deleted" in product && product.deleted)) productId = product.id;
    } catch (err) {
      if (!isMissing(err)) throw err;
    }
  }
  if (!productId) {
    const product = await s.stripe.products.create(
      {
        name: plan.name,
        ...(plan.description?.trim()
          ? { description: plan.description.trim().slice(0, 1000) }
          : {}),
        metadata: metadata({ shop_id: shop.id, plan_id: plan.id }),
      },
      onAccount(account.stripe_account_id, {
        idempotencyKey: await idempotencyKey(
          "membership_product",
          plan.id,
          account.stripe_account_id,
          plan.stripe_product_id ?? "none",
        ),
      }),
    );
    productId = product.id;
  }

  const price = await s.stripe.prices.create(
    {
      product: productId,
      currency: shop.currency,
      unit_amount: plan.price_cents,
      recurring: { interval: plan.interval, interval_count: plan.interval_count },
      metadata: metadata({ shop_id: shop.id, plan_id: plan.id }),
    },
    onAccount(account.stripe_account_id, {
      idempotencyKey: await idempotencyKey(
        "membership_price",
        plan.id,
        productId,
        shop.currency,
        plan.price_cents,
        plan.interval,
        plan.interval_count,
      ),
    }),
  );

  const { data, error } = await s.admin
    .from("membership_plans")
    .update({ stripe_product_id: productId, stripe_price_id: price.id })
    .eq("shop_id", plan.shop_id)
    .eq("id", plan.id)
    .eq("price_cents", plan.price_cents)
    .eq("interval", plan.interval)
    .eq("interval_count", plan.interval_count)
    .select("id");
  if (error) throw dbFailure("membership_plans stripe ids update", error);
  if (!Array.isArray(data) || data.length === 0) {
    throw errors.conflict("The plan's price changed while preparing checkout. Try again.", {
      reason: "plan_changed",
    });
  }
  return price.id;
}

const ENDED_SUBSCRIPTION = new Set<string>(["canceled", "incomplete_expired"]);

/** The subscription is still live in Stripe (not ended, not missing). */
async function isLive(
  s: Services,
  account: AccountRow,
  subscriptionId: string,
): Promise<boolean> {
  try {
    const subscription = await s.stripe.subscriptions.retrieve(
      subscriptionId,
      {},
      onAccount(account.stripe_account_id),
    );
    return !ENDED_SUBSCRIPTION.has(subscription.status);
  } catch (err) {
    if (isMissing(err)) return false;
    throw err;
  }
}

function sessionSubscription(session: Stripe.Checkout.Session): string | null {
  return typeof session.subscription === "string"
    ? session.subscription
    : session.subscription?.id ?? null;
}

/** Cancels a subscription that is still live in Stripe; false when already ended/missing. */
async function cancelIfLive(
  s: Services,
  account: AccountRow,
  membership: MembershipRow,
  subscriptionId: string,
): Promise<boolean> {
  if (!(await isLive(s, account, subscriptionId))) return false;
  await s.stripe.subscriptions.cancel(
    subscriptionId,
    {},
    onAccount(account.stripe_account_id, {
      idempotencyKey: await idempotencyKey(
        "membership_stray_cancel",
        membership.id,
        subscriptionId,
      ),
    }),
  );
  s.log.warn("membership_stray_subscription_cancelled", {
    shop_id: membership.shop_id,
    membership_id: membership.id,
    subscription: subscriptionId,
  });
  return true;
}

/**
 * Closes a membership's Checkout links: expires the open ones and cancels
 * any subscription a completed one started (the webhook may not have linked
 * it yet). Returns how many live subscriptions were stopped.
 */
export async function closeMembershipCheckout(
  s: Services,
  membership: MembershipRow,
): Promise<number> {
  const account = await findAccount(s.admin, membership.shop_id);
  if (!account) return 0;
  const customer = await loadCustomer(s.admin, membership.shop_id, membership.customer_id);
  if (!customer.stripe_customer_id) return 0; // no checkout was ever created
  const match = sessionFor.membership(membership.shop_id, membership.id);
  await expireOpenSessions(s, account, customer.stripe_customer_id, match);
  let stopped = 0;
  for (
    const session of await customerSessions(s, account, customer.stripe_customer_id, "complete")
  ) {
    if (!match(session)) continue;
    const sub = sessionSubscription(session);
    if (sub && await cancelIfLive(s, account, membership, sub)) stopped += 1;
  }
  return stopped;
}

/** A cancelled membership must not bill: stop its linked or stray subscriptions. */
async function stopStrayBilling(s: Services, membership: MembershipRow): Promise<number> {
  let stopped = 0;
  if (membership.stripe_subscription_id) {
    const account = await findAccount(s.admin, membership.shop_id);
    if (account && await cancelIfLive(s, account, membership, membership.stripe_subscription_id)) {
      stopped += 1;
    }
  }
  return stopped + await closeMembershipCheckout(s, membership);
}

export async function membershipCheckout(
  s: Services,
  req: Request,
  input: z.output<typeof membershipCheckoutInput>,
): Promise<Record<string, unknown>> {
  const caller = await requireUser(req, { admin: s.admin });
  await requireShopRole(s.admin, caller, input.shop_id, ROLES.managerPlus);
  const membership = await loadMembership(s, input.shop_id, input.membership_id);
  if (membership.status !== "incomplete" || membership.stripe_subscription_id) {
    throw errors.conflict(`This membership is ${membership.status}; it does not need checkout.`, {
      reason: "membership_not_incomplete",
    });
  }
  const plan = await loadPlan(s, membership.shop_id, membership.plan_id);
  if (!plan.active || plan.archived_at) {
    throw errors.unprocessable("This membership plan is not available.", {
      reason: "plan_unavailable",
    });
  }
  const shop = await loadShop(s.admin, membership.shop_id);
  const account = await loadAccount(s.admin, shop.id);
  chargeable(plan.price_cents, shop.currency);
  const customer = await loadCustomer(s.admin, shop.id, membership.customer_id);
  const stripeCustomer = await ensureStripeCustomer(s, account, customer);
  // A link that was already paid started a subscription the webhook has not
  // linked yet: a second link would start a second, orphan subscription
  // (sync_stripe_subscription refuses it and it would bill unrecorded).
  const match = sessionFor.membership(shop.id, membership.id);
  for (const session of await customerSessions(s, account, stripeCustomer, "complete")) {
    const sub = match(session) ? sessionSubscription(session) : null;
    if (sub && await isLive(s, account, sub)) {
      throw errors.conflict(
        "This membership's payment link was already paid; it activates in a moment.",
        { reason: "membership_checkout_completed" },
      );
    }
  }
  const priceId = await ensurePlanPrice(s, account, shop, plan);

  const meta = metadata({
    shop_id: shop.id,
    membership_id: membership.id,
    plan_id: plan.id,
    customer_id: membership.customer_id,
    kind: "membership",
  });
  const feeBps = s.env.platformFeeBps();
  const portal = links.portal(s.env.appBaseUrl());
  const session = await createCheckoutSession(
    s,
    account,
    {
      mode: "subscription",
      customer: stripeCustomer,
      payment_method_types: ["card"],
      client_reference_id: membership.id,
      line_items: [{ price: priceId, quantity: 1 }],
      subscription_data: {
        metadata: meta,
        // bps -> percent with at most two decimals (Stripe's precision).
        ...(feeBps > 0 ? { application_fee_percent: feeBps / 100 } : {}),
      },
      metadata: meta,
      success_url: withQuery(portal, { membership: "active" }),
      cancel_url: withQuery(portal, { membership: "canceled" }),
    },
    "membership_checkout",
    [membership.id, priceId, stripeCustomer, requestPart(input.request_nonce, s.now)],
  );
  // One live link per membership: two completed links would start two
  // subscriptions for one membership.
  await expireOpenSessions(s, account, stripeCustomer, match, session.id);
  return {
    url: session.url,
    expires_at: session.expires_at,
    amount_cents: plan.price_cents,
    interval: plan.interval,
    interval_count: plan.interval_count,
    currency: shop.currency,
  };
}

export async function membershipCancel(
  s: Services,
  req: Request,
  input: z.output<typeof membershipCancelInput>,
): Promise<Record<string, unknown>> {
  const caller = await requireUser(req, { admin: s.admin });
  await requireShopRole(s.admin, caller, input.shop_id, ROLES.managerPlus);
  const membership = await loadMembership(s, input.shop_id, input.membership_id);
  const atPeriodEnd = input.at_period_end ?? false;

  if (membership.status === "cancelled") {
    // Cancelled in the CRM but possibly still billing in Stripe (a checkout
    // link completed after the cancel): stop it instead of refusing.
    const stopped = await stopStrayBilling(s, membership);
    if (!stopped) {
      throw errors.conflict("This membership is already cancelled.", {
        reason: "already_cancelled",
      });
    }
    return {
      membership_id: membership.id,
      status: "cancelled",
      cancel_at_period_end: false,
      current_period_end: membership.current_period_end,
      stopped_subscriptions: stopped,
    };
  }

  if (!membership.stripe_subscription_id) {
    // Never billed: close its checkout links first (and stop a subscription
    // a link already started), then abandon it (incomplete -> cancelled).
    await closeMembershipCheckout(s, membership);
    const { data, error } = await s.admin
      .from("memberships")
      .update({ status: "cancelled" })
      .eq("shop_id", membership.shop_id)
      .eq("id", membership.id)
      .eq("status", "incomplete")
      .is("stripe_subscription_id", null)
      .select("id, status");
    if (error) throw dbFailure("memberships cancel", error);
    if (!Array.isArray(data) || data.length === 0) {
      throw errors.conflict("This membership changed; refresh and try again.", {
        reason: "membership_changed",
      });
    }
    return {
      membership_id: membership.id,
      status: "cancelled",
      cancel_at_period_end: false,
      current_period_end: membership.current_period_end,
    };
  }

  const account = await loadAccount(s.admin, membership.shop_id, { requireCharges: false });
  const key = await idempotencyKey(
    "membership_cancel",
    membership.id,
    membership.stripe_subscription_id,
    atPeriodEnd ? "period_end" : "now",
  );
  const subscription = atPeriodEnd
    ? await s.stripe.subscriptions.update(
      membership.stripe_subscription_id,
      { cancel_at_period_end: true },
      onAccount(account.stripe_account_id, { idempotencyKey: key }),
    )
    : await s.stripe.subscriptions.cancel(
      membership.stripe_subscription_id,
      {},
      onAccount(account.stripe_account_id, { idempotencyKey: key }),
    );

  const status = membershipStatusOf(subscription.status);
  const periodEnd = periodEndOf(subscription) ?? membership.current_period_end;
  const synced = await s.admin.rpc("sync_stripe_subscription", {
    p_shop_id: membership.shop_id,
    p_subscription_id: membership.stripe_subscription_id,
    p_status: status,
    p_current_period_end: periodEnd,
    p_cancel_at_period_end: subscription.cancel_at_period_end === true,
    p_membership_id: membership.id,
  });
  if (synced.error) {
    // Stripe has the change; the subscription webhook will reconcile.
    s.log.error("membership_sync_failed", {
      shop_id: membership.shop_id,
      membership_id: membership.id,
      error: rpcError("sync_stripe_subscription", synced.error),
    });
  }
  const row = synced.data as { status?: string; cancel_at_period_end?: boolean } | null;
  return {
    membership_id: membership.id,
    status: row?.status ?? status,
    cancel_at_period_end: row?.cancel_at_period_end ?? subscription.cancel_at_period_end === true,
    current_period_end: periodEnd,
  };
}
