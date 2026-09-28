/**
 * Public gift card pages (P-13): /gift/:slug sells the shop's gift cards
 * (public_gift_card_offer + payments gift_card_checkout → Stripe Checkout)
 * and /gift/:slug/done?order=<token> follows the order
 * (public_gift_card_order_status: never the code — it is emailed to the
 * recipient once the payment succeeds).
 */
import { useMutation, useQuery } from '@tanstack/react-query';
import { z } from 'zod';
import { unwrap } from '@/lib/db';
import { AppError, toAppError } from '@/lib/errors';
import { publicKey } from '@/lib/queryKeys';
import { supabase } from '@/lib/supabase';
import { invokeEdge } from '@/features/quotes/shared/edge';
import { isSafeCheckoutUrl, navigation } from '@/features/public-docs/shared/checkout';
import { parseDocument, zIntOrNull, zText } from '@/features/public-docs/shared/schemas';

function retryTransient(failureCount: number, error: unknown): boolean {
  const kind = toAppError(error).kind;
  return failureCount < 2 && (kind === 'network' || kind === 'server' || kind === 'unknown');
}

export const offerSchema = z.object({
  value_cents: z.number().int(),
  price_cents: z.number().int(),
});
export type GiftOffer = z.output<typeof offerSchema>;

export const giftShopSchema = z.object({
  shop: z.object({ name: z.string(), logo_path: zText, brand_color: zText }),
  enabled: z.boolean(),
  offers: z.array(offerSchema),
  allow_custom_amount: z.boolean(),
  min_custom_cents: zIntOrNull,
  max_custom_cents: zIntOrNull,
  expires_months: zIntOrNull,
  terms: zText,
  currency: z
    .string()
    .nullish()
    .transform((v) => v ?? 'usd'),
});
export type GiftShop = z.output<typeof giftShopSchema>;

/** "Valid for 5 years from purchase" / "Never expires". */
export function expiryText(months: number | null): string {
  if (months === null) return 'Never expires.';
  if (months % 12 === 0) {
    const years = months / 12;
    return `Valid for ${years} year${years === 1 ? '' : 's'} from purchase.`;
  }
  return `Valid for ${months} months from purchase.`;
}

export function useGiftShop(slug: string) {
  return useQuery({
    queryKey: publicKey('gift-shop', slug),
    retry: retryTransient,
    queryFn: async () =>
      parseDocument(
        giftShopSchema,
        unwrap(await supabase.rpc('public_gift_card_offer', { p_slug: slug })),
      ),
  });
}

export type GiftChoice = { offerIndex: number } | { amountCents: number };

export interface GiftCheckoutInput {
  choice: GiftChoice;
  purchaser: { name: string; email: string };
  recipient: { name?: string; email: string; message?: string };
  requestNonce: string;
}

const giftCheckoutResultSchema = z.object({
  url: z.string().min(1),
  expires_at: z.number(),
  price_cents: z.number().int(),
  value_cents: z.number().int(),
  currency: z.string(),
});

/** payments.gift_card_checkout → Stripe Checkout (the server prices the order). */
export function useGiftCheckout(slug: string) {
  return useMutation({
    mutationFn: async ({ choice, purchaser, recipient, requestNonce }: GiftCheckoutInput) => {
      const result = await invokeEdge(
        'payments',
        'gift_card_checkout',
        {
          slug,
          ...('offerIndex' in choice
            ? { offer_index: choice.offerIndex }
            : { amount_cents: choice.amountCents }),
          purchaser,
          recipient,
          request_nonce: requestNonce,
        },
        giftCheckoutResultSchema,
      );
      if (!isSafeCheckoutUrl(result.url)) {
        throw new AppError('The payment page could not be opened. Please try again.', {
          kind: 'server',
        });
      }
      navigation.assign(result.url);
      return result;
    },
  });
}

export const orderStatusSchema = z.object({
  status: z.enum(['pending', 'paid', 'refunded', 'expired']),
  value_cents: z.number().int(),
  recipient_name: zText,
  last4: zText,
});
export type GiftOrderStatus = z.output<typeof orderStatusSchema>;

/** Polling while the webhook issues the card after Stripe redirects back. */
export const ORDER_POLL_INTERVAL_MS = 2500;
export const ORDER_POLL_ATTEMPTS = 10;

export function useGiftOrderStatus(token: string) {
  return useQuery({
    queryKey: publicKey('gift-order', token),
    retry: retryTransient,
    refetchOnWindowFocus: false,
    queryFn: async () =>
      parseDocument(
        orderStatusSchema,
        unwrap(await supabase.rpc('public_gift_card_order_status', { p_token: token })),
      ),
    refetchInterval: (query) => {
      if (query.state.data && query.state.data.status !== 'pending') return false;
      return query.state.dataUpdateCount < ORDER_POLL_ATTEMPTS ? ORDER_POLL_INTERVAL_MS : false;
    },
  });
}
