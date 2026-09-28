/**
 * The open Checkout Sessions of a job or an invoice, as the database knows
 * them (0106 job_checkout_holds, 0109 invoice_checkout_holds).
 *
 * Every Checkout Session the payments edge opens is HELD before its URL is
 * handed out:
 *  - a booking or quote deposit link, and the pay link of a single-job
 *    invoice whose job is still open, for the JOB (payments_hold_job_checkout):
 *    while it is live the customer's online cancel (public_cancel_booking)
 *    refuses with 55000 HINT checkout_open, so a deposit cannot be paid on a
 *    booking the customer cancelled in another tab;
 *  - every /i invoice pay link (completed jobs and grouped invoices too) for
 *    the INVOICE (payments_hold_invoice_checkout): while it (or a job hold of
 *    one of the invoice's jobs) is live, record_manual_payment and gift card /
 *    store credit redemptions refuse with 55000 HINT checkout_open, so cash
 *    cannot be taken for a balance the customer can still pay by card.
 * A hold ends when Stripe expires the session, when the session's payment
 * row turns processing / received (a trigger), or when the edge expires the
 * session (expireOpenSessions and closeSession callers release it:
 * releaseCheckoutHolds; the customer's booking_cancel and staff
 * cancel_open_payments also sweep every live hold of the job / invoice).
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
  releaseCheckoutHolds,
  type Services,
  type SessionMatch,
} from "./lib.ts";

/** The job a hold is for (a jobs row, service role). */
export interface HeldJob {
  id: string;
  shop_id: string;
  customer_id: string;
}

/** A Checkout Session's expiry as the ISO time the hold RPCs take. */
function holdUntil(session: { expires_at?: number | null }): string {
  const expiresAt = session.expires_at;
  if (typeof expiresAt !== "number" || !Number.isSafeInteger(expiresAt) || expiresAt <= 0) {
    throw new Error("Stripe returned a Checkout Session without expires_at");
  }
  return new Date(expiresAt * 1000).toISOString();
}

/**
 * Records `session` (just created, still open) as paying toward `jobId`
 * until Stripe expires it. Call it BEFORE handing the URL out. "closed" when
 * the job was cancelled, marked no-show or completed meanwhile (55000 HINT
 * booking_closed): nothing is recorded, and a deposit caller must expire the
 * session and refuse (a closed job cannot be cancelled online, so an invoice
 * pay link needs no JOB hold; its invoice hold is holdInvoiceCheckout's).
 */
export async function holdJobCheckout(
  s: Services,
  shopId: string,
  jobId: string,
  session: { id: string; expires_at?: number | null },
): Promise<"held" | "closed"> {
  const { error } = await s.admin.rpc("payments_hold_job_checkout", {
    p_shop_id: shopId,
    p_job_id: jobId,
    p_session_id: session.id,
    p_expires_at: holdUntil(session),
  });
  if (!error) return "held";
  if (refusedWith(error, "55000", "booking_closed")) return "closed";
  throw dbFailure("payments_hold_job_checkout", error);
}

/** Why payments_hold_invoice_checkout would not hold an invoice pay link. */
export type InvoiceHoldRefusal = "invoice_closed" | "balance_changed" | "booking_cancelled";

const INVOICE_HOLD_REFUSALS: ReadonlyArray<InvoiceHoldRefusal> = [
  "invoice_closed",
  "balance_changed",
  "booking_cancelled",
];

/**
 * Records `session` (an /i pay link, just created, still open) against the
 * invoice until Stripe expires it (0109). Call it BEFORE handing the URL out:
 * it locks the invoice (the lock every manual payment takes), so cash
 * recorded meanwhile is either already in the balance it checks or waits for
 * this hold. `amountCents` is the session's amount without tip. Anything but
 * "held" is the database's refusal (55000): the invoice is no longer open or
 * nothing is left to pay (invoice_closed), less is left than the session
 * charges (balance_changed), or every appointment it bills was cancelled
 * (booking_cancelled). The caller expires the session and refuses
 * (refuseUnheldInvoiceSession).
 */
export async function holdInvoiceCheckout(
  s: Services,
  shopId: string,
  invoiceId: string,
  session: { id: string; expires_at?: number | null },
  amountCents: number,
): Promise<"held" | InvoiceHoldRefusal> {
  const { error } = await s.admin.rpc("payments_hold_invoice_checkout", {
    p_shop_id: shopId,
    p_invoice_id: invoiceId,
    p_session_id: session.id,
    p_expires_at: holdUntil(session),
    p_amount_cents: amountCents,
  });
  if (!error) return "held";
  for (const reason of INVOICE_HOLD_REFUSALS) {
    if (refusedWith(error, "55000", reason)) return reason;
  }
  throw dbFailure("payments_hold_invoice_checkout", error);
}

const INVOICE_HOLD_MESSAGES: Record<InvoiceHoldRefusal, string> = {
  invoice_closed: "This invoice is no longer taking card payments. Refresh the page to see it.",
  balance_changed: "This invoice's balance just changed. Refresh the page and try again.",
  booking_cancelled:
    "The appointment on this invoice was cancelled, so it can't be paid online. Please contact the shop.",
};

/**
 * An invoice pay link the database would not hold: the session is expired
 * (nobody has its URL) and the caller answers 409 with the refusal as
 * `reason` (409 payment_in_progress when it was somehow paid already).
 */
