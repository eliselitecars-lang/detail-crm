import { Navigate, Outlet, createBrowserRouter, type RouteObject } from 'react-router';
import { AppShell } from '@/components/layout/AppShell';
import { RequireAuth } from '@/features/auth/RequireAuth';
import { RequireShop } from '@/features/shop/RequireShop';
import { ShopProvider } from '@/features/shop/ShopProvider';
import { publicRoutes, staffRoutes } from './featureRoutes';
import { lazyPage } from './lazyPage';
import NotFoundPage, { AppNotFoundPage } from './NotFound';
import { RootLayout, BootScreen } from './RootLayout';
import { RouteErrorBoundary } from './RouteErrorBoundary';

/**
 *  /                         → /app
 *  /login … /invite/:token    auth (features/auth)
 *  /book/:slug … /portal      public feature routes
 *  /app/onboarding            create a shop (signed in, no shell)
 *  /app/*                     staff shell + staff feature routes
 */
export const appRoutes: RouteObject[] = [
  {
    id: 'root',
    Component: RootLayout,
    HydrateFallback: BootScreen,
    ErrorBoundary: RouteErrorBoundary,
    children: [
      { index: true, element: <Navigate to="/app" replace /> },
      ...publicRoutes,
      {
        path: 'app',
        element: (
          <RequireAuth>
            <ShopProvider>
              <Outlet />
            </ShopProvider>
          </RequireAuth>
        ),
        ErrorBoundary: RouteErrorBoundary,
        children: [
          {
            path: 'onboarding',
            lazy: lazyPage(() => import('@/features/shop/onboarding/OnboardingPage')),
          },
          {
            element: (
              <RequireShop>
                <AppShell />
              </RequireShop>
            ),
            ErrorBoundary: RouteErrorBoundary,
            children: [...staffRoutes, { path: '*', Component: AppNotFoundPage }],
          },
        ],
      },
      { path: '*', Component: NotFoundPage },
    ],
  },
];

export function createAppRouter() {
  return createBrowserRouter(appRoutes);
}
