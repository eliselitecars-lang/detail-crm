/**
 * Staff payment actions (JWT + role verified here; payments has
 * verify_jwt = false because of its public actions):
 *   payment_sheet      manager+, or an assigned technician when the shop lets
 *                      technicians collect (iOS PaymentSheet). Only manager+
 *                      get the Stripe customer + ephemeral key (saved cards).
 *   cancel_open_payments  same callers: release an invoice (cancel unconfirmed
 *                      sheets, expire open Checkout sessions)
 *   sweep_payment_sheets  pg_cron (x-cron-secret): abandon stale sheets
 *   charge_saved_card  manager+ (off-session charge of a saved card)
 *   setup_card         manager+ (SetupIntent for PaymentSheet setup mode)
 *   setup_card_link    manager+ (Checkout setup-mode link to text/email)
 *   refund             owner/admin (card payments; cash etc. use refund_manual_payment)
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
  expireOpenSessions,
  findAccount,
  IDEMPOTENCY_WINDOW_MS,
  type InvoiceRow,
  loadAccount,
  loadCustomer,
  loadInvoice,
  loadShop,
  metadata,
  paymentInProgress,
  platformFee,
  requestedAmount,
  requestPart,
  rpcError,
  type Services,
  sessionFor,
} from "./lib.ts";
import { settleInvoice, settlePending, sweepStale } from "./settle.ts";

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
  invoice_id: uuid,
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
  const shop = await loadShop(s.admin, shopId);
  if (!shop.techs_can_collect_payments) {
    throw errors.forbidden("Your role does not allow collecting payments.");
  }
  const invoice = await loadInvoice(s.admin, shopId, invoiceId);
  if (
    !invoice.job_id || !(await isAssignedToJob(s.admin, shopId, invoice.job_id, membership.id))
  ) {
    throw errors.forbidden("You can only collect payments for jobs assigned to you.");
  }
  return { membership, invoice };
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
 * Expires the invoice's open Checkout pay links, and its job's open deposit
 * links, before a staff attempt charges it (one live payment instrument per
 * invoice: a deposit payment is attached to the job's invoice, so a deposit
 * link paid after the balance was collected would overpay it). 409 when one
 * of them was paid in the meantime.
 */
async function supersedePayLinks(
  s: Services,
  account: AccountRow,
  invoice: InvoiceRow,
  stripeCustomer: string | null,
): Promise<void> {
  const customerId = stripeCustomer ??
    (await loadCustomer(s.admin, invoice.shop_id, invoice.customer_id)).stripe_customer_id;
  if (!customerId) return; // no pay link was ever created for this customer
  await expireOpenSessions(
    s,
    account,
    customerId,
    sessionFor.invoiceOrDeposit(invoice.shop_id, invoice),
    undefined,
    { refuseCompleted: true },
  );
}

// ---------------------------------------------------------------------------
// payment_sheet
// ---------------------------------------------------------------------------

export async function paymentSheet(
  s: Services,
  req: Request,
  input: z.output<typeof paymentSheetInput>,
): Promise<Record<string, unknown>> {
  const { membership, invoice: requested } = await requireCollector(
    s,
    req,
    input.shop_id,
    input.invoice_id,
  );
  // Saved cards are manager+ (SPEC §3): only they get the customer on the
  // sheet. A technician's sheet takes a new card and cannot list, charge or
  // detach the customer's saved ones.
  const withCustomer = hasRole(membership, ROLES.managerPlus);
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
    const balance = assertPayable(invoice);
    const amount = requestedAmount(input.amount_cents, balance);
    // Bounded by what this sheet collects, never the balance: a tip is
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
      key: await idempotencyKey("payment_sheet", ...parts),
    };
  };

  // Latest sheet wins: settle this invoice's earlier attempts first (an
  // abandoned sheet would otherwise keep the invoice locked). The intent a
  // retry of this same request created is handed back, not cancelled.
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
  // same balance there while this sheet is open. A link paid just now -> 409.
  await supersedePayLinks(s, account, invoice, stripeCustomer);
  const { amount, tip, total, parts } = request;
  const fee = platformFee(s.env, amount);

  const intent = await freshIntent(s, account, parts, {
    amount: total,
    currency: shop.currency,
    ...(stripeCustomer ? { customer: stripeCustomer } : {}),
    automatic_payment_methods: { enabled: true },
    description: `${shop.name} invoice #${invoice.number}`,
    metadata: metadata({
      shop_id: shop.id,
      invoice_id: invoice.id,
      job_id: invoice.job_id,
      customer_id: invoice.customer_id,
      kind: "payment",
      tip_cents: tip,
      source: "payment_sheet",
      member_id: membership.id,
      request_key: request.key,
    }),
    ...(fee ? { application_fee_amount: fee } : {}),
  });
  const ephemeral = stripeCustomer
    ? await ephemeralKey(
      s,
      account,
      stripeCustomer,
      input.ephemeral_key_api_version ?? STRIPE_API_VERSION,
      part,
    )
    : null;

  // Shows as pending on the invoice until the webhook settles it, the sheet
  // is cancelled (cancel_open_payments) or the sweep abandons it.
  await recordStripePayment(s, {
    p_shop_id: shop.id,
    p_payment_intent_id: intent.id,
    p_status: "pending",
    p_amount_cents: amount,
    p_tip_cents: tip,
    p_kind: "payment",
    p_method: "card",
    p_invoice_id: invoice.id,
    p_customer_id: invoice.customer_id,
  });

  return {
    payment_intent_id: intent.id,
    payment_intent_client_secret: intent.client_secret,
    ...(stripeCustomer && ephemeral
      ? { ephemeral_key_secret: ephemeral, customer_id: stripeCustomer }
      : {}),
    publishable_key: s.env.stripe().publishableKey,
    stripe_account_id: account.stripe_account_id,
    amount_cents: amount,
    tip_cents: tip,
    currency: shop.currency,
  };
}

