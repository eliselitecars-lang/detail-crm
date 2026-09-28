/**
 * Report result schemas (validated at the boundary — the generated types
 * can't express which columns are nullable, and two reports return jsonb)
 * plus display labels. Shapes follow 0047_reports_money.sql and
 * 0048_reports_work.sql.
 */
import { z } from 'zod';
import { Constants } from '@/lib/database.types';

/** bigint/numeric columns arrive as JSON numbers (or strings for big numerics). */
const zNum = z.union([z.number(), z.string()]).transform((v, ctx) => {
  const n = typeof v === 'number' ? v : Number(v);
  if (!Number.isFinite(n)) {
    ctx.addIssue({ code: 'custom', message: 'not a number' });
    return z.NEVER;
  }
  return n;
});
const zNullableNum = zNum.nullable();
/** Nullable column that older servers don't return (missing → null). */
const zOptionalNum = zNum.nullish().transform((v) => v ?? null);

export const PAYMENT_METHODS = Constants.public.Enums.payment_method;
export type PaymentMethod = (typeof PAYMENT_METHODS)[number];

export const METHOD_LABELS: Record<PaymentMethod, string> = {
  card: 'Card (online)',
  card_present: 'Card (in person)',
  cash: 'Cash',
  check: 'Check',
  bank_transfer: 'Bank transfer',
  gift_card: 'Gift card / credit',
  ach_debit: 'Bank debit (ACH)',
  bnpl: 'Pay later',
  other: 'Other',
};

export const revenueRowSchema = z.object({
  bucket_start: z.string(),
  gross_cents: zNum,
  refunds_cents: zNum,
  net_cents: zNum,
  tips_cents: zNum,
  payments_count: zNum,
});
export type RevenueRow = z.infer<typeof revenueRowSchema>;

/** report_revenue_totals (0093): the whole period in one row (same rules as report_revenue). */
export const revenueTotalsSchema = z.object({
  gross_cents: zNum,
  refunds_cents: zNum,
  net_cents: zNum,
  tips_cents: zNum,
  payments_count: zNum,
});
export type RevenueTotals = z.infer<typeof revenueTotalsSchema>;

export const paymentsRowSchema = z.object({
  method: z.enum(PAYMENT_METHODS),
  payments_count: zNum,
  gross_cents: zNum,
  refunds_cents: zNum,
  net_cents: zNum,
  tips_cents: zNum,
  tip_refunds_cents: zNum,
  collected_cents: zNum,
  deposits_cents: zNum,
  memberships_cents: zNum,
  /**
   * Card money lost to chargebacks (payments.disputed_cents). Informational:
   * disputes never change balances or net revenue. Optional for servers
   * before 0093.
   */
  disputes_lost_cents: zNum.optional().default(0),
});
export type PaymentsRow = z.infer<typeof paymentsRowSchema>;

export const salesRowSchema = z.object({
  service_id: z.string().nullable(),
  service_name: z.string().nullable(),
  service_kind: z.enum(Constants.public.Enums.service_kind).nullable(),
  category_id: z.string().nullable(),
  category_name: z.string().nullable(),
  quantity: zNum,
  jobs_count: zNum,
  gross_cents: zNum,
  discount_cents: zNum,
  net_cents: zNum,
});
export type SalesRow = z.infer<typeof salesRowSchema>;

export const teamRowSchema = z.object({
  member_id: z.string(),
  display_name: z.string(),
  role: z.enum(Constants.public.Enums.shop_role),
  active: z.boolean(),
  worked_seconds: zNum,
  hours: zNum,
  jobs_completed: zNum,
  revenue_cents: zNum,
  pre_tax_revenue_cents: zNum,
  // Pay columns are null unless the caller may see them (owner/admin, or a
  // technician's own row).
  hourly_rate_cents: zNullableNum,
  commission_bps: zNullableNum,
  commission_cents: zNullableNum,
  labor_cost_cents: zNullableNum,
  // 0065 (P-12): null for managers; missing on servers before it.
  tips_cents: zOptionalNum,
  service_commission_cents: zOptionalNum,
  sales_commission_cents: zOptionalNum,
  total_earnings_cents: zOptionalNum,
});
export type TeamRow = z.infer<typeof teamRowSchema>;

