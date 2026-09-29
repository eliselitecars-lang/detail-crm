/**
 * Staff payment actions (JWT + role verified here; payments has
 * verify_jwt = false because of its public actions):
 *   payment_sheet      manager+, or an assigned technician when the shop lets
 *                      technicians collect (iOS PaymentSheet). Only manager+
 *                      get the Stripe customer + ephemeral key (saved cards).
 *   cancel_open_payments  same callers: release an invoice or a job (cancel
 *                      unconfirmed sheets, expire open Checkout sessions)
 *   sweep_payment_sheets  pg_cron (x-cron-secret): abandon stale sheets
 *   charge_saved_card  manager+ (off-session charge of a saved card)
 *   setup_card         manager+ (SetupIntent for PaymentSheet setup mode)
 *   setup_card_link    manager+ (Checkout setup-mode link to text/email)
 *   remove_saved_card  manager+ (detach in Stripe, then drop from the CRM)
 *   refund             owner/admin (Stripe payments: card, card_present,
 *                      ach_debit, bnpl; cash etc. use refund_manual_payment)
 *   terminal_payment_intent  same callers as payment_sheet (terminal.ts):
 *                      a card_present intent for Tap to Pay / a reader
 *
 * The staff intents and SetupIntents are card-only (payment_method_types
 * ['card'], or ['card_present'] in person): a sheet, a saved card or a
 * reader settles at once. Bank debits and pay-later are offered only on the
 * public Checkout links (public.ts, P-31).
 */
import { z } from "zod";
import {
  hasRole,
  isAssignedToJob,
  type Membership,
  requireCronSecret,
  requireShopRole,
  requireUser,
  ROLES,
} from "../_shared/auth.ts";
import { errors, HttpError } from "../_shared/errors.ts";
import { links, withQuery } from "../_shared/links.ts";
import {
  releaseInvoiceCheckouts,
  releaseJobCheckouts,
  supersedeInvoicePages,
} from "./checkout_holds.ts";
import { nonNegativeCents, positiveCents, requestNonce, uuid } from "../_shared/schemas.ts";
import { idempotencyKey, onAccount, type Stripe, STRIPE_API_VERSION } from "../_shared/stripe.ts";
import { isStripeError } from "../_shared/stripe_errors.ts";
import {
  type AccountRow,
  assertPayable,
  boundedTip,
  chargeable,
  dbFailure,
  ensureStripeCustomer,
  ephemeralKey,
  findAccount,
  IDEMPOTENCY_WINDOW_MS,
  invoiceJobIds,
  type InvoiceRow,
  isInvalidRequest,
  liveInvoiceForJob,
  loadAccount,
  loadCustomer,
  loadInvoice,
  loadShop,
  loadShopSlug,
  metadata,
  payableBalance,
  paymentInProgress,
  platformFee,
  requestedAmount,
  requestPart,
  rpcError,
  type Services,
  sessionFor,
  type ShopRow,
} from "./lib.ts";
import { settleInvoice, settleJob, settlePending, sweepStale } from "./settle.ts";

/** Stripe API version for the ephemeral key (must match the mobile SDK's when it asks). */
const apiVersion = z.string().regex(
  /^\d{4}-\d{2}-\d{2}(\.[a-z]+)?$/,
  "must be a Stripe API version like 2026-08-26.dahlia",
);

export const paymentSheetInput = z.object({
  shop_id: uuid,
  invoice_id: uuid,
  amount_cents: positiveCents.optional(),
  tip_cents: nonNegativeCents.optional(),
  request_nonce: requestNonce.optional(),
  ephemeral_key_api_version: apiVersion.optional(),
}).strict();

export const cancelOpenPaymentsInput = z.object({
  shop_id: uuid,
  invoice_id: uuid.optional(),
  job_id: uuid.optional(),
}).strict().refine((input) => (input.invoice_id === undefined) !== (input.job_id === undefined), {
  message: "give exactly one of invoice_id or job_id",
  path: ["invoice_id"],
});

export const removeSavedCardInput = z.object({
  shop_id: uuid,
  customer_id: uuid,
  payment_method_id: z.string().regex(/^(pm|card|src)_[A-Za-z0-9]+$/, "must be a saved card id"),
}).strict();

export const sweepPaymentSheetsInput = z.object({}).strict();

export const chargeSavedCardInput = z.object({
  shop_id: uuid,
  invoice_id: uuid,
  payment_method_id: z.string().regex(/^(pm|card|src)_[A-Za-z0-9]+$/, "must be a saved card id")
    .optional(),
  amount_cents: positiveCents.optional(),
  request_nonce: requestNonce.optional(),
}).strict();

export const setupCardInput = z.object({
  shop_id: uuid,
  customer_id: uuid,
  request_nonce: requestNonce.optional(),
  ephemeral_key_api_version: apiVersion.optional(),
}).strict();

export const setupCardLinkInput = z.object({
  shop_id: uuid,
  customer_id: uuid,
  request_nonce: requestNonce.optional(),
}).strict();

export const refundInput = z.object({
  shop_id: uuid,
  payment_id: uuid,
  amount_cents: positiveCents.optional(),
  /** One per refund attempt; a retry of the same attempt reuses it. */
  request_nonce: requestNonce.optional(),
}).strict();

// ---------------------------------------------------------------------------

/** manager+, or a technician assigned to the invoice's job when allowed. */
async function requireCollector(
  s: Services,
  req: Request,
  shopId: string,
  invoiceId: string,
): Promise<{ membership: Membership; invoice: InvoiceRow }> {
  const caller = await requireUser(req, { admin: s.admin });
  const membership = await requireShopRole(s.admin, caller, shopId, ROLES.anyStaff);
  if (hasRole(membership, ROLES.managerPlus)) {
    return { membership, invoice: await loadInvoice(s.admin, shopId, invoiceId) };
  }
  await requireTechCollection(s, shopId);
  const invoice = await loadInvoice(s.admin, shopId, invoiceId);
  if (
    !invoice.job_id || !(await isAssignedToJob(s.admin, shopId, invoice.job_id, membership.id))
  ) {
    throw errors.forbidden("You can only collect payments for jobs assigned to you.");
  }
  return { membership, invoice };
}

