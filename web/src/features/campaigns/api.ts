/**
 * Campaigns (SPEC §4.7): drafts are edited directly (RLS manager+; the
 * campaigns_client_guard trigger allows draft edits only); launch / cancel
 * go through launch_campaign / cancel_campaign, which materialize
 * recipients and queue messages exactly once.
 */
import { keepPreviousData, useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { z } from 'zod';
import { useToast } from '@/components/ui';
import type { Json } from '@/lib/database.types';
import { unwrap, unwrapRequired } from '@/lib/db';
import { isNonRetryable } from '@/lib/errors';
import { shopKey } from '@/lib/queryKeys';
import { supabase } from '@/lib/supabase';
import { useShop } from '@/features/shop/shopContext';
import {
  campaignPreviewSchema,
  type CampaignChannel,
  type CampaignPreview,
  type CampaignStatus,
  type RecipientStats,
} from './model';

export const campaignKeys = {
  all: (shopId: string) => shopKey(shopId, 'campaigns'),
  list: (shopId: string) => [...campaignKeys.all(shopId), 'list'] as const,
  detail: (shopId: string, id: string) => [...campaignKeys.all(shopId), 'detail', id] as const,
  stats: (shopId: string, id: string) => [...campaignKeys.all(shopId), 'stats', id] as const,
  audience: (shopId: string, channel: CampaignChannel, audience: Json) =>
    [...campaignKeys.all(shopId), 'audience', channel, audience] as const,
  tags: (shopId: string) => [...campaignKeys.all(shopId), 'tags'] as const,
};

const LIST_COLUMNS =
  'id, name, channel, status, recipient_count, scheduled_at, launched_at, cancelled_at, created_at, updated_at';

export function useCampaigns() {
  const { shopId } = useShop();
  return useQuery({
    queryKey: campaignKeys.list(shopId),
    queryFn: async () => {
      const result = await supabase
        .from('campaigns')
        .select(LIST_COLUMNS)
        .eq('shop_id', shopId)
        .order('created_at', { ascending: false })
        .limit(500);
      return unwrap(result) ?? [];
    },
  });
}

export type CampaignListRow = NonNullable<ReturnType<typeof useCampaigns>['data']>[number];

export function useCampaign(id: string | undefined) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: campaignKeys.detail(shopId, id ?? 'new'),
    enabled: id !== undefined,
    queryFn: async () => {
      const result = await supabase
        .from('campaigns')
        .select(
          'id, name, channel, subject, body, audience, status, scheduled_at, launched_at, cancelled_at, recipient_count, created_at, updated_at',
        )
        .eq('shop_id', shopId)
        .eq('id', id as string)
        .maybeSingle();
      return unwrapRequired(result, 'campaign');
    },
  });
}

export type Campaign = NonNullable<ReturnType<typeof useCampaign>['data']>;

export interface CampaignDraftInput {
  name: string;
  channel: CampaignChannel;
  subject: string | null;
  body: string;
  audience: NonNullable<Json>;
  scheduled_at: string | null;
}

/** Creates (no id) or updates a draft; resolves to the campaign id. */
export function useSaveCampaign() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async ({ id, values }: { id?: string; values: CampaignDraftInput }) => {
      if (id) {
        const result = await supabase
          .from('campaigns')
          .update(values)
          .eq('shop_id', shopId)
          .eq('id', id)
          .select('id')
          .maybeSingle();
        return unwrapRequired(result, 'campaign').id;
      }
      const result = await supabase
        .from('campaigns')
        .insert({ ...values, shop_id: shopId })
        .select('id')
        .single();
      return unwrapRequired(result, 'campaign').id;
    },
    onSettled: () => queryClient.invalidateQueries({ queryKey: campaignKeys.all(shopId) }),
  });
}

export function useDeleteCampaign() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  const toast = useToast();
  return useMutation({
    mutationFn: async (id: string) => {
      unwrap(await supabase.from('campaigns').delete().eq('shop_id', shopId).eq('id', id));
    },
    onSuccess: () => toast.success('Draft deleted'),
    onSettled: () => queryClient.invalidateQueries({ queryKey: campaignKeys.all(shopId) }),
  });
}

export function useLaunchCampaign() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (id: string) =>
      unwrapRequired(await supabase.rpc('launch_campaign', { p_campaign_id: id }), 'campaign'),
    onSettled: () => {
      void queryClient.invalidateQueries({ queryKey: campaignKeys.all(shopId) });
      void queryClient.invalidateQueries({ queryKey: shopKey(shopId, 'messages') });
    },
  });
}

export function useCancelCampaign() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (id: string) =>
      unwrapRequired(await supabase.rpc('cancel_campaign', { p_campaign_id: id }), 'campaign'),
    onSettled: () => {
      void queryClient.invalidateQueries({ queryKey: campaignKeys.all(shopId) });
      void queryClient.invalidateQueries({ queryKey: shopKey(shopId, 'messages') });
    },
  });
}

/**
 * How many customers the audience reaches right now — the same SQL the
 * launch uses (preview_campaign_audience), so it is exact at this moment;
 * opt-ins/outs before launch can still change it (labelled an estimate).
 */
export function useAudiencePreview(channel: CampaignChannel, audience: Json, enabled = true) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: campaignKeys.audience(shopId, channel, audience),
    enabled,
    placeholderData: keepPreviousData,
    staleTime: 30_000,
    queryFn: async () =>
      z
        .number()
        .int()
        .parse(
          unwrap(
            await supabase.rpc('preview_campaign_audience', {
              p_shop_id: shopId,
              p_channel: channel,
              p_audience: audience,
            }),
          ),
        ),
  });
}

