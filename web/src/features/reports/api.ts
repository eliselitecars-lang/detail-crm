/**
 * Report RPCs (SPEC §4.8, migrations 0047/0048). All are manager+ except
 * report_team, which technicians may call for their own row. Dates are
 * inclusive shop-local calendar dates; the server buckets in the shop's
 * time zone. Results are validated with zod (see model.ts).
 */
import { useQuery } from '@tanstack/react-query';
import { z } from 'zod';
import { unwrap } from '@/lib/db';
import { AppError } from '@/lib/errors';
import { shopKey } from '@/lib/queryKeys';
import { supabase } from '@/lib/supabase';
import { useShop } from '@/features/shop/shopContext';
import {
  customersReportSchema,
  giftCardsReportSchema,
  jobProfitRowSchema,
  leadSourceRowSchema,
  memberEarningsRowSchema,
  quoteConversionSchema,
  serviceProfitRowSchema,
  outstandingReportSchema,
  paymentsRowSchema,
  revenueRowSchema,
  revenueTotalsSchema,
  salesRowSchema,
  teamRowSchema,
  type CustomersReport,
  type GiftCardsReport,
  type JobProfitRow,
  type LeadSourceRow,
  type MemberEarningsRow,
  type QuoteConversion,
  type ServiceProfitRow,
  type OutstandingReport,
  type PaymentsRow,
  type RevenueRow,
  type RevenueTotals,
  type SalesRow,
  type TeamRow,
} from './model';
import { bucketStart, type Bucket, type DateRange } from './ranges';

export const reportKeys = {
  all: (shopId: string) => shopKey(shopId, 'reports'),
  revenue: (shopId: string, range: DateRange, bucket: Bucket) =>
    [...reportKeys.all(shopId), 'revenue', range.from, range.to, bucket] as const,
  revenueTotals: (shopId: string, range: DateRange) =>
    [...reportKeys.all(shopId), 'revenue-totals', range.from, range.to] as const,
  payments: (shopId: string, range: DateRange) =>
    [...reportKeys.all(shopId), 'payments', range.from, range.to] as const,
  sales: (shopId: string, range: DateRange) =>
    [...reportKeys.all(shopId), 'sales', range.from, range.to] as const,
  team: (shopId: string, range: DateRange) =>
    [...reportKeys.all(shopId), 'team', range.from, range.to] as const,
  customers: (shopId: string, range: DateRange) =>
    [...reportKeys.all(shopId), 'customers', range.from, range.to] as const,
  outstanding: (shopId: string) => [...reportKeys.all(shopId), 'outstanding'] as const,
  earnings: (shopId: string, memberId: string, range: DateRange) =>
    [...reportKeys.all(shopId), 'earnings', memberId, range.from, range.to] as const,
  giftCards: (shopId: string, range: DateRange) =>
    [...reportKeys.all(shopId), 'gift-cards', range.from, range.to] as const,
  jobProfit: (shopId: string, range: DateRange) =>
    [...reportKeys.all(shopId), 'job-profit', range.from, range.to] as const,
  serviceProfit: (shopId: string, range: DateRange) =>
    [...reportKeys.all(shopId), 'service-profit', range.from, range.to] as const,
  leadSources: (shopId: string, range: DateRange) =>
    [...reportKeys.all(shopId), 'lead-sources', range.from, range.to] as const,
  quoteConversion: (shopId: string, range: DateRange) =>
    [...reportKeys.all(shopId), 'quote-conversion', range.from, range.to] as const,
};

function parse<T>(schema: z.ZodType<T>, data: unknown): T {
  const result = schema.safeParse(data);
  if (!result.success) {
    throw new AppError('The report came back in an unexpected format. Please try again.', {
      kind: 'server',
      cause: result.error,
    });
  }
  return result.data;
}

/**
 * report_revenue returns every bucket through the one containing `to`
 * (ascending). If the response was cut short (PostgREST max_rows), the
 * totals would silently understate the period — fail loudly instead.
 */
export function assertCompleteRevenue(rows: RevenueRow[], range: DateRange, bucket: Bucket): void {
  const last = rows.at(-1);
  if (last && last.bucket_start < bucketStart(range.to, bucket)) {
    throw new AppError(
      'This report has too many periods to show at once. Choose a shorter range or group by month.',
      { kind: 'validation' },
    );
  }
}

interface Options {
  enabled?: boolean;
}

export function useRevenueReport(
  range: DateRange,
  bucket: Bucket,
  { enabled = true }: Options = {},
) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: reportKeys.revenue(shopId, range, bucket),
    enabled,
    queryFn: async (): Promise<RevenueRow[]> => {
      const rows = parse(
        z.array(revenueRowSchema),
        unwrap(
          await supabase.rpc('report_revenue', {
            p_shop_id: shopId,
            p_from: range.from,
            p_to: range.to,
            p_bucket: bucket,
          }),
        ) ?? [],
      );
      assertCompleteRevenue(rows, range, bucket);
      return rows;
    },
  });
}

/**
 * The period's revenue totals in one row (report_revenue_totals): the
 * summary cards never depend on how many buckets the chart has.
 */
export function useRevenueTotals(range: DateRange, { enabled = true }: Options = {}) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: reportKeys.revenueTotals(shopId, range),
    enabled,
    queryFn: async (): Promise<RevenueTotals> => {
      const rows = parse(
        z.array(revenueTotalsSchema),
        unwrap(
          await supabase.rpc('report_revenue_totals', {
            p_shop_id: shopId,
            p_from: range.from,
            p_to: range.to,
          }),
        ) ?? [],
      );
      const row = rows[0];
      if (!row) {
        throw new AppError('The report came back in an unexpected format. Please try again.', {
          kind: 'server',
        });
      }
      return row;
    },
  });
}