/** A technician collects only while the shop allows it (shops.techs_can_collect_payments). */
async function requireTechCollection(s: Services, shopId: string): Promise<void> {
  const shop = await loadShop(s.admin, shopId);
  if (!shop.techs_can_collect_payments) {
    throw errors.forbidden("Your role does not allow collecting payments.");
  }
}

/**
 * Someone who may collect in this shop at all (no invoice yet): manager+,
 * or a technician while the shop lets technicians collect. Used to set up a
 * card reader (terminal_location / terminal_connection_token); every
 * payment still checks the invoice (requireCollector).
 */
export async function requireShopCollector(
  s: Services,
  req: Request,
  shopId: string,
): Promise<Membership> {
  const caller = await requireUser(req, { admin: s.admin });
  const membership = await requireShopRole(s.admin, caller, shopId, ROLES.anyStaff);
  if (!hasRole(membership, ROLES.managerPlus)) await requireTechCollection(s, shopId);
  return membership;
}

interface JobRow {
  id: string;
  shop_id: string;
  customer_id: string;
}

/** The same callers for a job: manager+, or its assigned technician when allowed. */
async function requireJobCollector(
  s: Services,
  req: Request,
  shopId: string,
  jobId: string,
): Promise<JobRow> {
  const caller = await requireUser(req, { admin: s.admin });
  const membership = await requireShopRole(s.admin, caller, shopId, ROLES.anyStaff);
  if (!hasRole(membership, ROLES.managerPlus)) await requireTechCollection(s, shopId);
  const { data, error } = await s.admin
    .from("jobs")
    .select("id, shop_id, customer_id")
    .eq("shop_id", shopId)
    .eq("id", jobId)
    .maybeSingle();
  if (error) throw dbFailure("jobs lookup", error);
  if (!data) throw errors.notFound("Job not found.");
  const job = data as JobRow;
  if (
    !hasRole(membership, ROLES.managerPlus) &&
    !(await isAssignedToJob(s.admin, shopId, job.id, membership.id))
  ) {
    throw errors.forbidden("You can only collect payments for jobs assigned to you.");
  }
  return job;
}

async function recordStripePayment(
  s: Services,
  args: Record<string, unknown>,
): Promise<{ id: string; status: string } | null> {
  const { data, error } = await s.admin.rpc("upsert_stripe_payment", args);
  if (error) {
    // Stripe already has the truth; the webhook records it. Never fail the
    // request after money moved, but make the gap visible.
    s.log.error("payment_record_failed", {
      shop_id: args.p_shop_id,
      payment_intent: args.p_payment_intent_id,
      error,
    });
    return null;
  }
  const row = data as { id?: string; status?: string } | null;
  return row?.id && row.status ? { id: row.id, status: row.status } : null;
}

/**
 * Expires the invoice's open Checkout pay links, and its jobs' open deposit
 * links, before a staff attempt charges it (one live payment instrument per
 * invoice: a deposit payment is attached to the job's invoice, so a deposit
 * link paid after the balance was collected would overpay it). Both the
 * customer's sessions Stripe lists and every live hold the database has for
 * the invoice and its jobs (supersedeInvoicePages: also a page opened for a
 * customer merged into this one) are closed, the same set cash is refused
 * for. 409 when one of them was paid in the meantime.
 */
async function supersedePayLinks(
  s: Services,
  account: AccountRow,
  invoice: InvoiceRow,
  stripeCustomer: string | null,
): Promise<void> {
  const customerId = stripeCustomer ??
    (await loadCustomer(s.admin, invoice.shop_id, invoice.customer_id)).stripe_customer_id;
  const jobIds = await invoiceJobIds(s.admin, invoice);
  await supersedeInvoicePages(
    s,
    account,
    invoice,
    jobIds,
    customerId,
    sessionFor.invoiceOrDeposit(invoice.shop_id, invoice, jobIds),
  );
}

// ---------------------------------------------------------------------------
// payment_sheet / terminal_payment_intent (intents a device confirms)
// ---------------------------------------------------------------------------

/**
 * The two ways a device collects an invoice payment: the iOS PaymentSheet
 * (card entered / wallet, card-not-present) and Stripe Terminal (Tap to Pay
 * on iPhone or a reader, card_present). They share every money rule; only
 * the intent's payment method type, the saved-card customer (sheet,
 * manager+) and the idempotency scope differ.
 */
export type DeviceChannel = "sheet" | "terminal";

export interface DeviceIntentInput {
  shop_id: string;
  invoice_id: string;
  amount_cents?: number;
  tip_cents?: number;
  request_nonce?: string;
}

export interface DeviceIntent {
  membership: Membership;
  shop: ShopRow;
  account: AccountRow;
  invoice: InvoiceRow;
  intent: Stripe.PaymentIntent & { client_secret: string };
  stripeCustomer: string | null;
  amount: number;
  tip: number;
  part: string;
}

const CHANNEL = {
  sheet: {
    scope: "payment_sheet",
    source: "payment_sheet",
    method: "card",
    types: ["card"],
  },
  terminal: {
    scope: "terminal_intent",
    source: "terminal",
    method: "card_present",
    types: ["card_present"],
  },
} as const;

/**
 * Opens (or, for a retry of the same request, hands back) the device's
 * PaymentIntent for `amount_cents` (default: what can be paid now) plus a
 * bounded tip, after settling the invoice's earlier attempts (latest wins)
 * and expiring its open pay / deposit links, and records the pending payment
 * row. Money in flight (an attempt processing, ACH clearing) is never
 * charged twice: 409 payment_in_progress, or the amount is bounded by what
 * is not already on its way.
 */
