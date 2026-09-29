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
  | { action: 'booking_deposit_checkout'; token: string }
  /** A self-scheduled quote's deposit (token = the quote's /q token). */
  | { action: 'quote_deposit_checkout'; token: string };

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

/**
 * Whose deposit card pages payments `deposit_checkout_cancel` closes: a
 * booking's (its /booking token; the /q page passes self_schedule.job_token),
 * or every job an invoice bills (the /i token).
 */
export type DepositCheckoutTarget = { bookingToken: string } | { invoiceToken: string };

/**
 * payments `deposit_checkout_cancel` (PUBLIC by link token): expires the
 * booking's open deposit card pages (the Checkout Sessions
 * booking_deposit_checkout / quote_deposit_checkout opened) and releases
 * their holds, so the booking is not held (online cancel, cash and gift cards
 * on its invoice wait for an open page) for the ~30-40 minutes Stripe keeps a
 * page alive. Invoice pay pages, staff payment sheets and terminal payments
 * are never touched. The edge refuses (409 payment_in_progress) when one of
 * the pages was just paid.
 */
export async function cancelDepositCheckout(target: DepositCheckoutTarget): Promise<void> {
  const body =
    'invoiceToken' in target
      ? { action: 'deposit_checkout_cancel', invoice_token: target.invoiceToken }
      : { action: 'deposit_checkout_cancel', token: target.bookingToken };
  let response: Awaited<ReturnType<typeof supabase.functions.invoke<unknown>>>;
  try {
    response = await supabase.functions.invoke<unknown>('payments', { body });
  } catch (error) {
    throw await edgeFunctionError(error);
  }
  if (response.error) throw await edgeFunctionError(response.error);
}

/** Leaves the app for Stripe Checkout (wrapped so tests can observe it). */
export const navigation = {
  assign(url: string) {
    window.location.assign(url);
  },
};
