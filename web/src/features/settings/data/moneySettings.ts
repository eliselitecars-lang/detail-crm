/**
 * Money programme settings, one row per shop (0061): gift card sales
 * (gift_card_settings, P-13) and the referral programme (referral_settings,
 * P-29). Managers read, owners/admins edit. Nothing is seeded with amounts:
 * the shop enters every price.
 */
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { z } from 'zod';
import { useShop } from '@/features/shop/shopContext';
import { unwrapRequired, type Row, type UpdateRow } from '@/lib/db';
import { supabase } from '@/lib/supabase';
import { settingsKeys } from '../api';

export type GiftCardSettings = Omit<Row<'gift_card_settings'>, 'offers'> & {
  offers: GiftCardOffer[];
};
export type GiftCardSettingsPatch = Omit<
  UpdateRow<'gift_card_settings'>,
  'shop_id' | 'updated_at' | 'offers'
> & { offers?: GiftCardOffer[] };
export type ReferralSettings = Row<'referral_settings'>;
export type ReferralSettingsPatch = Omit<UpdateRow<'referral_settings'>, 'shop_id' | 'updated_at'>;

export const giftCardOfferSchema = z.object({
  value_cents: z.number().int(),
  price_cents: z.number().int(),
});
export type GiftCardOffer = z.infer<typeof giftCardOfferSchema>;

/** Limits of gift_card_offers_valid / gift_card_settings_custom_range (0061). */
export const GIFT_CARD_LIMITS = {
  maxOffers: 8,
  minValueCents: 500,
  maxValueCents: 100000,
  minExpiryMonths: 60,
  maxExpiryMonths: 600,
} as const;

export const moneySettingsKeys = {
  giftCards: (shopId: string) => [...settingsKeys.all(shopId), 'gift-card-settings'] as const,
  referrals: (shopId: string) => [...settingsKeys.all(shopId), 'referral-settings'] as const,
};

function parseGiftCardSettings(row: Row<'gift_card_settings'>): GiftCardSettings {
  const offers = z.array(giftCardOfferSchema).safeParse(row.offers);
  return { ...row, offers: offers.success ? offers.data : [] };
}

export function useGiftCardSettings() {
  const { shopId } = useShop();
  return useQuery({
    queryKey: moneySettingsKeys.giftCards(shopId),
    queryFn: async (): Promise<GiftCardSettings> =>
      parseGiftCardSettings(
        unwrapRequired(
          await supabase.from('gift_card_settings').select('*').eq('shop_id', shopId).maybeSingle(),
          'gift card settings',
        ),
      ),
  });
}

export function useUpdateGiftCardSettings() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (patch: GiftCardSettingsPatch): Promise<GiftCardSettings> =>
      parseGiftCardSettings(
        unwrapRequired(
          await supabase
            .from('gift_card_settings')
            .update(patch)
            .eq('shop_id', shopId)
            .select('*')
            .maybeSingle(),
          'gift card settings',
        ),
      ),
    onSuccess: (row) => queryClient.setQueryData(moneySettingsKeys.giftCards(shopId), row),
  });
}

export function useReferralSettings() {
  const { shopId } = useShop();
  return useQuery({
    queryKey: moneySettingsKeys.referrals(shopId),
    queryFn: async (): Promise<ReferralSettings> =>
      unwrapRequired(
        await supabase.from('referral_settings').select('*').eq('shop_id', shopId).maybeSingle(),
        'referral settings',
      ),
  });
}

export function useUpdateReferralSettings() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (patch: ReferralSettingsPatch): Promise<ReferralSettings> =>
      unwrapRequired(
        await supabase
          .from('referral_settings')
          .update(patch)
          .eq('shop_id', shopId)
          .select('*')
          .maybeSingle(),
        'referral settings',
      ),
    onSuccess: (row) => queryClient.setQueryData(moneySettingsKeys.referrals(shopId), row),
  });
}
