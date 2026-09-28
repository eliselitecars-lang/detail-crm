/**
 * Membership billing:
 *   membership_checkout       manager+: Checkout (mode subscription) link for
 *                             an incomplete membership; the plan's
 *                             Product/Price live on the shop's connected
 *                             account and are created lazily (weekly,
 *                             monthly or yearly). A new link expires the
 *                             membership's older open links.
 *   membership_cancel         manager+: cancel now, or at the end of the paid
 *                             period. A never-billed membership's open links
 *                             are expired first; a cancelled membership that
 *                             Stripe still bills (link completed after the
 *                             cancel) is stopped.
 *   membership_join_checkout  PUBLIC by shop slug (/join/<slug>, P-23): the
 *                             customer joins an online plan; the membership
 *                             is prepared by membership_join_prepare (0069)
 *                             and paid through the same subscription Checkout.
 *   portal_membership_cancel  signed-in client (portal): cancel at the end of
 *                             the paid period (never immediately).
 *   portal_billing_portal     signed-in client: Stripe's billing portal on the
 *                             shop's account to update the card and see
 *                             billing history (cancelling stays in the CRM).
 * Subscription state is written back with sync_stripe_subscription (the
 * webhook remains the source of truth and replays are harmless).
 */
import { z } from "zod";
import { requireShopRole, requireUser, ROLES } from "../_shared/auth.ts";
import { errors, HttpError } from "../_shared/errors.ts";
import { links, withQuery } from "../_shared/links.ts";
import { email, requestNonce, uuid } from "../_shared/schemas.ts";
import { idempotencyKey, onAccount, type Stripe } from "../_shared/stripe.ts";
import {
  type AccountRow,
  appPage,
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
  loadShopBySlug,
  metadata,
  publicValidationMessage,
  requestPart,
  rpcError,
  type Services,
  sessionFor,
  type ShopRow,
  SLUG_RE,
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

const trimmed = (max: number) => z.string().trim().min(1).max(max);

export const membershipJoinCheckoutInput = z.object({
  slug: z.string().regex(SLUG_RE, "must be a shop link name"),
  plan_id: uuid,
  customer: z.object({
    first_name: trimmed(100),
    last_name: trimmed(100).optional(),
    email: z.string().trim().max(254).pipe(email),
    /** Any common format; the database normalises it to E.164 for the shop's country. */
    phone: z.string().trim().min(7).max(32).optional(),
    sms_opt_in: z.boolean().optional(),
    email_opt_in: z.boolean().optional(),
  }).strict(),
  /** The vehicle the membership covers (vehicle-scoped plans); optional. */
  vehicle: z.object({
    year: z.number().int().min(1886).max(2100).optional(),
    make: trimmed(60),
    model: trimmed(60),
  }).strict().optional(),
  request_nonce: requestNonce.optional(),
}).strict();

export const portalMembershipInput = z.object({ membership_id: uuid }).strict();

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
  interval: "week" | "month" | "year";
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

/** Most updates sent when idempotent replays keep returning a stale subscription. */
const MAX_CANCEL_ATTEMPTS = 4;

/**
 * Sets cancel_at_period_end on the subscription and returns its CURRENT
 * state. Stripe's idempotency layer replays the first response stored under
 * a key for 24 hours without running the request again: after the
 * subscription was resumed (for example in the Stripe Dashboard), a second
 * cancel under the same key would get the old "cancelling" body while Stripe
 * keeps billing, and the CRM would show a cancellation that never happened
 * (no webhook corrects it, since nothing changed in Stripe). So the key also
 * carries the 10-minute window, the subscription is re-read after every
 * update, and while it is still not cancelling the update is sent again under
 * a key chained on the attempt.
 */
async function cancelAtPeriodEnd(
  s: Services,
  account: AccountRow,
  subscriptionId: string,
  scope: string,
  parts: ReadonlyArray<string>,
): Promise<Stripe.Subscription> {
  const window = requestPart(undefined, s.now);
  const chain: string[] = [];
  for (let attempt = 0; attempt < MAX_CANCEL_ATTEMPTS; attempt++) {
    await s.stripe.subscriptions.update(
      subscriptionId,
      { cancel_at_period_end: true },
      onAccount(account.stripe_account_id, {
        idempotencyKey: await idempotencyKey(scope, ...parts, window, ...chain),
      }),
    );
    const current = await s.stripe.subscriptions.retrieve(
      subscriptionId,
      {},
      onAccount(account.stripe_account_id),
    );
    if (current.cancel_at_period_end === true || ENDED_SUBSCRIPTION.has(current.status)) {
      return current;
    }
    chain.push(`retry:${attempt + 1}`);
  }
  throw errors.conflict("This membership keeps changing. Refresh and try again.", {
    reason: "membership_changed",
  });
}

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
  const shop = await loadShop(s.admin, membership.shop_id);
  const portal = links.portal(s.env.appBaseUrl());
  return await subscriptionCheckout(s, shop, membership, {
    successUrl: withQuery(portal, { membership: "active" }),
    cancelUrl: withQuery(portal, { membership: "canceled" }),
    nonce: input.request_nonce,
    source: "membership_checkout",
  });
}

