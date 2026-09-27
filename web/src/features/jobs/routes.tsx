import { Outlet } from 'react-router';
import { lazyPage } from '@/app/lazyPage';
import type { FeatureRoutes } from '@/app/routeTypes';
import { RequireRole } from '@/features/shop/RequireRole';

/** Jobs routes (see web/README.md → Routing). */
export const routes: FeatureRoutes = {
  staff: [
    {
      path: 'jobs',
      element: (
        <RequireRole capability="jobs.viewAssigned">
          <Outlet />
        </RequireRole>
      ),
      children: [
        { index: true, lazy: lazyPage(() => import('./JobsPage')) },
        {
          path: 'new',
          element: (
            <RequireRole capability="jobs.manage">
              <Outlet />
            </RequireRole>
          ),
          children: [{ index: true, lazy: lazyPage(() => import('./NewJobPage')) }],
        },
        { path: ':jobId', lazy: lazyPage(() => import('./JobDetailPage')) },
      ],
    },
  ],
};
