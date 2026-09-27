/**
 * The signed-in user's notifications in the current shop (RLS: recipient
 * only). Keys live under shellKeys.notifications(shopId) so the top-bar bell
 * and this page refresh together.
 */
import {
  useInfiniteQuery,
  useMutation,
  useQuery,
  useQueryClient,
  type InfiniteData,
} from '@tanstack/react-query';
import { unwrap } from '@/lib/db';
import { shellKeys } from '@/lib/queryKeys';
import { supabase } from '@/lib/supabase';
import type { Row } from '@/lib/db';

export type NotificationRow = Pick<
  Row<'notifications'>,
  'id' | 'kind' | 'title' | 'body' | 'job_id' | 'read_at' | 'created_at'
>;

const COLUMNS = 'id, kind, title, body, job_id, read_at, created_at';
export const UNREAD_LIMIT = 100;
export const READ_PAGE_SIZE = 30;

export const notificationKeys = {
  all: (shopId: string) => shellKeys.notifications(shopId),
  unread: (shopId: string, userId: string) =>
    [...shellKeys.notifications(shopId), 'page', userId, 'unread'] as const,
  read: (shopId: string, userId: string) =>
    [...shellKeys.notifications(shopId), 'page', userId, 'read'] as const,
};

export function useUnreadNotifications(shopId: string, userId: string) {
  return useQuery({
    queryKey: notificationKeys.unread(shopId, userId),
    enabled: userId !== '',
    queryFn: async (): Promise<NotificationRow[]> =>
      unwrap(
        await supabase
          .from('notifications')
          .select(COLUMNS)
          .eq('shop_id', shopId)
          .eq('user_id', userId)
          .is('read_at', null)
          .order('created_at', { ascending: false })
          .order('id')
          .limit(UNREAD_LIMIT),
      ) ?? [],
  });
}

export function useReadNotifications(shopId: string, userId: string) {
  return useInfiniteQuery({
    queryKey: notificationKeys.read(shopId, userId),
    enabled: userId !== '',
    initialPageParam: 0,
    queryFn: async ({ pageParam }): Promise<NotificationRow[]> =>
      unwrap(
        await supabase
          .from('notifications')
          .select(COLUMNS)
          .eq('shop_id', shopId)
          .eq('user_id', userId)
          .not('read_at', 'is', null)
          .order('created_at', { ascending: false })
          .order('id')
          .range(pageParam, pageParam + READ_PAGE_SIZE - 1),
      ) ?? [],
    getNextPageParam: (last, pages) =>
      last.length < READ_PAGE_SIZE ? undefined : pages.length * READ_PAGE_SIZE,
  });
}

/**
 * Marks one notification read. Optimistic (allowed: local, reversible,
 * non-money) — the row shows as read at once and rolls back on error.
 */
export function useMarkNotificationRead(shopId: string, userId: string) {
  const queryClient = useQueryClient();
  const key = notificationKeys.unread(shopId, userId);
  return useMutation({
    mutationFn: async (id: string) => {
      unwrap(
        await supabase
          .from('notifications')
          .update({ read_at: new Date().toISOString() })
          .eq('shop_id', shopId)
          .eq('user_id', userId)
          .eq('id', id)
          .is('read_at', null),
      );
    },
    onMutate: async (id) => {
      await queryClient.cancelQueries({ queryKey: key });
      const previous = queryClient.getQueryData<NotificationRow[]>(key);
      queryClient.setQueryData<NotificationRow[]>(key, (rows) =>
        rows?.map((r) => (r.id === id ? { ...r, read_at: new Date().toISOString() } : r)),
      );
      return { previous };
    },
    onError: (_error, _id, context) => {
      if (context?.previous) queryClient.setQueryData(key, context.previous);
    },
    onSettled: () => queryClient.invalidateQueries({ queryKey: notificationKeys.all(shopId) }),
  });
}

export function useMarkAllNotificationsRead(shopId: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async () =>
      unwrap(await supabase.rpc('mark_all_notifications_read', { p_shop_id: shopId })),
    onSettled: () => queryClient.invalidateQueries({ queryKey: notificationKeys.all(shopId) }),
  });
}

/** Dismiss = delete (recipients may delete their own notifications). */
export function useDismissNotification(shopId: string, userId: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (id: string) => {
      unwrap(
        await supabase
          .from('notifications')
          .delete()
          .eq('shop_id', shopId)
          .eq('user_id', userId)
          .eq('id', id),
      );
    },
    onSuccess: (_data, id) => {
      queryClient.setQueryData<NotificationRow[]>(notificationKeys.unread(shopId, userId), (rows) =>
        rows?.filter((r) => r.id !== id),
      );
      queryClient.setQueryData<InfiniteData<NotificationRow[], number>>(
        notificationKeys.read(shopId, userId),
        (data) =>
          data && { ...data, pages: data.pages.map((page) => page.filter((r) => r.id !== id)) },
      );
    },
    onSettled: () => queryClient.invalidateQueries({ queryKey: notificationKeys.all(shopId) }),
  });
}
