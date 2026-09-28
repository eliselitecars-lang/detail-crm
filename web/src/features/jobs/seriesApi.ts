/**
 * Recurring jobs (P-1, 0051): the series row (managers+), the occurrence
 * preview and the "this and following" edits. Occurrences are ordinary jobs;
 * every write goes through the series RPCs (job_series has no write policy).
 */
import { keepPreviousData, useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useNavigate } from 'react-router';
import { z } from 'zod';
import { unwrap } from '@/lib/db';
import { shopDayRangeUtc, type LocalDate } from '@/lib/dates';
import type { Json } from '@/lib/database.types';
import { shopKey } from '@/lib/queryKeys';
import { supabase } from '@/lib/supabase';
import { useShop } from '@/features/shop/shopContext';
import { jobKeys } from './api';
import type { SeriesRow } from './series';

export const seriesKeys = {
  row: (shopId: string, seriesId: string) => [...jobKeys.all(shopId), 'series', seriesId] as const,
  preview: (shopId: string, payload: unknown) =>
    [...jobKeys.all(shopId), 'series-preview', payload] as const,
};

const SERIES_COLUMNS =
  'id, freq, interval, by_weekday, month_mode, month_day, month_nth, month_weekday, start_date, ' +
  'local_start, duration_minutes, until_date, max_occurrences, active, ended_at';

const seriesRowSchema = z.object({
  id: z.string(),
  freq: z.string(),
  interval: z.number(),
  by_weekday: z.array(z.number()),
  month_mode: z.string().nullable(),
  month_day: z.number().nullable(),
  month_nth: z.number().nullable(),
  month_weekday: z.number().nullable(),
  start_date: z.string(),
  local_start: z.string(),
  duration_minutes: z.number(),
  until_date: z.string().nullable(),
  max_occurrences: z.number().nullable(),
  active: z.boolean(),
  ended_at: z.string().nullable(),
});

/** The series of an occurrence (managers+ only: technicians never read series rows). */
export function useJobSeries(seriesId: string | null, enabled: boolean) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: seriesKeys.row(shopId, seriesId ?? ''),
    enabled: enabled && seriesId !== null,
    queryFn: async (): Promise<SeriesRow | null> => {
      const data = unwrap(
        await supabase
          .from('job_series')
          .select(SERIES_COLUMNS)
          .eq('shop_id', shopId)
          .eq('id', seriesId ?? '')
          .maybeSingle(),
      );
      return data === null ? null : seriesRowSchema.parse(data);
    },
  });
}

export interface PreviewOccurrence {
  seq: number;
  starts_at: string;
  ends_at: string;
}

const previewSchema = z.array(
  z.object({ seq: z.number(), starts_at: z.string(), ends_at: z.string() }),
);

/** First occurrences the rule would create (job_series_preview; no writes). */
export function useSeriesPreview(payload: Record<string, unknown> | null, count = 6) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: seriesKeys.preview(shopId, { payload, count }),
    enabled: payload !== null,
    placeholderData: keepPreviousData,
    staleTime: 60_000,
    queryFn: async (): Promise<PreviewOccurrence[]> =>
      previewSchema.parse(
        unwrap(
          await supabase.rpc('job_series_preview', {
            p_shop_id: shopId,
            p_series: payload as Json,
            p_count: count,
          }),
        ) ?? [],
      ),
  });
}

const createResultSchema = z.object({
  series_id: z.string(),
  jobs_created: z.number(),
  first_job_id: z.string().nullable(),
  generated_through: z.string().nullable(),
});

export type CreateSeriesResult = z.infer<typeof createResultSchema>;

export function useCreateSeries() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (series: Record<string, unknown>): Promise<CreateSeriesResult> =>
      createResultSchema.parse(
        unwrap(
          await supabase.rpc('create_job_series', { p_shop_id: shopId, p_series: series as Json }),
        ),
      ),
    onSettled: () => queryClient.invalidateQueries({ queryKey: jobKeys.all(shopId) }),
  });
}

/**
 * update_job_series: {updated, deleted, created, changed, kept};
 * end_job_series: {deleted, kept}. deleted = eligible visits removed,
 * created = visits generated, changed = visits updated in place (the usual
 * outcome of a time / location / bay edit), kept = visits left as they were.
 */
const editResultSchema = z.object({
  deleted: z.number(),
  kept: z.number(),
  created: z.number().optional(),
  changed: z.number().optional(),
});

export type SeriesEditResult = z.infer<typeof editResultSchema>;