export function usePaymentsReport(range: DateRange, { enabled = true }: Options = {}) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: reportKeys.payments(shopId, range),
    enabled,
    queryFn: async (): Promise<PaymentsRow[]> =>
      parse(
        z.array(paymentsRowSchema),
        unwrap(
          await supabase.rpc('report_payments', {
            p_shop_id: shopId,
            p_from: range.from,
            p_to: range.to,
          }),
        ) ?? [],
      ),
  });
}

export function useSalesReport(range: DateRange, { enabled = true }: Options = {}) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: reportKeys.sales(shopId, range),
    enabled,
    queryFn: async (): Promise<SalesRow[]> =>
      parse(
        z.array(salesRowSchema),
        unwrap(
          await supabase.rpc('report_sales_by_service', {
            p_shop_id: shopId,
            p_from: range.from,
            p_to: range.to,
          }),
        ) ?? [],
      ),
  });
}

export function useTeamReport(range: DateRange, { enabled = true }: Options = {}) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: reportKeys.team(shopId, range),
    enabled,
    queryFn: async (): Promise<TeamRow[]> =>
      parse(
        z.array(teamRowSchema),
        unwrap(
          await supabase.rpc('report_team', {
            p_shop_id: shopId,
            p_from: range.from,
            p_to: range.to,
          }),
        ) ?? [],
      ),
  });
}

/** Top-customer list length requested from report_customers (server max 100). */
export const TOP_CUSTOMERS_LIMIT = 25;

export function useCustomersReport(range: DateRange, { enabled = true }: Options = {}) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: reportKeys.customers(shopId, range),
    enabled,
    queryFn: async (): Promise<CustomersReport> =>
      parse(
        customersReportSchema,
        unwrap(
          await supabase.rpc('report_customers', {
            p_shop_id: shopId,
            p_from: range.from,
            p_to: range.to,
            p_limit: TOP_CUSTOMERS_LIMIT,
          }),
        ),
      ),
  });
}

export function useOutstandingReport({ enabled = true }: Options = {}) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: reportKeys.outstanding(shopId),
    enabled,
    queryFn: async (): Promise<OutstandingReport> =>
      parse(
        outstandingReportSchema,
        unwrap(await supabase.rpc('report_outstanding', { p_shop_id: shopId })),
      ),
  });
}

/** One member's completed jobs with their share, commissions and tips (0065). */
export function useMemberEarnings(
  memberId: string,
  range: DateRange,
  { enabled = true }: Options = {},
) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: reportKeys.earnings(shopId, memberId, range),
    enabled,
    queryFn: async (): Promise<MemberEarningsRow[]> =>
      parse(
        z.array(memberEarningsRowSchema),
        unwrap(
          await supabase.rpc('report_member_earnings', {
            p_shop_id: shopId,
            p_member_id: memberId,
            p_from: range.from,
            p_to: range.to,
          }),
        ) ?? [],
      ),
  });
}

export function useGiftCardsReport(range: DateRange, { enabled = true }: Options = {}) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: reportKeys.giftCards(shopId, range),
    enabled,
    queryFn: async (): Promise<GiftCardsReport> =>
      parse(
        giftCardsReportSchema,
        unwrap(
          await supabase.rpc('report_gift_cards', {
            p_shop_id: shopId,
            p_from: range.from,
            p_to: range.to,
          }),
        ),
      ),
  });
}

export function useJobProfitReport(range: DateRange, { enabled = true }: Options = {}) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: reportKeys.jobProfit(shopId, range),
    enabled,
    queryFn: async (): Promise<JobProfitRow[]> =>
      parse(
        z.array(jobProfitRowSchema),
        unwrap(
          await supabase.rpc('report_job_profit', {
            p_shop_id: shopId,
            p_from: range.from,
            p_to: range.to,
          }),
        ) ?? [],
      ),
  });
}

export function useServiceProfitReport(range: DateRange, { enabled = true }: Options = {}) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: reportKeys.serviceProfit(shopId, range),
    enabled,
    queryFn: async (): Promise<ServiceProfitRow[]> =>
      parse(
        z.array(serviceProfitRowSchema),
        unwrap(
          await supabase.rpc('report_service_profit', {
            p_shop_id: shopId,
            p_from: range.from,
            p_to: range.to,
          }),
        ) ?? [],
      ),
  });
}

export function useLeadSourcesReport(range: DateRange, { enabled = true }: Options = {}) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: reportKeys.leadSources(shopId, range),
    enabled,
    queryFn: async (): Promise<LeadSourceRow[]> =>
      parse(
        z.array(leadSourceRowSchema),
        unwrap(
          await supabase.rpc('report_lead_sources', {
            p_shop_id: shopId,
            p_from: range.from,
            p_to: range.to,
          }),
        ) ?? [],
      ),
  });
}

export function useQuoteConversionReport(range: DateRange, { enabled = true }: Options = {}) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: reportKeys.quoteConversion(shopId, range),
    enabled,
    queryFn: async (): Promise<QuoteConversion> =>
      parse(
        quoteConversionSchema,
        unwrap(
          await supabase.rpc('report_quote_conversion', {
            p_shop_id: shopId,
            p_from: range.from,
            p_to: range.to,
          }),
        ),
      ),
  });
}
