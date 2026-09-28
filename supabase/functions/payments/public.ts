/**
 * Public payment actions, authorized only by an unguessable link token:
 *   invoice_checkout          /i/<token>        pay the invoice balance (+ optional tip)
 *   booking_deposit_checkout  /booking/<token>  pay the booking deposit still due
 *                                               (never more than the job's
 *                                               invoice still owes)
 *   quote_deposit_checkout    /q/<token>        pay the deposit of the job the
 *                                               customer scheduled from the
 *                                               approved quote (P-16)
 * Amounts come from the database; the client can only add a bounded tip.
 * Sessions live ~30–40 minutes (checkoutRequest) and a new one expires the
 * document's older open sessions, so a stale link cannot be paid twice. The
 * invoice and its jobs' deposits are one balance (a deposit payment attaches
 * to the job's live invoice, single or grouped), so a new invoice link also
 * expires its jobs' open deposit links and a new deposit link the job's open
 * invoice links — before it is created, and 409 payment_in_progress when one
 * was just paid.
 * Card attempts already open on the invoice / booking are settled first
 * (settle.ts), exactly as the staff paths do: an unconfirmed PaymentSheet is
 * superseded (cancelled), money that already landed is recorded (the rest is
 * charged), and a payment still processing blocks a second one (409
 * payment_in_progress) — a pending payment does not lower the balance. ACH
 * debits still clearing (`processing`) are subtracted from what is charged.
 *
 * Payment methods (P-31): the links use the connected account's enabled
 * methods (no payment_method_types): cards and wallets always, US bank
 * debits and pay-later when the shop enabled them in Stripe. The card is
 * saved for later through the card options (SAVE_CARD_OPTIONS); Link is not
 * offered (NO_LINK_WALLET), since a Link payment would leave no card on file.
 */
import { z } from "zod";
import { errors } from "../_shared/errors.ts";
import { links, withQuery } from "../_shared/links.ts";
import { nonNegativeCents, publicToken, requestNonce } from "../_shared/schemas.ts";
import {
  assertPayable,
  boundedTip,
  chargeable,
  checkoutRequest,
  createCheckoutSession,
  dbFailure,
  ensureStripeCustomer,
  expireOpenSessions,
  findAccount,
  INVOICE_COLUMNS,
  invoiceJobIds,
  type InvoiceRow,
  liveInvoiceForJob,
  loadAccount,
  loadCustomer,
  loadInvoice,
  loadShop,
  metadata,
  NO_LINK_WALLET,
  payableBalance,
  paymentInProgress,
  platformFee,
  SAVE_CARD_OPTIONS,
  type Services,
  sessionFor,
} from "./lib.ts";
import { settleInvoice, settleJob } from "./settle.ts";

export const invoiceCheckoutInput = z.object({
  token: publicToken,
  tip_cents: nonNegativeCents.optional(),
  request_nonce: requestNonce.optional(),
}).strict();

export const bookingDepositCheckoutInput = z.object({
  token: publicToken,
  request_nonce: requestNonce.optional(),
}).strict();

export const quoteDepositCheckoutInput = z.object({
  /** quotes.public_token (the /q/<token> link). */
  token: publicToken,
  request_nonce: requestNonce.optional(),
}).strict();

export interface CheckoutResult {
  url: string;
  expires_at: number;
  amount_cents: number;
  tip_cents: number;
  currency: string;
}

