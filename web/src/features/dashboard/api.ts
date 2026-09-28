/**
 * Dashboard data: the server-computed summary (dashboard_summary), today's
 * schedule (calendar_events), pending online-booking requests and the
 * caller's own time clock. All money/figures come from the server.
 */
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { z } from 'zod';
import { unwrap } from '@/lib/db';
import { AppError } from '@/lib/errors';
import {
  cancelOpenPaymentsResultSchema,
  type CancelOpenPaymentsResult,
} from '@/features/invoices/api';
import { EdgeFunctionError, invokeEdge } from '@/features/quotes/shared/edge';
import { shopDayRangeUtc, type LocalDate } from '@/lib/dates';
import { shopKey } from '@/lib/queryKeys';
import { supabase } from '@/lib/supabase';
import { useRealtime, type RealtimeTable } from '@/lib/useRealtime';
import { dashboardSummarySchema, JOB_STATUSES } from './summary';

export const dashboardKeys = {
  all: (shopId: string) => shopKey(shopId, 'dashboard'),
  summary: (shopId: string) => [...dashboardKeys.all(shopId), 'summary'] as const,
  schedule: (shopId: string, day: LocalDate) =>
    [...dashboardKeys.all(shopId), 'schedule', day] as const,
  requests: (shopId: string) => [...dashboardKeys.all(shopId), 'requests'] as const,
  clock: (shopId: string, memberId: string) =>
    [...dashboardKeys.all(shopId), 'clock', memberId] as const,
  hours: (shopId: string, memberId: string, from: LocalDate, to: LocalDate) =>
    [...dashboardKeys.all(shopId), 'hours', memberId, from, to] as const,
};

// ---------------------------------------------------------------- summary

export function useDashboardSummary(shopId: string) {
  return useQuery({
    queryKey: dashboardKeys.summary(shopId),
    refetchInterval: 5 * 60_000,
    queryFn: async () => {
      const data = unwrap(await supabase.rpc('dashboard_summary', { p_shop_id: shopId }));
      const parsed = dashboardSummarySchema.safeParse(data);
      if (!parsed.success) {
        throw new AppError('The dashboard couldn’t be loaded. Please try again.', {
          kind: 'server',
          cause: parsed.error,
        });
      }
      return parsed.data;
    },
  });
}

/** Refreshes every dashboard query when jobs, payments, messages or time entries change. */
export function useDashboardRealtime(shopId: string) {
  const keys = (table: RealtimeTable) => [dashboardKeys.all(shopId), shopKey(shopId, table)];
  useRealtime({ table: 'jobs', shopId, invalidate: keys('jobs') });
  useRealtime({ table: 'payments', shopId, invalidate: keys('payments') });
  useRealtime({ table: 'messages', shopId, invalidate: keys('messages') });
  useRealtime({ table: 'time_entries', shopId, invalidate: keys('time_entries') });
}

// ---------------------------------------------------------------- today's schedule

const scheduleRowSchema = z.object({
  event_type: z.string(),
  id: z.string(),
  job_number: z.number().int().nullable(),
  status: z.enum(JOB_STATUSES).nullable(),
  starts_at: z.string(),
  ends_at: z.string(),
  is_busy_block: z.boolean(),
  customer_id: z.string().nullable(),
  customer_name: z.string().nullable(),
  vehicle_label: z.string().nullable(),
  location_type: z.enum(['shop', 'mobile']).nullable(),
  service_address: z.string().nullable(),
  assigned_member_ids: z.array(z.string()).nullable(),
  title: z.string().nullable(),
});
export type ScheduleJob = z.infer<typeof scheduleRowSchema>;

/**
 * Jobs overlapping the shop-local `day`. Technicians receive other people's
 * jobs as anonymous busy blocks; those are left out (only full job rows).
 */
