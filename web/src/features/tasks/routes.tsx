import { Outlet } from 'react-router';
import { lazyPage } from '@/app/lazyPage';
import type { FeatureRoutes } from '@/app/routeTypes';
import { RequireRole } from '@/features/shop/RequireRole';

/** Staff tasks: /app/tasks (every member sees their own; managers see all). */
export const routes: FeatureRoutes = {
  staff: [
    {
      path: 'tasks',
      element: (
        <RequireRole capability="tasks.own">
          <Outlet />
        </RequireRole>
      ),
      children: [{ index: true, lazy: lazyPage(() => import('./TasksPage')) }],
    },
  ],
};
