import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { render, type RenderResult } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import type { ReactElement, ReactNode } from 'react';
import { createMemoryRouter, RouterProvider, type RouteObject } from 'react-router';
import { ToastProvider } from '@/components/ui/Toast';
import { AuthContext, type AuthContextValue } from '@/features/auth/authContext';
import { ShopContext, type ShopContextValue } from '@/features/shop/shopContext';
import type { ShopMembership } from '@/features/shop/types';

export function createTestQueryClient() {
  return new QueryClient({
    defaultOptions: { queries: { retry: false, gcTime: Infinity }, mutations: { retry: false } },
  });
}

export function authValue(overrides: Partial<AuthContextValue> = {}): AuthContextValue {
  return {
    status: 'signedOut',
    session: null,
    user: null,
    recovery: false,
    recoveryChecking: false,
    signOut: () => Promise.resolve(),
    ...overrides,
  };
}

export function signedInAuth(email = 'owner@example.com', id = 'user-1'): AuthContextValue {
  const user = { id, email } as AuthContextValue['user'];
  return authValue({ status: 'signedIn', user, session: { user } as AuthContextValue['session'] });
}

export function membership(overrides: Partial<ShopMembership> = {}): ShopMembership {
  return {
    memberId: 'member-1',
    shopId: 'shop-1',
    role: 'owner',
    displayName: 'Olivia Owner',
    calendarColor: null,
    shop: {
      id: overrides.shopId ?? 'shop-1',
      name: 'Glacier Detailing',
      slug: 'glacier-detailing',
      timezone: 'America/Chicago',
      currency: 'usd',
      logo_path: null,
      brand_color: null,
      business_type: 'fixed',
      techs_can_collect_payments: false,
      tax_rate_bps: 0,
    },
    ...overrides,
  };
}

export function shopValue(overrides: Partial<ShopContextValue> = {}): ShopContextValue {
  const current = overrides.membership === undefined ? membership() : overrides.membership;
  return {
    status: current ? 'ready' : 'empty',
    error: null,
    refetch: () => Promise.resolve(),
    memberships: current ? [current] : [],
    membership: current,
    switchShop: () => undefined,
    ...overrides,
  };
}

export interface RenderRouteOptions {
  /** Initial URL. */
  path?: string;
  /** Route pattern for `ui` (default "*"). */
  routePath?: string;
  /** Extra routes (e.g. redirect targets). */
  routes?: RouteObject[];
  auth?: AuthContextValue;
  shop?: ShopContextValue | null;
  queryClient?: QueryClient;
}

/**
 * Renders `ui` inside a memory router with Query, Toast, Auth and (optionally)
 * Shop providers. Returns RTL helpers + a userEvent instance + the router.
 */
export function renderRoute(ui: ReactElement, options: RenderRouteOptions = {}) {
  const queryClient = options.queryClient ?? createTestQueryClient();
  const router = createMemoryRouter(
    [{ path: options.routePath ?? '*', element: ui }, ...(options.routes ?? [])],
    { initialEntries: [options.path ?? '/'] },
  );
  const wrap = (children: ReactNode) => {
    const withShop =
      options.shop === null ? (
        children
      ) : (
        <ShopContext value={options.shop ?? shopValue()}>{children}</ShopContext>
      );
    return (
      <QueryClientProvider client={queryClient}>
        <ToastProvider>
          <AuthContext value={options.auth ?? authValue()}>{withShop}</AuthContext>
        </ToastProvider>
      </QueryClientProvider>
    );
  };
  const user = userEvent.setup();
  const result: RenderResult = render(wrap(<RouterProvider router={router} />));
  return { ...result, user, router, queryClient };
}
