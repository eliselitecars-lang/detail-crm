import { Outlet } from 'react-router';
import { lazyPage } from '@/app/lazyPage';
import type { FeatureRoutes } from '@/app/routeTypes';
import { RequireRole } from '@/features/shop/RequireRole';

/**
 * Catalog routes (see web/README.md → Routing). Every staff role reads the
 * catalog; editing controls render only for catalog.manage (manager+), and
 * RLS enforces the same.
 */
export const routes: FeatureRoutes = {
  staff: [
    {
      path: 'catalog',
      element: (
        <RequireRole capability="catalog.view">
          <Outlet />
        </RequireRole>
      ),
      children: [
        { index: true, lazy: lazyPage(() => import('./CatalogPage')) },
        { path: 'services/:serviceId', lazy: lazyPage(() => import('./ServiceDetailPage')) },
      ],
    },
  ],
};
