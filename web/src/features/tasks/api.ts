/**
 * Staff tasks / internal reminders (P-32, 0081 + 0084). RLS narrows rows
 * (managers: all; others: assigned to or created by them); the tasks_guard
 * trigger stamps created_by / done_at / done_by and resets the due reminder.
 * Keys live under the `tasks` domain so the realtime subscription refreshes
 * every list.
 */
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { z } from 'zod';
import { unwrap, unwrapRequired } from '@/lib/db';
import { shopKey } from '@/lib/queryKeys';
import { supabase } from '@/lib/supabase';
import { useShop } from '@/features/shop/shopContext';
import { TASK_COLUMNS, taskRowSchema, type TaskRow, type TaskWrite } from './model';

export const taskKeys = {
  all: (shopId: string) => shopKey(shopId, 'tasks'),
  list: (shopId: string, status: TaskStatus) => [...taskKeys.all(shopId), 'list', status] as const,
  pickers: (shopId: string, kind: string, q: string) =>
    [...taskKeys.all(shopId), 'picker', kind, q] as const,
};

/** Most recent done tasks shown (older ones stay in the database). */
export const DONE_LIMIT = 100;
/** Safety cap for open lists. */
export const OPEN_LIMIT = 500;

export type TaskStatus = 'open' | 'done';

export function useTasks(status: TaskStatus) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: taskKeys.list(shopId, status),
    queryFn: async (): Promise<TaskRow[]> => {
      let query = supabase.from('tasks').select(TASK_COLUMNS).eq('shop_id', shopId);
      query =
        status === 'done'
          ? query
              .not('done_at', 'is', null)
              .order('done_at', { ascending: false })
              .limit(DONE_LIMIT)
          : query.is('done_at', null).order('created_at', { ascending: false }).limit(OPEN_LIMIT);
      return z.array(taskRowSchema).parse(unwrap(await query) ?? []);
    },
  });
}

export function useSaveTask() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async ({ id, values }: { id?: string; values: TaskWrite }) => {
      if (id) {
        return unwrapRequired<{ id: string }>(
          await supabase
            .from('tasks')
            .update(values)
            .eq('shop_id', shopId)
            .eq('id', id)
            .select('id')
            .maybeSingle(),
          'task',
        ).id;
      }
      return unwrapRequired<{ id: string }>(
        await supabase
          .from('tasks')
          .insert({ ...values, shop_id: shopId })
          .select('id')
          .single(),
        'task',
      ).id;
    },
    onSettled: () => queryClient.invalidateQueries({ queryKey: taskKeys.all(shopId) }),
  });
}

/**
 * Tick / untick. Optimistic (a local, reversible, non-money field): the row
 * moves at once and rolls back on error; the server stamps the real done_at.
 */
export function useToggleTaskDone() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async ({ id, done }: { id: string; done: boolean }) => {
      unwrapRequired(
        await supabase
          .from('tasks')
          .update({ done_at: done ? new Date().toISOString() : null })
          .eq('shop_id', shopId)
          .eq('id', id)
          .select('id')
          .maybeSingle(),
        'task',
      );
    },
    onMutate: async ({ id, done }) => {
      await queryClient.cancelQueries({ queryKey: taskKeys.all(shopId) });
      const snapshots = queryClient.getQueriesData<TaskRow[]>({ queryKey: taskKeys.all(shopId) });
      const doneAt = done ? new Date().toISOString() : null;
      for (const [key, rows] of snapshots) {
        if (!Array.isArray(rows)) continue;
        queryClient.setQueryData<TaskRow[]>(
          key,
          rows.map((r) => (r.id === id ? { ...r, done_at: doneAt } : r)),
        );
      }
      return { snapshots };
    },
    onError: (_error, _vars, context) => {
      for (const [key, rows] of context?.snapshots ?? []) queryClient.setQueryData(key, rows);
    },
    onSettled: () => queryClient.invalidateQueries({ queryKey: taskKeys.all(shopId) }),
  });
}

export function useDeleteTask() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (id: string) => {
      unwrapRequired(
        await supabase
          .from('tasks')
          .delete()
          .eq('shop_id', shopId)
          .eq('id', id)
          .select('id')
          .maybeSingle(),
        'task',
      );
    },
    onSettled: () => queryClient.invalidateQueries({ queryKey: taskKeys.all(shopId) }),
  });
}

const memberSchema = z.array(
  z.object({ member_id: z.string(), display_name: z.string(), active: z.boolean() }),
);
export type TaskMember = z.output<typeof memberSchema>[number];

/** Team names for assignees (shop_team: every member may call it). */
export function useTaskMembers() {
  const { shopId } = useShop();
  return useQuery({
    queryKey: [...shopKey(shopId, 'team'), 'task-members'] as const,
    staleTime: 5 * 60_000,
    queryFn: async () =>
      memberSchema.parse(unwrap(await supabase.rpc('shop_team', { p_shop_id: shopId })) ?? []),
  });
}

export interface PickerOption {
  id: string;
  label: string;
}

/** Customer / job lookup for linking a task (search_shop; RLS-narrowed for technicians). */
export function useLinkSearch(kind: 'customer' | 'job', query: string) {
  const { shopId } = useShop();
  const q = query.trim();
  return useQuery({
    queryKey: taskKeys.pickers(shopId, kind, q),
    enabled: q.length >= 1,
    queryFn: async (): Promise<PickerOption[]> =>
      (
        unwrap(await supabase.rpc('search_shop', { p_shop_id: shopId, p_query: q, p_limit: 12 })) ??
        []
      )
        .filter((row) => row.kind === kind && !row.archived)
        .map((row) => ({
          id: row.id,
          label:
            kind === 'job'
              ? [row.number !== null ? `Job #${row.number}` : row.title, row.subtitle]
                  .filter(Boolean)
                  .join(' · ')
              : [row.title, row.subtitle].filter(Boolean).join(' · '),
        })),
  });
}
