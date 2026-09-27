/**
 * The signed-in user's own account (`account` edge function, verify_jwt).
 * delete_account refuses with 409 `owns_shops` (details.shops) while the
 * user still owns a shop: ownership must be transferred or the shop deleted
 * first, since a shop cannot be left without an owner.
 */
import { useMutation } from '@tanstack/react-query';
import { z } from 'zod';
import { EdgeFunctionError, invokeEdge } from '@/features/quotes/shared/edge';

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
