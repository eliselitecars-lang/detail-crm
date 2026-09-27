import { z } from 'zod';
import { SHOP_ROLES } from './permissions';

/** Shop fields the shell needs everywhere (from `shops`). */
export const shopSummarySchema = z.object({
  id: z.string(),
  name: z.string(),
  slug: z.string(),
  timezone: z.string(),
  currency: z.string(),
  logo_path: z.string().nullable(),
  brand_color: z.string().nullable(),
  business_type: z.enum(['fixed', 'mobile', 'both']),
  techs_can_collect_payments: z.boolean(),
  tax_rate_bps: z.number(),
});

export type ShopSummary = z.infer<typeof shopSummarySchema>;

/** Columns selected for ShopSummary (keep in sync with the schema above). */
export const SHOP_SUMMARY_COLUMNS =
  'id, name, slug, timezone, currency, logo_path, brand_color, business_type, techs_can_collect_payments, tax_rate_bps';

export const membershipRowSchema = z.object({
  id: z.string(),
  shop_id: z.string(),
  role: z.enum(SHOP_ROLES),
  display_name: z.string(),
  calendar_color: z.string().nullable(),
  shop: shopSummarySchema,
});

export type MembershipRow = z.infer<typeof membershipRowSchema>;

/** The signed-in user's active membership in one shop. */
export interface ShopMembership {
  /** shop_members.id — use as member_id in job_assignments, time_entries… */
  memberId: string;
  shopId: string;
  role: MembershipRow['role'];
  displayName: string;
  calendarColor: string | null;
  shop: ShopSummary;
}

export function toMembership(row: MembershipRow): ShopMembership {
  return {
    memberId: row.id,
    shopId: row.shop_id,
    role: row.role,
    displayName: row.display_name,
    calendarColor: row.calendar_color,
    shop: row.shop,
  };
}
