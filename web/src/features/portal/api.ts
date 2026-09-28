/**
 * Client portal (/portal). Clients have no table access (SPEC §3): the page
 * links the caller's customer records with portal_claim_customers() (only
 * for a CONFIRMED email) and reads everything through portal_overview()
 * (0043), which returns curated documents referencing the public
 * /booking, /q and /i pages by token.
 */
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
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
import { navigation } from '@/features/public-docs/shared/checkout';
import { invokeEdge } from '@/features/quotes/shared/edge';

export const portalKeys = {
  claim: (userId: string) => portalKey(userId, 'claim'),
  overview: (userId: string) => portalKey(userId, 'overview'),
  memberships: (userId: string) => portalKey(userId, 'memberships'),
  documents: (userId: string) => portalKey(userId, 'documents'),
  reports: (userId: string) => portalKey(userId, 'job-reports'),
  referrals: (userId: string) => portalKey(userId, 'referrals'),
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

const portalRetry = (failureCount: number, error: unknown) =>
  failureCount < 2 && toAppError(error).kind !== 'permission';

// ---------------------------------------------------------------------------
// Memberships self-service (P-23): portal_memberships + payments edge
// ---------------------------------------------------------------------------

export const portalMembershipSchema = z.object({
  id: z.string(),
  shop_name: z.string(),
  shop_slug: z.string(),
  plan_name: z.string(),
  status: zMembershipStatus,
  price_cents: zCentsValue,
  interval: zMembershipInterval,
  interval_count: z.number().int(),
  current_period_end: zText,
  cancel_at_period_end: z
    .boolean()
    .nullish()
    .transform((v) => v ?? false),
  /** Included visits per billing period (null = unlimited / not limited). */
  uses_per_period: zIntOrNull,
  uses_this_period: zIntOrNull,
  can_cancel: z.boolean(),
});
export type PortalMembership = z.output<typeof portalMembershipSchema>;

export function usePortalMemberships(userId: string, enabled: boolean) {
  return useQuery({
    queryKey: portalKeys.memberships(userId),
    queryFn: async () =>
      parseDocument(
        z.array(portalMembershipSchema),
        unwrap(await supabase.rpc('portal_memberships')) ?? [],
      ),
    enabled,
    retry: portalRetry,
  });
}

const cancelResultSchema = z.object({
  membership_id: z.string(),
  status: z.string(),
  cancel_at_period_end: z.boolean(),
  current_period_end: z.string().nullable(),
});

/** payments → portal_membership_cancel: ends at the close of the paid period (never now). */
export function useCancelMembership(userId: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (membershipId: string) =>
      invokeEdge(
        'payments',
        'portal_membership_cancel',
        { membership_id: membershipId },
        cancelResultSchema,
      ),
    onSettled: () => {
      void queryClient.invalidateQueries({ queryKey: portalKeys.memberships(userId) });
      void queryClient.invalidateQueries({ queryKey: portalKeys.overview(userId) });
    },
  });
}

const billingPortalSchema = z.object({ url: z.string().min(1) });

/** payments → portal_billing_portal: Stripe's page to update the card / see receipts. */
export function useBillingPortal() {
  return useMutation({
    mutationFn: async (membershipId: string) => {
      const { url } = await invokeEdge(
        'payments',
        'portal_billing_portal',
        { membership_id: membershipId },
        billingPortalSchema,
      );
      let safe = false;
      try {
        safe = new URL(url).protocol === 'https:';
      } catch {
        safe = false;
      }
      if (!safe) throw new Error('The billing page could not be opened.');
      navigation.assign(url);
      return url;
    },
  });
}

// ---------------------------------------------------------------------------
// Documents and job reports shared with the client (P-25, P-8)
// ---------------------------------------------------------------------------

export const portalDocumentSchema = z.object({
  id: z.string(),
  shop_name: z.string(),
  file_name: z.string(),
  content_type: zText,
  size_bytes: z
    .number()
    .int()
    .nullish()
    .transform((v) => v ?? null),
  job_number: zIntOrNull,
  created_at: z.string(),
});
export type PortalDocument = z.output<typeof portalDocumentSchema>;

export function usePortalDocuments(userId: string, enabled: boolean) {
  return useQuery({
    queryKey: portalKeys.documents(userId),
    queryFn: async () =>
      parseDocument(
        z.array(portalDocumentSchema),
        unwrap(await supabase.rpc('portal_documents')) ?? [],
      ),
    enabled,
    retry: portalRetry,
  });
}

export const portalReportSchema = z.object({
  shop_name: z.string(),
  job_number: z.number().int(),
  completed_at: zText,
  published_at: zText,
  report_path: z.string().regex(/^\/r\/[0-9a-f-]{36}$/i),
});
export type PortalReport = z.output<typeof portalReportSchema>;

export function usePortalReports(userId: string, enabled: boolean) {
  return useQuery({
    queryKey: portalKeys.reports(userId),
    queryFn: async () =>
      parseDocument(
        z.array(portalReportSchema),
        unwrap(await supabase.rpc('portal_job_reports')) ?? [],
      ),
    enabled,
    retry: portalRetry,
  });
}

// ---------------------------------------------------------------------------
// Referrals (P-29)
// ---------------------------------------------------------------------------

export const portalReferralSchema = z.object({
  shop_name: z.string(),
  code: z.string(),
  /** Null while the service has no public app URL configured. */
  share_url: zText,
  credits_earned_cents: zCentsValue,
  credit_balance_cents: zCentsValue,
});
export type PortalReferral = z.output<typeof portalReferralSchema>;

export function usePortalReferrals(userId: string, enabled: boolean) {
  return useQuery({
    queryKey: portalKeys.referrals(userId),
    queryFn: async () =>
      parseDocument(
        z.array(portalReferralSchema),
        unwrap(await supabase.rpc('portal_referrals')) ?? [],
      ),
    enabled,
    retry: portalRetry,
    // portal_referrals may create the code on first read: never refetch in a loop.
    staleTime: 10 * 60_000,
  });
}
