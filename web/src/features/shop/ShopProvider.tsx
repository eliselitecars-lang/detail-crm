import { useQuery } from '@tanstack/react-query';
import { useCallback, useMemo, useState, type ReactNode } from 'react';
import { useAuth } from '@/features/auth/authContext';
import { shellKeys } from '@/lib/queryKeys';
import { readLocal, storageKeys, writeLocal } from '@/lib/storage';
import { fetchMemberships } from './api';
import { selectMembership, sortMemberships } from './selection';
import { ShopContext, type ShopContextValue, type ShopStatus } from './shopContext';

/**
 * Loads the signed-in user's memberships (joined to shops), picks the
 * current shop (last used, remembered per user in localStorage) and exposes
 * it. Must sit inside <AuthProvider> and <RequireAuth>.
 */
export function ShopProvider({ children }: { children: ReactNode }) {
  const { user } = useAuth();
  const userId = user?.id ?? '';
  const [preferredShopId, setPreferredShopId] = useState<string | null>(() =>
    userId ? readLocal(storageKeys.lastShop(userId)) : null,
  );

  const query = useQuery({
    queryKey: shellKeys.memberships(userId),
    queryFn: () => fetchMemberships(userId),
    enabled: userId !== '',
    staleTime: 5 * 60_000,
  });

  const memberships = useMemo(() => sortMemberships(query.data ?? []), [query.data]);
  const membership = selectMembership(memberships, preferredShopId);

  const switchShop = useCallback(
    (shopId: string) => {
      setPreferredShopId(shopId);
      if (userId) writeLocal(storageKeys.lastShop(userId), shopId);
    },
    [userId],
  );

  // 'error' only when nothing was ever loaded. A failed BACKGROUND refetch
  // (window focus, invalidation) keeps the cached memberships: tearing down
  // the app shell for it would discard whatever the user was editing.
  const status: ShopStatus = query.isPending
    ? 'loading'
    : query.isError && query.data === undefined
      ? 'error'
      : memberships.length === 0
        ? 'empty'
        : 'ready';

  const value = useMemo<ShopContextValue>(
    () => ({
      status,
      error: query.error,
      refetch: query.refetch,
      memberships,
      membership: status === 'ready' ? membership : null,
      switchShop,
    }),
    [status, query.error, query.refetch, memberships, membership, switchShop],
  );

  return <ShopContext value={value}>{children}</ShopContext>;
}
