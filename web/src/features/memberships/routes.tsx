import { Outlet } from 'react-router';
import { lazyPage } from '@/app/lazyPage';
import type { FeatureRoutes } from '@/app/routeTypes';
import { RequireRole } from '@/features/shop/RequireRole';

/** Memberships routes (see web/README.md → Routing). */
export const routes: FeatureRoutes = {
  staff: [
    {
      path: 'memberships',
      element: (
        <RequireRole capability="memberships.view">
          <Outlet />
        </RequireRole>
      ),
      children: [{ index: true, lazy: lazyPage(() => import('./MembershipsPage')) }],
    },
  ],
};
