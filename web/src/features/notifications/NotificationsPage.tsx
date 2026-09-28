import {
  BellOff,
  CalendarClock,
  CalendarPlus,
  CalendarX,
  Check,
  CheckCheck,
  CircleDollarSign,
  ClipboardCheck,
  FileCheck,
  FileX,
  Gift,
  Info,
  ListTodo,
  MessageSquare,
  MessageSquareWarning,
  PackageMinus,
  PenLine,
  UserPlus,
  Users,
  Webhook,
  Wrench,
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
import { useUnreadCount } from '@/components/layout/shellApi';
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
import { PushPrefsCard } from './components/PushPrefsCard';
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
  gift_card_purchased: <Gift aria-hidden="true" />,
  membership_joined: <Users aria-hidden="true" />,
  low_stock: <PackageMinus aria-hidden="true" />,
  inspection_acknowledged: <ClipboardCheck aria-hidden="true" />,
  job_assigned: <Wrench aria-hidden="true" />,
  job_rescheduled: <CalendarClock aria-hidden="true" />,
  new_lead: <UserPlus aria-hidden="true" />,
  task_assigned: <ListTodo aria-hidden="true" />,
  task_due: <ListTodo aria-hidden="true" />,
  sms_number_status: <MessageSquareWarning aria-hidden="true" />,
  webhook_failing: <Webhook aria-hidden="true" />,
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

  const unreadRows = unread.data?.pages.flat() ?? [];
  const loadedUnread = unreadRows.filter((n) => !n.read_at).length;
  // Exact server count (the list is paged, so loaded rows can be fewer).
  const unreadTotal = useUnreadCount(shopId, userId);
  const unreadCount = Math.max(unreadTotal.data ?? 0, loadedUnread);
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
        description="Bookings, payments, quote responses, messages, tasks and signed forms."
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
          ) : unread.isError && unreadRows.length === 0 ? (
            <ErrorState compact error={unread.error} onRetry={() => void unread.refetch()} />
          ) : unreadRows.length === 0 ? (
            <EmptyState
              compact
              icon={<Check aria-hidden="true" />}
              title="You’re all caught up"
              description="New notifications show up here as they happen."
            />
          ) : (
            <>
              <NotificationList
                rows={unreadRows}
                shopId={shopId}
                userId={userId}
                label="Unread notifications"
              />
              <LoadMore
                query={unread}
                label={
                  unreadCount > unreadRows.length
                    ? `Show more unread (${unreadCount - unreadRows.length} more)`
                    : 'Show more unread'
                }
              />
            </>
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
              <LoadMore query={read} label="Load more" />
            </>
          )}
        </SectionCard>

        <PushPrefsCard />
      </div>
    </>
  );
}

interface PagedQuery {
  hasNextPage: boolean;
  isFetchNextPageError: boolean;
  isFetchingNextPage: boolean;
  error: unknown;
  fetchNextPage: () => Promise<unknown>;
}

function LoadMore({ query, label }: { query: PagedQuery; label: string }) {
  if (!query.hasNextPage && !query.isFetchNextPageError) return null;
  return (
    <div className="border-line flex flex-col items-center gap-2 border-t px-4 py-3">
      {query.isFetchNextPageError && (
        <p role="alert" className="text-danger-ink text-sm">
          {toAppError(query.error).message}
        </p>
      )}
      <Button
        variant="secondary"
        size="sm"
        loading={query.isFetchingNextPage}
        onClick={() => void query.fetchNextPage()}
      >
        {label}
      </Button>
    </div>
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
