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

export const PAYMENT_METHODS = Constants.public.Enums.payment_method;
export type PaymentMethod = (typeof PAYMENT_METHODS)[number];

export const METHOD_LABELS: Record<PaymentMethod, string> = {
  card: 'Card (online)',
  card_present: 'Card (in person)',
  cash: 'Cash',
  check: 'Check',
  bank_transfer: 'Bank transfer',
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
});
export type TeamRow = z.infer<typeof teamRowSchema>;

/** True when the server returned any pay column (so the table shows them). */
export function teamHasPay(rows: readonly TeamRow[]): boolean {
  return rows.some(
    (r) =>
      r.hourly_rate_cents !== null ||
      r.commission_bps !== null ||
      r.commission_cents !== null ||
      r.labor_cost_cents !== null,
  );
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