export async function openDeviceIntent(
  s: Services,
  req: Request,
  input: DeviceIntentInput,
  channel: DeviceChannel,
): Promise<DeviceIntent> {
  const how = CHANNEL[channel];
  const { membership, invoice: requested } = await requireCollector(
    s,
    req,
    input.shop_id,
    input.invoice_id,
  );
  // Saved cards are manager+ (SPEC §3): only they get the customer on the
  // sheet. A technician's sheet takes a new card and cannot list, charge or
  // detach the customer's saved ones. A reader never uses saved cards.
  const withCustomer = channel === "sheet" && hasRole(membership, ROLES.managerPlus);
  assertPayable(requested);
  const shop = await loadShop(s.admin, requested.shop_id);
  const account = await loadAccount(s.admin, shop.id);
  const stripeCustomer = withCustomer
    ? await ensureStripeCustomer(
      s,
      account,
      await loadCustomer(s.admin, shop.id, requested.customer_id),
    )
    : null;
  const part = requestPart(input.request_nonce, s.now);

  const keyFor = async (invoice: InvoiceRow) => {
    // What can be paid now: the balance less ACH debits still clearing.
    const balance = await payableBalance(s, invoice);
    const amount = requestedAmount(input.amount_cents, balance);
    // Bounded by what this attempt collects, never the balance: a tip is
    // fee-free and never lowers the balance.
    const tip = boundedTip(input.tip_cents, amount);
    const total = chargeable(amount + tip, shop.currency);
    const parts = [invoice.id, amount, tip, balance, stripeCustomer ?? "no_customer", part];
    return {
      balance,
      amount,
      tip,
      total,
      parts,
      key: await idempotencyKey(how.scope, ...parts),
    };
  };

  // Latest attempt wins: settle this invoice's earlier attempts first (an
  // abandoned sheet or reader would otherwise keep the invoice locked). The
  // intent a retry of this same request created is handed back, not
  // cancelled.
  let invoice = requested;
  let request = await keyFor(invoice);
  const earlier = await settleInvoice(s, account, shop.id, invoice.id, {
    keepRequestKey: request.key,
  });
  if (earlier.succeeded > 0) {
    // Money landed that the webhook had not recorded yet: charge what is left.
    for (const row of earlier.kept) await settlePending(s, account, row);
    invoice = await loadInvoice(s.admin, shop.id, invoice.id);
    request = await keyFor(invoice);
  }
  if (earlier.in_progress > 0) throw paymentInProgress();
  // Latest attempt wins the other way too: the invoice's open pay links
  // (texted / emailed Checkout) are expired, so the customer cannot pay the
  // same balance there while this attempt is open. A link paid just now -> 409.
  await supersedePayLinks(s, account, invoice, stripeCustomer);
  const { amount, tip, total, parts } = request;
  const fee = platformFee(s.env, amount);

  const intent = await freshIntent(s, account, how.scope, parts, {
    amount: total,
    currency: shop.currency,
    ...(stripeCustomer ? { customer: stripeCustomer } : {}),
    payment_method_types: [...how.types],
    // In person: captured as soon as the reader confirms (no separate
    // capture step; the pinned API version supports automatic capture for
    // card_present).
    ...(channel === "terminal" ? { capture_method: "automatic" as const } : {}),
    description: `${shop.name} invoice #${invoice.number}`,
    metadata: metadata({
      shop_id: shop.id,
      invoice_id: invoice.id,
      job_id: invoice.job_id,
      customer_id: invoice.customer_id,
      kind: "payment",
      tip_cents: tip,
      source: how.source,
      channel: channel === "terminal" ? "terminal" : null,
      member_id: membership.id,
      request_key: request.key,
    }),
    ...(fee ? { application_fee_amount: fee } : {}),
  });

  // Shows as pending on the invoice until the webhook settles it, the
  // attempt is cancelled (cancel_open_payments) or the sweep abandons it.
  await recordStripePayment(s, {
    p_shop_id: shop.id,
    p_payment_intent_id: intent.id,
    p_status: "pending",
    p_amount_cents: amount,
    p_tip_cents: tip,
    p_kind: "payment",
    p_method: how.method,
    p_invoice_id: invoice.id,
    p_customer_id: invoice.customer_id,
    p_stripe_method_type: how.types[0],
  });
  return { membership, shop, account, invoice, intent, stripeCustomer, amount, tip, part };
}

export async function paymentSheet(
  s: Services,
  req: Request,
  input: z.output<typeof paymentSheetInput>,
): Promise<Record<string, unknown>> {
  const opened = await openDeviceIntent(s, req, input, "sheet");
  const { account, intent, stripeCustomer } = opened;
  const ephemeral = stripeCustomer
    ? await ephemeralKey(
      s,
      account,
      stripeCustomer,
      input.ephemeral_key_api_version ?? STRIPE_API_VERSION,
      opened.part,
    )
    : null;
  return {
    payment_intent_id: intent.id,
    payment_intent_client_secret: intent.client_secret,
    ...(stripeCustomer && ephemeral
      ? { ephemeral_key_secret: ephemeral, customer_id: stripeCustomer }
      : {}),
    publishable_key: s.env.stripe().publishableKey,
    stripe_account_id: account.stripe_account_id,
    amount_cents: opened.amount,
    tip_cents: opened.tip,
    currency: opened.shop.currency,
  };
}

/**
 * Creates the sheet's (or reader's) PaymentIntent and returns it only while
 * it is really unconfirmed. Stripe replays the FIRST response stored under a key
 * (creation-time state) for 24 hours, so a replay never shows that the
 * intent was cancelled since (a newer sheet, cancel_open_payments, a pay
 * link) or paid: the intent is re-read after every create. A cancelled one
 * is replaced under a key chained on its id; one that already moved money is
 * 409 (the webhook records it).
 */
