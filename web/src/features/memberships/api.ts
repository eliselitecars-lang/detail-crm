/**
 * Memberships (SPEC §4.5): plan CRUD on membership_plans, subscribers from
 * memberships. Billing is Stripe-driven: create_membership makes an
 * incomplete membership, the payments edge function turns it into a
 * subscription (membership_checkout) or cancels it (membership_cancel), and
 * the webhook keeps status / period end in sync.
 */
import { keepPreviousData, useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { z } from 'zod';
import { pageRange } from '@/components/ui';
import { unwrap, unwrapRequired, type InsertRow, type Row } from '@/lib/db';
import { shopKey } from '@/lib/queryKeys';
import { supabase } from '@/lib/supabase';
import { useShop } from '@/features/shop/shopContext';
import { unwrapList } from '@/features/quotes/shared/db';
import { invokeEdge } from '@/features/quotes/shared/edge';
import { newRequestNonce } from '@/features/quotes/shared/format';
import type { Enums } from '@/features/quotes/shared/types';

export type MembershipStatus = Enums['membership_status'];
export type MembershipInterval = Enums['membership_interval'];
export type PlanRow = Row<'membership_plans'>;

export const MEMBERSHIP_STATUSES = [
  'incomplete',
  'active',
  'past_due',
  'cancelled',
] as const satisfies readonly MembershipStatus[];

export const SUBSCRIBER_PAGE_SIZE = 25;

export interface SubscriberFilters {
  status: MembershipStatus | 'all';
  page: number;
}

export const membershipKeys = {
  all: (shopId: string) => shopKey(shopId, 'memberships'),
  plans: (shopId: string, includeArchived: boolean) =>
    [...membershipKeys.all(shopId), 'plans', includeArchived] as const,
  subscribers: (shopId: string, filters: SubscriberFilters) =>
    [...membershipKeys.all(shopId), 'subscribers', filters] as const,
};

/** "$49.00 / month", "$120.00 every 3 months", "$499.00 / year". */
export function billingLabel(
  priceText: string,
  interval: MembershipInterval,
  intervalCount: number,
): string {
  if (intervalCount <= 1) return `${priceText} / ${interval}`;
  return `${priceText} every ${intervalCount} ${interval}s`;
}

export function usePlans(includeArchived = false) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: membershipKeys.plans(shopId, includeArchived),
    queryFn: async (): Promise<PlanRow[]> => {
      let request = supabase.from('membership_plans').select('*').eq('shop_id', shopId);
      if (!includeArchived) request = request.is('archived_at', null);
      return unwrapList(
        await request.order('sort', { ascending: true }).order('name', { ascending: true }),
      );
    },
  });
}

const subscriberRowSchema = z.object({
  id: z.string(),
  status: z.enum(MEMBERSHIP_STATUSES),
  plan_id: z.string(),
  customer_id: z.string(),
  vehicle_id: z.string().nullable(),
  stripe_subscription_id: z.string().nullable(),
  current_period_end: z.string().nullable(),
  cancel_at_period_end: z.boolean(),
  started_at: z.string().nullable(),
  cancelled_at: z.string().nullable(),
  created_at: z.string(),
  plan: z
    .object({
      id: z.string(),
      name: z.string(),
      price_cents: z.number(),
      interval: z.enum(['week', 'month', 'year']),
      interval_count: z.number(),
      included_uses_per_period: z
        .number()
        .nullish()
        .transform((v) => v ?? null),
    })
    .nullable(),
  customer: z
    .object({
      id: z.string(),
      first_name: z.string().nullable(),
      last_name: z.string().nullable(),
      company: z.string().nullable(),
      phone: z.string().nullable(),
      email: z.string().nullable(),
      sms_opted_out_at: z.string().nullable(),
      email_opted_out_at: z.string().nullable(),
    })
    .nullable(),
  vehicle: z
    .object({
      id: z.string(),
      year: z.number().nullable(),
      make: z.string().nullable(),
      model: z.string().nullable(),
      license_plate: z.string().nullable(),
    })
    .nullable(),
});

export type SubscriberRow = z.infer<typeof subscriberRowSchema>;

const SUBSCRIBER_COLUMNS =
  'id, status, plan_id, customer_id, vehicle_id, stripe_subscription_id, current_period_end, cancel_at_period_end, started_at, cancelled_at, created_at, ' +
  'plan:membership_plans(id, name, price_cents, interval, interval_count, included_uses_per_period), ' +
  'customer:customers(id, first_name, last_name, company, phone, email, sms_opted_out_at, email_opted_out_at), ' +
  'vehicle:vehicles(id, year, make, model, license_plate)';

export function useSubscribers(filters: SubscriberFilters) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: membershipKeys.subscribers(shopId, filters),
    placeholderData: keepPreviousData,
    queryFn: async (): Promise<{ rows: SubscriberRow[]; total: number }> => {
      let request = supabase
        .from('memberships')
        .select(SUBSCRIBER_COLUMNS, { count: 'exact' })
        .eq('shop_id', shopId);
      if (filters.status !== 'all') request = request.eq('status', filters.status);
      const { from, to } = pageRange(filters.page, SUBSCRIBER_PAGE_SIZE);
      const { data, error, count } = await request
        .order('created_at', { ascending: false })
        .range(from, to);
      const rows = z.array(subscriberRowSchema).parse(unwrap({ data, error }) ?? []);
      return { rows, total: count ?? rows.length };
    },
  });
}

