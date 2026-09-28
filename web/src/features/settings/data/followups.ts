/**
 * Document follow-ups (P-3): followup_settings, one row per shop (0081 /
 * 0085). Managers read, owners/admins write. A follow-up goes out only when
 * its kind is enabled here AND at least one channel of its template is on.
 */
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useShop } from '@/features/shop/shopContext';
import { unwrapRequired, type Row, type UpdateRow } from '@/lib/db';
import { supabase } from '@/lib/supabase';
import { dependentKeys, settingsKeys } from '../api';

export type FollowupSettings = Row<'followup_settings'>;
export type FollowupPatch = Omit<
  UpdateRow<'followup_settings'>,
  'shop_id' | 'created_at' | 'updated_at'
>;

export const followupKeys = {
  settings: (shopId: string) => [...settingsKeys.all(shopId), 'followups'] as const,
};

export function useFollowupSettings() {
  const { shopId } = useShop();
  return useQuery({
    queryKey: followupKeys.settings(shopId),
    queryFn: async (): Promise<FollowupSettings> =>
      unwrapRequired(
        await supabase.from('followup_settings').select('*').eq('shop_id', shopId).maybeSingle(),
        'follow-up settings',
      ),
  });
}

export function useUpdateFollowupSettings() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (patch: FollowupPatch): Promise<FollowupSettings> =>
      unwrapRequired(
        await supabase
          .from('followup_settings')
          .update(patch)
          .eq('shop_id', shopId)
          .select('*')
          .maybeSingle(),
        'follow-up settings',
      ),
    onSuccess: (row) => {
      queryClient.setQueryData(followupKeys.settings(shopId), row);
      // Open quote / invoice pages show each document's follow-up schedule.
      void queryClient.invalidateQueries({ queryKey: dependentKeys.documentFollowups(shopId) });
    },
  });
}

export const HOUR_UNITS = ['hours', 'days'] as const;
export type HourUnit = (typeof HOUR_UNITS)[number];

/** Hours → the largest whole unit for the form. */
export function splitHours(hours: number): { value: string; unit: HourUnit } {
  return hours % 24 === 0
    ? { value: String(hours / 24), unit: 'days' }
    : { value: String(hours), unit: 'hours' };
}

/** Form value → hours (1..2160, i.e. up to 90 days); null when invalid. */
export function joinHours(value: string, unit: HourUnit): number | null {
  const text = value.trim();
  if (!/^\d+$/.test(text)) return null;
  const hours = Number(text) * (unit === 'days' ? 24 : 1);
  return hours >= 1 && hours <= 2160 ? hours : null;
}