async function freshIntent(
  s: Services,
  account: AccountRow,
  scope: string,
  parts: ReadonlyArray<string | number>,
  params: Stripe.PaymentIntentCreateParams,
): Promise<Stripe.PaymentIntent & { client_secret: string }> {
  const chain: string[] = [];
  for (let attempt = 0; attempt < 4; attempt++) {
    const created = await s.stripe.paymentIntents.create(
      params,
      onAccount(account.stripe_account_id, {
        idempotencyKey: await idempotencyKey(scope, ...parts, ...chain),
      }),
    );
    const intent = await s.stripe.paymentIntents.retrieve(
      created.id,
      {},
      onAccount(account.stripe_account_id),
    );
    if (intent.status === "canceled") {
      chain.push(`after:${created.id}`);
      continue;
    }
    if (intent.status === "succeeded" || intent.status === "processing") throw paymentInProgress();
    const clientSecret = intent.client_secret ?? created.client_secret;
    if (!clientSecret) throw new Error("Stripe returned a PaymentIntent without a secret");
    return { ...intent, client_secret: clientSecret };
  }
  throw errors.conflict("This payment keeps changing. Refresh and try again.", {
    reason: "payment_superseded",
  });
}

// ---------------------------------------------------------------------------
// cancel_open_payments / sweep_payment_sheets
// ---------------------------------------------------------------------------

/**
 * Releases an invoice: cancels its unconfirmed PaymentSheet intents (their
 * pending rows block void / pricing / line-item edits) and expires its open
 * Checkout sessions and its job's open deposit sessions (so an old pay or
 * deposit link cannot be paid after a void or edit; the public pages open a
 * fresh one for what is still due), and releases every live page hold of
 * the invoice and its jobs (0106 / 0109: the holds that make cash, checks and
 * gift cards refuse with checkout_open). Call it when a sheet is dismissed,
 * before voiding or editing, and on checkout_open before retrying.
 *
 * With `job_id` instead, releases a job before it is cancelled / marked
 * no-show or moved to another customer: every unsettled card attempt of the
 * job (its deposits and its invoice's payments), the deposit links opened for
 * the job's CURRENT customer and, when the job has a non-void invoice, that
 * invoice's pay links; every live hold of the job and of that invoice is
 * released.
 *
 * Payments already processing are reported (`in_progress`), never cancelled.
 */
export async function cancelOpenPayments(
  s: Services,
  req: Request,
  input: z.output<typeof cancelOpenPaymentsInput>,
): Promise<Record<string, unknown>> {
  if (input.job_id !== undefined) {
    return await cancelOpenJobPayments(s, req, input.shop_id, input.job_id);
  }
  const { invoice } = await requireCollector(s, req, input.shop_id, input.invoice_id ?? "");
  const released = { invoice_id: invoice.id, job_id: invoice.job_id ?? null };
  const account = await findAccount(s.admin, invoice.shop_id);
  if (!account) return { ...released, ...NOTHING_RELEASED };
  const settled = await settleInvoice(s, account, invoice.shop_id, invoice.id);
  const jobIds = await invoiceJobIds(s.admin, invoice);
  // The customer's open pay / deposit pages and every live hold of the
  // invoice and its jobs (0106 / 0109) — what makes record_manual_payment
  // and gift card redemptions refuse with checkout_open — are expired and
  // released, so the staff apps' "cancel open payments and try again" works
  // even for a page an earlier attempt already expired, or one opened for a
  // previous customer. A page that was just paid keeps its hold (reported
  // through `settled` once its payment row lands).
  const expired = await releaseInvoiceCheckouts(
    s,
    account,
    invoice,
    jobIds,
    sessionFor.invoiceOrDeposit(invoice.shop_id, invoice, jobIds),
  );
  return {
    ...released,
    cancelled: settled.cancelled,
    succeeded: settled.succeeded,
    in_progress: settled.in_progress,
    sessions_expired: expired.length,
  };
}

const NOTHING_RELEASED = { cancelled: 0, succeeded: 0, in_progress: 0, sessions_expired: 0 };

async function cancelOpenJobPayments(
  s: Services,
  req: Request,
  shopId: string,
  jobId: string,
): Promise<Record<string, unknown>> {
  const job = await requireJobCollector(s, req, shopId, jobId);
  // The job's live invoice, single or grouped (P-7).
  const invoice = await liveInvoiceForJob(s.admin, job.shop_id, job.id);
  const released = { invoice_id: invoice?.id ?? null, job_id: job.id };
  const account = await findAccount(s.admin, job.shop_id);
  if (!account) return { ...released, ...NOTHING_RELEASED };

  // Every card row that carries the job: its deposits and the payments of
  // its invoice (payments_before_write stamps the invoice's job on them).
  const settled = await settleJob(s, account, job.shop_id, job.id);
  const match = invoice
    ? sessionFor.invoiceOrDeposit(job.shop_id, invoice, [job.id])
    : sessionFor.deposit(job.shop_id, job.id);
  // The current customer's matching sessions and every page the database
  // still holds for the job (0106), released so a job staff reopen is not
  // left blocked for the customer's online cancel until Stripe expires them.
  // A page that was just paid is reported through `settled`, not refused.
  const expired = await releaseJobCheckouts(s, account, job, match, {
    refuseCompleted: false,
    invoiceId: invoice?.id ?? null,
  });
  return {
    ...released,
    cancelled: settled.cancelled,
    succeeded: settled.succeeded,
    in_progress: settled.in_progress,
    sessions_expired: expired.length,
  };
}

/** pg_cron (x-cron-secret): abandon PaymentSheet intents left unconfirmed. */
export async function sweepPaymentSheets(
  s: Services,
  req: Request,
): Promise<Record<string, unknown>> {
  requireCronSecret(req, s.env.cronSecret());
  return await sweepStale(s);
}

