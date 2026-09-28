import { createContext, use } from 'react';
import { permissionContextOf, type PermissionContext, type ShopRole } from './permissions';
import type { ShopMembership, ShopSummary } from './types';

export type ShopStatus = 'loading' | 'error' | 'empty' | 'ready';

export interface ShopContextValue {
  status: ShopStatus;
  error: unknown;
  refetch: () => Promise<unknown>;
  /** All active memberships, sorted by shop name. */
  memberships: ShopMembership[];
  /** Current membership (null unless status === 'ready'). */
  membership: ShopMembership | null;
  switchShop: (shopId: string) => void;
}

export const ShopContext = createContext<ShopContextValue | null>(null);

/** Raw shop context (nullable). Shell, onboarding and guards use this. */
export function useShopContext(): ShopContextValue {
  const ctx = use(ShopContext);
  if (!ctx) throw new Error('useShopContext must be used inside <ShopProvider>');
  return ctx;
}

export interface CurrentShop {
  shop: ShopSummary;
  shopId: string;
  role: ShopRole;
  /** shop_members.id of the signed-in user in this shop. */
  memberId: string;
  displayName: string;
  /** IANA zone — pass to every lib/dates formatter. */
  timezone: string;
  currency: string;
  techsCanCollectPayments: boolean;
  /** shops.techs_can_share_reports: technicians may publish job reports on their jobs. */
  techsCanShareReports: boolean;
  permissions: PermissionContext;
  memberships: ShopMembership[];
  switchShop: (shopId: string) => void;
}

/**
 * The current shop for staff pages. Only valid under <RequireShop> (all
 * /app routes except onboarding), where a shop is guaranteed.
 */
export function useShop(): CurrentShop {
  const { membership, memberships, switchShop } = useShopContext();
  if (!membership) throw new Error('useShop must be used under <RequireShop> (no current shop)');
  return {
    shop: membership.shop,
    shopId: membership.shopId,
    role: membership.role,
    memberId: membership.memberId,
    displayName: membership.displayName,
    timezone: membership.shop.timezone,
    currency: membership.shop.currency,
    techsCanCollectPayments: membership.shop.techs_can_collect_payments,
    techsCanShareReports: membership.shop.techs_can_share_reports === true,
    permissions: permissionContextOf(membership),
    memberships,
    switchShop,
  };
}
