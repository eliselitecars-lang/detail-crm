import { Bell, CheckCheck } from 'lucide-react';
import { useId, useRef, useState } from 'react';
import { Link, useNavigate } from 'react-router';
import { Button, ErrorState, IconButton, LoadingState } from '@/components/ui';
import { useEscapeKey, useOutsideClick } from '@/components/ui/overlay';
import { useAuth } from '@/features/auth/authContext';
import { notificationLink, type NotificationKind } from '@/features/notifications/links';
import { useShop } from '@/features/shop/shopContext';
import { cn } from '@/lib/cn';
import { formatRelative } from '@/lib/dates';
import { shellKeys } from '@/lib/queryKeys';
import { useRealtime } from '@/lib/useRealtime';
import {
  useBellNotifications,
  useMarkNotificationsRead,
  useUnreadCount,
  type NotificationItem,
} from './shellApi';

/** Top-bar bell: unread count, latest notifications, realtime updates. */
export function NotificationsBell() {
  const { user } = useAuth();
  const { shopId } = useShop();
  const userId = user?.id ?? '';
  const navigate = useNavigate();
  const [open, setOpen] = useState(false);
  const panelId = useId();
  const wrapperRef = useRef<HTMLDivElement>(null);
  const buttonRef = useRef<HTMLButtonElement>(null);

  const unread = useUnreadCount(shopId, userId);
  const list = useBellNotifications(shopId, userId, open);
  const markRead = useMarkNotificationsRead(shopId, userId);

  useRealtime({
    table: 'notifications',
    shopId,
    filter: `user_id=eq.${userId}`,
    invalidate: [shellKeys.notifications(shopId)],
    enabled: userId !== '',
  });
  useOutsideClick([wrapperRef], () => setOpen(false), open);

  const count = unread.data ?? 0;
  const close = () => {
    setOpen(false);
    buttonRef.current?.focus();
  };
  useEscapeKey(open, close);

  const openItem = (item: NotificationItem) => {
    if (!item.read_at) markRead.mutate(item.id);
    setOpen(false);
    const link = notificationLink({ ...item, kind: item.kind as NotificationKind });
    if (link) void navigate(link.href);
  };

  return (
    <div ref={wrapperRef} className="relative">
      <IconButton
        ref={buttonRef}
        label={count > 0 ? `Notifications, ${count} unread` : 'Notifications'}
        icon={<Bell />}
        aria-expanded={open}
        aria-controls={panelId}
        onClick={() => setOpen((v) => !v)}
      />
      {count > 0 && (
        <span
          aria-hidden="true"
          className="tabular bg-danger pointer-events-none absolute -top-0.5 -right-0.5 flex h-4 min-w-4 items-center justify-center rounded-full px-1 text-[10px] font-semibold text-white"
        >
          {count > 99 ? '99+' : count}
        </span>
      )}
      {open && (
        <div
          id={panelId}
          role="dialog"
          aria-label="Notifications"
          className="rounded-card border-line bg-surface shadow-pop fixed inset-x-2 top-14 z-40 overflow-hidden border sm:absolute sm:inset-x-auto sm:top-full sm:right-0 sm:mt-1.5 sm:w-96"
        >
          <div className="border-line flex items-center justify-between border-b px-4 py-2.5">
            <h2 className="text-ink text-sm font-semibold">Notifications</h2>
            <Button
              variant="ghost"
              size="sm"
              leadingIcon={<CheckCheck className="size-4" aria-hidden="true" />}
              disabled={count === 0}
              loading={markRead.isPending && markRead.variables === undefined}
              onClick={() => markRead.mutate(undefined)}
            >
              Mark all read
            </Button>
          </div>
          <div className="max-h-[60vh] overflow-y-auto">
            {list.isPending ? (
              <LoadingState variant="rows" rows={3} label="Loading notifications…" />
            ) : list.isError ? (
              <ErrorState compact error={list.error} onRetry={() => void list.refetch()} />
            ) : list.data.length === 0 ? (
              <p className="text-muted px-4 py-8 text-center text-sm">You’re all caught up.</p>
            ) : (
              <ul className="divide-line divide-y">
                {list.data.map((item) => (
                  <li key={item.id}>
                    <button
                      type="button"
                      onClick={() => openItem(item)}
                      className="hover:bg-surface-2 focus-visible:bg-surface-2 flex w-full gap-3 px-4 py-3 text-left"
                    >
                      <span
                        aria-hidden="true"
                        className={cn(
                          'mt-1.5 size-2 shrink-0 rounded-full',
                          item.read_at ? 'bg-transparent' : 'bg-primary',
                        )}
                      />
                      <span className="min-w-0 flex-1">
                        <span
                          className={cn('text-ink block text-sm', !item.read_at && 'font-semibold')}
                        >
                          {item.title}
                          {!item.read_at && <span className="sr-only"> (unread)</span>}
                        </span>
                        {item.body && (
                          <span className="text-muted mt-0.5 block text-sm">{item.body}</span>
                        )}
                        <span className="text-subtle mt-1 block text-xs">
                          {formatRelative(item.created_at)}
                        </span>
                      </span>
                    </button>
                  </li>
                ))}
              </ul>
            )}
          </div>
          <div className="border-line border-t px-4 py-2.5 text-center">
            <Link
              to="/app/notifications"
              onClick={() => setOpen(false)}
              className="text-primary-ink text-sm font-medium hover:underline"
            >
              View all notifications
            </Link>
          </div>
        </div>
      )}
    </div>
  );
}