// ---------------------------------------------------------------------------
// charge_saved_card
// ---------------------------------------------------------------------------

interface SavedCard {
  stripe_payment_method_id: string;
  brand: string | null;
  last4: string | null;
  /**
   * The Stripe customer the card is attached to (P-20): a card moved to this
   * customer by a merge stays on the merged customer's Stripe customer, and
   * Stripe only charges it there. Null on rows saved before the column.
   */
  stripe_customer_id: string | null;
}

async function savedCard(
  s: Services,
  shopId: string,
  customerId: string,
  paymentMethodId: string | undefined,
): Promise<SavedCard> {
  let query = s.admin
    .from("customer_payment_methods")
    .select("stripe_payment_method_id, brand, last4, stripe_customer_id")
    .eq("shop_id", shopId)
    .eq("customer_id", customerId);
  query = paymentMethodId
    ? query.eq("stripe_payment_method_id", paymentMethodId)
    : query.eq("is_default", true);
  const { data, error } = await query.maybeSingle();
  if (error) throw dbFailure("customer_payment_methods lookup", error);
  if (!data) {
    if (paymentMethodId) throw errors.notFound("That card is not saved for this customer.");
    throw errors.unprocessable("This customer has no saved card.", { reason: "no_saved_card" });
  }
  return data as SavedCard;
}

function cardDeclined(err: { message?: string; code?: string; decline_code?: string }): HttpError {
  const reason = err.code ?? "card_declined";
  const message = reason === "authentication_required"
    ? "The card's bank requires the customer to confirm this payment. Send them a payment link instead."
    : err.message || "The card was declined.";
  return new HttpError("payment_failed", message, {
    details: { reason, stripe_code: err.code ?? null, decline_code: err.decline_code ?? null },
    cause: err,
  });
}

/**
 * Idempotency key of an off-session charge. With a request_nonce the key is
 * the attempt itself (invoice, card, amount, nonce): the first charge lowers
 * the balance, so a balance in the key would give a retry of the SAME attempt
 * (response lost) a new key and charge the card twice. Without a nonce the
 * balance and a 10-minute window only collapse double-clicks.
 */
export async function chargeKey(
  invoiceId: string,
  paymentMethodId: string,
  amount: number,
  request: { nonce?: string; balance: number; now: number },
): Promise<string> {
  return request.nonce
    ? await idempotencyKey(
      "charge_saved_card",
      invoiceId,
      paymentMethodId,
      amount,
      requestPart(request.nonce, request.now),
    )
    : await idempotencyKey(
      "charge_saved_card",
      invoiceId,
      paymentMethodId,
      amount,
      request.balance,
      requestPart(undefined, request.now),
    );
}

export async function chargeSavedCard(
  s: Services,
  req: Request,
  input: z.output<typeof chargeSavedCardInput>,
): Promise<Record<string, unknown>> {
  const caller = await requireUser(req, { admin: s.admin });
  const membership = await requireShopRole(s.admin, caller, input.shop_id, ROLES.managerPlus);
  let invoice = await loadInvoice(s.admin, input.shop_id, input.invoice_id);
  assertPayable(invoice);
  const shop = await loadShop(s.admin, invoice.shop_id);
  const account = await loadAccount(s.admin, shop.id);
  // An open sheet on this invoice is superseded (or, if it already took the
  // money, recorded first) so the card is never charged for a stale balance.
  const earlier = await settleInvoice(s, account, shop.id, invoice.id);
  if (earlier.in_progress > 0) throw paymentInProgress();
  if (earlier.succeeded > 0) invoice = await loadInvoice(s.admin, shop.id, invoice.id);
  // The balance less ACH debits still clearing toward it.
  const balance = await payableBalance(s, invoice);
  const amount = requestedAmount(input.amount_cents, balance);
  chargeable(amount, shop.currency);
  const customer = await loadCustomer(s.admin, shop.id, invoice.customer_id);
  const card = await savedCard(s, shop.id, customer.id, input.payment_method_id);
  // The card's own Stripe customer (a merged-in card keeps its original one).
  const cardOwner = card.stripe_customer_id ?? customer.stripe_customer_id;
  if (!cardOwner) {
    throw errors.unprocessable("This customer has no saved card.", { reason: "no_saved_card" });
  }
  // An open pay link could otherwise be paid for the same balance.
  await supersedePayLinks(s, account, invoice, customer.stripe_customer_id);
  const fee = platformFee(s.env, amount);
  const base = {
    p_shop_id: shop.id,
    p_amount_cents: amount,
    p_tip_cents: 0,
    p_kind: "payment",
    p_method: "card",
    p_invoice_id: invoice.id,
    p_customer_id: invoice.customer_id,
    p_card_brand: card.brand,
    p_card_last4: card.last4,
    p_stripe_method_type: "card",
  };

  let intent: Stripe.PaymentIntent;
  try {
    intent = await s.stripe.paymentIntents.create(
      {
        amount,
        currency: shop.currency,
        customer: cardOwner,
        payment_method: card.stripe_payment_method_id,
        off_session: true,
        confirm: true,
        payment_method_types: ["card"],
        description: `${shop.name} invoice #${invoice.number}`,
        metadata: metadata({
          shop_id: shop.id,
          invoice_id: invoice.id,
          job_id: invoice.job_id,
          customer_id: invoice.customer_id,
          kind: "payment",
          tip_cents: 0,
          source: "charge_saved_card",
          member_id: membership.id,
        }),
        ...(fee ? { application_fee_amount: fee } : {}),
      },
      onAccount(account.stripe_account_id, {
        idempotencyKey: await chargeKey(invoice.id, card.stripe_payment_method_id, amount, {
          nonce: input.request_nonce,
          balance,
          now: s.now,
        }),
      }),
    );
  } catch (err) {
    if (isStripeError(err) && err.type === "StripeCardError") {
      const failed = (err as { payment_intent?: { id?: unknown } }).payment_intent?.id;
      if (typeof failed === "string" && /^pi_[A-Za-z0-9]+$/.test(failed)) {
        await recordStripePayment(s, { ...base, p_payment_intent_id: failed, p_status: "failed" });
      }
      throw cardDeclined(err);
    }
    if (isGoneCard(err)) {
      // Deleted in Stripe, or no longer attached to this customer (removed
      // in the dashboard / another sheet): it can never be charged again.
      await removeCardRow(s, shop.id, card.stripe_payment_method_id);
      throw new HttpError(
        "unprocessable",
        "That saved card is no longer available; it was removed.",
        {
          details: { reason: "saved_card_removed" },
          cause: err,
        },
      );
    }
    throw err;
  }

  if (intent.status === "requires_action" || intent.status === "requires_payment_method") {
    throw cardDeclined({
      code: intent.status === "requires_action" ? "authentication_required" : "card_declined",
    });
  }
  const succeeded = intent.status === "succeeded";
  const chargeId = typeof intent.latest_charge === "string"
    ? intent.latest_charge
    : intent.latest_charge?.id ?? null;
  const row = await recordStripePayment(s, {
    ...base,
    p_payment_intent_id: intent.id,
    p_status: succeeded ? "succeeded" : "pending",
    p_charge_id: chargeId,
    p_paid_at: succeeded ? new Date(s.now).toISOString() : null,
  });
  return {
    payment_id: row?.id ?? null,
    payment_intent_id: intent.id,
    status: succeeded ? "succeeded" : "processing",
    amount_cents: amount,
    card_brand: card.brand,
    card_last4: card.last4,
  };
}