export async function invoiceCheckout(
  s: Services,
  input: z.output<typeof invoiceCheckoutInput>,
): Promise<CheckoutResult> {
  const { data, error } = await s.admin
    .from("invoices")
    .select(INVOICE_COLUMNS)
    .eq("public_token", input.token)
    .maybeSingle();
  if (error) throw dbFailure("invoices lookup", error);
  let invoice = data as InvoiceRow | null;
  // Drafts are not published (same as public_get_invoice).
  if (!invoice || invoice.status === "draft") throw errors.notFound("Invoice not found.");
  assertPayable(invoice);
  boundedTip(input.tip_cents, invoice.balance_cents);

  const shop = await loadShop(s.admin, invoice.shop_id);
  const account = await loadAccount(s.admin, shop.id);
  // Money in flight is not in balance_cents: settle the invoice's open card
  // attempts before offering the balance again.
  const earlier = await settleInvoice(s, account, shop.id, invoice.id);
  if (earlier.in_progress > 0) throw paymentInProgress();
  if (earlier.succeeded > 0) invoice = await loadInvoice(s.admin, shop.id, invoice.id);
  // The balance less ACH debits still clearing toward it.
  const balance = await payableBalance(s, invoice);
  const tip = boundedTip(input.tip_cents, balance);
  chargeable(balance + tip, shop.currency);
  const customer = await loadCustomer(s.admin, shop.id, invoice.customer_id);
  const stripeCustomer = await ensureStripeCustomer(s, account, customer);
  // Its jobs' open deposit links would be paid on top of this balance.
  const jobIds = await invoiceJobIds(s.admin, invoice);
  if (jobIds.length > 0) {
    await expireOpenSessions(
      s,
      account,
      stripeCustomer,
      sessionFor.deposits(shop.id, jobIds),
      undefined,
      { refuseCompleted: true },
    );
  }

  const meta = metadata({
    shop_id: shop.id,
    invoice_id: invoice.id,
    job_id: invoice.job_id,
    customer_id: invoice.customer_id,
    kind: "payment",
    tip_cents: tip,
    source: "invoice_checkout",
  });
  const fee = platformFee(s.env, balance);
  const page = links.invoice(s.env.appBaseUrl(), input.token);
  const request = checkoutRequest(input.request_nonce, s.now);
  const session = await createCheckoutSession(
    s,
    account,
    {
      mode: "payment",
      customer: stripeCustomer,
      payment_method_options: SAVE_CARD_OPTIONS,
      wallet_options: NO_LINK_WALLET,
      client_reference_id: invoice.id,
      line_items: [
        {
          quantity: 1,
          price_data: {
            currency: shop.currency,
            unit_amount: balance,
            product_data: { name: `Invoice #${invoice.number}` },
          },
        },
        ...(tip > 0
          ? [{
            quantity: 1,
            price_data: {
              currency: shop.currency,
              unit_amount: tip,
              product_data: { name: "Tip" },
            },
          }]
          : []),
      ],
      payment_intent_data: {
        description: `${shop.name} invoice #${invoice.number}`,
        metadata: meta,
        ...(fee ? { application_fee_amount: fee } : {}),
      },
      metadata: meta,
      success_url: withQuery(page, { paid: "1" }),
      cancel_url: withQuery(page, { canceled: "1" }),
      expires_at: request.expiresAt,
    },
    "invoice_checkout",
    [invoice.id, balance, tip, stripeCustomer, request.part],
  );
  // One live link per invoice: older sessions (other device, old balance or
  // tip) can no longer be paid.
  await expireOpenSessions(
    s,
    account,
    stripeCustomer,
    sessionFor.invoice(shop.id, invoice.id),
    session.id,
  );
  return {
    url: session.url,
    expires_at: session.expires_at,
    amount_cents: balance,
    tip_cents: tip,
    currency: shop.currency,
  };
}

interface JobRow {
  id: string;
  shop_id: string;
  number: number;
  customer_id: string;
  status: string;
  public_token: string;
}

const JOB_COLUMNS = "id, shop_id, number, customer_id, status, public_token";

const CLOSED_JOB_STATUSES = new Set(["cancelled", "no_show", "completed"]);

/**
 * `due` capped at the balance of the job's live invoice (single or grouped,
 * draft or issued alike: payments_before_write attaches a job payment to
 * either), less ACH debits still clearing toward it. With no invoice yet,
 * the deposit is bounded by the job total, which the database already
 * applied (least(deposit_required, total) - paid).
 */
