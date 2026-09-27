/**
 * Public payment actions, authorized only by an unguessable link token:
 *   invoice_checkout          /i/<token>        pay the invoice balance (+ optional tip)
 *   booking_deposit_checkout  /booking/<token>  pay the booking deposit still due
 * Amounts come from the database; the client can only add a bounded tip.
 * Sessions live ~30–40 minutes (checkoutRequest) and a new one expires the
 * document's older open sessions, so a stale link cannot be paid twice.
 * Card attempts already open on the invoice / booking are settled first
 * (settle.ts), exactly as the staff paths do: an unconfirmed PaymentSheet is
 * superseded (cancelled), money that already landed is recorded (the rest is
 * charged), and a payment still processing blocks a second one (409
 * payment_in_progress) — a pending payment does not lower the balance.
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
  type InvoiceRow,
  loadAccount,
  loadCustomer,
  loadInvoice,
  loadShop,
  metadata,
  paymentInProgress,
  platformFee,
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
  const balance = assertPayable(invoice);
  const tip = boundedTip(input.tip_cents, balance);
  chargeable(balance + tip, shop.currency);
  const customer = await loadCustomer(s.admin, shop.id, invoice.customer_id);
  const stripeCustomer = await ensureStripeCustomer(s, account, customer);

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
        // Saved for charge-card-on-file (webhook stores the payment method).
        setup_future_usage: "off_session",
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
}

const CLOSED_JOB_STATUSES = new Set(["cancelled", "no_show", "completed"]);

export async function bookingDepositCheckout(
  s: Services,
  input: z.output<typeof bookingDepositCheckoutInput>,
): Promise<CheckoutResult> {
  const { data, error } = await s.admin
    .from("jobs")
    .select("id, shop_id, number, customer_id, status")
    .eq("public_token", input.token)
    .maybeSingle();
  if (error) throw dbFailure("jobs lookup", error);
  const job = data as JobRow | null;
  if (!job) throw errors.notFound("Booking not found.");
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
  // shows it: least(deposit_required, total) - money already received.
  const summary = await s.admin.rpc("public_get_booking", { p_token: input.token });
  if (summary.error) {
    if (summary.error.code === "P0002") throw errors.notFound("Booking not found.");
    throw dbFailure("public_get_booking", summary.error);
  }
  const deposit =
    (summary.data as { deposit?: { due_cents?: unknown; payment_pending?: unknown } } | null)
      ?.deposit;
  const due = deposit?.due_cents;
  if (typeof due !== "number" || !Number.isSafeInteger(due)) {
    throw new Error("public_get_booking returned no deposit.due_cents");
  }
  if (due <= 0) {
    throw errors.conflict("No deposit is due for this booking.", { reason: "deposit_not_due" });
  }
  // A payment the settle above could not resolve is still on its way.
  if (deposit?.payment_pending === true) throw paymentInProgress();

  const shop = await loadShop(s.admin, job.shop_id);
  const account = await loadAccount(s.admin, shop.id);
  chargeable(due, shop.currency);
  const customer = await loadCustomer(s.admin, shop.id, job.customer_id);
  const stripeCustomer = await ensureStripeCustomer(s, account, customer);

  const meta = metadata({
    shop_id: shop.id,
    job_id: job.id,
    customer_id: job.customer_id,
    kind: "deposit",
    tip_cents: 0,
    source: "booking_deposit_checkout",
  });
  const fee = platformFee(s.env, due);
  const page = links.booking(s.env.appBaseUrl(), input.token);
  const request = checkoutRequest(input.request_nonce, s.now);
  const session = await createCheckoutSession(
    s,
    account,
    {
      mode: "payment",
      customer: stripeCustomer,
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
        setup_future_usage: "off_session",
        ...(fee ? { application_fee_amount: fee } : {}),
      },
      metadata: meta,
      success_url: withQuery(page, { paid: "1" }),
      cancel_url: withQuery(page, { canceled: "1" }),
      expires_at: request.expiresAt,
    },
    "deposit_checkout",
    [job.id, due, stripeCustomer, request.part],
  );
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
