/**
 * payments — money movement on the shop's connected Stripe account
 * (SPEC §5). verify_jwt = false at the gateway because some actions are
 * public; every action enforces its own authorization:
 *
 *   invoice_checkout           PUBLIC by invoice token
 *   booking_deposit_checkout   PUBLIC by booking (job) token
 *   quote_deposit_checkout     PUBLIC by quote token (a self-scheduled quote's deposit)
 *   booking_cancel             PUBLIC by booking (job) token: expire the booking's
 *                              open payment pages, then public_cancel_booking
 *                              as the caller (its rules, incl. technicians)
 *   gift_card_checkout         PUBLIC by shop slug (buy a gift card online)
 *   membership_join_checkout   PUBLIC by shop slug (join an online membership plan)
 *   portal_membership_cancel   signed-in client: their own membership, at period end
 *   portal_billing_portal      signed-in client: Stripe billing portal for their membership
 *   payment_sheet              manager+, or assigned technician when allowed
 *                              (saved cards / ephemeral key: manager+ only)
 *   terminal_location          manager+, or a technician when the shop allows collecting
 *   terminal_connection_token  same as terminal_location (Tap to Pay / readers)
 *   terminal_payment_intent    same as payment_sheet (in-person card_present intent)
 *   cancel_open_payments       same as payment_sheet: release an invoice or a job
 *   sweep_payment_sheets       pg_cron (x-cron-secret)
 *   charge_saved_card          manager+
 *   remove_saved_card          manager+
 *   setup_card                 manager+
 *   setup_card_link            manager+
 *   refund                     owner/admin
 *   membership_checkout        manager+
 *   membership_cancel          manager+
 *   delete_shop                owner (cancels billing, expires links, then
 *                              deletes the shop)
 *
 * All amounts are derived from the database (invoice balance, deposit due,
 * plan price, gift card offer); a client may only request a partial amount
 * (payment_sheet, terminal_payment_intent, charge_saved_card, refund), a
 * custom gift card amount the database validates, or add a bounded tip.
 * Payment rows are written with the service-role money RPCs; the
 * stripe-webhook function remains the source of truth for final states.
 */
import { createActionRouter, jsonAction } from "../_shared/actions.ts";
import { createHandler } from "../_shared/http.ts";
import { type Deps, services } from "./lib.ts";
import { deleteShop, deleteShopInput } from "./shop_delete.ts";
import { giftCardCheckout, giftCardCheckoutInput } from "./gift_cards.ts";
import {
  membershipCancel,
  membershipCancelInput,
  membershipCheckout,
  membershipCheckoutInput,
  membershipJoinCheckout,
  membershipJoinCheckoutInput,
  portalBillingPortal,
  portalMembershipCancel,
  portalMembershipInput,
} from "./memberships.ts";
import {
  bookingCancel,
  bookingCancelInput,
  bookingDepositCheckout,
  bookingDepositCheckoutInput,
  invoiceCheckout,
  invoiceCheckoutInput,
  quoteDepositCheckout,
  quoteDepositCheckoutInput,
} from "./public.ts";
import {
  terminalConnectionToken,
  terminalConnectionTokenInput,
  terminalLocation,
  terminalLocationInput,
  terminalPaymentIntent,
  terminalPaymentIntentInput,
} from "./terminal.ts";
import {
  cancelOpenPayments,
  cancelOpenPaymentsInput,
  chargeSavedCard,
  chargeSavedCardInput,
  paymentSheet,
  paymentSheetInput,
  refund,
  refundInput,
  removeSavedCard,
  removeSavedCardInput,
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
    quote_deposit_checkout: jsonAction(
      quoteDepositCheckoutInput,
      (input, ctx) => quoteDepositCheckout(services(deps, ctx), input),
    ),
    booking_cancel: jsonAction(
      bookingCancelInput,
      (input, ctx) => bookingCancel(services(deps, ctx), ctx.req, input),
    ),
    gift_card_checkout: jsonAction(
      giftCardCheckoutInput,
      (input, ctx) => giftCardCheckout(services(deps, ctx), input),
    ),
    membership_join_checkout: jsonAction(
      membershipJoinCheckoutInput,
      (input, ctx) => membershipJoinCheckout(services(deps, ctx), input),
    ),
    portal_membership_cancel: jsonAction(
      portalMembershipInput,
      (input, ctx) => portalMembershipCancel(services(deps, ctx), ctx.req, input),
    ),
    portal_billing_portal: jsonAction(
      portalMembershipInput,
      (input, ctx) => portalBillingPortal(services(deps, ctx), ctx.req, input),
    ),
    terminal_location: jsonAction(
      terminalLocationInput,
      (input, ctx) => terminalLocation(services(deps, ctx), ctx.req, input),
    ),
    terminal_connection_token: jsonAction(
      terminalConnectionTokenInput,
      (input, ctx) => terminalConnectionToken(services(deps, ctx), ctx.req, input),
    ),
    terminal_payment_intent: jsonAction(
      terminalPaymentIntentInput,
      (input, ctx) => terminalPaymentIntent(services(deps, ctx), ctx.req, input),
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
    remove_saved_card: jsonAction(
      removeSavedCardInput,
      (input, ctx) => removeSavedCard(services(deps, ctx), ctx.req, input),
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
    delete_shop: jsonAction(
      deleteShopInput,
      (input, ctx) => deleteShop(services(deps, ctx), ctx.req, input),
    ),
  });
  return createHandler(
    { name: "payments", env: deps.env, logger: deps.logger },
    (req, ctx) => router(req, ctx),
  );
}

if (import.meta.main) Deno.serve(makeHandler());
