import { CheckCheck, ChevronLeft, ExternalLink, MessagesSquare, UserRoundX } from 'lucide-react';
import { Fragment, useEffect, useRef } from 'react';
import { Link } from 'react-router';
import { Avatar, Button, EmptyState, ErrorState, LoadingState } from '@/components/ui';
import { formatPhone } from '@/lib/phone';
import { useMarkThreadRead, useThread, useThreadCustomer } from '../api';
import { formatDayLabel, shopDay } from '../format';
import { customerName, threadKey, type ThreadRef } from '../model';
import { Composer } from './Composer';
import { MessageBubble } from './MessageBubble';
import { OptOutBadges } from './OptOutBadges';

export interface ThreadViewProps {
  threadRef: ThreadRef;
  timeZone: string;
}

export function ThreadView({ threadRef, timeZone }: ThreadViewProps) {
  const thread = useThread(threadRef);
  const customer = useThreadCustomer(threadRef.kind === 'customer' ? threadRef.customerId : null);
  const markRead = useMarkThreadRead();
  const listRef = useRef<HTMLDivElement>(null);
  const key = threadKey(threadRef);

  const messages = thread.data?.messages;
  const unreadIds = (messages ?? [])
    .filter((m) => m.direction === 'inbound' && !m.read_at)
    .map((m) => m.id);
  const hasUnread = unreadIds.length > 0;
  const newestUnreadId = unreadIds[unreadIds.length - 1] ?? null;

  // Viewing a thread marks its inbound messages read — again when a new
  // reply arrives while it is open (realtime), never twice for the same one.
  const markedFor = useRef<string | null>(null);
  const { mutate: markThreadRead } = markRead;
  useEffect(() => {
    if (!newestUnreadId || markedFor.current === `${key}:${newestUnreadId}`) return;
    markedFor.current = `${key}:${newestUnreadId}`;
    markThreadRead(threadRef);
  }, [newestUnreadId, key, threadRef, markThreadRead]);

  // Keep the newest message in view.
  const lastId = messages?.[messages.length - 1]?.id;
  useEffect(() => {
    const el = listRef.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [lastId]);

  const title =
    threadRef.kind === 'customer'
      ? customer.data
        ? customerName(customer.data)
        : customer.isPending
          ? 'Loading…'
          : 'Customer'
      : formatPhone(threadRef.from) || threadRef.from;

  const latestChannel = messages?.[messages.length - 1]?.channel;

  let body;
  if (thread.isPending || (threadRef.kind === 'customer' && customer.isPending)) {
    body = <LoadingState label="Loading conversation…" />;
  } else if (thread.error || customer.error) {
    body = (
      <ErrorState
        error={thread.error ?? customer.error}
        title="Couldn’t load this conversation"
        onRetry={() => {
          void thread.refetch();
          if (threadRef.kind === 'customer') void customer.refetch();
        }}
        retrying={thread.isRefetching || customer.isRefetching}
      />
    );
  } else if (threadRef.kind === 'customer' && !customer.data) {
    body = (
      <EmptyState
        icon={<UserRoundX aria-hidden="true" />}
        title="Customer not found"
        description="They may have been deleted, or you may not have access."
      />
    );
  } else {
    const days: { day: string; items: NonNullable<typeof messages> }[] = [];
    for (const m of messages ?? []) {
      const day = shopDay(m.created_at, timeZone);
      const last = days[days.length - 1];
      if (last && last.day === day) last.items.push(m);
      else days.push({ day, items: [m] });
    }
    body = (
      <>
        <div ref={listRef} className="min-h-0 flex-1 overflow-y-auto px-3 py-4 sm:px-4">
          {days.length === 0 ? (
            <EmptyState
              icon={<MessagesSquare aria-hidden="true" />}
              title="No messages yet"
              description="Send the first text or email below."
              compact
            />
          ) : (
            <>
              {thread.data?.truncated && (
                <p className="text-muted mb-3 text-center text-xs">
                  Showing the most recent {messages?.length} messages.
                </p>
              )}
              <ol aria-label={`Messages with ${title}`} className="flex flex-col gap-2">
                {days.map((group) => (
                  <Fragment key={group.day}>
                    <li
                      className="text-muted my-2 text-center text-xs font-medium"
                      aria-hidden="true"
                    >
                      {formatDayLabel(group.day, timeZone)}
                    </li>
                    {group.items.map((m) => (
                      <MessageBubble key={m.id} message={m} timeZone={timeZone} />
                    ))}
                  </Fragment>
                ))}
              </ol>
            </>
          )}
        </div>
        {threadRef.kind === 'customer' && customer.data ? (
          <Composer
            key={customer.data.id}
            customer={customer.data}
            timeZone={timeZone}
            {...(latestChannel ? { defaultChannel: latestChannel } : {})}
          />
        ) : (
          <p className="border-line text-muted border-t p-4 text-sm">
            This number doesn’t match a customer yet. Add a customer with this phone number to reply
            — earlier texts from the number are attached to them automatically.
          </p>
        )}
      </>
    );
  }

  return (
    <section aria-label={`Conversation with ${title}`} className="flex min-h-0 flex-1 flex-col">
      <header className="border-line flex flex-wrap items-center gap-3 border-b px-3 py-3 sm:px-4">
        <Link
          to="/app/messages"
          className="text-muted hover:text-ink rounded-control -ml-1 inline-flex items-center p-1 md:hidden"
          aria-label="Back to conversations"
        >
          <ChevronLeft className="size-5" aria-hidden="true" />
        </Link>
        <span className="hidden shrink-0 sm:block" aria-hidden="true">
          <Avatar name={threadRef.kind === 'customer' ? title : null} size="md" />
        </span>
        <div className="min-w-0 flex-1">
          <h2 className="text-ink truncate text-base font-semibold">{title}</h2>
          {customer.data && (
            <p className="text-muted truncate text-xs">
              {[formatPhone(customer.data.phone), customer.data.email]
                .filter(Boolean)
                .join(' · ') || 'No contact details'}
            </p>
          )}
        </div>
        <div className="flex shrink-0 items-center gap-1">
          {hasUnread && (
            <Button
              variant="ghost"
              size="sm"
              leadingIcon={<CheckCheck />}
              loading={markRead.isPending}
              onClick={() => markThreadRead(threadRef)}
            >
              <span className="sr-only sm:not-sr-only">Mark read</span>
            </Button>
          )}
          {customer.data && (
            <Link
              to={`/app/customers/${customer.data.id}`}
              className="text-primary-ink rounded-control inline-flex items-center gap-1 p-1 text-sm font-medium hover:underline"
            >
              <span className="sr-only sm:not-sr-only">Customer profile</span>
              <ExternalLink className="size-4" aria-hidden="true" />
            </Link>
          )}
        </div>
        {customer.data && (
          <div className="basis-full">
            <OptOutBadges customer={customer.data} timeZone={timeZone} />
          </div>
        )}
      </header>
      {body}
    </section>
  );
}
