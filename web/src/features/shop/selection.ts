import type { ShopMembership } from './types';

/** Stable ordering for the shop switcher: by shop name, then id. */
export function sortMemberships(memberships: readonly ShopMembership[]): ShopMembership[] {
  return [...memberships].sort(
    (a, b) =>
      a.shop.name.localeCompare(b.shop.name, undefined, { sensitivity: 'base' }) ||
      a.shopId.localeCompare(b.shopId),
  );
}

/**
 * Which shop is current: the remembered one if the user still belongs to it,
 * otherwise the first by name. `null` when the user has no active shops.
 */
export function selectMembership(
  memberships: readonly ShopMembership[],
  preferredShopId: string | null | undefined,
): ShopMembership | null {
  if (memberships.length === 0) return null;
  if (preferredShopId) {
    const preferred = memberships.find((m) => m.shopId === preferredShopId);
    if (preferred) return preferred;
  }
  return sortMemberships(memberships)[0] ?? null;
}