/**
 * The subscription Checkout of an incomplete membership (staff link or the
 * public join page): the plan's recurring Price on the connected account,
 * one live link per membership, 409 when an earlier link was already paid.
 */
async function subscriptionCheckout(
  s: Services,
  shop: ShopRow,
  membership: MembershipRow,
  options: { successUrl: string; cancelUrl: string; nonce: string | undefined; source: string },
): Promise<Record<string, unknown>> {
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
    source: options.source,
  });
  const feeBps = s.env.platformFeeBps();
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
      success_url: options.successUrl,
      cancel_url: options.cancelUrl,
    },
    "membership_checkout",
    [membership.id, priceId, stripeCustomer, requestPart(options.nonce, s.now)],
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

// ---------------------------------------------------------------------------
// membership_join_checkout (PUBLIC, /join/<slug>)
// ---------------------------------------------------------------------------

interface JoinPrepared {
  membership_id: string;
  customer_id: string;
  shop_id: string;
}

/**
 * A customer joins one of the shop's online plans. membership_join_prepare
 * (0069, service role) owns the rules: the plan is active and sold online,
 * the customer is matched like an online booking (never overwritten) or
 * created, the vehicle is reused or added, a never-billed membership of a
 * retried join is reused, and at most 3 online joins per email per 24 h.
 * Then the same subscription Checkout as membership_checkout; the webhook
 * activates the membership (managers get 'membership_joined').
 */
/** The public join answer when the details match an existing membership of the plan. */
export const JOIN_UNAVAILABLE_MESSAGE =
  "We can't start this sign-up online. If you're already a member, manage your membership " +
  "from your client portal, or contact the shop.";

