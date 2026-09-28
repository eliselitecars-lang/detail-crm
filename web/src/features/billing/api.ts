/**
 * Shop subscription billing — data hooks (SPEC §4.10, docs/BILLING.md).
 *
 *   shop_entitlement(p_shop_id)   the shop's standing (every member)
 *   shop_billing (select)         the subscription status (owner/admin/manager;
 *                                 explicit columns: the Stripe ids are not granted)
 *   public_billing_plans()        the plans ([] while billing is off; anon too)
 *   billing function              checkout / portal (owner) -> a Stripe URL
 *
 * Nothing here writes billing state: Stripe's webhook does (billing-webhook).
 */
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useCallback } from 'react';
import { z } from 'zod';
import { AppError } from '@/lib/errors';
import { unwrap } from '@/lib/db';
import { publicKey, shopKey } from '@/lib/queryKeys';
import { useRequestNonces } from '@/lib/requestNonce';
import { supabase } from '@/lib/supabase';
import { invokeEdge } from '@/features/quotes/shared/edge';
import { redirectTo } from '@/features/settings/externalRedirect';
import {
  CONFIRM_POLL_MS,
  entitlementSchema,
  isStripeUrl,
  planSchema,
  shopBillingSchema,
  subscriptionConfirmed,
  type BillingPlan,
  type Entitlement,
  type ShopBilling,
} from './model';

export const billingKeys = {
  all: (shopId: string) => shopKey(shopId, 'billing'),
  entitlement: (shopId: string) => [...billingKeys.all(shopId), 'entitlement'] as const,
  status: (shopId: string) => [...billingKeys.all(shopId), 'status'] as const,
  plans: () => publicKey('billing-plans', 'all'),
};

function parse<S extends z.ZodType>(schema: S, value: unknown, what: string): z.output<S> {
  const parsed = schema.safeParse(value);
  if (!parsed.success) {
    throw new AppError(`The server sent an unexpected ${what}. Please try again.`, {
      kind: 'server',
      cause: parsed.error,
    });
  }
  return parsed.data;
}

/**
 * The member's view of the shop's standing. null when the server returned
 * nothing (an older backend): the shell then shows no billing UI.
 */
export function useShopEntitlement(shopId: string) {
  return useQuery({
    queryKey: billingKeys.entitlement(shopId),
    queryFn: () => fetchShopEntitlement(shopId),
    staleTime: 60_000,
  });
}

/** shop_entitlement(p_shop_id) once (useShopEntitlement's query; onboarding reads it directly). */
export async function fetchShopEntitlement(shopId: string): Promise<Entitlement | null> {
  const data = unwrap(await supabase.rpc('shop_entitlement', { p_shop_id: shopId }));
  return data === null ? null : parse(entitlementSchema, data, 'billing status');
}

/**
 * The shop's subscription status (managers and up). null = no row. With
 * `pollUntilConfirmed` (back from Checkout) it is re-read every
 * CONFIRM_POLL_MS until Stripe's webhook has recorded the subscription.
 */
export function useShopBillingStatus(
  shopId: string,
  enabled: boolean,
  { pollUntilConfirmed = false }: { pollUntilConfirmed?: boolean } = {},
) {
  return useQuery({
    queryKey: billingKeys.status(shopId),
    enabled,
    refetchInterval: (query) =>
      pollUntilConfirmed && !(query.state.data && subscriptionConfirmed(query.state.data.status))
        ? CONFIRM_POLL_MS
        : false,
    queryFn: async (): Promise<ShopBilling | null> => {
      const rows = unwrap(
        await supabase
          .from('shop_billing')
          .select('plan_id, status, trial_ends_at, current_period_end, cancel_at_period_end')
          .eq('shop_id', shopId)
          .limit(1),
      );
      const row = rows?.[0];
      return row === undefined ? null : parse(shopBillingSchema, row, 'subscription status');
    },
  });
}

/** The platform's plans ([] while billing is off). Works signed out (the /pricing page). */
export function useBillingPlans(enabled = true) {
  return useQuery({
    queryKey: billingKeys.plans(),
    enabled,
    queryFn: async (): Promise<BillingPlan[]> => {
      const data = unwrap(await supabase.rpc('public_billing_plans'));
      return parse(z.array(planSchema), data ?? [], 'plan list');
    },
    staleTime: 5 * 60_000,
  });
}

const urlSchema = z.object({ url: z.string().min(1) });

async function stripeUrl(action: 'checkout' | 'portal', params: Record<string, unknown>) {
  const { url } = await invokeEdge('billing', action, params, urlSchema);
  if (!isStripeUrl(url)) {
    throw new AppError('Stripe returned an unexpected link. Please try again.', {
      kind: 'server',
    });
  }
  return url;
}

/**
 * Owner: Stripe Checkout for `planId` (the billing function creates the
 * session; the price comes from Stripe, never from here), then leaves the
 * app for it. A retry after a network failure reuses the request nonce, so
 * Stripe returns the same session.
 */
export function useStartCheckout(shopId: string) {
  const nonces = useRequestNonces();
  return useMutation({
    mutationFn: async (planId: string) => {
      const key = `checkout:${shopId}:${planId}`;
      try {
        const url = await stripeUrl('checkout', {
          shop_id: shopId,
          plan_id: planId,
          request_nonce: nonces.take(key),
        });
        nonces.settle(key);
        redirectTo(url);
        return url;
      } catch (error) {
        nonces.settle(key, error);
        throw error;
      }
    },
  });
}

/** Owner: the Stripe Customer Portal (plan changes, card, invoices, cancel). */
export function useOpenBillingPortal(shopId: string) {
  return useMutation({
    mutationFn: async () => {
      const url = await stripeUrl('portal', { shop_id: shopId });
      redirectTo(url);
      return url;
    },
  });
}

/** Re-reads everything billing shows (after returning from Stripe). Stable per shop. */
export function useRefreshBilling(shopId: string) {
  const queryClient = useQueryClient();
  return useCallback(
    () => queryClient.invalidateQueries({ queryKey: billingKeys.all(shopId) }),
    [queryClient, shopId],
  );
}
