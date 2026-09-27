import {
  BellOff,
  CalendarPlus,
  CalendarX,
  Check,
  CheckCheck,
  CircleDollarSign,
  FileCheck,
  FileX,
  Info,
  MessageSquare,
  PenLine,
  X,
} from 'lucide-react';
import type { ReactNode } from 'react';
import { Link } from 'react-router';
import {
  Button,
  EmptyState,
  ErrorState,
  IconButton,
  LoadingState,
  PageHeader,
  SectionCard,
  useToast,
} from '@/components/ui';
import { useAuth } from '@/features/auth/authContext';
import { useShop } from '@/features/shop/shopContext';
import { cn } from '@/lib/cn';
import { formatDateTime, formatRelative } from '@/lib/dates';
import { toAppError } from '@/lib/errors';
import { shellKeys } from '@/lib/queryKeys';
import { useRealtime } from '@/lib/useRealtime';
import {
  useDismissNotification,
  useMarkAllNotificationsRead,
  useMarkNotificationRead,
  useReadNotifications,
  useUnreadNotifications,
  type NotificationRow,
} from './api';
import { KIND_LABELS, notificationLink, type NotificationKind } from './links';

const KIND_ICONS: Record<NotificationKind, ReactNode> = {
  new_booking: <CalendarPlus aria-hidden="true" />,
  booking_cancelled: <CalendarX aria-hidden="true" />,
  quote_approved: <FileCheck aria-hidden="true" />,
  quote_declined: <FileX aria-hidden="true" />,
  payment_received: <CircleDollarSign aria-hidden="true" />,
  inbound_message: <MessageSquare aria-hidden="true" />,
  form_signed: <PenLine aria-hidden="true" />,
  general: <Info aria-hidden="true" />,
};

export default function NotificationsPage() {
  const { shopId } = useShop();
  const { user } = useAuth();
  const userId = user?.id ?? '';
  const toast = useToast();
  const unread = useUnreadNotifications(shopId, userId);
  const read = useReadNotifications(shopId, userId);
  const markAll = useMarkAllNotificationsRead(shopId);

  useRealtime({
    table: 'notifications',
    shopId,
    filter: `user_id=eq.${userId}`,
    invalidate: [shellKeys.notifications(shopId)],
    enabled: userId !== '',
  });

  const unreadCount = unread.data?.filter((n) => !n.read_at).length ?? 0;
  const readRows = read.data?.pages.flat() ?? [];

  const onMarkAll = async () => {
    try {
      const changed = await markAll.mutateAsync();
      toast.success(
        changed === 1 ? '1 notification marked read' : `${changed} notifications marked read`,
      );
    } catch (error) {
      toast.error(toAppError(error).message);
    }
  };

  return (
    <>
      <PageHeader
        title="Notifications"
        description="Bookings, payments, quote responses, messages and signed forms."
        actions={
          <Button
            variant="secondary"
            leadingIcon={<CheckCheck className="size-4" aria-hidden="true" />}
            disabled={unreadCount === 0}
            loading={markAll.isPending}
            onClick={() => void onMarkAll()}
          >
            Mark all read
          </Button>
        }
      />
      <div className="flex flex-col gap-4 sm:gap-5">
        <SectionCard
          title="Unread"
          description={unreadCount > 0 ? `${unreadCount} new` : undefined}
          flush
        >
          {unread.isPending ? (
            <LoadingState variant="rows" rows={3} label="Loading notifications…" />
          ) : unread.isError ? (
            <ErrorState compact error={unread.error} onRetry={() => void unread.refetch()} />
          ) : unread.data.length === 0 ? (
            <EmptyState
              compact
              icon={<Check aria-hidden="true" />}
              title="You’re all caught up"
              description="New notifications show up here as they happen."
            />
          ) : (
            <NotificationList
              rows={unread.data}
              shopId={shopId}
              userId={userId}
              label="Unread notifications"
            />
          )}
        </SectionCard>

        <SectionCard title="Earlier" flush>
          {read.isPending ? (
            <LoadingState variant="rows" rows={3} label="Loading earlier notifications…" />
          ) : read.isError && readRows.length === 0 ? (
            <ErrorState compact error={read.error} onRetry={() => void read.refetch()} />
          ) : readRows.length === 0 ? (
            <EmptyState
              compact
              icon={<BellOff aria-hidden="true" />}
              title="No earlier notifications"
            />
          ) : (
            <>
              <NotificationList
                rows={readRows}
                shopId={shopId}
                userId={userId}
                label="Earlier notifications"
              />
              {(read.hasNextPage || read.isFetchNextPageError) && (
                <div className="border-line flex flex-col items-center gap-2 border-t px-4 py-3">
                  {read.isFetchNextPageError && (
                    <p role="alert" className="text-danger-ink text-sm">
                      {toAppError(read.error).message}
                    </p>
                  )}
                  <Button
                    variant="secondary"
                    size="sm"
                    loading={read.isFetchingNextPage}
                    onClick={() => void read.fetchNextPage()}
                  >
                    Load more
                  </Button>
                </div>
              )}
            </>
          )}
        </SectionCard>
      </div>
    </>
  );
}

