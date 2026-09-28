/**
 * delete_shop (OWNER only) — deletes a shop after closing everything that
 * could still move money for it on Stripe:
 *
 *   1. every unsettled card attempt of the shop is settled (unconfirmed
 *      PaymentSheets cancelled, money that already landed recorded); a
 *      payment still processing refuses the deletion (409
 *      payment_in_progress) before anything else changes;
 *   2. every platform subscription of the shop (what the shop pays the
 *      operator, docs/BILLING.md: the one shop_billing tracks AND any other
 *      live one of the shop's platform customer, e.g. a duplicate the webhook
 *      has not resolved yet) is set to end at its period end on the PLATFORM
 *      account (no Stripe-Account header). That is reversible, and from then
 *      on nothing renews. A Stripe failure stops the deletion here with 502
 *      upstream_error, before any link, membership or record changed;
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
 *      payments in flight);
 *   6. only now are the platform subscriptions cancelled immediately. A
 *      failure here is logged (platform_subscription_cancel_failed); the
 *      deletion stands, and step 2 already guarantees no further renewal.
 *   7. every text number the platform bought for the shop (sms-provisioning;
 *      read before step 5 removed its shop_sms_numbers row) is given back to
 *      Twilio with its Messaging Service, and its sms_number_releases entry
 *      is removed. A failure is logged (sms_number_release_failed) and the
 *      entry stays: sms-provisioning release_worklist retries it daily.
 *      Numbers support bound by hand stay on the worklist for the operator.
 *
 * When 3, 4 or 5 fails the shop still exists, so step 2 is undone: each
 * subscription it scheduled to end is set to renew again (a failure to undo
 * is logged; the owner can resume it in the Customer Portal).
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
import { type PlatformNumber, releasePlatformNumber, twilioClient } from "../_shared/twilio_api.ts";
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
  /** True when this deletion ended a live platform subscription of the shop. */
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

/** A platform subscription the deletion ends (step 2 -> 6). */
interface PlatformSubscription {
  id: string;
  /** Step 2 set cancel_at_period_end (undone if the deletion fails). */
  scheduled: boolean;
  /** Step 2 already cancelled it (it was incomplete). */
  ended: boolean;
}

/**
 * Every platform subscription of the shop that can still bill: the customer's
 * live ones (anything but canceled / incomplete_expired) and the one
 * shop_billing tracks. Stripe failures are 502 (platformCancelFailed).
 */
async function platformSubscriptions(s: Services, shopId: string): Promise<Stripe.Subscription[]> {
  // Service role: authenticated has no column grant on the Stripe ids.
  const { data, error } = await s.admin
    .from("shop_billing")
    .select("stripe_customer_id, stripe_subscription_id")
    .eq("shop_id", shopId)
    .maybeSingle<{ stripe_customer_id: string | null; stripe_subscription_id: string | null }>();
  if (error) throw dbFailure("shop_billing lookup", error);
  const customer = data?.stripe_customer_id ?? null;
  const tracked = data?.stripe_subscription_id ?? null;
  const found = new Map<string, Stripe.Subscription>();
  try {
    if (customer) {
      // The platform account itself: no Stripe-Account header.
      for await (
        const sub of s.stripe.subscriptions.list({ customer, status: "all", limit: 100 })
      ) {
        if (!ENDED.has(sub.status)) found.set(sub.id, sub);
      }
    }
    if (tracked && !found.has(tracked)) {
      try {
        const sub = await s.stripe.subscriptions.retrieve(tracked);
        if (!ENDED.has(sub.status)) found.set(sub.id, sub);
      } catch (err) {
        if (!isMissing(err)) throw err;
      }
    }
  } catch (err) {
    throw platformCancelFailed(err);
  }
  return [...found.values()];
}

/**
 * Step 2: nothing renews from here on. A subscription already set to end at
 * its period end is left as it is (and never resumed by releasePlatformHolds).
 * One still incomplete (nothing paid, no access) is cancelled outright.
 */
async function holdPlatformSubscriptions(
  s: Services,
  shopId: string,
): Promise<PlatformSubscription[]> {
  const held: PlatformSubscription[] = [];
  for (const sub of await platformSubscriptions(s, shopId)) {
    try {
      if (sub.status === "incomplete") {
        await s.stripe.subscriptions.cancel(sub.id);
        held.push({ id: sub.id, scheduled: false, ended: true });
      } else if (sub.cancel_at_period_end) {
        held.push({ id: sub.id, scheduled: false, ended: false });
      } else {
        // No custom idempotency key: setting the flag is idempotent, and a
        // replayed key would hand back a stale answer after an undo.
        const updated = await s.stripe.subscriptions.update(sub.id, {
          cancel_at_period_end: true,
        });
        held.push({ id: sub.id, scheduled: true, ended: false });
        if (!updated.cancel_at_period_end && !ENDED.has(updated.status)) {
          throw new Error(`platform subscription ${sub.id} still renews after the update`);
        }
      }
    } catch (err) {
      if (isMissing(err)) continue; // gone from Stripe meanwhile: nothing to end
      await releasePlatformHolds(s, shopId, held);
      throw platformCancelFailed(err);
    }
  }
  return held;
}

/** Undoes step 2 when the deletion failed afterwards (best effort, logged). */
async function releasePlatformHolds(
  s: Services,
  shopId: string,
  held: PlatformSubscription[],
): Promise<void> {
  for (const sub of held) {
    if (!sub.scheduled) continue;
    try {
      await s.stripe.subscriptions.update(sub.id, { cancel_at_period_end: false });
      s.log.info("platform_subscription_resumed", { shop_id: shopId, subscription: sub.id });
    } catch (err) {
      s.log.error("platform_subscription_resume_failed", {
        shop_id: shopId,
        subscription: sub.id,
        error: err instanceof Error ? err.message : String(err),
      });
    }
  }
}

