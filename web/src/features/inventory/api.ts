/**
 * Inventory & consumables (P-28; 0071 schema, 0077 ledger). Managers only
 * (RLS). Stock changes go through record_inventory_movement; product rows
 * are edited directly (the server ignores on_hand / low_stock_notified_at
 * after creation). Deleting a product removes its ledger rows too, so the
 * page offers archiving first.
 */
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { unwrap, unwrapRequired } from '@/lib/db';
import { shopKey } from '@/lib/queryKeys';
import { supabase } from '@/lib/supabase';
import { useShop } from '@/features/shop/shopContext';
import type { ManualMovementKind, Movement, Product, ProductWrite } from './model';

export const inventoryKeys = {
  all: (shopId: string) => shopKey(shopId, 'inventory'),
  products: (shopId: string) => [...inventoryKeys.all(shopId), 'products'] as const,
  movements: (shopId: string, productId: string) =>
    [...inventoryKeys.all(shopId), 'movements', productId] as const,
};

export const MOVEMENTS_LIMIT = 100;

export function useProducts() {
  const { shopId } = useShop();
  return useQuery({
    queryKey: inventoryKeys.products(shopId),
    queryFn: async (): Promise<Product[]> =>
      unwrap(await supabase.from('products').select('*').eq('shop_id', shopId).order('name')) ?? [],
  });
}

export function useMovements(productId: string) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: inventoryKeys.movements(shopId, productId),
    queryFn: async (): Promise<Movement[]> =>
      unwrap(
        await supabase
          .from('inventory_movements')
          .select(
            'id, kind, quantity, unit_cost_cents, job_id, note, created_at, job:jobs!inventory_movements_job_fk(id, number)',
          )
          .eq('shop_id', shopId)
          .eq('product_id', productId)
          .order('created_at', { ascending: false })
          .limit(MOVEMENTS_LIMIT),
      ) ?? [],
  });
}

function useInvalidateInventory() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return () => queryClient.invalidateQueries({ queryKey: inventoryKeys.all(shopId) });
}

export function useSaveProduct() {
  const { shopId } = useShop();
  const invalidate = useInvalidateInventory();
  return useMutation({
    mutationFn: async ({ id, values }: { id?: string; values: ProductWrite }) => {
      if (id) {
        const { on_hand: _ignored, ...patch } = values;
        return unwrapRequired<{ id: string }>(
          await supabase
            .from('products')
            .update(patch)
            .eq('shop_id', shopId)
            .eq('id', id)
            .select('id')
            .maybeSingle(),
          'product',
        ).id;
      }
      return unwrapRequired<{ id: string }>(
        await supabase
          .from('products')
          .insert({ ...values, shop_id: shopId })
          .select('id')
          .single(),
        'product',
      ).id;
    },
    onSettled: invalidate,
  });
}

export function useArchiveProduct() {
  const { shopId } = useShop();
  const invalidate = useInvalidateInventory();
  return useMutation({
    mutationFn: async ({ id, archived }: { id: string; archived: boolean }) => {
      unwrapRequired<{ id: string }>(
        await supabase
          .from('products')
          .update({ archived_at: archived ? new Date().toISOString() : null })
          .eq('shop_id', shopId)
          .eq('id', id)
          .select('id')
          .maybeSingle(),
        'product',
      );
    },
    onSettled: invalidate,
  });
}

export function useDeleteProduct() {
  const { shopId } = useShop();
  const invalidate = useInvalidateInventory();
  return useMutation({
    mutationFn: async (id: string) => {
      unwrapRequired<{ id: string }>(
        await supabase
          .from('products')
          .delete()
          .eq('shop_id', shopId)
          .eq('id', id)
          .select('id')
          .maybeSingle(),
        'product',
      );
    },
    onSettled: invalidate,
  });
}

export interface MovementInput {
  productId: string;
  kind: ManualMovementKind;
  quantity: number;
  /** Receipts only: the purchase cost per unit (becomes the product's cost). */
  unitCostCents: number | null;
  note: string;
}

export function useRecordMovement() {
  const invalidate = useInvalidateInventory();
  return useMutation({
    mutationFn: async ({ productId, kind, quantity, unitCostCents, note }: MovementInput) =>
      unwrapRequired(
        await supabase.rpc('record_inventory_movement', {
          p_product_id: productId,
          p_kind: kind,
          p_quantity: quantity,
          ...(kind === 'receive' && unitCostCents !== null
            ? { p_unit_cost_cents: unitCostCents }
            : {}),
          ...(note.trim() ? { p_note: note.trim() } : {}),
        }),
        'stock change',
      ),
    onSettled: invalidate,
  });
}
