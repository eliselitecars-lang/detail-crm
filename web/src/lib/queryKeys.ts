/**
 * TanStack Query key conventions.
 *
 *   ['me', ...]                       per signed-in user, not shop-scoped
 *   ['shop', shopId, domain, ...]     everything tenant data (domain = table
 *                                      or feature name, e.g. 'jobs')
 *   ['public', kind, slugOrToken]     anonymous public pages
 *   ['portal', ...]                   client portal
 *
 * Invalidating `shopKey(shopId, 'jobs')` refreshes every jobs query for that
 * shop (lists, details, counts) — which is exactly what useRealtime does.
 *
 * Each feature defines its keys in `features/<x>/api.ts` on top of these:
 *
 *   export const jobKeys = {
 *     all: (shopId: string) => shopKey(shopId, 'jobs'),
 *     list: (shopId: string, filters: JobFilters) => [...jobKeys.all(shopId), 'list', filters] as const,
 *     detail: (shopId: string, id: string) => [...jobKeys.all(shopId), 'detail', id] as const,
 *   };
 */

export type QueryKey = readonly unknown[];

/** Domains used by shared code; features may use any string. */
export type ShopDomain =
  | 'shop'
  | 'jobs'
  | 'customers'
  | 'vehicles'
  | 'quotes'
  | 'invoices'
  | 'payments'
  | 'memberships'
  | 'messages'
  | 'campaigns'
  | 'notifications'
  | 'time_entries'
  | 'team'
  | 'catalog'
  | 'settings'
  | 'reports'
  | 'search'
  | (string & {});

export function shopKey(shopId: string, domain: ShopDomain, ...rest: unknown[]) {
  return ['shop', shopId, domain, ...rest] as const;
}

export function meKey(...rest: unknown[]) {
  return ['me', ...rest] as const;
}

export function publicKey(kind: string, slugOrToken: string, ...rest: unknown[]) {
  return ['public', kind, slugOrToken, ...rest] as const;
}

export function portalKey(...rest: unknown[]) {
  return ['portal', ...rest] as const;
}

/** Shared keys owned by the shell. */
export const shellKeys = {
  memberships: (userId: string) => meKey(userId, 'memberships'),
  profile: (userId: string) => meKey(userId, 'profile'),
  notifications: (shopId: string) => shopKey(shopId, 'notifications'),
  notificationList: (shopId: string, userId: string) =>
    [...shopKey(shopId, 'notifications'), 'bell', userId] as const,
  unreadCount: (shopId: string, userId: string) =>
    [...shopKey(shopId, 'notifications'), 'unread', userId] as const,
  search: (shopId: string, query: string) => shopKey(shopId, 'search', query),
  slugCheck: (slug: string) => publicKey('slug-check', slug),
};