/** True when the server returned any pay column (so the table shows them). */
export function teamHasPay(rows: readonly TeamRow[]): boolean {
  return rows.some(
    (r) =>
      r.hourly_rate_cents !== null ||
      r.commission_bps !== null ||
      r.commission_cents !== null ||
      r.labor_cost_cents !== null ||
      r.total_earnings_cents !== null,
  );
}

/** True when the server returned the earnings columns (tips, commissions, total). */
export function teamHasEarnings(rows: readonly TeamRow[]): boolean {
  return rows.some(
    (r) =>
      r.tips_cents !== null ||
      r.service_commission_cents !== null ||
      r.sales_commission_cents !== null ||
      r.total_earnings_cents !== null,
  );
}

/** report_member_earnings (0065): one row per completed job the member worked or sold. */
export const memberEarningsRowSchema = z.object({
  job_id: z.string(),
  job_number: zNum,
  completed_at: z.string(),
  customer_label: z.string().nullable(),
  hours: zNum,
  revenue_share_cents: zNum,
  commission_cents: zNum,
  service_commission_cents: zNum,
  sales_commission_cents: zNum,
  tips_cents: zNum,
});
export type MemberEarningsRow = z.infer<typeof memberEarningsRowSchema>;

export interface EarningsTotals {
  hours: number;
  revenueShare: number;
  commission: number;
  serviceCommission: number;
  salesCommission: number;
  tips: number;
}

export function sumEarnings(rows: readonly MemberEarningsRow[]): EarningsTotals {
  const t: EarningsTotals = {
    hours: 0,
    revenueShare: 0,
    commission: 0,
    serviceCommission: 0,
    salesCommission: 0,
    tips: 0,
  };
  for (const r of rows) {
    t.hours += r.hours;
    t.revenueShare += r.revenue_share_cents;
    t.commission += r.commission_cents;
    t.serviceCommission += r.service_commission_cents;
    t.salesCommission += r.sales_commission_cents;
    t.tips += r.tips_cents;
  }
  t.hours = Math.round(t.hours * 100) / 100;
  return t;
}

/** report_gift_cards (0066): sales, redemptions and the outstanding balance. */
export const giftCardsReportSchema = z.object({
  sold_count: zNum,
  sold_value_cents: zNum,
  sold_price_cents: zNum,
  redeemed_cents: zNum,
  outstanding_liability_cents: zNum,
  expired_cents: zNum,
  credit_issued_cents: zNum,
});
export type GiftCardsReport = z.infer<typeof giftCardsReportSchema>;

/** report_job_profit (0078): labor / profit / margin are null for managers. */
export const jobProfitRowSchema = z.object({
  job_id: z.string(),
  job_number: zNum,
  completed_at: z.string(),
  customer_label: z.string().nullable(),
  revenue_cents: zNum,
  materials_cents: zNum,
  labor_cents: zNullableNum,
  profit_cents: zNullableNum,
  margin_bps: zNullableNum,
});
export type JobProfitRow = z.infer<typeof jobProfitRowSchema>;

/** report_service_profit (0078): catalog services only. */
export const serviceProfitRowSchema = z.object({
  service_id: z.string(),
  service_name: z.string().nullable(),
  jobs_count: zNum,
  revenue_cents: zNum,
  materials_cents: zNum,
  gross_profit_cents: zNum,
  margin_bps: zNullableNum,
});
export type ServiceProfitRow = z.infer<typeof serviceProfitRowSchema>;

export const CUSTOMER_SOURCES = Constants.public.Enums.customer_source;
export type CustomerSource = (typeof CUSTOMER_SOURCES)[number];

/** report_lead_sources (0078): one row per source, in enum order. */
export const leadSourceRowSchema = z.object({
  source: z.enum(CUSTOMER_SOURCES),
  customers_count: zNum,
  leads_count: zNum,
  converted_count: zNum,
  revenue_cents: zNum,
  first_job_revenue_cents: zNum,
});
export type LeadSourceRow = z.infer<typeof leadSourceRowSchema>;

