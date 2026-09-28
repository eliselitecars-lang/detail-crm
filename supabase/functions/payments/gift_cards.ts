/**
 * Online gift card sales (P-13), PUBLIC by shop slug:
 *   gift_card_checkout  /gift/<slug>: one of the shop's offers (offer_index)
 *                       or a custom amount (amount_cents, when the shop
 *                       allows it) -> a Stripe Checkout Session on the shop's
 *                       connected account for the offer's PRICE (the card
 *                       carries its VALUE; an offer may sell $100 of value
 *                       for $90).
 *
 * The order is created by gift_card_order_prepare (0066, service role),
 * which owns every rule: the shop has online sales on, the offer exists or
 * the custom amount is within the shop's range, the contact details, and
 * the abuse limits (5 orders per purchaser email per 24 h; 0110: 10 unpaid
 * orders per connection — the visitor's address, passed as p_client_ip —
 * and 100 per shop). Prices never come
 * from the client: amount_cents is only a request that the RPC validates.
 * The webhook issues the card when the payment succeeds
 * (gift_card_order_paid) and follows refunds (gift_card_order_refunded); a
 * gift card sale is never a payments row (a card is tender when redeemed).
 * Card-only: a gift card is delivered at once, so methods that clear days
 * later are not offered.
 *
 * request_nonce: a retry of the same submission (same nonce, same details)
 * hands back the order's Checkout Session while it is still open, instead of
 * preparing a second order with a second payable session (which would also
 * spend the purchaser's order allowance). The session carries a hash of the
 * nonce and the details (metadata request_key); the order is found among the
 * purchaser's recent pending orders.
 */
import { z } from "zod";
import { clientIp } from "../_shared/client_ip.ts";
import { HttpError } from "../_shared/errors.ts";
import { idempotencyKey, onAccount, type Stripe } from "../_shared/stripe.ts";
import { withQuery } from "../_shared/links.ts";
import { formatCents } from "../_shared/money.ts";
import { email, positiveCents, requestNonce } from "../_shared/schemas.ts";
import {
  type AccountRow,
  appPage,
  chargeable,
  checkoutRequest,
  createCheckoutSession,
  dbFailure,
  loadAccount,
  loadShopBySlug,
  metadata,
  paymentInProgress,
  platformFee,
  publicValidationMessage,
  refusedWith,
  rpcError,
  type Services,
  SLUG_RE,
} from "./lib.ts";

const name = z.string().trim().min(1).max(120);

export const giftCardCheckoutInput = z.object({
  slug: z.string().regex(SLUG_RE, "must be a shop link name"),
  /** Index into the shop's offers (gift_card_settings.offers). */
  offer_index: z.number().int().min(0).max(7).optional(),
  /** A custom amount (value = price), only when the shop allows it. */
  amount_cents: positiveCents.optional(),
  purchaser: z.object({ name, email: z.string().trim().max(254).pipe(email) }).strict(),
  recipient: z.object({
    name: name.optional(),
    email: z.string().trim().max(254).pipe(email),
    message: z.string().max(500).optional(),
  }).strict(),
  request_nonce: requestNonce.optional(),
}).strict().refine(
  (input) => (input.offer_index === undefined) !== (input.amount_cents === undefined),
  {
    message: "choose one of the offers or an amount",
    path: ["offer_index"],
  },
);

export interface GiftCardCheckoutResult {
  url: string;
  expires_at: number;
  price_cents: number;
  value_cents: number;
  currency: string;
}

interface PreparedOrder {
  order_id: string;
  token: string;
  shop_id: string;
  value_cents: number;
  price_cents: number;
  currency: string;
}

function isPrepared(value: unknown): value is PreparedOrder {
  const v = value as Partial<PreparedOrder> | null;
  return typeof v?.order_id === "string" && typeof v.token === "string" &&
    typeof v.shop_id === "string" && Number.isSafeInteger(v.value_cents) &&
    Number.isSafeInteger(v.price_cents) && (v.price_cents ?? 0) > 0 &&
    typeof v.currency === "string";
}

/** How far back a retried submission's order is looked for (sessions live 32–42 min). */
const RETRY_LOOKBACK_MS = 60 * 60 * 1000;

/** Pending orders checked for a retried submission (the RPC allows 5 per email a day). */
const RETRY_CANDIDATES = 5;

interface PendingOrder {
  id: string;
  value_cents: number;
  price_cents: number;
  stripe_checkout_session_id: string;
}

/**
 * The still-open Checkout Session of an earlier call with the same
 * request_key (same nonce, same details), or null. A session of that call
 * that was already paid means the money is on its way (409); an expired
 * one is passed over, so a new order is prepared.
 */
async function retriedOrderSession(
  s: Services,
  account: AccountRow,
  shopId: string,
  purchaserEmail: string,
  requestKey: string,
): Promise<{ order: PendingOrder; session: Stripe.Checkout.Session & { url: string } } | null> {
  const { data, error } = await s.admin
    .from("gift_card_orders")
    .select("id, value_cents, price_cents, stripe_checkout_session_id")
    .eq("shop_id", shopId)
    .eq("purchaser_email", purchaserEmail)
    .eq("status", "pending")
    .not("stripe_checkout_session_id", "is", null)
    .gte("created_at", new Date(s.now - RETRY_LOOKBACK_MS).toISOString())
    .order("created_at", { ascending: false })
    .limit(RETRY_CANDIDATES);
  if (error) throw dbFailure("gift_card_orders lookup", error);
  for (const order of (data ?? []) as PendingOrder[]) {
    let session: Stripe.Checkout.Session;
    try {
      session = await s.stripe.checkout.sessions.retrieve(
        order.stripe_checkout_session_id,
        {},
        onAccount(account.stripe_account_id),
      );
    } catch (err) {
      const e = err as { type?: unknown; statusCode?: unknown };
      // A session Stripe no longer has cannot be handed back.
      if (e?.type === "StripeInvalidRequestError" && e.statusCode === 404) continue;
      throw err;
    }
    if (session.metadata?.request_key !== requestKey) continue;
    if (session.status === "complete") throw paymentInProgress();
    if (session.status === "open" && session.url) {
      return { order, session: { ...session, url: session.url } };
    }
  }
  return null;
}

