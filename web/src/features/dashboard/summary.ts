/**
 * dashboard_summary(p_shop_id) jsonb contract (0046_reports_dashboard.sql),
 * validated at the boundary. Money/inbox figures are null for technicians
 * (scope "own").
 */
import { z } from 'zod';

const cents = z.number().int();
const count = z.number().int().nonnegative();

const period = z.object({
  net_cents: cents,
  tips_cents: cents,
  payments_count: count,
});

const moneyCount = z.object({ count, balance_cents: cents });

export const JOB_STATUSES = [
  'requested',
  'scheduled',
  'confirmed',
  'en_route',
  'in_progress',
  'completed',
  'cancelled',
  'no_show',
] as const;

export const dashboardSummarySchema = z.object({
  shop_id: z.string(),
  timezone: z.string(),
  as_of: z.string(),
  scope: z.enum(['shop', 'own']),
  today: z.string(),
  week_start: z.string(),
  month_start: z.string(),
  jobs_today: z.object({
    total: count,
    by_status: z.partialRecord(z.enum(JOB_STATUSES), count),
  }),
  next_job: z
    .object({
      id: z.string(),
      number: z.number().int(),
      status: z.enum(JOB_STATUSES),
      scheduled_start: z.string(),
      scheduled_end: z.string(),
      location_type: z.enum(['shop', 'mobile']),
      customer_id: z.string(),
      customer_name: z.string().nullable(),
      vehicle_id: z.string().nullable(),
      vehicle_label: z.string().nullable(),
      assigned_member_ids: z.array(z.string()),
    })
    .nullable(),
  jobs_this_week: count,
  pending_booking_requests: count.nullable(),
  quotes_awaiting_response: count.nullable(),
  open_invoices: moneyCount.nullable(),
  overdue_invoices: moneyCount.nullable(),
  revenue: z.object({ today: period, week: period, month: period }).nullable(),
  unread_inbound_messages: count.nullable(),
  clocked_in: z.object({
    count,
    members: z.array(
      z.object({
        member_id: z.string(),
        display_name: z.string(),
        since: z.string(),
        job_id: z.string().nullable(),
      }),
    ),
  }),
});

export type DashboardSummary = z.infer<typeof dashboardSummarySchema>;
export type NextJob = NonNullable<DashboardSummary['next_job']>;

/** Seconds → "7h 05m" / "45m". */
export function formatDuration(seconds: number): string {
  const total = Math.max(0, Math.floor(seconds / 60));
  const h = Math.floor(total / 60);
  const m = total % 60;
  if (h === 0) return `${m}m`;
  return `${h}h ${String(m).padStart(2, '0')}m`;
}

/**
 * calendar_events titles are "<customer> — <service, service>" where
 * <customer> is the person's name or, failing that, the company. Returns the
 * customer part (the whole title when the job has no line items yet).
 */
export function customerFromTitle(title: string | null): string | null {
  if (!title) return null;
  const at = title.indexOf(' — ');
  return (at >= 0 ? title.slice(0, at) : title).trim() || null;
}

/**
 * Display name for a schedule row: calendar_events' customer_name is the
 * person's name only, so company-only (fleet) customers fall back to the title.
 */
export function scheduleCustomerLabel(row: {
  customer_name: string | null;
  title: string | null;
}): string {
  return row.customer_name ?? customerFromTitle(row.title) ?? 'Customer';
}

/** calendar_events titles are "<customer> — <service, service>"; returns the services part. */
export function servicesFromTitle(title: string | null): string | null {
  if (!title) return null;
  const at = title.indexOf(' — ');
  return at >= 0 ? title.slice(at + 3).trim() || null : null;
}