function NotificationList({
  rows,
  shopId,
  userId,
  label,
}: {
  rows: NotificationRow[];
  shopId: string;
  userId: string;
  label: string;
}) {
  return (
    <ul className="divide-line divide-y" aria-label={label}>
      {rows.map((n) => (
        <NotificationItem key={n.id} n={n} shopId={shopId} userId={userId} />
      ))}
    </ul>
  );
}

function NotificationItem({
  n,
  shopId,
  userId,
}: {
  n: NotificationRow;
  shopId: string;
  userId: string;
}) {
  const { timezone } = useShop();
  const toast = useToast();
  const markRead = useMarkNotificationRead(shopId, userId);
  const dismiss = useDismissNotification(shopId, userId);
  const link = notificationLink(n);
  const unread = n.read_at === null;

  const onDismiss = async () => {
    try {
      await dismiss.mutateAsync(n.id);
    } catch (error) {
      toast.error(toAppError(error).message);
    }
  };

  return (
    <li className={cn('flex gap-3 px-4 py-3 sm:px-5', unread && 'bg-primary-soft/40')}>
      <span
        className={cn(
          'mt-0.5 flex size-8 shrink-0 items-center justify-center rounded-full [&_svg]:size-4',
          unread ? 'bg-primary-soft text-primary-ink' : 'bg-surface-2 text-muted',
        )}
      >
        {KIND_ICONS[n.kind]}
      </span>
      <div className="min-w-0 flex-1">
        <p className={cn('text-ink text-sm break-words', unread && 'font-semibold')}>
          {n.title}
          {unread && <span className="sr-only"> (unread)</span>}
        </p>
        {n.body && <p className="text-muted mt-0.5 text-sm break-words">{n.body}</p>}
        <p className="text-subtle mt-1 text-xs">
          {KIND_LABELS[n.kind]} ·{' '}
          <time dateTime={n.created_at} title={formatDateTime(n.created_at, timezone)}>
            {formatRelative(n.created_at)}
          </time>
        </p>
        {(link || unread) && (
          <div className="mt-2 flex flex-wrap gap-2">
            {link && (
              <Link
                to={link.href}
                onClick={() => {
                  if (unread) markRead.mutate(n.id);
                }}
                className="text-primary-ink text-sm font-medium hover:underline"
              >
                {link.label}
              </Link>
            )}
            {unread && (
              <button
                type="button"
                onClick={() => markRead.mutate(n.id)}
                disabled={markRead.isPending}
                className="text-muted hover:text-ink text-sm font-medium"
              >
                Mark read
              </button>
            )}
          </div>
        )}
      </div>
      <IconButton
        size="sm"
        label={`Dismiss notification: ${n.title}`}
        icon={<X />}
        loading={dismiss.isPending}
        onClick={() => void onDismiss()}
      />
    </li>
  );
}
