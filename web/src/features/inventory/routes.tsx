import { Outlet } from 'react-router';
import { lazyPage } from '@/app/lazyPage';
import type { FeatureRoutes } from '@/app/routeTypes';
import { RequireRole } from '@/features/shop/RequireRole';

/** Inventory & consumables: /app/inventory (managers). */
export const routes: FeatureRoutes = {
  staff: [
    {
      path: 'inventory',
      element: (
        <RequireRole capability="inventory.view">
          <Outlet />
        </RequireRole>
      ),
      children: [{ index: true, lazy: lazyPage(() => import('./InventoryPage')) }],
    },
  ],
};
