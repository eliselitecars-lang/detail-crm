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
 * The customer's invoice_checkout_cancel (back from Stripe with ?canceled=1,
 * or before using a gift card on /i) closes only the invoice's own /i pay
 * links and releases their invoice holds and the job hold such a link took
 * (releaseInvoicePayLinks): never a deposit link, a staff PaymentSheet or a
 * Terminal payment. Its counterpart deposit_checkout_cancel (back from
 * Stripe with ?canceled=1 on /booking or /q, or from /i when a gift card is
 * refused because a deposit page is open) closes only the jobs' open deposit
 * links and releases their job holds (releaseDepositLinks): never an invoice
 * pay link or its holds, a staff PaymentSheet or a Terminal payment.
 */
import { errors, type HttpError } from "../_shared/errors.ts";
import { idempotencyKey, onAccount } from "../_shared/stripe.ts";
import {
  type AccountRow,
  customerSessions,
  dbFailure,
  expireOpenSessions,
  isInvalidRequest,
  loadCustomer,
  paymentInProgress,
  refusedWith,
  releaseCheckoutHolds,
  type Services,
  sessionFor,
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
 * Why payments_hold_job_checkout would not hold a job's page (55000):
 *  - booking_closed: the job was cancelled, marked no-show or completed;
 *  - deposit_not_due (0118, deposit pages only): nothing is due any more
 *    (cash, a gift card or another page covered the deposit meanwhile);
 *  - balance_changed (0118, deposit pages only): less is due than the
 *    session charges (`amountCents`), e.g. part of the deposit was taken in
 *    cash while the session was being created.
 */
export type JobHoldRefusal = "booking_closed" | "deposit_not_due" | "balance_changed";

const JOB_HOLD_REFUSALS: ReadonlyArray<JobHoldRefusal> = [
  "booking_closed",
  "deposit_not_due",
  "balance_changed",
];

/**
 * Records `session` (just created, still open) as paying toward `jobId`
 * until Stripe expires it. Call it BEFORE handing the URL out. Anything but
 * "held" is the database's refusal (JobHoldRefusal): nothing is recorded,
 * and a deposit caller must expire the session and refuse
 * (refuseUnheldJobSession). A deposit page passes `amountCents` (what the
 * session charges): the database re-reads the deposit still due under the
 * lock every manual payment takes (0118) and refuses a session that would
 * charge more. An /i pay link's session was already held (and re-checked)
 * for its invoice, so its job hold is only the cancel guard: it passes no
 * amount (a closed job cannot be cancelled online, so "booking_closed"
 * needs no job hold there; the invoice hold still guards its money).
 */
export async function holdJobCheckout(
  s: Services,
  shopId: string,
  jobId: string,
  session: { id: string; expires_at?: number | null },
  amountCents?: number,
): Promise<"held" | JobHoldRefusal> {
  const { error } = await s.admin.rpc("payments_hold_job_checkout", {
    p_shop_id: shopId,
    p_job_id: jobId,
    p_session_id: session.id,
    p_expires_at: holdUntil(session),
    ...(amountCents === undefined ? {} : { p_amount_cents: amountCents }),
  });
  if (!error) return "held";
  for (const reason of JOB_HOLD_REFUSALS) {
    if (refusedWith(error, "55000", reason)) return reason;
  }
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

const JOB_HOLD_MESSAGES: Record<JobHoldRefusal, string> = {
  booking_closed: "This booking is no longer taking deposits.",
  deposit_not_due: "No deposit is due for this booking.",
  balance_changed: "This booking's deposit just changed. Refresh the page and try again.",
};

/**
 * A job deposit link the database would not hold: the job closed, or the
 * deposit due changed, while the session was being created. The session is
 * expired (nobody has its URL) and the caller answers 409 with the refusal
 * as `reason` (409 payment_in_progress when it was somehow paid already).
 */
export async function refuseUnheldJobSession(
  s: Services,
  account: AccountRow,
  sessionId: string,
  reason: JobHoldRefusal,
): Promise<never> {
  if (await closeSession(s, account, sessionId) === "complete") throw paymentInProgress();
  throw errors.conflict(JOB_HOLD_MESSAGES[reason], { reason });
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
  let paid = false;
  for (const sessionId of await liveHolds(s, pages.shopId, pages.jobIds, pages.invoiceId)) {
    if (released.includes(sessionId)) continue;
    const outcome = await closeSession(s, account, sessionId);
    if (outcome === "complete") {
      // Keeps its hold (its payment row releases it); the others are still
      // closed and released below before the refusal.
      paid = true;
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
  if (paid && options.refuseCompleted) throw paymentInProgress();
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

/**
 * Before a staff card attempt charges the invoice (charge_saved_card,
 * payment_sheet, terminal_payment_intent): every page that could still pay
 * the same balance is expired and released — the invoice customer's open
 * pay links and its jobs' deposit links (`match`), and every live hold of
 * the invoice and of the jobs it bills. The holds are the database's record
 * of every open page (the ones money_refuse_open_checkout refuses cash
 * for), so this also closes a page Stripe lists under another Stripe
 * customer: one opened before the invoice moved to this customer (a
 * customer merge keeps the survivor's Stripe customer), or before the
 * customer got a new one. 409 payment_in_progress when one of them was
 * already paid (the pages that could still be closed are closed first).
 * Returns the sessions this call expired.
 */
export async function supersedeInvoicePages(
  s: Services,
  account: AccountRow,
  invoice: { id: string; shop_id: string },
  jobIds: ReadonlyArray<string>,
  stripeCustomer: string | null,
  match: SessionMatch,
): Promise<string[]> {
  return await releaseHeldPages(
    s,
    account,
    { shopId: invoice.shop_id, stripeCustomer, jobIds, invoiceId: invoice.id },
    match,
    { refuseCompleted: true },
  );
}

/** The invoice a customer's invoice_checkout_cancel closes pay links for. */
export interface PayLinkInvoice {
  id: string;
  shop_id: string;
  customer_id: string;
  job_id: string | null;
}

/** 409 payment_in_progress, worded for the customer (the /i page shows it as is). */
function payLinkPaying(): HttpError {
  return errors.conflict(
    "Your card payment is already going through, so the payment page can't be closed. Refresh in a moment to see it.",
    { reason: "payment_in_progress" },
  );
}

/**
 * Closes one /i pay link. "closed" when it can no longer be paid: this call
 * expired it (a repeat replays Stripe's first answer under the same key), it
 * had expired already, or Stripe no longer knows it on this account.
 * "paying" when it was paid (complete: a card payment, or a bank debit /
 * pay-later payment submitted and still processing), or when Stripe would
 * not expire it although it is still open (a payment on it is being
 * confirmed right now). A "paying" page keeps its holds: its payment row
 * releases them.
 */
async function closePayLink(
  s: Services,
  account: AccountRow,
  sessionId: string,
): Promise<"closed" | "paying"> {
  try {
    await s.stripe.checkout.sessions.expire(
      sessionId,
      {},
      onAccount(account.stripe_account_id, {
        idempotencyKey: await idempotencyKey("checkout_expire", sessionId),
      }),
    );
    return "closed";
  } catch (err) {
    // Only open sessions can be expired.
    if (!isInvalidRequest(err)) throw err;
  }
  try {
    const current = await s.stripe.checkout.sessions.retrieve(
      sessionId,
      {},
      onAccount(account.stripe_account_id),
    );
    return current.status === "expired" ? "closed" : "paying";
  } catch (err) {
    // Not on this account (e.g. the shop connected another Stripe account).
    if (isInvalidRequest(err)) return "closed";
    throw err;
  }
}

/**
 * The customer's invoice_checkout_cancel: closes the invoice's open /i pay
 * links (the Checkout Sessions invoice_checkout opened for it) and releases
 * their holds, so a gift card or store credit can pay the invoice at once
 * instead of after Stripe expires the page. The links are
 *  - the invoice customer's open sessions matching sessionFor.invoice (the
 *    live invoice's links booking_cancel matches: mode payment, kind payment,
 *    this invoice_id), and
 *  - every live hold of the invoice (only invoice_checkout takes one; also a
 *    link opened for the invoice's previous customer).
 * Deposit links (kind deposit) and their job holds, card-setup and
 * membership links, staff PaymentSheets and Terminal payments (PaymentIntents,
 * never listed here) are left alone. Each closed link loses its invoice hold
 * and the job hold a single-job invoice's link took (by session id, so a
 * deposit link's hold is never among them). Nothing open: nothing changes.
 * A link that was just paid, or whose payment is going through, keeps its
 * holds and the call ends in 409 payment_in_progress once every other link
 * is closed. Returns how many links were closed and released.
 */
export async function releaseInvoicePayLinks(
  s: Services,
  account: AccountRow,
  invoice: PayLinkInvoice,
): Promise<number> {
  const shopId = invoice.shop_id;
  const links = new Set<string>();
  const customer = await loadCustomer(s.admin, shopId, invoice.customer_id);
  if (customer.stripe_customer_id) {
    const match = sessionFor.invoice(shopId, invoice.id);
    for (
      const session of await customerSessions(s, account, customer.stripe_customer_id, "open")
    ) {
      if (session.status === "open" && match(session)) links.add(session.id);
    }
  }
  for (const sessionId of await liveHolds(s, shopId, [], invoice.id)) links.add(sessionId);

  const closed: string[] = [];
  let paying = false;
  for (const sessionId of links) {
    if (await closePayLink(s, account, sessionId) === "closed") closed.push(sessionId);
    else paying = true;
  }
  if (closed.length > 0) {
    // The closed links' holds (invoice and job), then the database's own
    // releases for the invoice and its job (idempotent), by session only.
    await releaseCheckoutHolds(s, shopId, closed);
    if (invoice.job_id) {
      const { error } = await s.admin.rpc("payments_release_job_checkouts", {
        p_shop_id: shopId,
        p_job_id: invoice.job_id,
        p_session_ids: closed,
      });
      if (error) throw dbFailure("payments_release_job_checkouts", error);
    }
    const { error } = await s.admin.rpc("payments_release_invoice_checkouts", {
      p_shop_id: shopId,
      p_invoice_id: invoice.id,
      p_session_ids: closed,
    });
    if (error) throw dbFailure("payments_release_invoice_checkouts", error);
  }
  if (paying) throw payLinkPaying();
  return closed.length;
}

/** The jobs whose deposit links a customer's deposit_checkout_cancel closes. */
export interface DepositLinkJobs {
  shopId: string;
  /** The customer whose Stripe customer's open sessions are listed. */
  customerId: string;
  jobIds: ReadonlyArray<string>;
}

/**
 * The live job holds of these jobs that only a deposit link can have taken:
 * an /i pay link's job hold always comes with an invoice hold for the same
 * session (invoice_checkout holds the invoice first), so a session with an
 * invoice hold is an invoice pay link and is left out.
 */
async function depositHolds(
  s: Services,
  shopId: string,
  jobIds: ReadonlyArray<string>,
): Promise<string[]> {
  const held = await liveHolds(s, shopId, jobIds, null);
  if (held.length === 0) return [];
  const { data, error } = await s.admin
    .from("invoice_checkout_holds")
    .select("stripe_checkout_session_id")
    .eq("shop_id", shopId)
    .in("stripe_checkout_session_id", held);
  if (error) throw dbFailure("invoice_checkout_holds lookup", error);
  const payLinks = new Set(
    ((data ?? []) as Array<{ stripe_checkout_session_id: string }>).map((row) =>
      row.stripe_checkout_session_id
    ),
  );
  return held.filter((id) => !payLinks.has(id));
}

/**
 * A held session that was not among the customer's open deposit links: read
 * it first and close it only when it is one of these jobs' deposit links.
 * "closed" when Stripe no longer knows it on this account (its hold is
 * stale); "other" when it is not a deposit link of these jobs (left alone).
 */
async function heldDepositLink(
  s: Services,
  account: AccountRow,
  sessionId: string,
  match: SessionMatch,
): Promise<"closed" | "paying" | "other"> {
  let current;
  try {
    current = await s.stripe.checkout.sessions.retrieve(
      sessionId,
      {},
      onAccount(account.stripe_account_id),
    );
  } catch (err) {
    if (isInvalidRequest(err)) return "closed";
    throw err;
  }
  if (!match(current)) return "other";
  if (current.status === "expired") return "closed";
  if (current.status === "complete") return "paying";
  return await closePayLink(s, account, sessionId);
}

/**
 * The customer's deposit_checkout_cancel (back from Stripe with ?canceled=1
 * on /booking or /q, or before a gift card on /i): closes the jobs' open
 * deposit links (the Checkout Sessions booking_deposit_checkout and
 * quote_deposit_checkout opened: sessionFor.deposits) and releases their job
 * holds, so the booking is not held for the ~30-40 minutes Stripe keeps the
 * page alive (the customer's online cancel, and cash or a gift card on the
 * job's invoice, wait for a live deposit page). The links are
 *  - the customer's open sessions matching sessionFor.deposits, and
 *  - every live job hold of the jobs that has no invoice hold (the deposit
 *    links' holds; also a link opened for the job's previous customer),
 *    read from Stripe first and closed only when it is such a deposit link.
 * Invoice pay links (and their invoice and job holds), card-setup and
 * membership links, staff PaymentSheets and Terminal payments are left
 * alone, and nothing is settled or charged. Nothing open: nothing changes.
 * A link that was just paid, or whose payment is going through, keeps its
 * hold and the call ends in 409 payment_in_progress once every other link is
 * closed. Returns how many links were closed and released.
 */
export async function releaseDepositLinks(
  s: Services,
  account: AccountRow,
  pages: DepositLinkJobs,
): Promise<number> {
  const { shopId, jobIds } = pages;
  if (jobIds.length === 0) return 0;
  const match = sessionFor.deposits(shopId, jobIds);
  const listed = new Set<string>();
  const customer = await loadCustomer(s.admin, shopId, pages.customerId);
  if (customer.stripe_customer_id) {
    for (
      const session of await customerSessions(s, account, customer.stripe_customer_id, "open")
    ) {
      if (session.status === "open" && match(session)) listed.add(session.id);
    }
  }

  const closed: string[] = [];
  let paying = false;
  for (const sessionId of listed) {
    if (await closePayLink(s, account, sessionId) === "closed") closed.push(sessionId);
    else paying = true;
  }
  for (const sessionId of await depositHolds(s, shopId, jobIds)) {
    if (listed.has(sessionId)) continue;
    const outcome = await heldDepositLink(s, account, sessionId, match);
    if (outcome === "closed") closed.push(sessionId);
    else if (outcome === "paying") paying = true;
  }
  if (closed.length > 0) {
    // The closed links' job holds (they have no invoice hold), then the
    // database's own release for each job (idempotent), by session only.
    await releaseCheckoutHolds(s, shopId, closed);
    for (const jobId of jobIds) {
      const { error } = await s.admin.rpc("payments_release_job_checkouts", {
        p_shop_id: shopId,
        p_job_id: jobId,
        p_session_ids: closed,
      });
      if (error) throw dbFailure("payments_release_job_checkouts", error);
    }
  }
  if (paying) throw payLinkPaying();
  return closed.length;
}

/** What a customer's erasure closes: their Stripe customers' pages and their documents' holds. */
export interface CustomerPages {
  shopId: string;
  /** The Stripe customers of the customer and of every duplicate merged into them. */
  stripeCustomers: ReadonlyArray<string>;
  /** Their jobs and invoices (holds of pages opened for an earlier customer too). */
  jobIds: ReadonlyArray<string>;
  invoiceIds: ReadonlyArray<string>;
}

/**
 * Before a customer is erased (erase_customer, 0125): every Checkout Session
 * the CRM opened on the shop's account for the customer is expired — the
 * Stripe customers' open sessions of this shop (pay and deposit links,
 * card-setup and membership join links) and every live job / invoice hold of
 * their jobs and invoices (a page opened for a previous customer) — and the
 * holds are released, so the database's checkout_open refusal is cleared.
 * 409 payment_in_progress when one was just paid (the others are closed
 * first; the paid one keeps its hold until its payment row lands). Returns
 * how many sessions this call expired.
 */
export async function releaseCustomerPages(
  s: Services,
  account: AccountRow,
  pages: CustomerPages,
): Promise<number> {
  const { shopId } = pages;
  const ours: SessionMatch = (session) => session.metadata?.shop_id === shopId;
  const expired: string[] = [];
  for (const stripeCustomer of new Set(pages.stripeCustomers)) {
    expired.push(
      ...await expireOpenSessions(s, account, stripeCustomer, ours, undefined, {
        refuseCompleted: true,
      }),
    );
  }
  const held = new Set<string>(await liveHolds(s, shopId, pages.jobIds, null));
  if (pages.invoiceIds.length > 0) {
    const { data, error } = await s.admin
      .from("invoice_checkout_holds")
      .select("stripe_checkout_session_id")
      .eq("shop_id", shopId)
      .in("invoice_id", [...pages.invoiceIds])
      .gt("expires_at", new Date(s.now).toISOString());
    if (error) throw dbFailure("invoice_checkout_holds lookup", error);
    for (const row of (data ?? []) as Array<{ stripe_checkout_session_id: string }>) {
      held.add(row.stripe_checkout_session_id);
    }
  }
  const released: string[] = [];
  let paid = false;
  for (const sessionId of held) {
    if (expired.includes(sessionId)) continue;
    const outcome = await closeSession(s, account, sessionId);
    if (outcome === "complete") {
      paid = true; // keeps its hold: its payment row releases it
      continue;
    }
    if (outcome === "expired") expired.push(sessionId);
    released.push(sessionId);
  }
  await releaseCheckoutHolds(s, shopId, released);
  if (paid) throw paymentInProgress();
  return expired.length;
}