export async function refuseUnheldInvoiceSession(
  s: Services,
  account: AccountRow,
  sessionId: string,
  reason: InvoiceHoldRefusal,
): Promise<never> {
  if (await closeSession(s, account, sessionId) === "complete") throw paymentInProgress();
  throw errors.conflict(INVOICE_HOLD_MESSAGES[reason], { reason });
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

/** Live (not yet expired) holds of these jobs and / or this invoice (session ids). */
async function liveHolds(
  s: Services,
  shopId: string,
  jobIds: ReadonlyArray<string>,
  invoiceId: string | null,
): Promise<string[]> {
  const now = new Date(s.now).toISOString();
  const ids: string[] = [];
  if (jobIds.length > 0) {
    const { data, error } = await s.admin
      .from("job_checkout_holds")
      .select("stripe_checkout_session_id")
      .eq("shop_id", shopId)
      .in("job_id", [...jobIds])
      .gt("expires_at", now);
    if (error) throw dbFailure("job_checkout_holds lookup", error);
    for (const row of (data ?? []) as Array<{ stripe_checkout_session_id: string }>) {
      ids.push(row.stripe_checkout_session_id);
    }
  }
  if (invoiceId) {
    const { data, error } = await s.admin
      .from("invoice_checkout_holds")
      .select("stripe_checkout_session_id")
      .eq("shop_id", shopId)
      .eq("invoice_id", invoiceId)
      .gt("expires_at", now);
    if (error) throw dbFailure("invoice_checkout_holds lookup", error);
    for (const row of (data ?? []) as Array<{ stripe_checkout_session_id: string }>) {
      ids.push(row.stripe_checkout_session_id);
    }
  }
  return [...new Set(ids)];
}

/** What a release sweeps: the jobs' holds and, optionally, an invoice's. */
interface HeldPages {
  shopId: string;
  /** The Stripe customer whose open sessions `match` is applied to. */
  stripeCustomer: string | null;
  jobIds: ReadonlyArray<string>;
  invoiceId: string | null;
}

/**
 * Expires every open Checkout Session that pays toward the pages, then
 * releases their holds:
 *  - the customer's open sessions that `match` (also those opened before
 *    0106 / 0109, which have no hold), and
 *  - every live hold of the jobs and the invoice (a session opened for an
 *    earlier customer, whose Stripe customer the list above does not cover,
 *    and a hold whose session was already expired by an older deploy or in
 *    the Stripe dashboard).
 * A session that was already paid either throws 409 payment_in_progress
 * (`refuseCompleted`: the customer's cancel) or keeps its hold, which the
 * payment row releases (staff: settle reports the payment instead).
 * Returns the sessions this call expired.
 */
async function releaseHeldPages(
  s: Services,
  account: AccountRow,
  pages: HeldPages,
  match: SessionMatch,
  options: { refuseCompleted: boolean },
): Promise<string[]> {
  const expired = pages.stripeCustomer
    ? await expireOpenSessions(s, account, pages.stripeCustomer, match, undefined, {
      refuseCompleted: options.refuseCompleted,
    })
    : [];
  const released = [...expired];
  for (const sessionId of await liveHolds(s, pages.shopId, pages.jobIds, pages.invoiceId)) {
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
    // Every hold of these sessions, whichever job / invoice it was taken for
    // (expireOpenSessions already released the ones it expired) ...
    await releaseCheckoutHolds(s, pages.shopId, released);
    // ... and the database's own releases for the swept pages (idempotent).
    for (const jobId of pages.jobIds) {
      const { error } = await s.admin.rpc("payments_release_job_checkouts", {
        p_shop_id: pages.shopId,
        p_job_id: jobId,
        p_session_ids: released,
      });
      if (error) throw dbFailure("payments_release_job_checkouts", error);
    }
    if (pages.invoiceId) {
      const { error } = await s.admin.rpc("payments_release_invoice_checkouts", {
        p_shop_id: pages.shopId,
        p_invoice_id: pages.invoiceId,
        p_session_ids: released,
      });
      if (error) throw dbFailure("payments_release_invoice_checkouts", error);
    }
  }
  return expired;
}

/**
 * The job's pages (the customer's booking_cancel, staff cancel_open_payments
 * with job_id): the job's current customer's open sessions that `match` and
 * every live hold of the job — plus, with `invoiceId` (staff), every live
 * hold of the job's live invoice, so cash can be taken on it right after.
 * Returns the sessions this call expired.
 */
export async function releaseJobCheckouts(
  s: Services,
  account: AccountRow,
  job: HeldJob,
  match: SessionMatch,
  options: { refuseCompleted: boolean; invoiceId?: string | null },
): Promise<string[]> {
  const customer = await loadCustomer(s.admin, job.shop_id, job.customer_id);
  return await releaseHeldPages(
    s,
    account,
    {
      shopId: job.shop_id,
      stripeCustomer: customer.stripe_customer_id,
      jobIds: [job.id],
      invoiceId: options.invoiceId ?? null,
    },
    match,
    { refuseCompleted: options.refuseCompleted },
  );
}

/**
 * The invoice's pages (staff cancel_open_payments with invoice_id, what both
 * staff apps call on 55000 checkout_open): the invoice customer's open
 * sessions that `match`, every live hold of the invoice and every live job
 * hold of the jobs it bills — exactly the holds money_refuse_open_checkout
 * refuses manual money for, so the retry that follows can succeed (unless a
 * page was just paid: that hold stays until its payment row lands).
 * Returns the sessions this call expired.
 */
export async function releaseInvoiceCheckouts(
  s: Services,
  account: AccountRow,
  invoice: { id: string; shop_id: string; customer_id: string },
  jobIds: ReadonlyArray<string>,
  match: SessionMatch,
): Promise<string[]> {
  const customer = await loadCustomer(s.admin, invoice.shop_id, invoice.customer_id);
  return await releaseHeldPages(
    s,
    account,
    {
      shopId: invoice.shop_id,
      stripeCustomer: customer.stripe_customer_id,
      jobIds,
      invoiceId: invoice.id,
    },
    match,
    { refuseCompleted: false },
  );
}