export async function membershipJoinCheckout(
  s: Services,
  input: z.output<typeof membershipJoinCheckoutInput>,
): Promise<Record<string, unknown>> {
  // Card payments first: no customer or membership is created for a shop
  // that cannot bill it.
  const shop = await loadShopBySlug(s.admin, input.slug);
  await loadAccount(s.admin, shop.id);
  const { request_nonce: nonce, slug: _slug, plan_id: planId, ...payload } = input;
  const prepared = await s.admin.rpc("membership_join_prepare", {
    p_slug: shop.slug,
    p_plan_id: planId,
    p_payload: payload,
  });
  if (prepared.error) {
    switch (prepared.error.code) {
      case "55000":
        throw new HttpError("conflict", "This membership plan is not available online.", {
          details: { reason: "plan_unavailable" },
          cause: prepared.error,
        });
      case "22023":
        if (/already has this membership/i.test(prepared.error.message ?? "")) {
          // Anyone can type any email here: the answer must not confirm
          // that this person holds the plan (as portal_membership_access
          // never confirms ids). A neutral reason and wording, which a
          // real member still understands.
          throw new HttpError("conflict", JOIN_UNAVAILABLE_MESSAGE, {
            details: { reason: "join_unavailable" },
            cause: prepared.error,
          });
        }
        throw new HttpError(
          "unprocessable",
          publicValidationMessage(prepared.error, "Check your details and try again."),
          { details: { reason: "invalid_details" }, cause: prepared.error },
        );
      default:
        throw rpcError("membership_join_prepare", prepared.error, { notFound: "Shop not found." });
    }
  }
  const joined = prepared.data as Partial<JoinPrepared> | null;
  if (typeof joined?.membership_id !== "string" || joined.shop_id !== shop.id) {
    throw new Error("membership_join_prepare returned an unexpected membership");
  }
  const membership = await loadMembership(s, shop.id, joined.membership_id);
  const page = appPage(s.env.appBaseUrl(), "join", shop.slug);
  return await subscriptionCheckout(s, shop, membership, {
    successUrl: withQuery(page, { joined: "1" }),
    cancelUrl: withQuery(page, { canceled: "1" }),
    nonce,
    source: "membership_join_checkout",
  });
}

// ---------------------------------------------------------------------------
// Client portal (signed-in client, the customer's own memberships)
// ---------------------------------------------------------------------------

interface PortalAccess {
  shop_id: string;
  stripe_subscription_id: string | null;
  stripe_customer_id: string | null;
  status: MembershipStatus;
}

/**
 * The caller's own membership: portal_membership_access (0069, service
 * role) answers only for the portal user linked to the membership's
 * customer. Anything else (not signed in as that customer, another shop's
 * membership, an unknown id) is 403, so ids are never confirmed.
 */
async function portalAccess(
  s: Services,
  req: Request,
  membershipId: string,
): Promise<PortalAccess> {
  const caller = await requireUser(req, { admin: s.admin });
  const { data, error } = await s.admin.rpc("portal_membership_access", {
    p_membership_id: membershipId,
    p_user_id: caller.id,
  });
  if (error) throw rpcError("portal_membership_access", error);
  const access = data as Partial<PortalAccess> | null;
  if (!access || typeof access.shop_id !== "string") {
    throw errors.forbidden("You can only manage your own memberships.");
  }
  return access as PortalAccess;
}

export async function portalMembershipCancel(
  s: Services,
  req: Request,
  input: z.output<typeof portalMembershipInput>,
): Promise<Record<string, unknown>> {
  const access = await portalAccess(s, req, input.membership_id);
  if (access.status === "cancelled") {
    throw errors.conflict("This membership is already cancelled.", {
      reason: "already_cancelled",
    });
  }
  const subscriptionId = access.stripe_subscription_id;
  if (!subscriptionId) {
    // Never billed: there is nothing to stop (the portal does not list it).
    throw errors.conflict("This membership has not started billing yet.", {
      reason: "membership_not_billed",
    });
  }
  const account = await loadAccount(s.admin, access.shop_id, { requireCharges: false });
  // Always at the end of the paid period: the customer keeps what they paid for.
  const subscription = await cancelAtPeriodEnd(
    s,
    account,
    subscriptionId,
    "portal_membership_cancel",
    [input.membership_id, subscriptionId],
  );
  const status = membershipStatusOf(subscription.status);
  const periodEnd = periodEndOf(subscription);
  const synced = await s.admin.rpc("sync_stripe_subscription", {
    p_shop_id: access.shop_id,
    p_subscription_id: subscriptionId,
    p_status: status,
    p_current_period_end: periodEnd,
    p_cancel_at_period_end: subscription.cancel_at_period_end === true,
    p_membership_id: input.membership_id,
  });
  if (synced.error) {
    // Stripe has the change; the subscription webhook will reconcile.
    s.log.error("membership_sync_failed", {
      shop_id: access.shop_id,
      membership_id: input.membership_id,
      error: rpcError("sync_stripe_subscription", synced.error),
    });
  }
  const row = synced.data as
    | { status?: string; cancel_at_period_end?: boolean; current_period_end?: string | null }
    | null;
  s.log.info("portal_membership_cancelled", {
    shop_id: access.shop_id,
    membership_id: input.membership_id,
  });
  return {
    membership_id: input.membership_id,
    status: row?.status ?? status,
    cancel_at_period_end: row?.cancel_at_period_end ?? subscription.cancel_at_period_end === true,
    current_period_end: periodEnd ?? row?.current_period_end ?? null,
  };
}

