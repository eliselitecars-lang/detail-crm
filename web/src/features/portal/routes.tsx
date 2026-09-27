import { Outlet } from 'react-router';
import { lazyPage } from '@/app/lazyPage';
import type { FeatureRoutes } from '@/app/routeTypes';
import { RequireAuth } from '@/features/auth/RequireAuth';

/**
 * Client portal. Signed-out visitors go to /login?next=/portal (the auth
 * pages link to sign-up with the same `next`).
 */
export const routes: FeatureRoutes = {
  public: [
    {
      path: '/portal',
      element: (
        <RequireAuth>
          <Outlet />
        </RequireAuth>
      ),
      children: [{ index: true, lazy: lazyPage(() => import('./PortalPage')) }],
    },
  ],
};
