import { z } from 'zod';
import { toAppError } from '@/lib/errors';
import { supabase } from '@/lib/supabase';
import type { BusinessHoursRow } from '../businessHours';
import type { OnboardingValues } from './schema';

/** create_shop (migration 0002): creates the shop + owner membership; returns the shop id. */
export async function createShop(values: OnboardingValues): Promise<string> {
  const { data, error } = await supabase.rpc('create_shop', {
    p_name: values.name,
    p_slug: values.slug,
    p_timezone: values.timezone,
    p_business_type: values.businessType,
    // Optional args are omitted (not sent as null) so the generated Args type,
    // which marks defaulted params optional, accepts the call.
    ...(values.email ? { p_email: values.email } : {}),
    ...(values.phone ? { p_phone: values.phone } : {}),
  });
  if (error) throw toAppError(error);
  return z.object({ id: z.string() }).parse(data).id;
}

/**
 * Writes every onboarding field to the new shop (owners may update shops).
 * Besides the address + tax rate create_shop doesn't take, this repeats the
 * fields create_shop set, so a retry after a partial failure saves whatever
 * the owner corrected in the meantime (name, link, type, zone, phone, email).
 */
export async function saveShopDetails(shopId: string, values: OnboardingValues): Promise<void> {
  const { error } = await supabase
    .from('shops')
    .update({
      name: values.name,
      slug: values.slug,
      business_type: values.businessType,
      timezone: values.timezone,
      phone: values.phone,
      email: values.email,
      address_line1: values.addressLine1,
      address_line2: values.addressLine2,
      city: values.city,
      region: values.region,
      postal_code: values.postalCode,
      tax_rate_bps: values.taxRate,
    })
    .eq('id', shopId);
  if (error) throw toAppError(error);
}

/**
 * Replaces the shop's weekly hours atomically (replace_business_hours, 0092):
 * the old rows are deleted and the new ones inserted in one transaction, so a
 * rejected week (overlap 23P01, closes before opens 23514) leaves the stored
 * hours untouched. Idempotent, so a failed onboarding can retry. `[]` = closed
 * all week. Owner/admin only (42501). Rows may carry ONLY weekday / opens_at /
 * closes_at, so they are rebuilt explicitly.
 */
export async function replaceBusinessHours(
  shopId: string,
  rows: readonly BusinessHoursRow[],
): Promise<void> {
  const { error } = await supabase.rpc('replace_business_hours', {
    p_shop_id: shopId,
    p_rows: rows.map(({ weekday, opens_at, closes_at }) => ({ weekday, opens_at, closes_at })),
  });
  if (error) throw toAppError(error);
}
