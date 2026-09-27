/**
 * payments — card money movement on the shop's connected Stripe account
 * (SPEC §5). verify_jwt = false at the gateway because two actions are
 * public; every action enforces its own authorization:
 *
 *   invoice_checkout          PUBLIC by invoice token
 *   booking_deposit_checkout  PUBLIC by booking (job) token
 *   payment_sheet             manager+, or assigned technician when allowed
 *                             (saved cards / ephemeral key: manager+ only)
 *   cancel_open_payments      same as payment_sheet: release an invoice
 *   sweep_payment_sheets      pg_cron (x-cron-secret)
 *   charge_saved_card         manager+
 *   setup_card                manager+
 *   setup_card_link           manager+
 *   refund                    owner/admin
 *   membership_checkout       manager+
 *   membership_cancel         manager+
 *
 * All amounts are derived from the database (invoice balance, deposit due,
 * plan price); a client may only request a partial amount (payment_sheet,
 * charge_saved_card, refund) or add a bounded tip. Payment rows are written
 * with the service-role money RPCs; the stripe-webhook function remains the
 * source of truth for final states.
 */
import { createActionRouter, jsonAction } from "../_shared/actions.ts";
import { createHandler } from "../_shared/http.ts";
import { type Deps, services } from "./lib.ts";
import {
  membershipCancel,
  membershipCancelInput,
  membershipCheckout,
  membershipCheckoutInput,
} from "./memberships.ts";
import {
  bookingDepositCheckout,
  bookingDepositCheckoutInput,
  invoiceCheckout,
  invoiceCheckoutInput,
} from "./public.ts";
import {
  cancelOpenPayments,
  cancelOpenPaymentsInput,
  chargeSavedCard,
  chargeSavedCardInput,
  paymentSheet,
  paymentSheetInput,
  refund,
  refundInput,
  setupCard,
  setupCardInput,
  setupCardLink,
  setupCardLinkInput,
  sweepPaymentSheets,
  sweepPaymentSheetsInput,
} from "./staff.ts";

export type { Deps };

export function makeHandler(deps: Deps = {}): (req: Request) => Promise<Response> {
  const router = createActionRouter({
    invoice_checkout: jsonAction(
      invoiceCheckoutInput,
      (input, ctx) => invoiceCheckout(services(deps, ctx), input),
    ),
    booking_deposit_checkout: jsonAction(
      bookingDepositCheckoutInput,
      (input, ctx) => bookingDepositCheckout(services(deps, ctx), input),
    ),
    payment_sheet: jsonAction(
      paymentSheetInput,
      (input, ctx) => paymentSheet(services(deps, ctx), ctx.req, input),
    ),
    cancel_open_payments: jsonAction(
      cancelOpenPaymentsInput,
      (input, ctx) => cancelOpenPayments(services(deps, ctx), ctx.req, input),
    ),
    sweep_payment_sheets: jsonAction(
      sweepPaymentSheetsInput,
      (_input, ctx) => sweepPaymentSheets(services(deps, ctx), ctx.req),
    ),
    charge_saved_card: jsonAction(
      chargeSavedCardInput,
      (input, ctx) => chargeSavedCard(services(deps, ctx), ctx.req, input),
    ),
    setup_card: jsonAction(
      setupCardInput,
      (input, ctx) => setupCard(services(deps, ctx), ctx.req, input),
    ),
    setup_card_link: jsonAction(
      setupCardLinkInput,
      (input, ctx) => setupCardLink(services(deps, ctx), ctx.req, input),
    ),
    refund: jsonAction(refundInput, (input, ctx) => refund(services(deps, ctx), ctx.req, input)),
    membership_checkout: jsonAction(
      membershipCheckoutInput,
      (input, ctx) => membershipCheckout(services(deps, ctx), ctx.req, input),
    ),
    membership_cancel: jsonAction(
      membershipCancelInput,
      (input, ctx) => membershipCancel(services(deps, ctx), ctx.req, input),
    ),
  });
  return createHandler(
    { name: "payments", env: deps.env, logger: deps.logger },
    (req, ctx) => router(req, ctx),
  );
}

if (import.meta.main) Deno.serve(makeHandler());