function useInvalidateMemberships() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return () => queryClient.invalidateQueries({ queryKey: membershipKeys.all(shopId) });
}

export interface PlanInput {
  name: string;
  description: string | null;
  price_cents: number;
  interval: MembershipInterval;
  interval_count: number;
  included_service_ids: string[];
  discount_bps: number;
  active: boolean;
  /** Offered on the public join page (/join/<slug>). */
  online_joinable: boolean;
  /** Included services may be used this many times per billing period (null = unlimited). */
  included_uses_per_period: number | null;
  /** Shown on the join page and at checkout. */
  terms: string | null;
}

export function useSavePlan() {
  const { shopId } = useShop();
  const invalidate = useInvalidateMemberships();
  return useMutation({
    mutationFn: async ({ id, input }: { id: string | null; input: PlanInput }) => {
      if (id) {
        return unwrapRequired(
          await supabase
            .from('membership_plans')
            .update(input)
            .eq('shop_id', shopId)
            .eq('id', id)
            .select('*')
            .maybeSingle(),
          'plan',
        );
      }
      const row: InsertRow<'membership_plans'> = { ...input, shop_id: shopId };
      return unwrapRequired(
        await supabase.from('membership_plans').insert(row).select('*').maybeSingle(),
        'plan',
      );
    },
    onSettled: invalidate,
  });
}

/** Archive (hide from new sign-ups; existing subscribers keep billing) or restore. */
export function useArchivePlan() {
  const { shopId } = useShop();
  const invalidate = useInvalidateMemberships();
  return useMutation({
    mutationFn: async ({ id, archived }: { id: string; archived: boolean }) => {
      unwrap(
        await supabase
          .from('membership_plans')
          .update(
            archived
              ? { archived_at: new Date().toISOString(), active: false }
              : { archived_at: null },
          )
          .eq('shop_id', shopId)
          .eq('id', id),
      );
    },
    onSettled: invalidate,
  });
}

export const membershipUsageSchema = z.object({
  uses_per_period: z.number().int().nullable(),
  uses_this_period: z.number().int(),
  period_start: z.string().nullable(),
  period_end: z.string().nullable(),
});
export type MembershipUsage = z.infer<typeof membershipUsageSchema>;

/** Included-service uses in the current billing period (membership_usage, managers+). */
export function useMembershipUsage(membershipId: string, enabled: boolean) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: [...membershipKeys.all(shopId), 'usage', membershipId] as const,
    enabled,
    staleTime: 60_000,
    queryFn: async (): Promise<MembershipUsage> =>
      membershipUsageSchema.parse(
        unwrap(await supabase.rpc('membership_usage', { p_membership_id: membershipId })),
      ),
  });
}

/** "2 of 4 used", "3 used" (unlimited). */
export function usageText(usage: Pick<MembershipUsage, 'uses_per_period' | 'uses_this_period'>) {
  return usage.uses_per_period === null
    ? `${usage.uses_this_period} used`
    : `${usage.uses_this_period} of ${usage.uses_per_period} used`;
}

export function useCreateMembership() {
  const invalidate = useInvalidateMemberships();
  return useMutation({
    mutationFn: async (input: { planId: string; customerId: string; vehicleId: string | null }) =>
      unwrapRequired(
        await supabase.rpc('create_membership', {
          p_plan_id: input.planId,
          p_customer_id: input.customerId,
          ...(input.vehicleId ? { p_vehicle_id: input.vehicleId } : {}),
        }),
        'membership',
      ),
    onSettled: invalidate,
  });
}

export const checkoutResultSchema = z.object({
  url: z.url(),
  expires_at: z.number().nullable().optional(),
  amount_cents: z.number().int(),
  interval: z.enum(['week', 'month', 'year']),
  interval_count: z.number().int(),
  currency: z.string(),
});

export type CheckoutResult = z.infer<typeof checkoutResultSchema>;

/** payments.membership_checkout → Stripe Checkout (subscription) link. */
export function useMembershipCheckout() {
  const { shopId } = useShop();
  return useMutation({
    mutationFn: (membershipId: string) =>
      invokeEdge(
        'payments',
        'membership_checkout',
        { shop_id: shopId, membership_id: membershipId, request_nonce: newRequestNonce() },
        checkoutResultSchema,
      ),
  });
}

export const cancelResultSchema = z.object({
  membership_id: z.string(),
  status: z.string(),
  cancel_at_period_end: z.boolean(),
  current_period_end: z.string().nullable(),
});

export function useCancelMembership() {
  const { shopId } = useShop();
  const invalidate = useInvalidateMemberships();
  return useMutation({
    mutationFn: ({ membershipId, atPeriodEnd }: { membershipId: string; atPeriodEnd: boolean }) =>
      invokeEdge(
        'payments',
        'membership_cancel',
        { shop_id: shopId, membership_id: membershipId, at_period_end: atPeriodEnd },
        cancelResultSchema,
      ),
    onSettled: invalidate,
  });
}