/** Existing customer tags, for the audience builder's suggestions. */
export function useCustomerTags() {
  const { shopId } = useShop();
  return useQuery({
    queryKey: campaignKeys.tags(shopId),
    staleTime: 5 * 60_000,
    queryFn: async () => {
      const result = await supabase
        .from('customers')
        .select('tags')
        .eq('shop_id', shopId)
        .is('archived_at', null)
        .order('updated_at', { ascending: false })
        .limit(2000);
      const seen = new Map<string, string>();
      for (const row of unwrap(result) ?? []) {
        for (const tag of row.tags) {
          const key = tag.trim().toLowerCase();
          if (key && !seen.has(key)) seen.set(key, tag.trim());
        }
      }
      return [...seen.values()].sort((a, b) => a.localeCompare(b));
    },
  });
}

const STATUS_GROUPS = {
  pending: ['queued', 'sending'],
  sent: ['sent'],
  delivered: ['delivered'],
  failed: ['failed'],
  cancelled: ['cancelled'],
} as const;

/** Delivery status counts of a campaign's messages (exact HEAD counts per status group). */
export function useCampaignStats(id: string, status: CampaignStatus, recipients: number) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: campaignKeys.stats(shopId, id),
    enabled: status !== 'draft',
    queryFn: async (): Promise<RecipientStats> => {
      const entries = await Promise.all(
        (Object.keys(STATUS_GROUPS) as (keyof typeof STATUS_GROUPS)[]).map(async (group) => {
          const result = await supabase
            .from('messages')
            .select('id', { count: 'exact', head: true })
            .eq('shop_id', shopId)
            .eq('campaign_id', id)
            .in('status', [...STATUS_GROUPS[group]]);
          unwrap(result);
          return [group, result.count ?? 0] as const;
        }),
      );
      const counts = Object.fromEntries(entries) as Record<keyof typeof STATUS_GROUPS, number>;
      return { recipients, ...counts };
    },
  });
}

// ---------------------------------------------------------------------------
// Message preview (server-rendered, as launch_campaign sends it)
// ---------------------------------------------------------------------------

export interface CampaignPreviewInput {
  channel: CampaignChannel;
  body: string;
  subject: string | null;
}

/**
 * preview_campaign_message (0090, manager+): the campaign text rendered like
 * launch_campaign (shop values filled in, customer placeholders shown as
 * “[first name]”), with the opt-out line / unsubscribe footer, its length and
 * the limit that applies. Disabled while the body is blank.
 */
export function useCampaignPreview(input: CampaignPreviewInput) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: [...campaignKeys.all(shopId), 'preview', input] as const,
    enabled: input.body.trim() !== '',
    placeholderData: keepPreviousData,
    staleTime: 60_000,
    queryFn: async (): Promise<CampaignPreview> =>
      campaignPreviewSchema.parse(
        unwrap(
          await supabase.rpc('preview_campaign_message', {
            p_shop_id: shopId,
            p_channel: input.channel,
            p_body: input.body,
            ...(input.channel === 'email' && input.subject ? { p_subject: input.subject } : {}),
          }),
        ),
      ),
  });
}

// ---------------------------------------------------------------------------
// Public unsubscribe page (/u/:token) — anonymous visitors
// ---------------------------------------------------------------------------

/**
 * Records the email opt-out behind a marketing email's unsubscribe link
 * (public_unsubscribe, granted to anon; the token is that email's random
 * unsubscribe token, never its message id). Since 0126 it is a
 * marketing-only opt-out (scope 'marketing'): campaigns and marketing
 * follow-ups stop, while confirmations, reminders, quotes, invoices and
 * receipts still go to the address. Resolves true when done (idempotent),
 * false for an unknown link.
 */
export const unsubscribeInfoSchema = z.object({
  shop_name: z.string(),
  shop_logo_path: z.string().nullable(),
  /** The address is already opted out of this shop's email (any scope). */
  unsubscribed: z.boolean(),
  /**
   * 0126: 'marketing' — marketing email only (the unsubscribe link); 'all' —
   * every email (an older unsubscribe, or an opt-out the shop recorded).
   * Null when not unsubscribed.
   */
  scope: z.enum(['marketing', 'all']).nullish(),
});
export type UnsubscribeInfo = z.infer<typeof unsubscribeInfoSchema>;

/**
 * What the unsubscribe link is for (public_unsubscribe_info, anon): the
 * shop's name and logo and whether (and from what) the address is already
 * unsubscribed. Never the address itself. An unknown link is PT404 (kind
 * not_found).
 */
export function useUnsubscribeInfo(token: string) {
  return useQuery({
    queryKey: ['public', 'unsubscribe', token] as const,
    queryFn: async (): Promise<UnsubscribeInfo> =>
      unsubscribeInfoSchema.parse(
        unwrap(await supabase.rpc('public_unsubscribe_info', { p_token: token })),
      ),
    retry: (failureCount, error) => !isNonRetryable(error) && failureCount < 2,
  });
}

export function useUnsubscribe() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (token: string) => {
      const result = await supabase.rpc('public_unsubscribe', { p_token: token });
      return z.boolean().parse(unwrap(result));
    },
    onSuccess: (done, token) => {
      if (!done) return;
      // A marketing opt-out; an address already opted out of everything stays so.
      queryClient.setQueryData<UnsubscribeInfo>(['public', 'unsubscribe', token], (info) =>
        info ? { ...info, unsubscribed: true, scope: info.scope ?? 'marketing' } : info,
      );
    },
  });
}
