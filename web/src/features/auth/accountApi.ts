/**
 * The signed-in user's own account (`account` edge function, verify_jwt).
 * delete_account refuses with 409 `owns_shops` (details.shops) while the
 * user still owns a shop: ownership must be transferred or the shop deleted
 * first, since a shop cannot be left without an owner.
 */
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { z } from 'zod';
import { EdgeFunctionError, invokeEdge } from '@/features/quotes/shared/edge';
import { fetchMemberships } from '@/features/shop/api';
import { unwrap } from '@/lib/db';
import { shellKeys } from '@/lib/queryKeys';
import { readLocal, storageKeys, writeLocal } from '@/lib/storage';
import { supabase } from '@/lib/supabase';

const deletedSchema = z.object({ deleted: z.literal(true) });

export function useDeleteAccount() {
  return useMutation({
    mutationFn: () => invokeEdge('account', 'delete_account', {}, deletedSchema),
  });
}

const ownedShopsSchema = z.array(z.object({ shop_id: z.string(), name: z.string() }));
export type OwnedShop = z.infer<typeof ownedShopsSchema>[number];

/** The shops blocking deletion, when the server answered 409 owns_shops; else null. */
export function ownedShopsOf(error: unknown): OwnedShop[] | null {
  if (!(error instanceof EdgeFunctionError) || error.reason !== 'owns_shops') return null;
  const parsed = ownedShopsSchema.safeParse(error.details.shops);
  return parsed.success ? parsed.data : [];
}

/**
 * The signed-in user's active shop memberships (the same query and cache as
 * the staff shell's ShopProvider), for the "Your shops" card on /account.
 */
export function useMyMemberships(userId: string) {
  return useQuery({
    queryKey: shellKeys.memberships(userId),
    queryFn: () => fetchMemberships(userId),
    enabled: userId !== '',
    staleTime: 5 * 60_000,
  });
}

/**
 * leave_shop (0002): deactivates the caller's own membership. Owners are
 * refused (transfer ownership first); every other role may leave. Afterwards
 * the shell's memberships reload, so the app no longer opens that shop.
 */
export function useLeaveShop(userId: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (shopId: string) => {
      unwrap(await supabase.rpc('leave_shop', { p_shop_id: shopId }));
      // The app would otherwise try to reopen the shop that was just left.
      if (readLocal(storageKeys.lastShop(userId)) === shopId) {
        writeLocal(storageKeys.lastShop(userId), null);
      }
    },
    onSettled: () => queryClient.invalidateQueries({ queryKey: shellKeys.memberships(userId) }),
  });
}