export function useTodaySchedule(shopId: string, timezone: string, day: LocalDate | undefined) {
  return useQuery({
    queryKey: dashboardKeys.schedule(shopId, day ?? ''),
    enabled: day !== undefined,
    queryFn: async () => {
      const { from, to } = shopDayRangeUtc(day ?? '', timezone);
      const data = unwrap(
        await supabase.rpc('calendar_events', { p_shop_id: shopId, p_from: from, p_to: to }),
      );
      const rows = z.array(scheduleRowSchema).parse(data ?? []);
      return rows.filter((r) => r.event_type === 'job' && !r.is_busy_block);
    },
  });
}

// ---------------------------------------------------------------- booking requests

export interface BookingRequest {
  id: string;
  number: number;
  scheduled_start: string | null;
  scheduled_end: string | null;
  location_type: 'shop' | 'mobile';
  created_at: string;
  customer_id: string;
  customerName: string | null;
}

export function useBookingRequests(shopId: string, enabled: boolean) {
  return useQuery({
    queryKey: dashboardKeys.requests(shopId),
    enabled,
    queryFn: async (): Promise<BookingRequest[]> => {
      const jobs =
        unwrap(
          await supabase
            .from('jobs')
            .select(
              'id, number, scheduled_start, scheduled_end, location_type, created_at, customer_id',
            )
            .eq('shop_id', shopId)
            .eq('status', 'requested')
            .eq('source', 'online_booking')
            .order('scheduled_start', { ascending: true, nullsFirst: false })
            .order('created_at')
            .limit(20),
        ) ?? [];
      const ids = [...new Set(jobs.map((j) => j.customer_id))];
      const customers =
        ids.length === 0
          ? []
          : (unwrap(
              await supabase
                .from('customers')
                .select('id, first_name, last_name, company')
                .eq('shop_id', shopId)
                .in('id', ids),
            ) ?? []);
      const names = new Map(
        customers.map((c) => [
          c.id,
          [c.first_name, c.last_name].filter(Boolean).join(' ').trim() || c.company || null,
        ]),
      );
      return jobs.map((j) => ({ ...j, customerName: names.get(j.customer_id) ?? null }));
    },
  });
}

function useInvalidateJobs(shopId: string) {
  const queryClient = useQueryClient();
  return () =>
    Promise.all([
      queryClient.invalidateQueries({ queryKey: dashboardKeys.all(shopId) }),
      queryClient.invalidateQueries({ queryKey: shopKey(shopId, 'jobs') }),
    ]);
}

export const REQUEST_ALREADY_HANDLED =
  'This request was already handled — it’s no longer waiting for approval.';

/**
 * The status guard (`status = 'requested'`) turns a stale approve/decline into
 * a zero-row update, which PostgREST reports as success. Treat "nothing
 * changed" as a conflict so the UI never claims an action that didn't happen
 * (another manager, the customer's manage link or the jobs page got there first).
 */
function requireChanged(rows: { id: string }[] | null): void {
  if (!rows || rows.length === 0) {
    throw new AppError(REQUEST_ALREADY_HANDLED, { kind: 'conflict' });
  }
}

/** requested → scheduled (the status trigger validates the transition). */
export function useApproveRequest(shopId: string) {
  const invalidate = useInvalidateJobs(shopId);
  return useMutation({
    mutationFn: async (jobId: string) => {
      requireChanged(
        unwrap(
          await supabase
            .from('jobs')
            .update({ status: 'scheduled' })
            .eq('shop_id', shopId)
            .eq('id', jobId)
            .eq('status', 'requested')
            .select('id'),
        ),
      );
    },
    onSettled: invalidate,
  });
}

export const DECLINE_PAYMENT_IN_PROGRESS =
  'A card payment for this booking is still processing. Wait for it to finish, then decline.';

export interface DeclineRequestInput {
  jobId: string;
  reason: string;
  /**
   * Release the job's open card payments first (payments.cancel_open_payments
   * with `job_id`): an online booking can have an open deposit Checkout /
   * sheet, and nobody may pay for a declined appointment. True for every role
   * that can collect payments (the same rule as the job page and iPhone).
   */
  releasePayments: boolean;
}

export interface DeclineRequestResult {
  /** Card payments that had already gone through and were recorded. */
  recorded: number;
}

