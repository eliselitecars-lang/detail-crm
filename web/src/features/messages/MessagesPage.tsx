import { MessagesSquare, PenSquare } from 'lucide-react';
import { useMemo, useState } from 'react';
import { useNavigate, useSearchParams } from 'react-router';
import { Button, Card, EmptyState, PageHeader } from '@/components/ui';
import { cn } from '@/lib/cn';
import { useRealtime } from '@/lib/useRealtime';
import { useShop } from '@/features/shop/shopContext';
import { INBOX_PAGE, useInbox } from './api';
import { NewConversationDialog } from './components/NewConversationDialog';
import { ThreadList } from './components/ThreadList';
import { ThreadView } from './components/ThreadView';
import { threadKey } from './model';
import { refFromSearch, threadSearch } from './threadUtils';

/**
 * Two-way SMS/email inbox (SPEC §6): threads by customer on the left, the
 * selected conversation on the right (one pane at a time below md).
 * Deep link: /app/messages?customer=<id>. Owner/admin/manager only.
 */
export default function MessagesPage() {
  const { shopId, timezone } = useShop();
  const [params] = useSearchParams();
  const navigate = useNavigate();
  const [limit, setLimit] = useState(INBOX_PAGE);
  const [composing, setComposing] = useState(false);

  const inbox = useInbox(limit);
  useRealtime({ table: 'messages', shopId });

  const search = params.toString();
  const selected = useMemo(() => refFromSearch(new URLSearchParams(search)), [search]);
  const selectedKey = selected ? threadKey(selected) : null;
  const totalUnread = (inbox.data?.threads ?? []).reduce((sum, t) => sum + t.unread, 0);

  return (
    <>
      <PageHeader
        title="Messages"
        description={
          totalUnread > 0
            ? `${totalUnread} unread ${totalUnread === 1 ? 'message' : 'messages'}`
            : 'Two-way text and email conversations with customers.'
        }
        actions={
          <Button leadingIcon={<PenSquare />} onClick={() => setComposing(true)}>
            New message
          </Button>
        }
      />
      <Card className="flex h-[calc(100dvh-12rem)] min-h-[28rem] overflow-hidden">
        <div
          className={cn(
            'border-line min-h-0 w-full flex-col md:flex md:w-80 md:shrink-0 md:border-r lg:w-96',
            selected ? 'hidden' : 'flex',
          )}
        >
          <ThreadList
            threads={inbox.data?.threads}
            isPending={inbox.isPending}
            error={inbox.error}
            onRetry={() => void inbox.refetch()}
            retrying={inbox.isRefetching}
            selectedKey={selectedKey}
            timeZone={timezone}
            truncated={inbox.data?.truncated ?? false}
            loadingMore={inbox.isFetching && inbox.isPlaceholderData}
            onLoadMore={() => setLimit((n) => n + INBOX_PAGE)}
            onNewConversation={() => setComposing(true)}
          />
        </div>
        <div
          className={cn('min-h-0 min-w-0 flex-1 flex-col', selected ? 'flex' : 'hidden md:flex')}
        >
          {selected ? (
            <ThreadView key={selectedKey} threadRef={selected} timeZone={timezone} />
          ) : (
            <EmptyState
              icon={<MessagesSquare aria-hidden="true" />}
              title="Select a conversation"
              description="Pick a thread, or start a new message."
              className="m-auto"
            />
          )}
        </div>
      </Card>
      <NewConversationDialog
        open={composing}
        onClose={() => setComposing(false)}
        onPick={(customer) => {
          setComposing(false);
          void navigate({ search: threadSearch({ kind: 'customer', customerId: customer.id }) });
        }}
      />
    </>
  );
}
