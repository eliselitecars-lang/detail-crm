/** Deterministic backend fixtures for smoke tests (names only, no pricing). */

export interface MockUser {
  id: string;
  email: string;
  fullName: string;
}

export type Role = 'owner' | 'admin' | 'manager' | 'technician';

export const OWNER: MockUser = {
  id: '00000000-0000-4000-8000-000000000001',
  email: 'owner@glacier.test',
  fullName: 'Olivia Owner',
};

export const TECH: MockUser = {
  id: '00000000-0000-4000-8000-000000000002',
  email: 'tech@glacier.test',
  fullName: 'Theo Tech',
};

export const SHOP = {
  id: '10000000-0000-4000-8000-000000000001',
  name: 'Glacier Detailing',
  slug: 'glacier-detailing',
  timezone: 'America/Chicago',
  currency: 'usd',
  logo_path: null,
  brand_color: '#1F6FEB',
  business_type: 'mobile',
  techs_can_collect_payments: false,
  tax_rate_bps: 0,
};

/** A `shop_members` row as PostgREST returns it with the embedded shop. */
export function membershipRow(user: MockUser, role: Role, shop = SHOP) {
  return {
    id: `20000000-0000-4000-8000-${user.id.slice(-12)}`,
    shop_id: shop.id,
    role,
    display_name: user.fullName,
    calendar_color: null,
    shop,
  };
}
