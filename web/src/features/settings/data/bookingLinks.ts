/**
 * Private booking links (P-17): booking_links (0050 / 0053). The booking
 * page opened with ?link=<token> offers only the link's services (hidden
 * ones included). Managers read, owners/admins edit; the token is issued by
 * the server and never changes (make a new link instead).
 */
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useShop } from '@/features/shop/shopContext';
import { unwrap, type Row } from '@/lib/db';
import { supabase } from '@/lib/supabase';
import { settingsKeys } from '../api';
import { bookingUrl } from '../links';
import { unwrapList } from './shared';

export type BookingLink = Pick<
  Row<'booking_links'>,
  'id' | 'token' | 'name' | 'service_ids' | 'note' | 'active' | 'expires_at' | 'created_at'
>;

export const bookingLinkKeys = {
  list: (shopId: string) => [...settingsKeys.all(shopId), 'booking-links'] as const,
};

/** /book/<slug>?link=<token> */
export function bookingLinkUrl(slug: string, token: string, origin?: string): string {
  return `${bookingUrl(slug, origin)}?link=${encodeURIComponent(token)}`;
}

export function useBookingLinks() {
  const { shopId } = useShop();
  return useQuery({
    queryKey: bookingLinkKeys.list(shopId),
    queryFn: async (): Promise<BookingLink[]> =>
      unwrapList(
        await supabase
          .from('booking_links')
          .select('id, token, name, service_ids, note, active, expires_at, created_at')
          .eq('shop_id', shopId)
          .order('active', { ascending: false })
          .order('created_at', { ascending: false }),
      ),
  });
}

export interface BookingLinkInput {
  id?: string | undefined;
  name: string;
  service_ids: string[];
  note: string | null;
  active: boolean;
  expires_at: string | null;
}

export function useSaveBookingLink() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async ({ id, ...values }: BookingLinkInput): Promise<void> => {
      if (id) {
        unwrap(
          await supabase.from('booking_links').update(values).eq('id', id).eq('shop_id', shopId),
        );
      } else {
        unwrap(await supabase.from('booking_links').insert({ ...values, shop_id: shopId }));
      }
    },
    onSettled: () => queryClient.invalidateQueries({ queryKey: bookingLinkKeys.list(shopId) }),
  });
}

export function useDeleteBookingLink() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (id: string): Promise<void> => {
      unwrap(await supabase.from('booking_links').delete().eq('id', id).eq('shop_id', shopId));
    },
    onSettled: () => queryClient.invalidateQueries({ queryKey: bookingLinkKeys.list(shopId) }),
  });
}
