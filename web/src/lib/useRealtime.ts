import type {
  RealtimePostgresChangesPayload,
  RealtimePostgresChangesFilter,
} from '@supabase/supabase-js';
import { useQueryClient } from '@tanstack/react-query';
import { useEffect, useEffectEvent } from 'react';
import { shopKey, type QueryKey } from './queryKeys';
import { supabase } from './supabase';

/** Tables in the realtime publication (SPEC §4.7; tasks: 0081). */
export type RealtimeTable =
  'jobs' | 'messages' | 'notifications' | 'payments' | 'time_entries' | 'tasks';

export type RealtimeEvent = 'INSERT' | 'UPDATE' | 'DELETE' | '*';

export type RealtimePayload = RealtimePostgresChangesPayload<Record<string, unknown>>;

export interface UseRealtimeOptions {
  table: RealtimeTable;
  /** Shop to scope to; nothing subscribes while null/undefined. */
  shopId: string | null | undefined;
  /**
   * Query keys to invalidate on any change. Defaults to
   * `[shopKey(shopId, table)]` — every query of that domain for the shop.
   */
  invalidate?: readonly QueryKey[];
  event?: RealtimeEvent;
  /**
   * PostgREST-style filter. Defaults to `shop_id=eq.<shopId>`. Supabase allows
   * one filter per subscription; RLS still applies server-side either way, so
   * a narrower filter (e.g. `user_id=eq.<uid>`) is only an optimisation.
   */
  filter?: string;
  /** Called for every change payload (not debounced). */
  onChange?: (payload: RealtimePayload) => void;
  enabled?: boolean;
  /** Coalesces bursts of changes into one invalidation. */
  debounceMs?: number;
}

let channelSeq = 0;

/**
 * Subscribes to `postgres_changes` for a shop-scoped table and invalidates
 * the matching TanStack queries. Unsubscribes on unmount / shop switch.
 *
 *   useRealtime({ table: 'jobs', shopId });
 */
export function useRealtime({
  table,
  shopId,
  invalidate,
  event = '*',
  filter,
  onChange,
  enabled = true,
  debounceMs = 300,
}: UseRealtimeOptions): void {
  const queryClient = useQueryClient();

  const invalidateNow = useEffectEvent(() => {
    if (!shopId) return;
    const keys = invalidate ?? [shopKey(shopId, table)];
    for (const queryKey of keys) void queryClient.invalidateQueries({ queryKey });
  });
  const notify = useEffectEvent((payload: RealtimePayload) => {
    onChange?.(payload);
  });

  const effectiveFilter = filter ?? (shopId ? `shop_id=eq.${shopId}` : undefined);

  useEffect(() => {
    if (!enabled || !shopId || !effectiveFilter) return;

    let timer: ReturnType<typeof setTimeout> | undefined;
    const flush = () => {
      timer = undefined;
      invalidateNow();
    };

    channelSeq += 1;
    const config: RealtimePostgresChangesFilter<'*'> = {
      event: event as '*',
      schema: 'public',
      table,
      filter: effectiveFilter,
    };
    const channel = supabase
      .channel(`rt:${table}:${shopId}:${channelSeq}`)
      .on<Record<string, unknown>>('postgres_changes', config, (payload) => {
        notify(payload);
        if (debounceMs <= 0) {
          flush();
          return;
        }
        if (timer === undefined) timer = setTimeout(flush, debounceMs);
      })
      .subscribe();

    return () => {
      if (timer !== undefined) clearTimeout(timer);
      void supabase.removeChannel(channel);
    };
  }, [enabled, shopId, table, event, effectiveFilter, debounceMs]);
}
