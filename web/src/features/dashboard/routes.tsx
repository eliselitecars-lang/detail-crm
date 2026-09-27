import { lazyPage } from '@/app/lazyPage';
import type { FeatureRoutes } from '@/app/routeTypes';

/** Dashboard routes (see web/README.md → Routing). */
export const routes: FeatureRoutes = {
  staff: [{ index: true, lazy: lazyPage(() => import('./DashboardPage')) }],
};
