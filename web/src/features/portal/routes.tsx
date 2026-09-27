import { lazyPage } from '@/app/lazyPage';
import type { FeatureRoutes } from '@/app/routeTypes';

/** Public portal routes (see web/README.md → Routing). */
export const routes: FeatureRoutes = {
  public: [{ path: '/portal', lazy: lazyPage(() => import('./PortalPage')) }],
};
