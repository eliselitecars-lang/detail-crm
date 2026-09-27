import { Inbox, Mail, MessageSquare } from 'lucide-react';
import { useState } from 'react';
import { Link } from 'react-router';
import { Avatar, Button, EmptyState, ErrorState, LoadingState, Tabs } from '@/components/ui';
import { cn } from '@/lib/cn';
import { formatListTime } from '../format';
import { messagePreview, type ThreadSummary } from '../model';
import { threadSearch, threadTitle } from '../threadUtils';

export interface ThreadListProps {
  threads: readonly ThreadSummary[] | undefined;
  isPending: boolean;
  error: unknown;
  onRetry: () => void;
  retrying: boolean;
  selectedKey: string | null;
  timeZone: string;
  truncated: boolean;
  onLoadMore: () => void;
  loadingMore: boolean;
  onNewConversation: () => void;
}

export function ThreadList({
  threads,
  isPending,
  error,
  onRetry,
  retrying,
  selectedKey,
  timeZone,
  truncated,
  onLoadMore,
  loadingMore,
  onNewConversation,
}: ThreadListProps) {
  const [filter, setFilter] = useState<'all' | 'unread'>('all');
  if (isPending) return <LoadingState label="Loading conversations…" variant="rows" rows={6} />;
  if (error && !threads)
    return (
      <ErrorState
        error={error}
        title="Couldn’t load conversations"
        onRetry={onRetry}
        retrying={retrying}
        compact
      />
    );
  if (!threads || threads.length === 0)
    return (
      <EmptyState
        icon={<Inbox aria-hidden="true" />}
        title="No conversations yet"
        description="Texts and emails with customers appear here, including replies."
        action={<Button onClick={onNewConversation}>Start a conversation</Button>}
        compact
      />
    );

  const unreadThreads = threads.filter((t) => t.unread > 0);
  const shown = filter === 'unread' ? unreadThreads : threads;

  return (
    <nav aria-label="Conversations" className="flex min-h-0 flex-1 flex-col">
      <Tabs
        label="Show conversations"
        value={filter}
        onChange={setFilter}
        className="px-3 pt-2"
        items={[
          { value: 'all', label: 'All' },
          { value: 'unread', label: 'Unread', count: unreadThreads.length },
        ]}
      />
      {shown.length === 0 && (
        <EmptyState
          icon={<Inbox aria-hidden="true" />}
          title="No unread conversations"
          description="Replies you haven’t opened yet show up here."
          compact
        />
      )}
      <ul className="divide-line min-h-0 flex-1 divide-y overflow-y-auto">
        {shown.map((thread) => {
          const selected = thread.key === selectedKey;
          const title = threadTitle(thread);
          const outbound = thread.last.direction === 'outbound';
          const ChannelIcon = thread.last.channel === 'sms' ? MessageSquare : Mail;
          return (
            <li key={thread.key}>
              <Link
                to={threadSearch(thread.ref)}
                aria-current={selected ? 'true' : undefined}
                className={cn(
                  'hover:bg-surface-2 focus-visible:ring-primary flex gap-3 px-3 py-3 outline-none focus-visible:ring-2 focus-visible:ring-inset',
                  selected && 'bg-primary-soft hover:bg-primary-soft',
                )}
              >
                <span className="shrink-0" aria-hidden="true">
                  <Avatar name={thread.ref.kind === 'customer' ? title : null} size="md" />
                </span>
                <span className="min-w-0 flex-1">
                  <span className="flex items-baseline justify-between gap-2">
                    <span
                      className={cn(
                        'text-ink truncate text-sm',
                        thread.unread > 0 ? 'font-semibold' : 'font-medium',
                      )}
                    >
                      {title}
                    </span>
                    <time
                      dateTime={thread.last.created_at}
                      className="text-muted shrink-0 text-xs tabular-nums"
                    >
                      {formatListTime(thread.last.created_at, timeZone)}
                    </time>
                  </span>
                  <span className="mt-0.5 flex items-center gap-1.5">
                    <ChannelIcon
                      className="text-muted size-3.5 shrink-0"
                      aria-label={thread.last.channel === 'sms' ? 'Text' : 'Email'}
                    />
                    <span
                      className={cn(
                        'truncate text-sm',
                        thread.unread > 0 ? 'text-ink' : 'text-muted',
                      )}
                    >
                      {outbound && <span className="text-muted">You: </span>}
                      {messagePreview(thread.last)}
                    </span>
                    {thread.unread > 0 && (
                      <span className="bg-primary text-primary-fg ml-auto inline-flex min-w-5 shrink-0 items-center justify-center rounded-full px-1.5 text-xs font-semibold">
                        {thread.unread}
                        <span className="sr-only"> unread</span>
                      </span>
                    )}
                  </span>
                  {thread.ref.kind === 'unknown' && (
                    <span className="text-muted mt-0.5 block text-xs">
                      Not matched to a customer
                    </span>
                  )}
                </span>
              </Link>
            </li>
          );
        })}
      </ul>
      {truncated && filter === 'all' && (
        <div className="border-line border-t p-2">
          <Button variant="ghost" size="sm" fullWidth loading={loadingMore} onClick={onLoadMore}>
            Load older conversations
          </Button>
        </div>
      )}
    </nav>
  );
}