/**
 * Stripe refused the saved card itself: the payment method is missing
 * (resource_missing) or not attached to this customer any more (an invalid
 * request about the payment_method parameter).
 */
function isGoneCard(err: unknown): boolean {
  if (!isInvalidRequest(err)) return false;
  const e = err as { code?: unknown; param?: unknown };
  return e.param === "payment_method" ||
    (e.code === "resource_missing" && (e.param === undefined || e.param === "payment_method"));
}

/** remove_customer_payment_method (0011, service role): also promotes the next default. */
export async function removeCardRow(
  s: Services,
  shopId: string,
  paymentMethodId: string,
): Promise<boolean> {
  const { data, error } = await s.admin.rpc("remove_customer_payment_method", {
    p_shop_id: shopId,
    p_stripe_payment_method_id: paymentMethodId,
  });
  if (error) throw rpcError("remove_customer_payment_method", error);
  return data === true;
}

// ---------------------------------------------------------------------------
// remove_saved_card
// ---------------------------------------------------------------------------

/**
 * Staff remove a customer's saved card (manager+, like charging it). The card
 * is detached from the customer's Stripe customer on the connected account
 * (so no PaymentSheet or charge can use it again), then removed from the CRM.
 * A card Stripe no longer has, or that is attached to another Stripe
 * customer, is only removed from the CRM. `removed: false` when the CRM no
 * longer lists that card for the customer (a retry after success).
 */
export async function removeSavedCard(
  s: Services,
  req: Request,
  input: z.output<typeof removeSavedCardInput>,
): Promise<{ removed: boolean }> {
  const caller = await requireUser(req, { admin: s.admin });
  await requireShopRole(s.admin, caller, input.shop_id, ROLES.managerPlus);
  const customer = await loadCustomer(s.admin, input.shop_id, input.customer_id);
  const { data, error } = await s.admin
    .from("customer_payment_methods")
    .select("stripe_payment_method_id, stripe_customer_id")
    .eq("shop_id", customer.shop_id)
    .eq("customer_id", customer.id)
    .eq("stripe_payment_method_id", input.payment_method_id)
    .maybeSingle();
  if (error) throw dbFailure("customer_payment_methods lookup", error);
  if (!data) return { removed: false };
  // The Stripe customer the card is attached to: a card moved by a customer
  // merge (P-20) stays on the duplicate's Stripe customer.
  const owner = (data as { stripe_customer_id: string | null }).stripe_customer_id ??
    customer.stripe_customer_id;

  const account = await findAccount(s.admin, customer.shop_id);
  if (account) await detachCard(s, account, owner, input.payment_method_id);
  const removed = await removeCardRow(s, customer.shop_id, input.payment_method_id);
  s.log.info("saved_card_removed", {
    shop_id: customer.shop_id,
    customer_id: customer.id,
    payment_method: input.payment_method_id,
  });
  return { removed };
}

/** Detaches the card from the customer's Stripe customer; never from another customer. */
export async function detachCard(
  s: Services,
  account: AccountRow,
  stripeCustomer: string | null,
  paymentMethodId: string,
): Promise<void> {
  let pm: Stripe.PaymentMethod;
  try {
    pm = await s.stripe.paymentMethods.retrieve(
      paymentMethodId,
      {},
      onAccount(account.stripe_account_id),
    );
  } catch (err) {
    if (isInvalidRequest(err) && isMissingStripeObject(err)) return;
    throw err;
  }
  const owner = typeof pm.customer === "string" ? pm.customer : pm.customer?.id ?? null;
  if (!owner) return; // already detached
  if (owner !== stripeCustomer) {
    s.log.warn("saved_card_owner_mismatch", {
      shop_id: account.shop_id,
      payment_method: paymentMethodId,
    });
    return;
  }
  try {
    await s.stripe.paymentMethods.detach(
      paymentMethodId,
      {},
      onAccount(account.stripe_account_id, {
        idempotencyKey: await idempotencyKey("pm_detach", paymentMethodId),
      }),
    );
  } catch (err) {
    // Detached or deleted meanwhile: the outcome we wanted.
    if (!isInvalidRequest(err)) throw err;
    s.log.warn("saved_card_detach_skipped", {
      shop_id: account.shop_id,
      payment_method: paymentMethodId,
    });
  }
}

