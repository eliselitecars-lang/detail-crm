/**
 * delete_shop (OWNER only) — deletes a shop after closing everything that
 * could still move money for it on Stripe:
 *
 *   1. every unsettled card attempt of the shop is settled (unconfirmed
 *      PaymentSheets cancelled, money that already landed recorded); a
 *      payment still processing refuses the deletion (409
 *      payment_in_progress) before anything else changes;
 *   2. the shop's own subscription to the platform (shop_billing, 0100 —
 *      what the shop pays the operator, docs/BILLING.md) is cancelled
 *      immediately on the PLATFORM account (no Stripe-Account header;
 *      already ended or missing in Stripe is fine). A Stripe failure stops
 *      the deletion here with 502 upstream_error, before any link,
 *      membership or record changed;
 *   3. every open Checkout link the CRM created on the account (invoice pay
 *      links, booking deposits, card-saving and membership links) is expired
 *      (one just paid: 409 payment_in_progress);
 *   4. every membership that is not cancelled: its subscription is cancelled
 *      immediately on the connected account (resource_missing ignored), its
 *      open membership Checkout links are expired (a subscription a completed
 *      link started is stopped too), then it is recorded `cancelled` through
 *      the same service-role path membership_cancel uses
 *      (sync_stripe_subscription, or the incomplete -> cancelled update);
 *   5. the shop row is deleted (the database cascades to every tenant row,
 *      queues its stored files for storage-purge and logs its SMS number in
 *      sms_number_releases; shops_money_delete_guard re-checks memberships and
 *      payments in flight).
 *
 * A shop that never connected Stripe skips the Connect calls (1, 3 and the
 * memberships' subscriptions). The Connect account itself is left intact:
 * the owner keeps the Express dashboard, the balance and the payouts.
 * `confirm_name` must be the shop's name (trimmed, case-insensitive), so a
 * stray request cannot delete a shop.
 */
import { z } from "zod";
import { requireShopRole, requireUser, ROLES } from "../_shared/auth.ts";
import { errors, HttpError } from "../_shared/errors.ts";
import { uuid } from "../_shared/schemas.ts";
import { idempotencyKey, onAccount, type Stripe } from "../_shared/stripe.ts";
import {
  type AccountRow,
  dbFailure,
  findAccount,
  isInvalidRequest,
  loadShop,
  paymentInProgress,
  rpcError,
  type Services,
} from "./lib.ts";
import {
  closeMembershipCheckout,
  MEMBERSHIP_COLUMNS,
  type MembershipRow,
  membershipStatusOf,
  periodEndOf,
} from "./memberships.ts";
import { settleShop } from "./settle.ts";

export const deleteShopInput = z.object({
  shop_id: uuid,
  /** The shop's name, typed by the owner to confirm. */
  confirm_name: z.string().max(200),
}).strict();

export interface DeleteShopResponse {
  deleted: true;
  memberships_cancelled: number;
  sessions_expired: number;
  /** True when this deletion ended the shop's live platform subscription. */
  platform_subscription_cancelled: boolean;
}

/** The 502 when the platform subscription could not be cancelled (nothing was deleted). */
export const PLATFORM_CANCEL_FAILED_MESSAGE =
  "The shop's subscription could not be cancelled, so the shop was not deleted. " +
  "Try again in a moment.";

/** Same comparison the web confirmation uses: trimmed, case-insensitive. */
export function confirmsName(typed: string, shopName: string): boolean {
  return typed.trim().toLocaleLowerCase("en-US") === shopName.trim().toLocaleLowerCase("en-US");
}

const ENDED = new Set<string>(["canceled", "incomplete_expired"]);

function isMissing(err: unknown): boolean {
  if (!isInvalidRequest(err)) return false;
  const e = err as { code?: unknown; statusCode?: unknown };
  return e.code === "resource_missing" || e.statusCode === 404;
}

/**
 * Cancels the membership's subscription now; the Stripe subscription as it
 * stands afterwards, or null when Stripe no longer has it.
 */
