/**
 * Public Stripe Checkout (payments edge function, supabase/functions/payments
 * public.ts). Both actions are authorized only by the link token; the amount
 * comes from the database — the client may add a bounded tip on invoices.
 */
import { z } from 'zod';
import { AppError, edgeFunctionError } from '@/lib/errors';
import { supabase } from '@/lib/supabase';

const checkoutResultSchema = z.object({
  url: z.string().min(1),
  expires_at: z.number(),
  amount_cents: z.number().int(),
  tip_cents: z.number().int(),
  currency: z.string(),
});
export type CheckoutResult = z.output<typeof checkoutResultSchema>;

export type CheckoutRequest =
  | { action: 'invoice_checkout'; token: string; tipCents: number }
  | { action: 'booking_deposit_checkout'; token: string };

/** 8–64 url-safe characters (schemas.requestNonce): one per user click. */
export function newRequestNonce(): string {
  return crypto.randomUUID().replace(/-/g, '');
}

/** Only Stripe-hosted https pages are followed (never an arbitrary URL). */
export function isSafeCheckoutUrl(url: string): boolean {
  try {
    const parsed = new URL(url);
    return parsed.protocol === 'https:';
  } catch {
    return false;
  }
}

export async function createCheckout(request: CheckoutRequest): Promise<CheckoutResult> {
  const body =
    request.action === 'invoice_checkout'
      ? {
          action: request.action,
          token: request.token,
          tip_cents: request.tipCents,
          request_nonce: newRequestNonce(),
        }
      : { action: request.action, token: request.token, request_nonce: newRequestNonce() };
  let response: Awaited<ReturnType<typeof supabase.functions.invoke<unknown>>>;
  try {
    response = await supabase.functions.invoke<unknown>('payments', { body });
  } catch (error) {
    throw await edgeFunctionError(error);
  }
  if (response.error) throw await edgeFunctionError(response.error);
  const parsed = checkoutResultSchema.safeParse(response.data);
  if (!parsed.success || !isSafeCheckoutUrl(parsed.data.url)) {
    throw new AppError('The payment page could not be opened. Please try again.', {
      kind: 'server',
      cause: parsed.error,
    });
  }
  return parsed.data;
}

/** Leaves the app for Stripe Checkout (wrapped so tests can observe it). */
export const navigation = {
  assign(url: string) {
    window.location.assign(url);
  },
};