/** Marks the billing portal configuration the CRM created on a connected account. */
const PORTAL_CONFIG_TAG = "detail_crm_portal_v1";

/**
 * The connected account's billing portal configuration for members: update
 * the payment method and see invoices; cancelling and plan changes are off
 * (a member cancels in the CRM portal, which keeps the membership in sync).
 * Created once per account (found again by its metadata tag).
 */
async function portalConfiguration(s: Services, account: AccountRow): Promise<string> {
  for await (
    const config of s.stripe.billingPortal.configurations.list(
      { active: true, limit: 100 },
      onAccount(account.stripe_account_id),
    )
  ) {
    if (config.metadata?.[PORTAL_CONFIG_TAG] === "1") return config.id;
  }
  const created = await s.stripe.billingPortal.configurations.create(
    {
      features: {
        payment_method_update: { enabled: true },
        invoice_history: { enabled: true },
        customer_update: { enabled: false },
        subscription_cancel: { enabled: false },
        subscription_update: { enabled: false },
      },
      metadata: { [PORTAL_CONFIG_TAG]: "1" },
    },
    onAccount(account.stripe_account_id, {
      idempotencyKey: await idempotencyKey(
        "billing_portal_config",
        account.stripe_account_id,
        PORTAL_CONFIG_TAG,
      ),
    }),
  );
  return created.id;
}

export async function portalBillingPortal(
  s: Services,
  req: Request,
  input: z.output<typeof portalMembershipInput>,
): Promise<{ url: string }> {
  const access = await portalAccess(s, req, input.membership_id);
  const account = await loadAccount(s.admin, access.shop_id, { requireCharges: false });
  // The Stripe customer the subscription bills (the one the card is on).
  let customer = access.stripe_customer_id;
  if (access.stripe_subscription_id) {
    try {
      const subscription = await s.stripe.subscriptions.retrieve(
        access.stripe_subscription_id,
        {},
        onAccount(account.stripe_account_id),
      );
      const owner = typeof subscription.customer === "string"
        ? subscription.customer
        : subscription.customer?.id;
      if (owner) customer = owner;
    } catch (err) {
      if (!isMissing(err)) throw err;
    }
  }
  if (!customer) {
    throw errors.conflict("This membership has no billing details yet.", {
      reason: "membership_not_billed",
    });
  }
  const configuration = await portalConfiguration(s, account);
  const session = await s.stripe.billingPortal.sessions.create(
    {
      customer,
      configuration,
      return_url: links.portal(s.env.appBaseUrl()),
    },
    onAccount(account.stripe_account_id),
  );
  if (!session.url) throw new Error("Stripe returned a billing portal session without a URL");
  return { url: session.url };
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
  // Cancelling now cannot be undone, so a replayed response is always true;
  // a period-end cancel can be (a resume in Stripe), see cancelAtPeriodEnd.
  const subscription = atPeriodEnd
    ? await cancelAtPeriodEnd(
      s,
      account,
      membership.stripe_subscription_id,
      "membership_cancel",
      [membership.id, membership.stripe_subscription_id, "period_end"],
    )
    : await s.stripe.subscriptions.cancel(
      membership.stripe_subscription_id,
      {},
      onAccount(account.stripe_account_id, {
        idempotencyKey: await idempotencyKey(
          "membership_cancel",
          membership.id,
          membership.stripe_subscription_id,
          "now",
        ),
      }),
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
