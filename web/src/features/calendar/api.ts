/**
 * Calendar data: the calendar_events RPC (technicians get other jobs as
 * anonymized busy blocks — server-side) and the shop's business hours.
 * Keys live under the `jobs` domain so job realtime/mutations refresh them.
 */
import { keepPreviousData, useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { z } from 'zod';
import type { Json } from '@/lib/database.types';
import { unwrap, type Row } from '@/lib/db';
import { AppError } from '@/lib/errors';
import { shopKey } from '@/lib/queryKeys';
import { supabase } from '@/lib/supabase';
import { useShop } from '@/features/shop/shopContext';
import { JOB_STATUSES } from '@/features/jobs/model';
import type { BusinessHoursRow, CalendarRow } from './model';

export interface CalendarRange {
  from: string;
  to: string;
}

export const calendarKeys = {
  all: (shopId: string) => shopKey(shopId, 'jobs', 'calendar'),
  events: (shopId: string, range: CalendarRange, includeCancelled: boolean) =>
    shopKey(shopId, 'jobs', 'calendar', range.from, range.to, includeCancelled),
  hours: (shopId: string) => shopKey(shopId, 'settings', 'business_hours'),
  block: (shopId: string, id: string) => shopKey(shopId, 'jobs', 'calendar', 'block', id),
  routes: (shopId: string, ids: readonly string[]) =>
    shopKey(shopId, 'jobs', 'calendar', 'route', ...ids),
  shopPlace: (shopId: string) => shopKey(shopId, 'settings', 'shop-place'),
};

const rowSchema = z.object({
  event_type: z.string(),
  id: z.string(),
  job_number: z.number().nullable(),
  status: z.enum(JOB_STATUSES).nullable(),
  starts_at: z.string(),
  ends_at: z.string(),
  is_busy_block: z.boolean(),
  customer_id: z.string().nullable(),
  customer_name: z.string().nullable(),
  vehicle_id: z.string().nullable(),
  vehicle_label: z.string().nullable(),
  location_type: z.enum(['shop', 'mobile']).nullable(),
  service_address: z.string().nullable(),
  resource_id: z.string().nullable(),
  assigned_member_ids: z
    .array(z.string())
    .nullable()
    .transform((v) => v ?? []),
  member_id: z.string().nullable(),
  title: z.string().nullable(),
  // calendar_events v2 (0052); defaults keep v1-shaped fixtures readable
  event_kind: z.string().default('job'),
  series_id: z.string().nullable().default(null),
  color: z.string().nullable().default(null),
  service_lat: z.number().nullable().default(null),
  service_lng: z.number().nullable().default(null),
});

export function useCalendarEvents(range: CalendarRange | null, includeCancelled: boolean) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: calendarKeys.events(shopId, range ?? { from: '', to: '' }, includeCancelled),
    enabled: range !== null,
    placeholderData: keepPreviousData,
    queryFn: async (): Promise<CalendarRow[]> => {
      if (!range) return [];
      const data = unwrap(
        await supabase.rpc('calendar_events', {
          p_shop_id: shopId,
          p_from: range.from,
          p_to: range.to,
          p_include_cancelled: includeCancelled,
        }),
      );
      return z.array(rowSchema).parse(data ?? []);
    },
  });
}

export function useBusinessHours() {
  const { shopId } = useShop();
  return useQuery({
    queryKey: calendarKeys.hours(shopId),
    staleTime: 5 * 60_000,
    queryFn: async (): Promise<BusinessHoursRow[]> =>
      unwrap(
        await supabase
          .from('business_hours')
          .select('weekday, opens_at, closes_at')
          .eq('shop_id', shopId)
          .order('weekday')
          .order('opens_at'),
      ) ?? [],
  });
}

// ---------------------------------------------------------------------------
// Calendar events (P-17): blocked_times rows of every kind. Managers+ write
// them (RLS); customer-linked rows are readable by managers only.
// ---------------------------------------------------------------------------

export type CalendarEventRow = Pick<
  Row<'blocked_times'>,
  | 'id'
  | 'member_id'
  | 'starts_at'
  | 'ends_at'
  | 'reason'
  | 'kind'
  | 'title'
  | 'customer_id'
  | 'affects_capacity'
  | 'color'
  | 'recurrence'
>;

export function useCalendarEvent(blockId: string | null) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: calendarKeys.block(shopId, blockId ?? ''),
    enabled: blockId !== null,
    queryFn: async (): Promise<CalendarEventRow> => {
      const row = unwrap(
        await supabase
          .from('blocked_times')
          .select(
            'id, member_id, starts_at, ends_at, reason, kind, title, customer_id, affects_capacity, color, recurrence',
          )
          .eq('shop_id', shopId)
          .eq('id', blockId ?? '')
          .maybeSingle(),
      );
      if (!row) throw new AppError('This event no longer exists.', { kind: 'not_found' });
      return row;
    },
  });
}

export interface CalendarEventValues {
  kind: CalendarEventRow['kind'];
  member_id: string | null;
  customer_id: string | null;
  title: string | null;
  reason: string | null;
  starts_at: string;
  ends_at: string;
  affects_capacity: boolean;
  color: string | null;
  recurrence: Json | null;
}

