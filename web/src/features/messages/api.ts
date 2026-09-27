/**
 * Messages inbox data (SPEC §4.7): threads by customer, thread history,
 * read state, templates and sending. RLS: owner/admin/manager only
 * (technicians have no inbox). Everything lives under the `messages` domain
 * key so the realtime subscription refreshes it all.
 */
import { keepPreviousData, useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { z } from 'zod';
import { useToast } from '@/components/ui';
import { Constants } from '@/lib/database.types';
import { unwrap } from '@/lib/db';
import { toAppError } from '@/lib/errors';
import { shopKey } from '@/lib/queryKeys';
import { supabase } from '@/lib/supabase';
import { useShop } from '@/features/shop/shopContext';
import { sendMessage, type SendMessageInput } from './edge';
import {
  buildThreads,
  inboxMessageSchema,
  MESSAGE_COLUMNS,
  messageSchema,
  THREAD_CUSTOMER_COLUMNS,
  threadCustomerSchema,
  threadKey,
  unreadRowSchema,
  unreadThreadsOutside,
  type InboxMessage,
  type MessageChannel,
  type ThreadRef,
} from './model';

export const INBOX_PAGE = 300;
const THREAD_LIMIT = 200;

export const messageKeys = {
  all: (shopId: string) => shopKey(shopId, 'messages'),
  inbox: (shopId: string, limit: number) => [...messageKeys.all(shopId), 'inbox', limit] as const,
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

/** Unread rows read for counts and for unread threads outside the page. */
const UNREAD_LIMIT = 2000;
/** At most this many unread conversations are added beyond the newest page. */
const MAX_UNREAD_EXTRA_THREADS = 500;
/** Ids per `in.(…)` filter (keeps the request URL short). */
const ID_CHUNK = 100;

const INBOX_COLUMNS = `${MESSAGE_COLUMNS}, customer:customers!messages_customer_fk(${THREAD_CUSTOMER_COLUMNS})`;

async function fetchInbox(shopId: string, limit: number) {
  const [recent, unread] = await Promise.all([
    supabase
      .from('messages')
      .select(INBOX_COLUMNS)
      .eq('shop_id', shopId)
      .order('created_at', { ascending: false })
      .limit(limit),
    supabase
      .from('messages')
      .select('id, customer_id, from_address, created_at', { count: 'exact' })
      .eq('shop_id', shopId)
      .eq('direction', 'inbound')
      .is('read_at', null)
      .order('created_at', { ascending: false })
      .limit(UNREAD_LIMIT),
  ]);
  const messages = z.array(inboxMessageSchema).parse(unwrap(recent) ?? []);
  const unreadRows = z.array(unreadRowSchema).parse(unwrap(unread) ?? []);

  // Threads with unread messages always appear, even when the newest page is
  // all campaign sends: add each missing one via its newest unread message.
  const presentKeys = new Set(buildThreads(messages, []).map((t) => t.key));
  const extraIds = unreadThreadsOutside(presentKeys, unreadRows, MAX_UNREAD_EXTRA_THREADS);
  const chunks: string[][] = [];
  for (let i = 0; i < extraIds.length; i += ID_CHUNK) chunks.push(extraIds.slice(i, i + ID_CHUNK));
  const extra: InboxMessage[] = (
    await Promise.all(
      chunks.map(async (ids) => {
        const result = await supabase
          .from('messages')
          .select(INBOX_COLUMNS)
          .eq('shop_id', shopId)
          .in('id', ids);
        return z.array(inboxMessageSchema).parse(unwrap(result) ?? []);
      }),
    )
  ).flat();

  return {
    threads: buildThreads([...messages, ...extra], unreadRows),
    /** More history exists beyond `limit` (offer "Load older conversations"). */
    truncated: messages.length >= limit,
    /** Every unread inbound message of the shop, not just the listed threads'. */
    unreadTotal: unread.count ?? unreadRows.length,
  };
}

export function useInbox(limit: number) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: messageKeys.inbox(shopId, limit),
    queryFn: () => fetchInbox(shopId, limit),
    placeholderData: keepPreviousData,
  });
}

// ---------------------------------------------------------------------------
// One thread
// ---------------------------------------------------------------------------

async function fetchThread(shopId: string, ref: ThreadRef) {
  let query = supabase.from('messages').select(MESSAGE_COLUMNS).eq('shop_id', shopId);
  query =
    ref.kind === 'customer'
      ? query.eq('customer_id', ref.customerId)
      : query.is('customer_id', null).eq('from_address', ref.from);
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
      const inboxKey = [...messageKeys.all(shopId), 'inbox'];
      await queryClient.cancelQueries({ queryKey: inboxKey });
      const snapshot = queryClient.getQueriesData<Awaited<ReturnType<typeof fetchInbox>>>({
        queryKey: inboxKey,
      });
      const key = threadKey(ref);
      for (const [queryKey, data] of snapshot) {
        if (!data) continue;
        const cleared = data.threads.find((t) => t.key === key)?.unread ?? 0;
        queryClient.setQueryData(queryKey, {
          ...data,
          threads: data.threads.map((t) => (t.key === key ? { ...t, unread: 0 } : t)),
          unreadTotal: Math.max(0, data.unreadTotal - cleared),
        });
      }
      return { snapshot };
    },
    onError: (_error, _ref, context) => {
      for (const [queryKey, data] of context?.snapshot ?? []) {
        queryClient.setQueryData(queryKey, data);
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

const TEMPLATE_KEYS_FOR_CUSTOMERS = Constants.public.Enums.message_template_key.filter(
  (k) => k !== 'invite',
);

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