async function cancelSubscription(
  s: Services,
  account: AccountRow,
  membership: MembershipRow,
  subscriptionId: string,
): Promise<Stripe.Subscription | null> {
  try {
    return await s.stripe.subscriptions.cancel(
      subscriptionId,
      {},
      onAccount(account.stripe_account_id, {
        idempotencyKey: await idempotencyKey("membership_shop_delete", membership.id),
      }),
    );
  } catch (err) {
    if (isMissing(err)) return null;
    if (!isInvalidRequest(err)) throw err;
    // Already cancelled (Stripe refuses a second cancel): read its state.
    try {
      const current = await s.stripe.subscriptions.retrieve(
        subscriptionId,
        {},
        onAccount(account.stripe_account_id),
      );
      if (ENDED.has(current.status)) return current;
    } catch (readErr) {
      if (isMissing(readErr)) return null;
      throw readErr;
    }
    throw err;
  }
}

function platformCancelFailed(cause: unknown): HttpError {
  return new HttpError("upstream_error", PLATFORM_CANCEL_FAILED_MESSAGE, {
    details: { reason: "platform_subscription_cancel_failed" },
    cause,
  });
}

/**
 * Cancels the shop's platform subscription now (step 2). true when this call
 * ended a live subscription; false when the shop has none, or it had already
 * ended, or Stripe no longer has it. Any other failure is a 502
 * (platformCancelFailed).
 */
async function cancelPlatformSubscription(s: Services, shopId: string): Promise<boolean> {
  // Service role: authenticated has no column grant on the Stripe ids.
  const { data, error } = await s.admin
    .from("shop_billing")
    .select("stripe_subscription_id")
    .eq("shop_id", shopId)
    .maybeSingle<{ stripe_subscription_id: string | null }>();
  if (error) throw dbFailure("shop_billing lookup", error);
  const subscriptionId = data?.stripe_subscription_id ?? null;
  if (!subscriptionId) return false;
  try {
    // The platform account itself: no Stripe-Account header.
    const cancelled = await s.stripe.subscriptions.cancel(subscriptionId, {}, {
      idempotencyKey: await idempotencyKey(
        "platform_subscription_shop_delete",
        shopId,
        subscriptionId,
      ),
    });
    if (!ENDED.has(cancelled.status)) {
      throw new Error(`platform subscription still ${cancelled.status} after cancel`);
    }
    s.log.info("platform_subscription_cancelled", {
      shop_id: shopId,
      subscription: subscriptionId,
    });
    return true;
  } catch (err) {
    if (isMissing(err)) return false;
    if (isInvalidRequest(err)) {
      // Already cancelled (Stripe refuses a second cancel): read its state.
      try {
        const current = await s.stripe.subscriptions.retrieve(subscriptionId);
        if (ENDED.has(current.status)) return false;
      } catch (readErr) {
        if (isMissing(readErr)) return false;
        throw platformCancelFailed(readErr);
      }
    }
    throw platformCancelFailed(err);
  }
}

/** Records the membership cancelled (service role), like membership_cancel. */
async function recordCancelled(
  s: Services,
  membership: MembershipRow,
  subscription: Stripe.Subscription | null,
): Promise<void> {
  if (membership.stripe_subscription_id) {
    const { error } = await s.admin.rpc("sync_stripe_subscription", {
      p_shop_id: membership.shop_id,
      p_subscription_id: membership.stripe_subscription_id,
      p_status: "cancelled",
      p_current_period_end: (subscription ? periodEndOf(subscription) : null) ??
        membership.current_period_end,
      p_cancel_at_period_end: false,
      p_membership_id: membership.id,
    });
    if (error) throw rpcError("sync_stripe_subscription", error);
    return;
  }
  const { error } = await s.admin
    .from("memberships")
    .update({ status: "cancelled" })
    .eq("shop_id", membership.shop_id)
    .eq("id", membership.id)
    .neq("status", "cancelled");
  if (error) throw dbFailure("memberships cancel", error);
}

