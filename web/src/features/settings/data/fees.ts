/**
 * Preset fees (P-21): shop_fees (0061 / 0068). Members read (the job, quote
 * and invoice editors offer them); owners/admins edit. A fee on a document is
 * an ordinary line, so deleting a fee leaves existing lines as they are.
 */
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useShop } from '@/features/shop/shopContext';
import { unwrap, type Row } from '@/lib/db';
import { shopKey } from '@/lib/queryKeys';
import { supabase } from '@/lib/supabase';
import { settingsKeys } from '../api';
import { invalidateKeys, unwrapList } from './shared';

export type ShopFee = Pick<
  Row<'shop_fees'>,
  'id' | 'name' | 'amount_cents' | 'taxable' | 'auto_apply' | 'active' | 'sort'
>;
export type FeeAutoApply = Row<'shop_fees'>['auto_apply'];

export const FEE_AUTO_APPLY_LABELS: Record<FeeAutoApply, string> = {
  none: 'Added by hand',
  shop: 'Automatic on in-shop jobs',
  mobile: 'Automatic on mobile jobs',
  both: 'Automatic on every job',
};

export const feeKeys = {
  list: (shopId: string) => [...settingsKeys.all(shopId), 'fees'] as const,
};

export function useShopFees() {
  const { shopId } = useShop();
  return useQuery({
    queryKey: feeKeys.list(shopId),
    queryFn: async (): Promise<ShopFee[]> =>
      unwrapList(
        await supabase
          .from('shop_fees')
          .select('id, name, amount_cents, taxable, auto_apply, active, sort')
          .eq('shop_id', shopId)
          .is('archived_at', null)
          .order('sort')
          .order('name'),
      ),
  });
}

export interface FeeInput {
  id?: string | undefined;
  name: string;
  amount_cents: number;
  taxable: boolean;
  auto_apply: FeeAutoApply;
  active: boolean;
  sort?: number;
}

/** settings/* plus the jobs / quotes / invoices fee pickers (catalog domain). */
function invalidateFees(queryClient: ReturnType<typeof useQueryClient>, shopId: string) {
  return invalidateKeys(queryClient, [settingsKeys.all(shopId), shopKey(shopId, 'catalog')]);
}

export function useSaveFee() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async ({ id, ...values }: FeeInput): Promise<void> => {
      if (id) {
        unwrap(await supabase.from('shop_fees').update(values).eq('id', id).eq('shop_id', shopId));
      } else {
        unwrap(await supabase.from('shop_fees').insert({ ...values, shop_id: shopId }));
      }
    },
    onSettled: () => invalidateFees(queryClient, shopId),
  });
}

export function useDeleteFee() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (id: string): Promise<void> => {
      unwrap(await supabase.from('shop_fees').delete().eq('id', id).eq('shop_id', shopId));
    },
    onSettled: () => invalidateFees(queryClient, shopId),
  });
}
