/**
 * Calendar data: the calendar_events RPC (technicians get other jobs as
 * anonymized busy blocks — server-side) and the shop's business hours.
 * Keys live under the `jobs` domain so job realtime/mutations refresh them.
 */
import { keepPreviousData, useQuery } from '@tanstack/react-query';
import { z } from 'zod';
import { unwrap } from '@/lib/db';
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
  events: (shopId: string, range: CalendarRange, includeCancelled: boolean) =>
    shopKey(shopId, 'jobs', 'calendar', range.from, range.to, includeCancelled),
  hours: (shopId: string) => shopKey(shopId, 'settings', 'business_hours'),
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
  assigned_member_ids: z.array(z.string()).nullable().transform((v) => v ?? []),
  member_id: z.string().nullable(),
  title: z.string().nullable(),
});

export function useCalendarEvents(range: CalendarRange | null, includeCancelled: boolean) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: calendarKeys.events(
      shopId,
      range ?? { from: '', to: '' },
      includeCancelled,
    ),
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