function useInvalidateCalendar() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return () =>
    Promise.all([
      queryClient.invalidateQueries({ queryKey: calendarKeys.all(shopId) }),
      // the settings list of blocked times
      queryClient.invalidateQueries({ queryKey: shopKey(shopId, 'settings') }),
    ]);
}

async function insertEvent(shopId: string, values: CalendarEventValues): Promise<string> {
  const row = unwrap(
    await supabase
      .from('blocked_times')
      .insert({ ...values, shop_id: shopId })
      .select('id')
      .single(),
  );
  if (!row) throw new AppError('The event was not saved.', { kind: 'server' });
  return row.id;
}

async function updateEvent(shopId: string, id: string, values: Partial<CalendarEventValues>) {
  const rows = unwrap(
    await supabase
      .from('blocked_times')
      .update(values)
      .eq('shop_id', shopId)
      .eq('id', id)
      .select('id'),
  );
  if (!rows || rows.length === 0) {
    throw new AppError('This event could not be changed. It may have been removed.', {
      kind: 'not_found',
    });
  }
}

async function deleteEvent(shopId: string, id: string) {
  unwrap(await supabase.from('blocked_times').delete().eq('shop_id', shopId).eq('id', id));
}

export function useCreateCalendarEvent() {
  const { shopId } = useShop();
  const invalidate = useInvalidateCalendar();
  return useMutation({
    mutationFn: (values: CalendarEventValues) => insertEvent(shopId, values),
    onSettled: invalidate,
  });
}

export function useUpdateCalendarEvent() {
  const { shopId } = useShop();
  const invalidate = useInvalidateCalendar();
  return useMutation({
    mutationFn: ({ id, values }: { id: string; values: Partial<CalendarEventValues> }) =>
      updateEvent(shopId, id, values),
    onSettled: invalidate,
  });
}

/**
 * Splits a repeating event: a new event with `values` is written, then the
 * original's rule becomes `endRecurrence` — "this and following" (the
 * original stops the day before the occurrence, the new series takes over)
 * or "only this one" (the original skips the occurrence's date, 0115, and
 * the new row is that day's one-off). The new row is written first, so a
 * failure never loses visits.
 */
export function useSplitCalendarEvent() {
  const { shopId } = useShop();
  const invalidate = useInvalidateCalendar();
  return useMutation({
    mutationFn: async ({
      id,
      endRecurrence,
      values,
    }: {
      id: string;
      /** The original's rule, ended the day before the edited occurrence. */
      endRecurrence: Json;
      values: CalendarEventValues;
    }) => {
      const created = await insertEvent(shopId, values);
      try {
        await updateEvent(shopId, id, { recurrence: endRecurrence });
      } catch (error) {
        await deleteEvent(shopId, created).catch(() => undefined);
        throw error;
      }
    },
    onSettled: invalidate,
  });
}

export function useDeleteCalendarEvent() {
  const { shopId } = useShop();
  const invalidate = useInvalidateCalendar();
  return useMutation({
    mutationFn: async ({
      id,
      endRecurrence,
    }: {
      id: string;
      /**
       * Set: the series' new rule — ended before the occurrence (keep the
       * earlier ones) or with the occurrence skipped (0115); unset: delete
       * the event.
       */
      endRecurrence?: Json;
    }) => {
      if (endRecurrence !== undefined) await updateEvent(shopId, id, { recurrence: endRecurrence });
      else await deleteEvent(shopId, id);
    },
    onSettled: invalidate,
  });
}

// ---------------------------------------------------------------------------
// Day map (P-18): route order + the shop's own location
// ---------------------------------------------------------------------------

/** jobs.route_position of the day's jobs (calendar_events does not return it). */
export function useRoutePositions(jobIds: readonly string[]) {
  const { shopId } = useShop();
  const ids = [...jobIds].sort();
  return useQuery({
    queryKey: calendarKeys.routes(shopId, ids),
    enabled: ids.length > 0,
    queryFn: async (): Promise<Map<string, number | null>> => {
      const rows =
        unwrap(
          await supabase
            .from('jobs')
            .select('id, route_position')
            .eq('shop_id', shopId)
            .in('id', ids),
        ) ?? [];
      return new Map(rows.map((r) => [r.id, r.route_position]));
    },
  });
}

/** set_route_order: the listed jobs become stops 0, 1, 2… of their day. */
export function useSetRouteOrder() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (jobIds: string[]) => {
      unwrap(await supabase.rpc('set_route_order', { p_shop_id: shopId, p_job_ids: jobIds }));
    },
    onSettled: () => queryClient.invalidateQueries({ queryKey: calendarKeys.all(shopId) }),
  });
}

export type ShopPlace = Pick<
  Row<'shops'>,
  'lat' | 'lng' | 'address_line1' | 'city' | 'region' | 'postal_code'
>;

/** Where routes start: the shop's coordinates or address (members read their shop). */
export function useShopPlace(enabled: boolean) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: calendarKeys.shopPlace(shopId),
    enabled,
    staleTime: 10 * 60_000,
    queryFn: async (): Promise<ShopPlace | null> =>
      unwrap(
        await supabase
          .from('shops')
          .select('lat, lng, address_line1, city, region, postal_code')
          .eq('id', shopId)
          .maybeSingle(),
      ),
  });
}
