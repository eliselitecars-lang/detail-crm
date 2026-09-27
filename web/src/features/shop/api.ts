import { z } from 'zod';
import { toAppError } from '@/lib/errors';
import { supabase } from '@/lib/supabase';
import {
  membershipRowSchema,
  SHOP_SUMMARY_COLUMNS,
  toMembership,
  type ShopMembership,
} from './types';

/**
 * The signed-in user's ACTIVE memberships with their shops. RLS: a user can
 * always read their own shop_members rows and the shops they belong to.
 */
export async function fetchMemberships(userId: string): Promise<ShopMembership[]> {
  const { data, error } = await supabase
    .from('shop_members')
    .select(
      `id, shop_id, role, display_name, calendar_color, shop:shops!inner(${SHOP_SUMMARY_COLUMNS})`,
    )
    .eq('user_id', userId)
    .eq('active', true);
  if (error) throw toAppError(error);
  const rows = z.array(membershipRowSchema).parse(data ?? []);
  return rows.map(toMembership);
}
