import { Outlet } from 'react-router';
import { lazyPage } from '@/app/lazyPage';
import type { FeatureRoutes } from '@/app/routeTypes';
import { RequireRole } from '@/features/shop/RequireRole';

/**
 * Customers routes (see web/README.md → Routing). Technicians may open the
 * screens (customers.viewAssigned); RLS returns only customers on their
 * assigned jobs and every write action is hidden for them.
 */
export const routes: FeatureRoutes = {
  staff: [
    {
      path: 'customers',
      element: (
        <RequireRole capability="customers.viewAssigned">
          <Outlet />
        </RequireRole>
      ),
      children: [
        { index: true, lazy: lazyPage(() => import('./CustomersPage')) },
        { path: ':customerId', lazy: lazyPage(() => import('./CustomerDetailPage')) },
      ],
    },
  ],
};
