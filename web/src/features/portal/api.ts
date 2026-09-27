/**
 * Client portal (/portal). Clients have no table access (SPEC §3): the page
 * links the caller's customer records with portal_claim_customers() (only
 * for a CONFIRMED email) and reads everything through portal_overview()
 * (0043), which returns curated documents referencing the public
 * /booking, /q and /i pages by token.
 */
import { useQuery } from '@tanstack/react-query';
import { z } from 'zod';
import { unwrap } from '@/lib/db';
import { toAppError } from '@/lib/errors';
import { portalKey } from '@/lib/queryKeys';
import { supabase } from '@/lib/supabase';
import {
  parseDocument,
  zCentsValue,
  zIntOrNull,
  zInvoiceStatus,
  zJobStatus,
  zLocationType,
  zMembershipInterval,
  zMembershipStatus,
  zQuoteStatus,
  zText,
} from '@/features/public-docs/shared/schemas';

export const portalKeys = {
  claim: (userId: string) => portalKey(userId, 'claim'),
  overview: (userId: string) => portalKey(userId, 'overview'),
};

const portalShopSchema = z.object({
  slug: z.string(),
  name: z.string(),
  logo_path: zText,
  brand_color: zText,
  phone: zText,
  email: zText,
  website: zText,
  city: zText,
  region: zText,
  timezone: z.string(),
  currency: z
    .string()
    .nullish()
    .transform((v) => v ?? 'usd'),
  booking_enabled: z.boolean(),
});
export type PortalShop = z.output<typeof portalShopSchema>;

const jobSchema = z.object({
  token: z.string(),
  shop_slug: z.string(),
  number: z.number().int(),
  status: zJobStatus,
  scheduled_start: zText,
  scheduled_end: zText,
  completed_at: zText,
  location_type: zLocationType,
  vehicle: zText,
  services: zText,
  total_cents: zCentsValue,
  deposit_required_cents: zCentsValue.nullish().transform((v) => v ?? 0),
});
export type PortalJob = z.output<typeof jobSchema>;

export const portalOverviewSchema = z.object({
  shops: z.array(portalShopSchema),
  customers: z.array(
    z.object({
      shop_slug: z.string(),
      first_name: zText,
      last_name: zText,
      company: zText,
      email: zText,
      phone: zText,
      sms_opt_in: z.boolean(),
      email_opt_in: z.boolean(),
    }),
  ),
  vehicles: z.array(
    z.object({
      id: z.string(),
      shop_slug: z.string(),
      year: zIntOrNull,
      make: zText,
      model: zText,
      trim: zText,
      color: zText,
      license_plate: zText,
      category_id: zText,
      category_name: zText,
    }),
  ),
  upcoming_jobs: z.array(jobSchema),
  past_jobs: z.array(jobSchema),
  quotes: z.array(
    z.object({
      token: z.string(),
      shop_slug: z.string(),
      number: z.number().int(),
      status: zQuoteStatus,
      total_cents: zCentsValue,
      valid_until: zText,
      sent_at: zText,
      vehicle: zText,
    }),
  ),
  invoices: z.array(
    z.object({
      token: z.string(),
      shop_slug: z.string(),
      number: z.number().int(),
      status: zInvoiceStatus,
      total_cents: zCentsValue,
      amount_paid_cents: zCentsValue,
      balance_cents: zCentsValue,
      issued_at: zText,
      due_at: zText,
    }),
  ),
  memberships: z.array(
    z.object({
      shop_slug: z.string(),
      plan_name: z.string(),
      plan_description: zText,
      status: zMembershipStatus,
      price_cents: zCentsValue,
      interval: zMembershipInterval,
      interval_count: z.number().int(),
      discount_bps: zIntOrNull,
      included_services: z.array(z.string()),
      vehicle: zText,
      current_period_end: zText,
      cancel_at_period_end: z
        .boolean()
        .nullish()
        .transform((v) => v ?? false),
      started_at: zText,
    }),
  ),
});
export type PortalOverview = z.output<typeof portalOverviewSchema>;

/**
 * Links unlinked customer records whose email equals the caller's confirmed
 * email. Run once per session; a refusal (unconfirmed email) is shown as a
 * notice, and the overview still loads.
 */
export function usePortalClaim(userId: string) {
  return useQuery({
    queryKey: portalKeys.claim(userId),
    queryFn: async () => unwrap(await supabase.rpc('portal_claim_customers')),
    staleTime: Infinity,
    gcTime: Infinity,
    refetchOnWindowFocus: false,
    retry: (failureCount, error) => failureCount < 2 && toAppError(error).kind !== 'permission',
  });
}

export function usePortalOverview(userId: string, enabled: boolean) {
  return useQuery({
    queryKey: portalKeys.overview(userId),
    queryFn: async () =>
      parseDocument(portalOverviewSchema, unwrap(await supabase.rpc('portal_overview'))),
    enabled,
    retry: (failureCount, error) => failureCount < 2 && toAppError(error).kind !== 'permission',
  });
}
