/**
 * The signed-in user's notifications in the current shop (RLS: recipient
 * only). Keys live under shellKeys.notifications(shopId) so the top-bar bell
 * and this page refresh together.
 */
import {
  useInfiniteQuery,
  useMutation,
  useQueryClient,
  type InfiniteData,
} from '@tanstack/react-query';
import { useToast } from '@/components/ui';
import { unwrap } from '@/lib/db';
import { toAppError } from '@/lib/errors';
import { shellKeys } from '@/lib/queryKeys';
import { supabase } from '@/lib/supabase';
import type { Row } from '@/lib/db';

export type NotificationRow = Pick<
  Row<'notifications'>,
  | 'id'
  | 'kind'
  | 'title'
  | 'body'
  | 'job_id'
  | 'customer_id'
  | 'quote_id'
  | 'invoice_id'
  | 'read_at'
  | 'created_at'
>;

type NotificationPages = InfiniteData<NotificationRow[], number>;

const COLUMNS =
  'id, kind, title, body, job_id, customer_id, quote_id, invoice_id, read_at, created_at';
export const UNREAD_PAGE_SIZE = 50;
export const READ_PAGE_SIZE = 30;

export const notificationKeys = {
  all: (shopId: string) => shellKeys.notifications(shopId),
  unread: (shopId: string, userId: string) =>
    [...shellKeys.notifications(shopId), 'page', userId, 'unread'] as const,
  read: (shopId: string, userId: string) =>
    [...shellKeys.notifications(shopId), 'page', userId, 'read'] as const,
};

/**
 * Unread notifications, newest first, paged like the read list so none are
 * hidden behind a cap (the page offers "Load more"). Offsets are recomputed
 * from fresh pages on refetch, so marking rows read never skips any.
 */
export function useUnreadNotifications(shopId: string, userId: string) {
  return useInfiniteQuery({
    queryKey: notificationKeys.unread(shopId, userId),
    enabled: userId !== '',
    initialPageParam: 0,
    queryFn: async ({ pageParam }): Promise<NotificationRow[]> =>
      unwrap(
        await supabase
          .from('notifications')
          .select(COLUMNS)
          .eq('shop_id', shopId)
          .eq('user_id', userId)
          .is('read_at', null)
          .order('created_at', { ascending: false })
          .order('id')
          .range(pageParam, pageParam + UNREAD_PAGE_SIZE - 1),
      ) ?? [],
    getNextPageParam: (last, pages) =>
      last.length < UNREAD_PAGE_SIZE ? undefined : pages.length * UNREAD_PAGE_SIZE,
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
 * non-money) — the row shows as read at once and rolls back on error, with a
 * toast so the failure is announced (the toast region is a live region and
 * outlives the page, e.g. when the deep link navigated away).
 */
export function useMarkNotificationRead(shopId: string, userId: string) {
  const queryClient = useQueryClient();
  const toast = useToast();
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
      const previous = queryClient.getQueryData<NotificationPages>(key);
      const readAt = new Date().toISOString();
      queryClient.setQueryData<NotificationPages>(
        key,
        (data) =>
          data && {
            ...data,
            pages: data.pages.map((page) =>
              page.map((r) => (r.id === id ? { ...r, read_at: readAt } : r)),
            ),
          },
      );
      return { previous };
    },
    onError: (error, _id, context) => {
      if (context?.previous) queryClient.setQueryData(key, context.previous);
      toast.error('Couldn’t mark the notification read', toAppError(error).message);
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
      const drop = (data: NotificationPages | undefined) =>
        data && { ...data, pages: data.pages.map((page) => page.filter((r) => r.id !== id)) };
      queryClient.setQueryData<NotificationPages>(notificationKeys.unread(shopId, userId), drop);
      queryClient.setQueryData<NotificationPages>(notificationKeys.read(shopId, userId), drop);
    },
    onSettled: () => queryClient.invalidateQueries({ queryKey: notificationKeys.all(shopId) }),
  });
}