function isMissingStripeObject(err: unknown): boolean {
  const e = err as { code?: unknown; statusCode?: unknown };
  return e.code === "resource_missing" || e.statusCode === 404;
}

// ---------------------------------------------------------------------------
// setup_card / setup_card_link
// ---------------------------------------------------------------------------

async function setupContext(
  s: Services,
  req: Request,
  shopId: string,
  customerId: string,
) {
  const caller = await requireUser(req, { admin: s.admin });
  await requireShopRole(s.admin, caller, shopId, ROLES.managerPlus);
  const customer = await loadCustomer(s.admin, shopId, customerId);
  if (customer.archived_at) {
    throw errors.unprocessable("This customer is archived.", { reason: "customer_archived" });
  }
  const shop = await loadShop(s.admin, shopId);
  const account: AccountRow = await loadAccount(s.admin, shopId);
  const stripeCustomer = await ensureStripeCustomer(s, account, customer);
  // Webhook metadata contract: shop_id + customer_id link the saved card.
  const meta = metadata({ shop_id: shopId, customer_id: customer.id });
  return { shop, account, customer, stripeCustomer, meta };
}

export async function setupCard(
  s: Services,
  req: Request,
  input: z.output<typeof setupCardInput>,
): Promise<Record<string, unknown>> {
  const { account, customer, stripeCustomer, meta } = await setupContext(
    s,
    req,
    input.shop_id,
    input.customer_id,
  );
  const part = requestPart(input.request_nonce, s.now);
  const intent = await s.stripe.setupIntents.create(
    {
      customer: stripeCustomer,
      usage: "off_session",
      payment_method_types: ["card"],
      metadata: { ...meta, source: "setup_card" },
    },
    onAccount(account.stripe_account_id, {
      idempotencyKey: await idempotencyKey("setup_card", customer.id, stripeCustomer, part),
    }),
  );
  if (!intent.client_secret) throw new Error("Stripe returned a SetupIntent without a secret");
  const ephemeral = await ephemeralKey(
    s,
    account,
    stripeCustomer,
    input.ephemeral_key_api_version ?? STRIPE_API_VERSION,
    part,
  );
  return {
    setup_intent_id: intent.id,
    setup_intent_client_secret: intent.client_secret,
    ephemeral_key_secret: ephemeral,
    customer_id: stripeCustomer,
    publishable_key: s.env.stripe().publishableKey,
    stripe_account_id: account.stripe_account_id,
  };
}

export async function setupCardLink(
  s: Services,
  req: Request,
  input: z.output<typeof setupCardLinkInput>,
): Promise<Record<string, unknown>> {
  const { shop, account, customer, stripeCustomer, meta } = await setupContext(
    s,
    req,
    input.shop_id,
    input.customer_id,
  );
  // A public page: the customer who got this link by text has no account.
  const done = links.checkoutDone(s.env.appBaseUrl(), await loadShopSlug(s.admin, shop.id));
  const session = await s.stripe.checkout.sessions.create(
    {
      mode: "setup",
      currency: shop.currency,
      payment_method_types: ["card"],
      customer: stripeCustomer,
      client_reference_id: customer.id,
      setup_intent_data: {
        description: `Save a card with ${shop.name}`,
        metadata: { ...meta, source: "setup_card_link" },
      },
      metadata: { ...meta, source: "setup_card_link" },
      success_url: withQuery(done, { card: "saved" }),
      cancel_url: withQuery(done, { card: "canceled" }),
    },
    onAccount(account.stripe_account_id, {
      idempotencyKey: await idempotencyKey(
        "setup_card_link",
        customer.id,
        stripeCustomer,
        requestPart(input.request_nonce, s.now),
      ),
    }),
  );
  if (!session.url) throw new Error("Stripe returned a Checkout Session without a URL");
  return { url: session.url, expires_at: session.expires_at };
}

// ---------------------------------------------------------------------------
// refund
// ---------------------------------------------------------------------------

interface PaymentRow {
  id: string;
  shop_id: string;
  method: string;
  status: string;
  amount_cents: number;
  tip_cents: number;
  refunded_cents: number;
  stripe_payment_intent_id: string | null;
}

/** Payment methods whose money Stripe holds (0061 payments_card_via_stripe). */
const STRIPE_METHODS: ReadonlySet<string> = new Set(["card", "card_present", "ach_debit", "bnpl"]);

/** Refund statuses that returned nothing to the customer. */
const DEAD_REFUND = new Set(["failed", "canceled"]);

/**
 * Idempotency key of one refund attempt: the payment, the requested amount
 * ("full" when none), the client's request_nonce (else a 10-minute window
 * that only collapses double-clicks) and the charge's refunds that FAILED.
 * Never the cumulative refunded total: the first refund raises it, so a retry
 * of the same attempt (response lost) would get a new key and refund twice.
 * The failed refunds are in it because Stripe replays the first response
 * stored under a key: a retry after a refund failed must create a new one,
 * not be handed the failed refund's creation-time "succeeded" body again.
 */
export async function refundKey(
  paymentId: string,
  requested: number | undefined,
  nonce: string | undefined,
  now: number,
  failedRefundIds: ReadonlyArray<string>,
): Promise<string> {
  return await idempotencyKey(
    "refund",
    paymentId,
    requested ?? "full",
    requestPart(nonce, now),
    ...[...failedRefundIds].sort(),
  );
}

/** Refund metadata marking a request made without a nonce (and its amount). */
function windowScope(requested: number | undefined): string {
  return `window:${requested ?? "full"}`;
}

