import { lazyPage } from '@/app/lazyPage';
import type { FeatureRoutes } from '@/app/routeTypes';

/** Customer-facing job report: public /r/:token (the report's own token). */
export const routes: FeatureRoutes = {
  public: [{ path: '/r/:token', lazy: lazyPage(() => import('./JobReportPage')) }],
};