async function cancelMemberships(s: Services, account: AccountRow | null, shopId: string) {
  const { data, error } = await s.admin
    .from("memberships")
    .select(MEMBERSHIP_COLUMNS)
    .eq("shop_id", shopId)
    .neq("status", "cancelled");
  if (error) throw dbFailure("memberships lookup", error);
  let cancelled = 0;
  for (const membership of (data ?? []) as MembershipRow[]) {
    let subscription: Stripe.Subscription | null = null;
    if (account && membership.stripe_subscription_id) {
      subscription = await cancelSubscription(
        s,
        account,
        membership,
        membership.stripe_subscription_id,
      );
      if (subscription && !ENDED.has(subscription.status)) {
        throw new Error(
          `subscription still ${subscription.status} after cancel (${membership.id})`,
        );
      }
      s.log.info("membership_subscription_cancelled", {
        shop_id: shopId,
        membership_id: membership.id,
        status: subscription ? membershipStatusOf(subscription.status) : "missing",
      });
    }
    // Open links (and a subscription a completed one started) — no-op
    // without an account or a Stripe customer.
    await closeMembershipCheckout(s, membership);
    await recordCancelled(s, membership, subscription);
    cancelled += 1;
  }
  return cancelled;
}

/** Expires every open Checkout Session the CRM created for this shop on its account. */
async function expireShopSessions(s: Services, account: AccountRow, shopId: string) {
  let expired = 0;
  for await (
    const session of s.stripe.checkout.sessions.list(
      { status: "open", limit: 100 },
      onAccount(account.stripe_account_id),
    )
  ) {
    if (session.status !== "open" || session.metadata?.shop_id !== shopId) continue;
    try {
      await s.stripe.checkout.sessions.expire(
        session.id,
        {},
        onAccount(account.stripe_account_id, {
          idempotencyKey: await idempotencyKey("checkout_expire", session.id),
        }),
      );
      expired += 1;
    } catch (err) {
      if (!isInvalidRequest(err)) throw err;
      // Completed meanwhile: that money is still on its way.
      const current = await s.stripe.checkout.sessions.retrieve(
        session.id,
        {},
        onAccount(account.stripe_account_id),
      );
      if (current.status === "complete" && current.mode === "payment") throw paymentInProgress();
    }
  }
  return expired;
}

export async function deleteShop(
  s: Services,
  req: Request,
  input: z.output<typeof deleteShopInput>,
): Promise<DeleteShopResponse> {
  const caller = await requireUser(req, { admin: s.admin });
  await requireShopRole(s.admin, caller, input.shop_id, ROLES.owner);
  const shop = await loadShop(s.admin, input.shop_id);
  if (!confirmsName(input.confirm_name, shop.name)) {
    throw errors.unprocessable("Type the shop's name exactly to confirm.", {
      reason: "name_mismatch",
    });
  }

  // Money still moving refuses the deletion before anything is cancelled.
  const account = await findAccount(s.admin, shop.id);
  if (account) {
    const settled = await settleShop(s, account, shop.id);
    if (settled.in_progress > 0) throw paymentInProgress();
    // An ACH debit still clearing (P-31) settles days later: wait for it.
    const clearing = await s.admin
      .from("payments")
      .select("id")
      .eq("shop_id", shop.id)
      .eq("status", "processing")
      .limit(1);
    if (clearing.error) throw dbFailure("processing payments lookup", clearing.error);
    if ((clearing.data ?? []).length > 0) throw paymentInProgress();
  }
  // The shop's own platform subscription ends first: when Stripe fails here
  // (502) no link, membership or record has changed yet.
  const platformCancelled = await cancelPlatformSubscription(s, shop.id);
  const sessionsExpired = account ? await expireShopSessions(s, account, shop.id) : 0;
  const membershipsCancelled = await cancelMemberships(s, account, shop.id);

  const { data, error } = await s.admin.from("shops").delete().eq("id", shop.id).select("id");
  if (error) {
    if (error.code === "55000") {
      // shops_money_delete_guard: a membership or payment appeared meanwhile.
      throw new HttpError(
        "conflict",
        "A payment or membership changed while deleting the shop. Try again in a moment.",
        { details: { reason: "payment_in_progress" }, cause: error },
      );
    }
    throw dbFailure("shops delete", error);
  }
  if (!Array.isArray(data) || data.length === 0) throw errors.notFound("Shop not found.");
  s.log.info("shop_deleted", {
    shop_id: shop.id,
    deleted_by: caller.id,
    memberships_cancelled: membershipsCancelled,
    sessions_expired: sessionsExpired,
    platform_subscription_cancelled: platformCancelled,
    stripe_account: account?.stripe_account_id ?? null,
  });
  return {
    deleted: true,
    memberships_cancelled: membershipsCancelled,
    sessions_expired: sessionsExpired,
    platform_subscription_cancelled: platformCancelled,
  };
}
