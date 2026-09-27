/**
 * Messages inbox data (SPEC §4.7): threads by customer, thread history,
 * read state, templates and sending. RLS: owner/admin/manager only
 * (technicians have no inbox). Everything lives under the `messages` domain
 * key so the realtime subscription refreshes it all.
 */
import {
  keepPreviousData,
  useInfiniteQuery,
  useMutation,
  useQuery,
  useQueryClient,
  type InfiniteData,
} from '@tanstack/react-query';
import { z } from 'zod';
import { useToast } from '@/components/ui';
import { unwrap } from '@/lib/db';
import { toAppError } from '@/lib/errors';
import { shopKey } from '@/lib/queryKeys';
import { supabase } from '@/lib/supabase';
import { useShop } from '@/features/shop/shopContext';
import { sendMessage, type SendMessageInput } from './edge';
import {
  inboxThreadRowSchema,
  MESSAGE_COLUMNS,
  messageSchema,
  SENDABLE_TEMPLATE_KEYS,
  THREAD_CUSTOMER_COLUMNS,
  threadCustomerSchema,
  threadFromRow,
  threadKey,
  threadsFromPages,
  type InboxThreadRow,
  type MessageChannel,
  type ThreadRef,
} from './model';

/** Conversations per inbox_threads page ("Load older conversations" fetches the next). */
export const INBOX_PAGE_SIZE = 50;
const THREAD_LIMIT = 200;

export const messageKeys = {
  all: (shopId: string) => shopKey(shopId, 'messages'),
  inbox: (shopId: string) => [...messageKeys.all(shopId), 'inbox'] as const,
  unread: (shopId: string) => [...messageKeys.all(shopId), 'unread-count'] as const,
  thread: (shopId: string, key: string) => [...messageKeys.all(shopId), 'thread', key] as const,
  customer: (shopId: string, id: string) => [...messageKeys.all(shopId), 'customer', id] as const,
  templates: (shopId: string) => [...messageKeys.all(shopId), 'templates'] as const,
  jobs: (shopId: string, customerId: string) =>
    [...messageKeys.all(shopId), 'jobs', customerId] as const,
  preview: (shopId: string, jobId: string, key: string, channel: MessageChannel) =>
    [...messageKeys.all(shopId), 'preview', jobId, key, channel] as const,
  search: (shopId: string, query: string) => [...messageKeys.all(shopId), 'search', query] as const,
};

// ---------------------------------------------------------------------------
// Inbox (thread list)
// ---------------------------------------------------------------------------

type InboxPages = InfiniteData<InboxThreadRow[], string | null>;

/**
 * The conversation list: inbox_threads (0090) returns the newest message of
 * each conversation and its unread count, newest first, keyset-paged by
 * `p_before` (the last row's last_created_at). Owner/admin/manager only.
 */
export function useInbox() {
  const { shopId } = useShop();
  return useInfiniteQuery({
    queryKey: messageKeys.inbox(shopId),
    initialPageParam: null as string | null,
    queryFn: async ({ pageParam }): Promise<InboxThreadRow[]> => {
      const rows = unwrap(
        await supabase.rpc('inbox_threads', {
          p_shop_id: shopId,
          p_limit: INBOX_PAGE_SIZE,
          ...(pageParam ? { p_before: pageParam } : {}),
        }),
      );
      return z.array(inboxThreadRowSchema).parse(rows ?? []);
    },
    getNextPageParam: (last) =>
      last.length >= INBOX_PAGE_SIZE ? (last.at(-1)?.last_created_at ?? undefined) : undefined,
    select: (data) => threadsFromPages(data.pages),
  });
}

/** Unread inbound messages across the shop (inbox_unread_count). */
export function useInboxUnreadCount() {
  const { shopId } = useShop();
  return useQuery({
    queryKey: messageKeys.unread(shopId),
    queryFn: async (): Promise<number> =>
      z
        .number()
        .int()
        .parse(unwrap(await supabase.rpc('inbox_unread_count', { p_shop_id: shopId }))),
  });
}

// ---------------------------------------------------------------------------
// One thread
// ---------------------------------------------------------------------------