/** Where to go after an edit that may have replaced the open visit. */
export interface SeriesNavigation {
  /** The job still exists (kept, or not touched). */
  stillThere: boolean;
  /** Otherwise: the series' first visit on or after the old date (null = none). */
  successorId: string | null;
}

async function locateAfterEdit(
  shopId: string,
  jobId: string,
  seriesId: string,
  fromDate: LocalDate,
  timeZone: string,
): Promise<SeriesNavigation> {
  const still = unwrap(
    await supabase.from('jobs').select('id').eq('shop_id', shopId).eq('id', jobId).maybeSingle(),
  );
  if (still) return { stillThere: true, successorId: null };
  const next = unwrap(
    await supabase
      .from('jobs')
      .select('id')
      .eq('shop_id', shopId)
      .eq('series_id', seriesId)
      .gte('scheduled_start', shopDayRangeUtc(fromDate, timeZone).from)
      .order('scheduled_start')
      .limit(1),
  );
  return { stillThere: false, successorId: next?.[0]?.id ?? null };
}

/** After a series edit the open visit may have been replaced by a new job: go there. */
export function useFollowSeriesEdit() {
  const navigate = useNavigate();
  return (nav: SeriesNavigation) => {
    if (nav.stillThere) return;
    void navigate(nav.successorId ? `/app/jobs/${nav.successorId}` : '/app/jobs', {
      replace: true,
    });
  };
}

export interface SeriesEditArgs {
  seriesId: string;
  /** The open visit ("this and following" starts here). */
  jobId: string;
  /** Its shop-local date, to find its replacement afterwards. */
  jobDate: LocalDate;
}

/**
 * update_job_series ("this and following" from `jobId`): eligible visits
 * from there on are replaced, others kept. Returns the counts and where the
 * open visit went (it may have been replaced by a new job).
 */
export function useUpdateSeries() {
  const { shopId, timezone } = useShop();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async ({
      seriesId,
      jobId,
      jobDate,
      patch,
    }: SeriesEditArgs & { patch: Record<string, unknown> }): Promise<
      SeriesEditResult & SeriesNavigation
    > => {
      const result = editResultSchema.parse(
        unwrap(
          await supabase.rpc('update_job_series', {
            p_series_id: seriesId,
            p_patch: patch as Json,
            p_from_job_id: jobId,
          }),
        ),
      );
      return {
        ...result,
        ...(await locateAfterEdit(shopId, jobId, seriesId, jobDate, timezone)),
      };
    },
    onSettled: () => queryClient.invalidateQueries({ queryKey: jobKeys.all(shopId) }),
  });
}

/** end_job_series: no visits after `afterDate` (eligible later visits are removed). */
export function useEndSeries() {
  const { shopId, timezone } = useShop();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async ({
      seriesId,
      jobId,
      jobDate,
      afterDate,
    }: SeriesEditArgs & { afterDate: LocalDate }): Promise<SeriesEditResult & SeriesNavigation> => {
      const result = editResultSchema.parse(
        unwrap(
          await supabase.rpc('end_job_series', {
            p_series_id: seriesId,
            p_after_date: afterDate,
          }),
        ),
      );
      return {
        ...result,
        ...(await locateAfterEdit(shopId, jobId, seriesId, jobDate, timezone)),
      };
    },
    onSettled: () =>
      Promise.all([
        queryClient.invalidateQueries({ queryKey: jobKeys.all(shopId) }),
        queryClient.invalidateQueries({ queryKey: shopKey(shopId, 'customers') }),
      ]),
  });
}

function visits(n: number): string {
  return `${n} upcoming visit${n === 1 ? '' : 's'}`;
}

/**
 * "8 upcoming visits updated, 2 removed, 3 added; 1 kept as it was (…)" — for
 * toasts after a series edit. Only the counts that happened are named.
 */
export function describeSeriesEdit(result: SeriesEditResult): string {
  const changed = result.changed ?? 0;
  const created = result.created ?? 0;
  const parts: string[] = [];
  if (changed > 0) parts.push(`${visits(changed)} updated`);
  if (result.deleted > 0) {
    parts.push(
      parts.length === 0 ? `${visits(result.deleted)} removed` : `${result.deleted} removed`,
    );
  }
  if (created > 0) {
    parts.push(parts.length === 0 ? `${visits(created)} added` : `${created} added`);
  }
  const done = parts.length > 0 ? parts.join(', ') : 'No upcoming visits needed a change';
  if (result.kept === 0) return `${done}.`;
  return `${done}; ${result.kept} kept as ${result.kept === 1 ? 'it was' : 'they were'} (already confirmed, paid or worked on).`;
}
