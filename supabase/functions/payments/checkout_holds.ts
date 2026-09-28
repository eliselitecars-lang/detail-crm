/**
 * The job's open Checkout Sessions, as the database knows them (0106
 * job_checkout_holds).
 *
 * Every Checkout Session the payments edge opens for a job (a booking or
 * quote deposit link, a pay link of the job's single-job invoice) is HELD
 * before its URL is handed out: while a hold is live the customer's online
 * cancel (public_cancel_booking) refuses with 55000 HINT checkout_open, so a
 * deposit cannot be paid on a booking the customer cancelled in another tab.
 * A hold ends when Stripe expires the session, when the session's payment
 * row turns processing / received (a trigger), or when the edge expires the
 * session and releases it (releaseJobCheckouts: the customer's
 * booking_cancel, staff cancel_open_payments).
 */
import { errors } from "../_shared/errors.ts";
import { idempotencyKey, onAccount } from "../_shared/stripe.ts";
import {
  type AccountRow,
  dbFailure,
  expireOpenSessions,
  isInvalidRequest,
  loadCustomer,
  paymentInProgress,
  refusedWith,
  type Services,
  type SessionMatch,
} from "./lib.ts";

/** The job a hold is for (a jobs row, service role). */
export interface HeldJob {
  id: string;
  shop_id: string;
  customer_id: string;
}

/**
 * Records `session` (just created, still open) as paying toward `jobId`
 * until Stripe expires it. Call it BEFORE handing the URL out. "closed" when
 * the job was cancelled, marked no-show or completed meanwhile (55000 HINT
 * booking_closed): nothing is recorded, and a deposit caller must expire the
 * session and refuse (a closed job cannot be cancelled, so an invoice pay
 * link needs no hold).
 */
export async function holdJobCheckout(
  s: Services,
  shopId: string,
  jobId: string,
  session: { id: string; expires_at?: number | null },
): Promise<"held" | "closed"> {
  const expiresAt = session.expires_at;
  if (typeof expiresAt !== "number" || !Number.isSafeInteger(expiresAt) || expiresAt <= 0) {
    throw new Error("Stripe returned a Checkout Session without expires_at");
  }
  const { error } = await s.admin.rpc("payments_hold_job_checkout", {
    p_shop_id: shopId,
    p_job_id: jobId,
    p_session_id: session.id,
    p_expires_at: new Date(expiresAt * 1000).toISOString(),
  });
  if (!error) return "held";
  if (refusedWith(error, "55000", "booking_closed")) return "closed";
  throw dbFailure("payments_hold_job_checkout", error);
}

/**
 * A job deposit link that could not be held: the job closed while the
 * session was being created. The session is expired (nobody has its URL)
 * and the caller answers 409 booking_closed.
 */
export async function refuseClosedJobSession(
  s: Services,
  account: AccountRow,
  sessionId: string,
): Promise<never> {
  if (await closeSession(s, account, sessionId) === "complete") throw paymentInProgress();
  throw errors.conflict("This booking is no longer taking deposits.", {
    reason: "booking_closed",
  });
}

/**
 * Expires one Checkout Session on the connected account. "expired" when this
 * call expired it; "complete" when it was paid (the money is on its way);
 * "closed" when it had already expired or Stripe no longer knows it.
 */
export async function closeSession(
  s: Services,
  account: AccountRow,
  sessionId: string,
): Promise<"expired" | "complete" | "closed"> {
  try {
    await s.stripe.checkout.sessions.expire(
      sessionId,
      {},
      onAccount(account.stripe_account_id, {
        idempotencyKey: await idempotencyKey("checkout_expire", sessionId),
      }),
    );
    return "expired";
  } catch (err) {
    // Only open sessions can be expired: it completed or expired meanwhile.
    if (!isInvalidRequest(err)) throw err;
  }
  try {
    const current = await s.stripe.checkout.sessions.retrieve(
      sessionId,
      {},
      onAccount(account.stripe_account_id),
    );
    return current.status === "complete" ? "complete" : "closed";
  } catch (err) {
    // Not on this account (e.g. the shop connected another Stripe account).
    if (isInvalidRequest(err)) return "closed";
    throw err;
  }
}

/** The job's holds that have not expired yet (session ids). */
async function liveHolds(s: Services, job: HeldJob): Promise<string[]> {
  const { data, error } = await s.admin
    .from("job_checkout_holds")
    .select("stripe_checkout_session_id")
    .eq("shop_id", job.shop_id)
    .eq("job_id", job.id)
    .gt("expires_at", new Date(s.now).toISOString());
  if (error) throw dbFailure("job_checkout_holds lookup", error);
  return ((data ?? []) as Array<{ stripe_checkout_session_id: string }>)
    .map((row) => row.stripe_checkout_session_id);
}

/**
 * Expires every open Checkout Session that pays toward the job, then
 * releases their holds:
 *  - the job's current customer's open sessions that `match` (also those
 *    opened before 0106, which have no hold), and
 *  - every live hold of the job (a session opened for an earlier customer
 *    of the job, whose Stripe customer the list above does not cover).
 * A session that was already paid either throws 409 payment_in_progress
 * (`refuseCompleted`: the customer's cancel) or keeps its hold, which the
 * payment row releases (staff: settle reports the payment instead).
 * Returns the sessions this call expired.
 */
export async function releaseJobCheckouts(
  s: Services,
  account: AccountRow,
  job: HeldJob,
  match: SessionMatch,
  options: { refuseCompleted: boolean },
): Promise<string[]> {
  const customer = await loadCustomer(s.admin, job.shop_id, job.customer_id);
  const expired = customer.stripe_customer_id
    ? await expireOpenSessions(s, account, customer.stripe_customer_id, match, undefined, {
      refuseCompleted: options.refuseCompleted,
    })
    : [];
  const released = [...expired];
  for (const sessionId of await liveHolds(s, job)) {
    if (released.includes(sessionId)) continue;
    const outcome = await closeSession(s, account, sessionId);
    if (outcome === "complete") {
      if (options.refuseCompleted) throw paymentInProgress();
      continue;
    }
    if (outcome === "expired") expired.push(sessionId);
    released.push(sessionId);
  }
  if (released.length > 0) {
    const { error } = await s.admin.rpc("payments_release_job_checkouts", {
      p_shop_id: job.shop_id,
      p_job_id: job.id,
      p_session_ids: released,
    });
    if (error) throw dbFailure("payments_release_job_checkouts", error);
  }
  return expired;
}