/**
 * Creates the sheet's PaymentIntent and returns it only while it is really
 * unconfirmed. Stripe replays the FIRST response stored under a key
 * (creation-time state) for 24 hours, so a replay never shows that the
 * intent was cancelled since (a newer sheet, cancel_open_payments, a pay
 * link) or paid: the intent is re-read after every create. A cancelled one
 * is replaced under a key chained on its id; one that already moved money is
 * 409 (the webhook records it).
 */
async function freshIntent(
  s: Services,
  account: AccountRow,
  parts: ReadonlyArray<string | number>,
  params: Stripe.PaymentIntentCreateParams,
): Promise<Stripe.PaymentIntent & { client_secret: string }> {
  const chain: string[] = [];
  for (let attempt = 0; attempt < 4; attempt++) {
    const created = await s.stripe.paymentIntents.create(
      params,
      onAccount(account.stripe_account_id, {
        idempotencyKey: await idempotencyKey("payment_sheet", ...parts, ...chain),
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
 * fresh one for what is still due). Call it when a sheet is dismissed and before voiding or editing.
 * Payments already processing are reported, never cancelled.
 */
export async function cancelOpenPayments(
  s: Services,
  req: Request,
  input: z.output<typeof cancelOpenPaymentsInput>,
): Promise<Record<string, unknown>> {
  const { invoice } = await requireCollector(s, req, input.shop_id, input.invoice_id);
  const account = await findAccount(s.admin, invoice.shop_id);
  if (!account) {
    return {
      invoice_id: invoice.id,
      cancelled: 0,
      succeeded: 0,
      in_progress: 0,
      sessions_expired: 0,
    };
  }
  const settled = await settleInvoice(s, account, invoice.shop_id, invoice.id);
  const customer = await loadCustomer(s.admin, invoice.shop_id, invoice.customer_id);
  const expired = customer.stripe_customer_id
    ? await expireOpenSessions(
      s,
      account,
      customer.stripe_customer_id,
      sessionFor.invoiceOrDeposit(invoice.shop_id, invoice),
    )
    : [];
  return {
    invoice_id: invoice.id,
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
}

async function savedCard(
  s: Services,
  shopId: string,
  customerId: string,
  paymentMethodId: string | undefined,
): Promise<SavedCard> {
  let query = s.admin
    .from("customer_payment_methods")
    .select("stripe_payment_method_id, brand, last4")
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
  const balance = assertPayable(invoice);
  const amount = requestedAmount(input.amount_cents, balance);
  chargeable(amount, shop.currency);
  const customer = await loadCustomer(s.admin, shop.id, invoice.customer_id);
  const card = await savedCard(s, shop.id, customer.id, input.payment_method_id);
  if (!customer.stripe_customer_id) {
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
  };

  let intent: Stripe.PaymentIntent;
  try {
    intent = await s.stripe.paymentIntents.create(
      {
        amount,
        currency: shop.currency,
        customer: customer.stripe_customer_id,
        payment_method: card.stripe_payment_method_id,
        off_session: true,
        confirm: true,
        automatic_payment_methods: { enabled: true, allow_redirects: "never" },
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
      automatic_payment_methods: { enabled: true },
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
  const portal = links.portal(s.env.appBaseUrl());
  const session = await s.stripe.checkout.sessions.create(
    {
      mode: "setup",
      currency: shop.currency,
      customer: stripeCustomer,
      client_reference_id: customer.id,
      setup_intent_data: {
        description: `Save a card with ${shop.name}`,
        metadata: { ...meta, source: "setup_card_link" },
      },
      metadata: { ...meta, source: "setup_card_link" },
      success_url: withQuery(portal, { card: "saved" }),
      cancel_url: withQuery(portal, { card: "canceled" }),
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
  if (!paymentIntentId || !["card", "card_present"].includes(payment.method)) {
    throw errors.unprocessable("Only card payments are refunded through Stripe.", {
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
