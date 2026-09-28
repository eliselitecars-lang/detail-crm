/**
 * Public membership join page (/join/:slug, P-23). Plans come from
 * public_membership_plans (anon, curated); joining goes through the
 * payments edge function (membership_join_checkout), which prepares the
 * membership server-side (membership_join_prepare: customer matching, abuse
 * limits) and opens a Stripe subscription Checkout. Prices never come from
 * the client.
 */
import { useMutation, useQuery } from '@tanstack/react-query';
import { z } from 'zod';
import { unwrap } from '@/lib/db';
import { AppError, toAppError } from '@/lib/errors';
import { publicKey } from '@/lib/queryKeys';
import { supabase } from '@/lib/supabase';
import { invokeEdge } from '@/features/quotes/shared/edge';
import { newRequestNonce } from '@/features/quotes/shared/format';
import { isSafeCheckoutUrl, navigation } from '@/features/public-docs/shared/checkout';
import { parseDocument, zIntOrNull, zText } from '@/features/public-docs/shared/schemas';

export const publicPlanSchema = z.object({
  id: z.string(),
  name: z.string(),
  description: zText,
  price_cents: z.number().int(),
  interval: z.enum(['week', 'month', 'year']),
  interval_count: z.number().int(),
  included_services: z
    .array(z.string())
    .nullish()
    .transform((v) => v ?? []),
  discount_bps: z
    .number()
    .int()
    .nullish()
    .transform((v) => v ?? 0),
  uses_per_period: zIntOrNull,
  terms: zText,
});
export type PublicPlan = z.output<typeof publicPlanSchema>;

export const publicPlansSchema = z.object({
  shop: z.object({ name: z.string(), logo_path: zText, brand_color: zText }),
  plans: z.array(publicPlanSchema),
  currency: z
    .string()
    .nullish()
    .transform((v) => v ?? 'usd'),
});
export type PublicPlans = z.output<typeof publicPlansSchema>;

function retryTransient(failureCount: number, error: unknown): boolean {
  const kind = toAppError(error).kind;
  return failureCount < 2 && (kind === 'network' || kind === 'server' || kind === 'unknown');
}

export function usePublicMembershipPlans(slug: string) {
  return useQuery({
    queryKey: publicKey('membership-plans', slug),
    retry: retryTransient,
    queryFn: async () =>
      parseDocument(
        publicPlansSchema,
        unwrap(await supabase.rpc('public_membership_plans', { p_slug: slug })),
      ),
  });
}

export interface JoinInput {
  planId: string;
  customer: {
    first_name: string;
    last_name?: string;
    email: string;
    phone?: string;
    sms_opt_in: boolean;
    email_opt_in: boolean;
  };
  /** One per form: a retry of the same submission reuses the open checkout. */
  requestNonce: string;
}

const joinResultSchema = z.object({
  url: z.string().min(1),
  expires_at: z.number().nullable().optional(),
  amount_cents: z.number().int(),
  interval: z.enum(['week', 'month', 'year']),
  interval_count: z.number().int(),
  currency: z.string(),
});

/** Starts the subscription checkout and leaves for Stripe. */
export function useJoinCheckout(slug: string) {
  return useMutation({
    mutationFn: async ({ planId, customer, requestNonce }: JoinInput) => {
      const result = await invokeEdge(
        'payments',
        'membership_join_checkout',
        { slug, plan_id: planId, customer, request_nonce: requestNonce },
        joinResultSchema,
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

export { newRequestNonce };
