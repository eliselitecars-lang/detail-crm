/**
 * Personal iCal feed (P-19): calendar_feed_tokens (0050 / 0055). Every member
 * manages their own token; include_all (every job of the shop) is for owners,
 * admins and managers. The token is a credential: whoever has the link sees
 * the feed, so rotating it (a new link) cuts off the old one.
 */
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { z } from 'zod';
import { useShop } from '@/features/shop/shopContext';
import { unwrap, type Row } from '@/lib/db';
import { functionsUrl } from '@/lib/env';
import { supabase } from '@/lib/supabase';
import { settingsKeys } from '../api';

export type CalendarFeed = Pick<
  Row<'calendar_feed_tokens'>,
  'id' | 'token' | 'include_all' | 'created_at' | 'last_accessed_at'
>;

export const calendarFeedKeys = {
  mine: (shopId: string, memberId: string) =>
    [...settingsKeys.all(shopId), 'calendar-feed', memberId] as const,
};

/** https and webcal:// links of a feed token (null when Supabase isn't configured). */
export function calendarFeedUrls(token: string): { https: string; webcal: string } | null {
  const https = functionsUrl(`/functions/v1/calendar-feed?token=${encodeURIComponent(token)}`);
  if (!https) return null;
  return { https, webcal: https.replace(/^https?:\/\//, 'webcal://') };
}

export function useMyCalendarFeed() {
  const { shopId, memberId } = useShop();
  return useQuery({
    queryKey: calendarFeedKeys.mine(shopId, memberId),
    queryFn: async (): Promise<CalendarFeed | null> =>
      unwrap(
        await supabase
          .from('calendar_feed_tokens')
          .select('id, token, include_all, created_at, last_accessed_at')
          .eq('shop_id', shopId)
          .eq('member_id', memberId)
          .is('revoked_at', null)
          .maybeSingle(),
      ),
  });
}

const createResultSchema = z.object({ token: z.string(), path: z.string() });

/** Creates the member's feed, or a new link for it (the old one stops working). */
export function useCreateCalendarFeed() {
  const { shopId, memberId } = useShop();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (includeAll: boolean) =>
      createResultSchema.parse(
        unwrap(
          await supabase.rpc('create_calendar_feed', {
            p_shop_id: shopId,
            p_include_all: includeAll,
          }),
        ),
      ),
    onSettled: () =>
      queryClient.invalidateQueries({ queryKey: calendarFeedKeys.mine(shopId, memberId) }),
  });
}

export function useRevokeCalendarFeed() {
  const { shopId, memberId } = useShop();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (): Promise<boolean> =>
      unwrap(await supabase.rpc('revoke_calendar_feed', { p_shop_id: shopId })) === true,
    onSettled: () =>
      queryClient.invalidateQueries({ queryKey: calendarFeedKeys.mine(shopId, memberId) }),
  });
}
