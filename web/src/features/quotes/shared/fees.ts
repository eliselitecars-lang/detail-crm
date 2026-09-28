/**
 * Preset fees (P-21, shop_fees): the shop's own fixed amounts (travel,
 * disposal…), added to a quote or invoice as an ordinary line by the server
 * (add_fee_line, managers+, under each document's edit rules). The amount
 * comes from the fee row — the client only names the fee.
 */
import { useMutation, useQuery } from '@tanstack/react-query';
import { unwrap, unwrapRequired, type Row } from '@/lib/db';
import { shopKey } from '@/lib/queryKeys';
import { supabase } from '@/lib/supabase';
import { useShop } from '@/features/shop/shopContext';
import { unwrapList } from './db';

export type ShopFee = Pick<
  Row<'shop_fees'>,
  'id' | 'name' | 'amount_cents' | 'taxable' | 'auto_apply'
>;

export const feeKeys = {
  active: (shopId: string) => shopKey(shopId, 'fees', 'active'),
};

/** Active, non-archived fees (every member may read them). */
export function useShopFees(enabled = true) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: feeKeys.active(shopId),
    enabled,
    staleTime: 60_000,
    queryFn: async (): Promise<ShopFee[]> =>
      unwrapList(
        await supabase
          .from('shop_fees')
          .select('id, name, amount_cents, taxable, auto_apply')
          .eq('shop_id', shopId)
          .eq('active', true)
          .is('archived_at', null)
          .order('sort', { ascending: true })
          .order('name', { ascending: true }),
      ),
  });
}

export type FeeDocumentKind = 'quote' | 'invoice';

/** add_fee_line → the new line's id. `onSettled` refreshes the document. */
export function useAddFeeLine(kind: FeeDocumentKind, documentId: string, onSettled: () => unknown) {
  return useMutation({
    mutationFn: async (feeId: string): Promise<string> =>
      unwrapRequired(
        await supabase.rpc('add_fee_line', {
          p_doc_kind: kind,
          p_doc_id: documentId,
          p_fee_id: feeId,
        }),
        'line',
      ),
    onSettled,
  });
}

/** Moves a line into a proposal option (fee lines are added as shared lines). */
export async function moveQuoteLineToOption(
  shopId: string,
  lineId: string,
  optionId: string | null,
): Promise<void> {
  unwrap(
    await supabase
      .from('quote_line_items')
      .update({ option_id: optionId })
      .eq('shop_id', shopId)
      .eq('id', lineId),
  );
}
