/**
 * Data hooks owned by the app shell (notifications bell, global search).
 * Query keys come from shellKeys so feature pages that change the same data
 * (e.g. the Notifications page) invalidate these via shopKey(shopId, …).
 */
import { keepPreviousData, useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { z } from 'zod';
import { toAppError } from '@/lib/errors';
import { shellKeys } from '@/lib/queryKeys';
import { supabase } from '@/lib/supabase';

export const notificationSchema = z.object({
  id: z.string(),
  kind: z.string(),
  title: z.string(),
  body: z.string().nullable(),
  job_id: z.string().nullable(),
  read_at: z.string().nullable(),
  created_at: z.string(),
});
export type NotificationItem = z.infer<typeof notificationSchema>;

const BELL_LIMIT = 15;

export function useBellNotifications(shopId: string, userId: string, enabled: boolean) {
  return useQuery({
    queryKey: shellKeys.notificationList(shopId, userId),
    enabled,
    queryFn: async () => {
      const { data, error } = await supabase
        .from('notifications')
        .select('id, kind, title, body, job_id, read_at, created_at')
        .eq('shop_id', shopId)
        .eq('user_id', userId)
        .order('created_at', { ascending: false })
        .limit(BELL_LIMIT);
      if (error) throw toAppError(error);
      return z.array(notificationSchema).parse(data ?? []);
    },
  });
}

export function useUnreadCount(shopId: string, userId: string) {
  return useQuery({
    queryKey: shellKeys.unreadCount(shopId, userId),
    queryFn: async () => {
      const { count, error } = await supabase
        .from('notifications')
        .select('id', { count: 'exact', head: true })
        .eq('shop_id', shopId)
        .eq('user_id', userId)
        .is('read_at', null);
      if (error) throw toAppError(error);
      return count ?? 0;
    },
  });
}

/** Marks one notification (or all unread when `id` is omitted) as read. */
export function useMarkNotificationsRead(shopId: string, userId: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (id?: string) => {
      let query = supabase
        .from('notifications')
        .update({ read_at: new Date().toISOString() })
        .eq('shop_id', shopId)
        .eq('user_id', userId)
        .is('read_at', null);
      if (id) query = query.eq('id', id);
      const { error } = await query;
      if (error) throw toAppError(error);
    },
    onSettled: () => queryClient.invalidateQueries({ queryKey: shellKeys.notifications(shopId) }),
  });
}

export const SEARCH_KINDS = ['customer', 'vehicle', 'job', 'quote', 'invoice'] as const;
export type SearchKind = (typeof SEARCH_KINDS)[number];

export const searchResultSchema = z.object({
  kind: z.enum(SEARCH_KINDS),
  id: z.string(),
  title: z.string(),
  subtitle: z.string().nullable().optional(),
  /** For vehicles: the owning customer (search results link there). */
  customer_id: z.string().nullable().optional(),
});
export type SearchResult = z.infer<typeof searchResultSchema>;

/** Where a search hit opens. */
export function searchResultHref(result: SearchResult): string | null {
  switch (result.kind) {
    case 'customer':
      return `/app/customers/${result.id}`;
    case 'vehicle':
      return result.customer_id ? `/app/customers/${result.customer_id}` : null;
    case 'job':
      return `/app/jobs/${result.id}`;
    case 'quote':
      return `/app/quotes/${result.id}`;
    case 'invoice':
      return `/app/invoices/${result.id}`;
    default:
      return null;
  }
}

/** search_shop(p_shop_id, p_query) — SPEC §4.9 global search. */
export function useShopSearch(shopId: string, query: string) {
  const q = query.trim();
  return useQuery({
    queryKey: shellKeys.search(shopId, q),
    enabled: q.length >= 2,
    placeholderData: keepPreviousData,
    staleTime: 30_000,
    queryFn: async ({ signal }) => {
      const { data, error } = await supabase
        .rpc('search_shop', { p_shop_id: shopId, p_query: q })
        .abortSignal(signal);
      if (error) throw toAppError(error);
      const rows = Array.isArray(data) ? (data as unknown[]) : [];
      // Skip rows of kinds this client doesn't know yet instead of failing the whole search.
      return rows.flatMap((row) => {
        const parsed = searchResultSchema.safeParse(row);
        return parsed.success ? [parsed.data] : [];
      });
    },
  });
}
