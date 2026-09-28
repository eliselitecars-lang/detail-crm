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
import { z } from 'zod';
import { useToast } from '@/components/ui';
import { unwrap, unwrapRequired } from '@/lib/db';
import { AppError, toAppError } from '@/lib/errors';
import { meKey, shellKeys, shopKey } from '@/lib/queryKeys';
import { supabase } from '@/lib/supabase';
import type { Row } from '@/lib/db';
import { toEdgeError } from '@/features/quotes/shared/edge';
import type { NotificationKind } from './links';

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

// ---------------------------------------------------------------------------
// Push notifications (iPhone app): per-member preferences (0081/0082)
// ---------------------------------------------------------------------------

export type PushPrefs = Pick<Row<'member_notification_prefs'>, 'push_kinds' | 'muted_until'>;

export const pushPrefsKeys = {
  prefs: (shopId: string, memberId: string) => shopKey(shopId, 'notification-prefs', memberId),
  devices: (userId: string) => meKey(userId, 'push-devices'),
};

/** The member's own row; null = never saved (every kind is pushed, no mute). */
export function usePushPrefs(shopId: string, memberId: string) {
  return useQuery({
    queryKey: pushPrefsKeys.prefs(shopId, memberId),
    queryFn: async (): Promise<PushPrefs | null> =>
      unwrap(
        await supabase
          .from('member_notification_prefs')
          .select('push_kinds, muted_until')
          .eq('shop_id', shopId)
          .eq('member_id', memberId)
          .maybeSingle(),
      ),
  });
}

/** How many iPhones the user has turned notifications on for (own rows only). */
export function usePushDeviceCount(userId: string) {
  return useQuery({
    queryKey: pushPrefsKeys.devices(userId),
    enabled: userId !== '',
    queryFn: async (): Promise<number> => {
      const result = await supabase
        .from('device_push_tokens')
        .select('id', { count: 'exact', head: true })
        .eq('user_id', userId)
        .is('disabled_at', null);
      if (result.error) throw toAppError(result.error);
      return result.count ?? 0;
    },
  });
}

export interface SavePushPrefsInput {
  pushKinds: NotificationKind[];
  /** ISO instant, or null for no mute. */
  mutedUntil: string | null;
}

export function useSavePushPrefs(shopId: string, memberId: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async ({ pushKinds, mutedUntil }: SavePushPrefsInput): Promise<PushPrefs> => {
      const row = unwrapRequired(
        await supabase.rpc('set_notification_prefs', {
          p_shop_id: shopId,
          p_push_kinds: pushKinds,
          ...(mutedUntil ? { p_muted_until: mutedUntil } : {}),
        }),
        'push setting',
      );
      return { push_kinds: row.push_kinds, muted_until: row.muted_until };
    },
    onSuccess: (prefs) => {
      queryClient.setQueryData(pushPrefsKeys.prefs(shopId, memberId), prefs);
    },
    onSettled: () =>
      queryClient.invalidateQueries({ queryKey: pushPrefsKeys.prefs(shopId, memberId) }),
  });
}

const sendTestSchema = z.object({
  sent: z.number().int(),
  failed: z.number().int(),
  invalid_tokens: z.number().int(),
});

/** push → send_test: a test notification to the caller's own iPhones only. */
export function useSendTestPush(shopId: string, userId: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async () => {
      let response: Awaited<ReturnType<typeof supabase.functions.invoke<unknown>>>;
      try {
        response = await supabase.functions.invoke<unknown>('push', {
          body: { action: 'send_test', shop_id: shopId },
        });
      } catch (error) {
        throw await toEdgeError(error);
      }
      if (response.error) throw await toEdgeError(response.error);
      const parsed = sendTestSchema.safeParse(response.data);
      if (!parsed.success) {
        throw new AppError('The server sent an unexpected response. Please try again.', {
          kind: 'server',
          cause: parsed.error,
        });
      }
      return parsed.data;
    },
    onSettled: () => queryClient.invalidateQueries({ queryKey: pushPrefsKeys.devices(userId) }),
  });
}