async function capByJobInvoice(s: Services, job: JobRow, due: number): Promise<number> {
  const invoice = await liveInvoiceForJob(s.admin, job.shop_id, job.id);
  if (!invoice) return due;
  if (invoice.status === "paid") return 0;
  const balance = invoice.balance_cents;
  if (typeof balance !== "number" || !Number.isSafeInteger(balance)) {
    throw new Error("job invoice has no balance_cents");
  }
  const { data, error } = await s.admin
    .from("payments")
    .select("amount_cents")
    .eq("shop_id", job.shop_id)
    .eq("invoice_id", invoice.id)
    .eq("status", "processing");
  if (error) throw dbFailure("processing payments lookup", error);
  const processing = ((data ?? []) as Array<{ amount_cents: number }>)
    .reduce((sum, row) => sum + (Number.isSafeInteger(row.amount_cents) ? row.amount_cents : 0), 0);
  return Math.min(due, balance - processing);
}

export async function bookingDepositCheckout(
  s: Services,
  input: z.output<typeof bookingDepositCheckoutInput>,
): Promise<CheckoutResult> {
  const { data, error } = await s.admin
    .from("jobs")
    .select(JOB_COLUMNS)
    .eq("public_token", input.token)
    .maybeSingle();
  if (error) throw dbFailure("jobs lookup", error);
  const job = data as JobRow | null;
  if (!job) throw errors.notFound("Booking not found.");
  return await depositCheckout(s, job, {
    page: links.booking(s.env.appBaseUrl(), input.token),
    nonce: input.request_nonce,
    source: "booking_deposit_checkout",
  });
}

/**
 * P-16: the deposit of the job a customer scheduled from the approved quote
 * (public_schedule_quote), paid on the quote's own /q page. The same rules
 * as the booking deposit; 409 not_scheduled until the customer scheduled it
 * there (a staff conversion never exposes the job through the quote), and
 * 409 booking_closed once the job no longer belongs to the quote's customer.
 */
export async function quoteDepositCheckout(
  s: Services,
  input: z.output<typeof quoteDepositCheckoutInput>,
): Promise<CheckoutResult> {
  const { data, error } = await s.admin
    .from("quotes")
    .select("id, shop_id, customer_id, status, converted_job_id, self_scheduled_at")
    .eq("public_token", input.token)
    .maybeSingle();
  if (error) throw dbFailure("quotes lookup", error);
  const quote = data as {
    id: string;
    shop_id: string;
    customer_id: string;
    status: string;
    converted_job_id: string | null;
    self_scheduled_at: string | null;
  } | null;
  // Drafts are not published (same as public_get_quote).
  if (!quote || quote.status === "draft") throw errors.notFound("Quote not found.");
  if (!quote.self_scheduled_at || !quote.converted_job_id) {
    throw errors.conflict("Pick a time for this quote before paying the deposit.", {
      reason: "not_scheduled",
    });
  }
  const found = await s.admin
    .from("jobs")
    .select(JOB_COLUMNS)
    .eq("shop_id", quote.shop_id)
    .eq("id", quote.converted_job_id)
    .maybeSingle();
  if (found.error) throw dbFailure("jobs lookup", found.error);
  const job = found.data as JobRow | null;
  // The job only while it is still this quote's customer's, exactly as
  // money_public_quote_json hands it out (0067): a job staff moved to another
  // customer got a new booking token, and the old quote link must not open a
  // Checkout on that customer (their Stripe customer, email and saved card).
  if (!job || job.customer_id !== quote.customer_id) {
    throw errors.conflict("This appointment is no longer taking deposits.", {
      reason: "booking_closed",
    });
  }
  return await depositCheckout(s, job, {
    page: links.quote(s.env.appBaseUrl(), input.token),
    nonce: input.request_nonce,
    source: "quote_deposit_checkout",
    quoteId: quote.id,
  });
}

/**
 * Checkout for the deposit still due on a job (booking page or quote page).
 * The card is saved for later (charge-card-on-file); ACH / pay-later appear
 * when the shop enabled them.
 */
