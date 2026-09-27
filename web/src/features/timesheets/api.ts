/**
 * Time clock (SPEC §4.6): everyone clocks themselves in/out with the
 * clock_in / clock_out RPCs; managers+ read and edit every entry (manual
 * rows: the server forces source 'manual' and rejects overlaps); RLS gives
 * technicians only their own rows. Keys live under the `time_entries`
 * domain so the realtime subscription refreshes them.
 */
import { keepPreviousData, useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { z } from 'zod';
import { useToast } from '@/components/ui';
import { unwrap, unwrapRequired } from '@/lib/db';
import { shopKey } from '@/lib/queryKeys';
import { supabase } from '@/lib/supabase';
import { useShop } from '@/features/shop/shopContext';
import { SHOP_ROLES } from '@/features/shop/permissions';
import {
  TIME_ENTRY_COLUMNS,
  timeEntrySchema,
  type EntryPatch,
  type EntryWrite,
  type TimeEntryKind,
} from './model';

export interface EntryFilters {
  /** UTC ISO bounds [from, to) */
  from: string;
  to: string;
  memberId: string | null;
}

export const timeKeys = {
  all: (shopId: string) => shopKey(shopId, 'time_entries'),
  list: (shopId: string, f: EntryFilters) => [...timeKeys.all(shopId), 'list', f] as const,
  open: (shopId: string, memberId: string) => [...timeKeys.all(shopId), 'open', memberId] as const,
  members: (shopId: string) => [...shopKey(shopId, 'team'), 'timesheet-members'] as const,
  jobSearch: (shopId: string, q: string) => [...timeKeys.all(shopId), 'job-search', q] as const,
};

/** Entries overlapping [from, to) (open entries count as running until now). */
export function useTimeEntries(filters: EntryFilters, enabled = true) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: timeKeys.list(shopId, filters),
    enabled,
    placeholderData: keepPreviousData,
    queryFn: async () => {
      let query = supabase
        .from('time_entries')
        .select(TIME_ENTRY_COLUMNS)
        .eq('shop_id', shopId)
        .lt('clock_in', filters.to)
        .or(`clock_out.is.null,clock_out.gte.${filters.from}`);
      if (filters.memberId) query = query.eq('member_id', filters.memberId);
      const result = await query.order('clock_in', { ascending: false }).limit(2000);
      const rows = z.array(timeEntrySchema).parse(unwrap(result) ?? []);
      return { entries: rows, truncated: rows.length >= 2000 };
    },
  });
}

/** The signed-in member's running entries (shift and/or job). */
export function useMyOpenEntries() {
  const { shopId, memberId } = useShop();
  return useQuery({
    queryKey: timeKeys.open(shopId, memberId),
    queryFn: async () => {
      const result = await supabase
        .from('time_entries')
        .select(TIME_ENTRY_COLUMNS)
        .eq('shop_id', shopId)
        .eq('member_id', memberId)
        .is('clock_out', null)
        .order('clock_in', { ascending: false });
      return z.array(timeEntrySchema).parse(unwrap(result) ?? []);
    },
  });
}

const memberSchema = z.array(
  z.object({
    member_id: z.string(),
    display_name: z.string(),
    role: z.enum(SHOP_ROLES),
    active: z.boolean(),
    calendar_color: z.string().nullable(),
  }),
);

/** Team directory for names/colours (shop_team; any member may call it). */
export function useTimesheetMembers() {
  const { shopId } = useShop();
  return useQuery({
    queryKey: timeKeys.members(shopId),
    staleTime: 5 * 60_000,
    queryFn: async () =>
      memberSchema.parse(unwrap(await supabase.rpc('shop_team', { p_shop_id: shopId })) ?? []),
  });
}

export function useClock() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  const toast = useToast();
  const invalidate = () => queryClient.invalidateQueries({ queryKey: timeKeys.all(shopId) });
  const clockIn = useMutation({
    mutationFn: async () =>
      unwrapRequired(
        await supabase.rpc('clock_in', { p_shop_id: shopId, p_source: 'web' }),
        'time entry',
      ),
    onSuccess: () => toast.success('Clocked in'),
    onSettled: invalidate,
  });
  const clockOut = useMutation({
    mutationFn: async (kind: TimeEntryKind) =>
      unwrapRequired(
        await supabase.rpc('clock_out', { p_shop_id: shopId, p_kind: kind }),
        'time entry',
      ),
    onSuccess: (_entry, kind) =>
      toast.success(kind === 'shift' ? 'Clocked out' : 'Job clock stopped'),
    onSettled: invalidate,
  });
  return { clockIn, clockOut };
}

/** A new manual entry, or the changed columns of an existing one. */
export type SaveEntryInput = { values: EntryWrite } | { id: string; patch: EntryPatch };

export function useSaveEntry() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (input: SaveEntryInput) => {
      if ('id' in input) {
        // Only the changed columns (see entryEditPatch); nothing changed → no write.
        if (Object.keys(input.patch).length === 0) return input.id;
        const result = await supabase
          .from('time_entries')
          .update(input.patch)
          .eq('shop_id', shopId)
          .eq('id', input.id)
          .select('id')
          .maybeSingle();
        return unwrapRequired(result, 'time entry').id;
      }
      const { values } = input;
      const result = await supabase
        .from('time_entries')
        .insert({ ...values, shop_id: shopId, source: 'manual' })
        .select('id')
        .single();
      return unwrapRequired(result, 'time entry').id;
    },
    onSettled: () => queryClient.invalidateQueries({ queryKey: timeKeys.all(shopId) }),
  });
}

export function useDeleteEntry() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (id: string) => {
      unwrap(await supabase.from('time_entries').delete().eq('shop_id', shopId).eq('id', id));
    },
    onSettled: () => queryClient.invalidateQueries({ queryKey: timeKeys.all(shopId) }),
  });
}

const jobHitSchema = z.array(
  z.object({
    kind: z.string(),
    id: z.string(),
    title: z.string().nullable(),
    subtitle: z.string().nullable(),
    number: z.number().nullable(),
  }),
);
export interface JobHit {
  id: string;
  label: string;
}

/** Job lookup for manual job entries (search_shop; number or customer). */
export function useJobSearch(query: string) {
  const { shopId } = useShop();
  const q = query.trim();
  return useQuery({
    queryKey: timeKeys.jobSearch(shopId, q),
    enabled: q.length >= 1,
    placeholderData: keepPreviousData,
    queryFn: async (): Promise<JobHit[]> =>
      jobHitSchema
        .parse(
          unwrap(
            await supabase.rpc('search_shop', { p_shop_id: shopId, p_query: q, p_limit: 10 }),
          ) ?? [],
        )
        .filter((row) => row.kind === 'job')
        .map((row) => ({
          id: row.id,
          label: [row.number !== null ? `Job #${row.number}` : row.title, row.subtitle]
            .filter(Boolean)
            .join(' · '),
        })),
  });
}