/**
 * requested → cancelled with a reason. The open deposit links / sheets are
 * released first; a payment still processing stops the decline (the status
 * does not change) so the money is never taken for a cancelled job.
 */
export function useDeclineRequest(shopId: string) {
  const invalidate = useInvalidateJobs(shopId);
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async ({
      jobId,
      reason,
      releasePayments,
    }: DeclineRequestInput): Promise<DeclineRequestResult> => {
      let recorded = 0;
      if (releasePayments) {
        let released: CancelOpenPaymentsResult;
        try {
          released = await invokeEdge(
            'payments',
            'cancel_open_payments',
            { shop_id: shopId, job_id: jobId },
            cancelOpenPaymentsResultSchema,
          );
        } catch (error) {
          if (error instanceof EdgeFunctionError && error.reason === 'payment_in_progress') {
            throw new AppError(DECLINE_PAYMENT_IN_PROGRESS, { kind: 'validation', cause: error });
          }
          throw error;
        }
        if (released.in_progress > 0) {
          throw new AppError(DECLINE_PAYMENT_IN_PROGRESS, { kind: 'validation' });
        }
        recorded = released.succeeded;
      }
      requireChanged(
        unwrap(
          await supabase
            .from('jobs')
            .update({ status: 'cancelled', cancel_reason: reason.trim() || null })
            .eq('shop_id', shopId)
            .eq('id', jobId)
            .eq('status', 'requested')
            .select('id'),
        ),
      );
      return { recorded };
    },
    onSettled: (_data, _error, input) =>
      Promise.all([
        invalidate(),
        ...(input.releasePayments
          ? (['invoices', 'payments'] as const).map((domain) =>
              queryClient.invalidateQueries({ queryKey: shopKey(shopId, domain) }),
            )
          : []),
      ]),
  });
}

// ---------------------------------------------------------------- my time clock

/** The caller's open time entries (at most one shift + one job entry). */
export function useMyOpenEntries(shopId: string, memberId: string) {
  return useQuery({
    queryKey: dashboardKeys.clock(shopId, memberId),
    queryFn: async () =>
      unwrap(
        await supabase
          .from('time_entries')
          .select('id, kind, job_id, clock_in')
          .eq('shop_id', shopId)
          .eq('member_id', memberId)
          .is('clock_out', null)
          .order('clock_in', { ascending: false }),
      ) ?? [],
  });
}

/** Seconds worked by the caller between two shop-local dates (report_team, own row). */
export function useMyHours(shopId: string, memberId: string, from?: LocalDate, to?: LocalDate) {
  return useQuery({
    queryKey: dashboardKeys.hours(shopId, memberId, from ?? '', to ?? ''),
    enabled: from !== undefined && to !== undefined,
    queryFn: async () => {
      const rows =
        unwrap(
          await supabase.rpc('report_team', {
            p_shop_id: shopId,
            p_from: from ?? '',
            p_to: to ?? '',
          }),
        ) ?? [];
      const own = rows.find((r) => r.member_id === memberId);
      return own ? own.worked_seconds : 0;
    },
  });
}

function useInvalidateClock(shopId: string) {
  const queryClient = useQueryClient();
  return () =>
    Promise.all([
      queryClient.invalidateQueries({ queryKey: dashboardKeys.all(shopId) }),
      queryClient.invalidateQueries({ queryKey: shopKey(shopId, 'time_entries') }),
    ]);
}

export function useClockIn(shopId: string) {
  const invalidate = useInvalidateClock(shopId);
  return useMutation({
    mutationFn: async () => {
      unwrap(await supabase.rpc('clock_in', { p_shop_id: shopId, p_source: 'web' }));
    },
    onSettled: invalidate,
  });
}

export function useClockOut(shopId: string) {
  const invalidate = useInvalidateClock(shopId);
  return useMutation({
    mutationFn: async () => {
      unwrap(await supabase.rpc('clock_out', { p_shop_id: shopId }));
    },
    onSettled: invalidate,
  });
}