async function depositCheckout(
  s: Services,
  job: JobRow,
  options: { page: string; nonce: string | undefined; source: string; quoteId?: string },
): Promise<CheckoutResult> {
  if (CLOSED_JOB_STATUSES.has(job.status)) {
    throw errors.conflict("This booking is no longer taking deposits.", {
      reason: "booking_closed",
    });
  }

  // Card attempts already open on the booking (a deposit link that is still
  // processing, a sheet on its invoice) are settled first: money in flight
  // is not in due_cents.
  const connected = await findAccount(s.admin, job.shop_id);
  if (connected) {
    const earlier = await settleJob(s, connected, job.shop_id, job.id);
    if (earlier.in_progress > 0) throw paymentInProgress();
  }

  // Deposit still due, computed by the database exactly as the booking page
  // shows it: least(deposit_required, total) - money already received,
  // then capped at what the job's invoice still owes (below).
  const summary = await s.admin.rpc("public_get_booking", { p_token: job.public_token });
  if (summary.error) {
    // PT404: public_get_booking's unknown token (0042); P0002 before that convention.
    if (summary.error.code === "PT404" || summary.error.code === "P0002") {
      throw errors.notFound("Booking not found.");
    }
    throw dbFailure("public_get_booking", summary.error);
  }
  const deposit =
    (summary.data as { deposit?: { due_cents?: unknown; payment_pending?: unknown } } | null)
      ?.deposit;
  const jobDue = deposit?.due_cents;
  if (typeof jobDue !== "number" || !Number.isSafeInteger(jobDue)) {
    throw new Error("public_get_booking returned no deposit.due_cents");
  }
  // The deposit is worked out from the JOB total, but the payment lands on
  // the job's non-void invoice (payments_before_write), whose lines and
  // discount stay editable until money arrives: it can owe less than the
  // job's deposit share. Never charge more than that invoice still owes —
  // every other way money enters (record_manual_payment, invoice_checkout)
  // refuses to overpay it too.
  const due = await capByJobInvoice(s, job, jobDue);
  // A payment the settle above could not resolve (a card attempt, or an ACH
  // debit / pay-later payment still processing) is still on its way.
  if (deposit?.payment_pending === true) throw paymentInProgress();
  if (due <= 0) {
    throw errors.conflict("No deposit is due for this booking.", { reason: "deposit_not_due" });
  }

  const shop = await loadShop(s.admin, job.shop_id);
  const account = await loadAccount(s.admin, shop.id);
  chargeable(due, shop.currency);
  const customer = await loadCustomer(s.admin, shop.id, job.customer_id);
  const stripeCustomer = await ensureStripeCustomer(s, account, customer);
  // An open pay link of the job's invoice already covers this deposit share.
  const live = await liveInvoiceForJob(s.admin, shop.id, job.id);
  await expireOpenSessions(
    s,
    account,
    stripeCustomer,
    sessionFor.jobInvoices(shop.id, job.id, live?.id ?? null),
    undefined,
    { refuseCompleted: true },
  );

  const meta = metadata({
    shop_id: shop.id,
    job_id: job.id,
    customer_id: job.customer_id,
    kind: "deposit",
    tip_cents: 0,
    source: options.source,
    quote_id: options.quoteId,
  });
  const fee = platformFee(s.env, due);
  const request = checkoutRequest(options.nonce, s.now);
  const session = await createCheckoutSession(
    s,
    account,
    {
      mode: "payment",
      customer: stripeCustomer,
      payment_method_options: SAVE_CARD_OPTIONS,
      wallet_options: NO_LINK_WALLET,
      client_reference_id: job.id,
      line_items: [{
        quantity: 1,
        price_data: {
          currency: shop.currency,
          unit_amount: due,
          product_data: { name: `Deposit for booking #${job.number}` },
        },
      }],
      payment_intent_data: {
        description: `${shop.name} deposit for booking #${job.number}`,
        metadata: meta,
        ...(fee ? { application_fee_amount: fee } : {}),
      },
      metadata: meta,
      success_url: withQuery(options.page, { paid: "1" }),
      cancel_url: withQuery(options.page, { canceled: "1" }),
      expires_at: request.expiresAt,
    },
    "deposit_checkout",
    [job.id, due, stripeCustomer, request.part],
  );
  // One live deposit link per job (whichever page opened it).
  await expireOpenSessions(
    s,
    account,
    stripeCustomer,
    sessionFor.deposit(shop.id, job.id),
    session.id,
  );
  return {
    url: session.url,
    expires_at: session.expires_at,
    amount_cents: due,
    tip_cents: 0,
    currency: shop.currency,
  };
}