export async function refund(
  s: Services,
  req: Request,
  input: z.output<typeof refundInput>,
): Promise<Record<string, unknown>> {
  const caller = await requireUser(req, { admin: s.admin });
  const membership = await requireShopRole(s.admin, caller, input.shop_id, ROLES.adminPlus);
  const { data, error } = await s.admin
    .from("payments")
    .select(
      "id, shop_id, method, status, amount_cents, tip_cents, refunded_cents, stripe_payment_intent_id",
    )
    .eq("shop_id", input.shop_id)
    .eq("id", input.payment_id)
    .maybeSingle();
  if (error) throw dbFailure("payments lookup", error);
  const payment = data as PaymentRow | null;
  if (!payment) throw errors.notFound("Payment not found.");
  const paymentIntentId = payment.stripe_payment_intent_id;
  if (!paymentIntentId || !STRIPE_METHODS.has(payment.method)) {
    // (the reason keeps its original name: it is a client contract)
    throw errors.unprocessable("Only payments taken through Stripe are refunded here.", {
      reason: "not_a_card_payment",
    });
  }
  if (!["succeeded", "partially_refunded"].includes(payment.status)) {
    throw errors.conflict(`A ${payment.status} payment cannot be refunded.`, {
      reason: "not_refundable",
    });
  }
  const account = await loadAccount(s.admin, payment.shop_id, { requireCharges: false });

  // Stripe is the source of truth for what was already refunded (refunds made
  // in the Stripe dashboard may not have reached the webhook yet).
  const intent = await s.stripe.paymentIntents.retrieve(
    paymentIntentId,
    { expand: ["latest_charge"] },
    onAccount(account.stripe_account_id),
  );
  const charge = typeof intent.latest_charge === "object" ? intent.latest_charge : null;
  if (!charge) {
    throw errors.conflict("This payment has no charge to refund.", { reason: "not_refundable" });
  }
  const existing = await s.stripe.refunds.list(
    { charge: charge.id, limit: 100 },
    onAccount(account.stripe_account_id),
  );
  const refunds = existing.data ?? [];
  const key = await refundKey(
    payment.id,
    input.amount_cents,
    input.request_nonce,
    s.now,
    refunds.filter((r) => DEAD_REFUND.has(r.status ?? "")).map((r) => r.id),
  );
  const charged = Math.min(payment.amount_cents + payment.tip_cents, charge.amount);
  const alreadyRefunded = Math.max(payment.refunded_cents, charge.amount_refunded);

  const record = async (total: number): Promise<string | null> => {
    const applied = await s.admin.rpc("apply_stripe_refund", {
      p_payment_intent_id: paymentIntentId,
      p_refunded_cents_total: total,
    });
    if (applied.error) {
      // The refund exists in Stripe; charge.refunded will reconcile the row.
      s.log.error("refund_record_failed", {
        shop_id: payment.shop_id,
        payment_id: payment.id,
        error: rpcError("apply_stripe_refund", applied.error),
      });
      return null;
    }
    return (applied.data as { status?: string } | null)?.status ?? null;
  };
  const result = async (made: Stripe.Refund, total: number) => ({
    payment_id: payment.id,
    refund_id: made.id,
    refund_status: made.status,
    amount_cents: made.amount,
    refunded_cents_total: total,
    payment_status: await record(total),
  });

  // An attempt Stripe already took. With a request_nonce it is a retry of
  // the same attempt (response lost): hand back that refund, which is
  // already part of charge.amount_refunded. Without a nonce a retry and a
  // deliberate second refund of the same amount look alike (same key in the
  // 10-minute bucket, or the same amount within IDEMPOTENCY_WINDOW_MS), so
  // the request is refused with 409 possible_duplicate_refund instead of a
  // success that refunded nothing: the caller sees the earlier refund and
  // sends a fresh request_nonce if a second refund is really meant.
  const scope = windowScope(input.amount_cents);
  const earlier = refunds.find((r) =>
    !DEAD_REFUND.has(r.status ?? "") &&
    (r.metadata?.request_key === key ||
      (!input.request_nonce && r.metadata?.payment_id === payment.id &&
        r.metadata?.retry_scope === scope && typeof r.created === "number" &&
        r.created * 1000 >= s.now - IDEMPOTENCY_WINDOW_MS))
  );
  if (earlier) {
    const done = await result(earlier, Math.min(alreadyRefunded, charged));
    if (input.request_nonce) return done;
    throw errors.conflict(
      "A refund of this amount was just made for this payment. Nothing new was refunded.",
      {
        reason: "possible_duplicate_refund",
        refund_id: done.refund_id,
        amount_cents: done.amount_cents,
        refunded_cents_total: done.refunded_cents_total,
      },
    );
  }

  const refundable = charged - alreadyRefunded;
  if (refundable <= 0) {
    throw errors.conflict("This payment is already fully refunded.", { reason: "fully_refunded" });
  }
  const amount = input.amount_cents ?? refundable;
  if (amount > refundable) {
    throw errors.unprocessable("The refund is more than the refundable amount.", {
      reason: "amount_exceeds_refundable",
      refundable_cents: refundable,
    });
  }

  const created = await s.stripe.refunds.create(
    {
      payment_intent: paymentIntentId,
      amount,
      ...((charge.application_fee_amount ?? 0) > 0 ? { refund_application_fee: true } : {}),
      metadata: metadata({
        shop_id: payment.shop_id,
        payment_id: payment.id,
        member_id: membership.id,
        request_key: key,
        retry_scope: input.request_nonce ? null : scope,
      }),
    },
    onAccount(account.stripe_account_id, { idempotencyKey: key }),
  );
  // A replay hands back the creation-time body: judge a listed refund by its
  // current state, which is already part of the charge's refunded total.
  const listed = refunds.find((r) => r.id === created.id);
  if (DEAD_REFUND.has((listed ?? created).status ?? "")) {
    throw errors.unprocessable("Stripe could not process this refund.", {
      reason: "refund_failed",
    });
  }
  return listed
    ? await result(listed, Math.min(alreadyRefunded, charged))
    : await result(created, alreadyRefunded + amount);
}