/**
 * Step 6 (the shop is gone): cancels each subscription now. true when one was
 * live; a Stripe failure is logged only (step 2 already stopped renewals).
 */
async function cancelPlatformSubscriptions(
  s: Services,
  shopId: string,
  held: PlatformSubscription[],
): Promise<boolean> {
  for (const sub of held) {
    if (sub.ended) continue;
    try {
      const cancelled = await s.stripe.subscriptions.cancel(sub.id, {}, {
        idempotencyKey: await idempotencyKey("platform_subscription_shop_delete", shopId, sub.id),
      });
      if (!ENDED.has(cancelled.status)) {
        throw new Error(`platform subscription still ${cancelled.status} after cancel`);
      }
      s.log.info("platform_subscription_cancelled", { shop_id: shopId, subscription: sub.id });
    } catch (err) {
      if (isMissing(err)) continue;
      if (isInvalidRequest(err)) {
        // Already cancelled (Stripe refuses a second cancel).
        try {
          const current = await s.stripe.subscriptions.retrieve(sub.id);
          if (ENDED.has(current.status)) continue;
        } catch (readErr) {
          if (isMissing(readErr)) continue;
        }
      }
      s.log.error("platform_subscription_cancel_failed", {
        shop_id: shopId,
        subscription: sub.id,
        error: err instanceof Error ? err.message : String(err),
      });
    }
  }
  return held.length > 0;
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

/** Step 7's input: the numbers the platform bought for the shop (service role). */
async function platformNumbers(s: Services, shopId: string): Promise<PlatformNumber[]> {
  const { data, error } = await s.admin
    .from("shop_sms_numbers")
    .select("phone_number, twilio_number_sid, messaging_service_sid")
    .eq("shop_id", shopId)
    .not("twilio_number_sid", "is", null);
  if (error) throw dbFailure("shop_sms_numbers lookup", error);
  return (data ?? []) as PlatformNumber[];
}

/**
 * Step 7 (the shop is gone): each number goes back to Twilio, so the
 * platform stops paying for it, and leaves the operator's worklist. Returns
 * how many were released; failures are logged and stay on the worklist.
 */
async function releaseShopNumbers(
  s: Services,
  shopId: string,
  numbers: PlatformNumber[],
): Promise<number> {
  if (numbers.length === 0) return 0;
  let released = 0;
  try {
    const twilio = twilioClient(s.env.twilio(), s.fetch ?? fetch);
    for (const number of numbers) {
      try {
        await releasePlatformNumber(
          twilio,
          number,
          (err) =>
            s.log.warn("sms_service_delete_failed", {
              shop_id: shopId,
              error: err instanceof Error ? err.message : String(err),
            }),
        );
        released += 1;
        s.log.info("sms_number_released", { shop_id: shopId, source: "delete_shop" });
        const { error } = await s.admin
          .from("sms_number_releases")
          .delete()
          .eq("shop_id", shopId)
          .eq("phone_number", number.phone_number);
        if (error) {
          s.log.warn("sms_number_release_entry_kept", {
            shop_id: shopId,
            code: error.code ?? null,
          });
        }
      } catch (err) {
        s.log.error("sms_number_release_failed", {
          shop_id: shopId,
          error: err instanceof Error ? err.message : String(err),
        });
      }
    }
  } catch (err) {
    // Twilio credentials missing or invalid: every number stays on the worklist.
    s.log.error("sms_number_release_failed", {
      shop_id: shopId,
      error: err instanceof Error ? err.message : String(err),
    });
  }
  return released;
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
  // Step 2: the shop's platform subscriptions stop renewing (reversible);
  // when Stripe fails here (502) no link, membership or record has changed.
  const held = await holdPlatformSubscriptions(s, shop.id);
  let sessionsExpired: number;
  let membershipsCancelled: number;
  let numbers: PlatformNumber[];
  try {
    sessionsExpired = account ? await expireShopSessions(s, account, shop.id) : 0;
    membershipsCancelled = await cancelMemberships(s, account, shop.id);
    // Read now: the cascade of the delete below removes these rows.
    numbers = await platformNumbers(s, shop.id);
    const deleted = await s.admin.from("shops").delete().eq("id", shop.id).select("id");
    if (deleted.error) {
      if (deleted.error.code === "55000") {
        // shops_money_delete_guard: a membership or payment appeared meanwhile.
        throw new HttpError(
          "conflict",
          "A payment or membership changed while deleting the shop. Try again in a moment.",
          { details: { reason: "payment_in_progress" }, cause: deleted.error },
        );
      }
      throw dbFailure("shops delete", deleted.error);
    }
    if (!Array.isArray(deleted.data) || deleted.data.length === 0) {
      throw errors.notFound("Shop not found.");
    }
  } catch (err) {
    // The shop is still there: it keeps its plan.
    await releasePlatformHolds(s, shop.id, held);
    throw err;
  }
  const platformCancelled = await cancelPlatformSubscriptions(s, shop.id, held);
  const numbersReleased = await releaseShopNumbers(s, shop.id, numbers);
  s.log.info("shop_deleted", {
    shop_id: shop.id,
    deleted_by: caller.id,
    memberships_cancelled: membershipsCancelled,
    sessions_expired: sessionsExpired,
    platform_subscription_cancelled: platformCancelled,
    sms_numbers_released: numbersReleased,
    stripe_account: account?.stripe_account_id ?? null,
  });
  return {
    deleted: true,
    memberships_cancelled: membershipsCancelled,
    sessions_expired: sessionsExpired,
    platform_subscription_cancelled: platformCancelled,
  };
}
