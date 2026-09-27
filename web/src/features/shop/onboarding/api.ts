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

/** Replaces the shop's weekly hours (idempotent, so a failed onboarding can retry). */
export async function replaceBusinessHours(
  shopId: string,
  rows: readonly BusinessHoursRow[],
): Promise<void> {
  const removed = await supabase.from('business_hours').delete().eq('shop_id', shopId);
  if (removed.error) throw toAppError(removed.error);
  if (rows.length === 0) return;
  const { error } = await supabase
    .from('business_hours')
    .insert(rows.map((row) => ({ ...row, shop_id: shopId })));
  if (error) throw toAppError(error);
}