/** report_quote_conversion (0078): quotes SENT in the range. */
export const quoteConversionSchema = z.object({
  sent: zNum,
  viewed: zNum,
  approved: zNum,
  declined: zNum,
  expired: zNum,
  converted: zNum,
  conversion_rate_bps: zNullableNum,
  average_quote_cents: zNullableNum,
  average_approved_cents: zNullableNum,
  median_hours_to_approve: zNullableNum,
  by_month: z.array(
    z.object({ month: z.string(), sent: zNum, approved: zNum, approved_cents: zNum }),
  ),
});
export type QuoteConversion = z.infer<typeof quoteConversionSchema>;

/** 0.5 h → "30 min"; 30 h → "1.3 days"; null → "—". */
export function formatWaitHours(hours: number | null): string {
  if (hours === null || !Number.isFinite(hours)) return '—';
  if (hours < 1) return `${Math.max(1, Math.round(hours * 60))} min`;
  if (hours < 48)
    return `${new Intl.NumberFormat('en-US', { maximumFractionDigits: 1 }).format(hours)} h`;
  return `${new Intl.NumberFormat('en-US', { maximumFractionDigits: 1 }).format(hours / 24)} days`;
}

/** "2026-03" → "Mar 2026" (short: "Mar"). */
export function monthLabel(month: string, short = false): string {
  const [y, m] = month.split('-').map(Number);
  if (!y || !m) return month;
  return new Date(Date.UTC(y, m - 1, 1)).toLocaleDateString('en-US', {
    timeZone: 'UTC',
    month: 'short',
    ...(short ? {} : { year: 'numeric' }),
  });
}

export const customersReportSchema = z.object({
  from: z.string(),
  to: z.string(),
  timezone: z.string(),
  customers_served: zNum,
  new_customers: zNum,
  returning_customers: zNum,
  customers_created: zNum,
  completed_jobs: zNum,
  average_ticket_cents: zNullableNum,
  top_customers: z.array(
    z.object({
      customer_id: z.string(),
      name: z.string().nullable(),
      lifetime_net_cents: zNum,
      completed_jobs: zNum,
      last_completed_at: z.string().nullable(),
    }),
  ),
});
export type CustomersReport = z.infer<typeof customersReportSchema>;
export type TopCustomer = CustomersReport['top_customers'][number];

export const AGING_BUCKETS = ['0-30', '31-60', '61-90', '90+'] as const;
export type AgingBucket = (typeof AGING_BUCKETS)[number];

export const AGING_LABELS: Record<AgingBucket, string> = {
  '0-30': 'Current – 30 days',
  '31-60': '31–60 days',
  '61-90': '61–90 days',
  '90+': 'Over 90 days',
};

export const outstandingReportSchema = z.object({
  as_of: z.string(),
  timezone: z.string(),
  count: zNum,
  balance_cents: zNum,
  overdue_count: zNum,
  overdue_balance_cents: zNum,
  buckets: z.array(z.object({ bucket: z.enum(AGING_BUCKETS), count: zNum, balance_cents: zNum })),
  invoices: z.array(
    z.object({
      invoice_id: z.string(),
      number: zNum,
      status: z.string(),
      customer_id: z.string(),
      customer_name: z.string().nullable(),
      job_id: z.string().nullable(),
      issued_at: z.string().nullable(),
      due_at: z.string().nullable(),
      total_cents: zNum,
      amount_paid_cents: zNum,
      balance_cents: zNum,
      days_past_due: zNum,
      overdue: z.boolean(),
      bucket: z.enum(AGING_BUCKETS),
    }),
  ),
});
export type OutstandingReport = z.infer<typeof outstandingReportSchema>;
export type OutstandingInvoice = OutstandingReport['invoices'][number];

/** "12.5" hours → "12.5 h"; 0 → "0 h". */
export function formatHours(hours: number): string {
  return `${new Intl.NumberFormat('en-US', { maximumFractionDigits: 2 }).format(hours)} h`;
}

export function formatCount(n: number): string {
  return new Intl.NumberFormat('en-US', { maximumFractionDigits: 2 }).format(n);
}

/** "1 invoice" / "3 invoices". */
export function countOf(n: number, one: string, many = `${one}s`): string {
  return `${formatCount(n)} ${n === 1 ? one : many}`;
}