/** PostgREST `or` operand: the value double-quoted (addresses contain + and @). */
function quoted(value: string): string {
  return `"${value.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;
}

async function fetchThread(shopId: string, ref: ThreadRef) {
  let query = supabase.from('messages').select(MESSAGE_COLUMNS).eq('shop_id', shopId);
  // A conversation without a customer: what that address sent us and what we sent it.
  query =
    ref.kind === 'customer'
      ? query.eq('customer_id', ref.customerId)
      : query
          .is('customer_id', null)
          .or(
            `and(direction.eq.inbound,from_address.eq.${quoted(ref.from)}),and(direction.eq.outbound,to_address.eq.${quoted(ref.from)})`,
          );
  const result = await query.order('created_at', { ascending: false }).limit(THREAD_LIMIT);
  const rows = z.array(messageSchema).parse(unwrap(result) ?? []);
  return {
    // oldest first for display (the query takes the newest THREAD_LIMIT)
    messages: [...rows].sort((a, b) => a.created_at.localeCompare(b.created_at)),
    truncated: rows.length >= THREAD_LIMIT,
  };
}

export function useThread(ref: ThreadRef | null) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: messageKeys.thread(shopId, ref ? threadKey(ref) : 'none'),
    queryFn: () => fetchThread(shopId, ref as ThreadRef),
    enabled: ref !== null,
  });
}

export function useThreadCustomer(customerId: string | null) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: messageKeys.customer(shopId, customerId ?? 'none'),
    enabled: customerId !== null,
    queryFn: async () => {
      const result = await supabase
        .from('customers')
        .select(THREAD_CUSTOMER_COLUMNS)
        .eq('shop_id', shopId)
        .eq('id', customerId as string)
        .maybeSingle();
      const row = unwrap(result);
      return row === null ? null : threadCustomerSchema.parse(row);
    },
  });
}

/**
 * Marks every unread inbound message of a thread as read. Read state is a
 * local, reversible, non-money field, so the inbox badge clears
 * immediately and is rolled back if the update fails.
 */
export function useMarkThreadRead() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (ref: ThreadRef) => {
      let query = supabase
        .from('messages')
        .update({ read_at: new Date().toISOString() })
        .eq('shop_id', shopId)
        .eq('direction', 'inbound')
        .is('read_at', null);
      query =
        ref.kind === 'customer'
          ? query.eq('customer_id', ref.customerId)
          : query.is('customer_id', null).eq('from_address', ref.from);
      const { error } = await query;
      if (error) throw toAppError(error);
    },
    onMutate: async (ref) => {
      const inboxKey = messageKeys.inbox(shopId);
      const unreadKey = messageKeys.unread(shopId);
      await Promise.all([
        queryClient.cancelQueries({ queryKey: inboxKey }),
        queryClient.cancelQueries({ queryKey: unreadKey }),
      ]);
      const inbox = queryClient.getQueryData<InboxPages>(inboxKey);
      const unread = queryClient.getQueryData<number>(unreadKey);
      const key = threadKey(ref);
      let cleared = 0;
      if (inbox) {
        queryClient.setQueryData<InboxPages>(inboxKey, {
          ...inbox,
          pages: inbox.pages.map((page) =>
            page.map((row) => {
              const thread = threadFromRow(row);
              if (thread?.key !== key || row.unread_count === 0) return row;
              cleared += row.unread_count;
              return { ...row, unread_count: 0 };
            }),
          ),
        });
      }
      if (unread !== undefined) {
        queryClient.setQueryData<number>(unreadKey, Math.max(0, unread - cleared));
      }
      return { inbox, unread };
    },
    onError: (_error, _ref, context) => {
      if (context?.inbox) queryClient.setQueryData(messageKeys.inbox(shopId), context.inbox);
      if (context?.unread !== undefined) {
        queryClient.setQueryData(messageKeys.unread(shopId), context.unread);
      }
    },
    onSettled: () => queryClient.invalidateQueries({ queryKey: messageKeys.all(shopId) }),
  });
}

// ---------------------------------------------------------------------------
// Sending
// ---------------------------------------------------------------------------

export function useSendMessage() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  const toast = useToast();
  return useMutation({
    mutationFn: (input: Omit<SendMessageInput, 'shopId'>) => sendMessage({ ...input, shopId }),
    onSuccess: (result) => {
      // The function tries to deliver at once and reports how that went.
      if (result.status === 'failed')
        toast.error('Message not delivered', result.error ?? 'The provider rejected it.');
      else if (result.status === 'queued')
        toast.info('Message queued', 'Delivery will be retried automatically.');
      else if (result.status === 'cancelled')
        toast.error('Message not sent', result.error ?? 'The customer can no longer be reached.');
      else toast.success('Message sent');
    },
    onSettled: () => queryClient.invalidateQueries({ queryKey: messageKeys.all(shopId) }),
  });
}

const TEMPLATE_KEYS_FOR_CUSTOMERS = SENDABLE_TEMPLATE_KEYS;

export function useMessageTemplates() {
  const { shopId } = useShop();
  return useQuery({
    queryKey: messageKeys.templates(shopId),
    staleTime: 5 * 60_000,
    queryFn: async () => {
      const result = await supabase
        .from('message_templates')
        .select('id, key, channel, subject, body, enabled')
        .eq('shop_id', shopId)
        .in('key', TEMPLATE_KEYS_FOR_CUSTOMERS)
        .order('key');
      return unwrap(result) ?? [];
    },
  });
}

export function useCustomerJobs(customerId: string | null) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: messageKeys.jobs(shopId, customerId ?? 'none'),
    enabled: customerId !== null,
    queryFn: async () => {
      const result = await supabase
        .from('jobs')
        .select('id, number, status, scheduled_start')
        .eq('shop_id', shopId)
        .eq('customer_id', customerId as string)
        .order('created_at', { ascending: false })
        .limit(20);
      return unwrap(result) ?? [];
    },
  });
}

const templatePreviewSchema = z.array(
  z.object({
    enabled: z.boolean().nullable(),
    to_address: z.string().nullable(),
    subject: z.string().nullable(),
    body: z.string().nullable(),
  }),
);

/** Server-rendered preview of a template for a job (nothing is queued). */
export function useTemplatePreview(
  jobId: string | null,
  templateKey: string | null,
  channel: MessageChannel,
) {
  const { shopId } = useShop();
  const key = templateKey as (typeof TEMPLATE_KEYS_FOR_CUSTOMERS)[number] | null;
  return useQuery({
    queryKey: messageKeys.preview(shopId, jobId ?? 'none', key ?? 'none', channel),
    enabled: jobId !== null && key !== null,
    queryFn: async () => {
      const result = await supabase.rpc('preview_template_message', {
        p_job_id: jobId as string,
        p_key: key as NonNullable<typeof key>,
        p_channel: channel,
      });
      return templatePreviewSchema.parse(unwrap(result) ?? [])[0] ?? null;
    },
  });
}

const customerHitSchema = z.array(
  z.object({
    kind: z.string(),
    id: z.string(),
    title: z.string().nullable(),
    subtitle: z.string().nullable(),
    archived: z.boolean().nullable(),
  }),
);
export type CustomerHit = { id: string; title: string; subtitle: string | null };

/** Customer search for "New conversation" (search_shop escapes wildcards server-side). */
export function useCustomerSearch(query: string) {
  const { shopId } = useShop();
  const q = query.trim();
  return useQuery({
    queryKey: messageKeys.search(shopId, q),
    enabled: q.length >= 2,
    placeholderData: keepPreviousData,
    queryFn: async (): Promise<CustomerHit[]> => {
      const result = await supabase.rpc('search_shop', {
        p_shop_id: shopId,
        p_query: q,
        p_limit: 10,
      });
      return customerHitSchema
        .parse(unwrap(result) ?? [])
        .filter((row) => row.kind === 'customer' && !row.archived)
        .map((row) => ({
          id: row.id,
          title: row.title ?? 'Unnamed customer',
          subtitle: row.subtitle,
        }));
    },
  });
}