export async function giftCardCheckout(
  s: Services,
  req: Request,
  input: z.output<typeof giftCardCheckoutInput>,
): Promise<GiftCardCheckoutResult> {
  // Card payments first: no order is created (nor the abuse limit spent)
  // for a shop that cannot take the payment.
  const shop = await loadShopBySlug(s.admin, input.slug);
  const account = await loadAccount(s.admin, shop.id);

  const payload = {
    ...(input.offer_index !== undefined ? { offer_index: input.offer_index } : {}),
    ...(input.amount_cents !== undefined ? { amount_cents: input.amount_cents } : {}),
    purchaser: input.purchaser,
    recipient: {
      email: input.recipient.email,
      ...(input.recipient.name ? { name: input.recipient.name } : {}),
      ...(input.recipient.message?.trim() ? { message: input.recipient.message.trim() } : {}),
    },
  };
  // A retry of this very submission gets its open session back.
  const requestKey = input.request_nonce
    ? await idempotencyKey(
      "gift_card_request",
      shop.id,
      input.request_nonce,
      JSON.stringify(payload),
    )
    : null;
  if (requestKey) {
    const earlier = await retriedOrderSession(
      s,
      account,
      shop.id,
      input.purchaser.email,
      requestKey,
    );
    if (earlier) {
      const currency = (earlier.session.currency ?? shop.currency).toLowerCase();
      return {
        url: earlier.session.url,
        expires_at: earlier.session.expires_at,
        price_cents: earlier.order.price_cents,
        value_cents: earlier.order.value_cents,
        currency,
      };
    }
  }

  // The visitor's address for the RPC's per-connection limit (0110).
  const ip = clientIp(req);
  const prepared = await s.admin.rpc("gift_card_order_prepare", {
    p_slug: shop.slug,
    p_payload: payload,
    ...(ip ? { p_client_ip: ip } : {}),
  });
  if (prepared.error) {
    switch (prepared.error.code) {
      case "55000":
        throw new HttpError("conflict", "This shop is not selling gift cards online right now.", {
          details: { reason: "disabled" },
          cause: prepared.error,
        });
      case "22023": {
        // HINT amount_out_of_range (0095); the message text for an older database.
        const outOfRange = refusedWith(
          prepared.error,
          "22023",
          "amount_out_of_range",
          /amount out of range/i,
        );
        throw new HttpError(
          "unprocessable",
          publicValidationMessage(prepared.error, "Check the gift card details and try again."),
          {
            details: { reason: outOfRange ? "amount_out_of_range" : "invalid_order" },
            cause: prepared.error,
          },
        );
      }
      default:
        throw rpcError("gift_card_order_prepare", prepared.error, {
          notFound: "Shop not found.",
        });
    }
  }
  if (!isPrepared(prepared.data) || prepared.data.shop_id !== shop.id) {
    throw new Error("gift_card_order_prepare returned an unexpected order");
  }
  const order = prepared.data;
  const currency = order.currency.toLowerCase();
  chargeable(order.price_cents, currency);

  const meta = metadata({
    shop_id: shop.id,
    gift_card_order_id: order.order_id,
    kind: "gift_card",
    source: "gift_card_checkout",
  });
  const fee = platformFee(s.env, order.price_cents);
  const base = s.env.appBaseUrl();
  const request = checkoutRequest(input.request_nonce, s.now);
  const value = formatCents(order.value_cents, currency);
  const session = await createCheckoutSession(
    s,
    account,
    {
      mode: "payment",
      payment_method_types: ["card"],
      customer_email: input.purchaser.email,
      client_reference_id: order.order_id,
      line_items: [{
        quantity: 1,
        price_data: {
          currency,
          unit_amount: order.price_cents,
          product_data: { name: `Gift card ${value}` },
        },
      }],
      payment_intent_data: {
        description: `${shop.name} gift card ${value}`,
        metadata: meta,
        ...(fee ? { application_fee_amount: fee } : {}),
      },
      // The session only: it identifies a retried submission (above).
      metadata: requestKey ? { ...meta, request_key: requestKey } : meta,
      success_url: withQuery(appPage(base, "gift", shop.slug, "done"), { order: order.token }),
      cancel_url: withQuery(appPage(base, "gift", shop.slug), { canceled: "1" }),
      expires_at: request.expiresAt,
    },
    "gift_card_checkout",
    [order.order_id, order.price_cents, request.part],
  );

  // The session that pays this order (service role; shown to staff).
  const { error } = await s.admin
    .from("gift_card_orders")
    .update({ stripe_checkout_session_id: session.id })
    .eq("shop_id", shop.id)
    .eq("id", order.order_id)
    .is("stripe_checkout_session_id", null);
  if (error) {
    // The webhook finds the order through the payment's metadata anyway.
    s.log.error("gift_card_order_session_not_saved", {
      shop_id: shop.id,
      order_id: order.order_id,
      error: dbFailure("gift_card_orders update", error).message,
    });
  }
  return {
    url: session.url,
    expires_at: session.expires_at,
    price_cents: order.price_cents,
    value_cents: order.value_cents,
    currency,
  };
}
