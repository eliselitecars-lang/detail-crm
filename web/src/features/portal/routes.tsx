import { Outlet } from 'react-router';
import { lazyPage } from '@/app/lazyPage';
import type { FeatureRoutes } from '@/app/routeTypes';
import { RequireAuth } from '@/features/auth/RequireAuth';
import { CUSTOMER_PORTAL_PATH } from './paths';

/**
 * Client portal. Signed-out visitors go to /login?next=/portal (the auth
 * pages link to sign-up with the same `next`).
 */
export const routes: FeatureRoutes = {
  public: [
    {
      path: CUSTOMER_PORTAL_PATH,
      element: (
        <RequireAuth>
          <Outlet />
        </RequireAuth>
      ),
      children: [{ index: true, lazy: lazyPage(() => import('./PortalPage')) }],
    },
  ],
};
