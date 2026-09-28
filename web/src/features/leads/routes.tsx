import { lazyPage } from '@/app/lazyPage';
import type { FeatureRoutes } from '@/app/routeTypes';

/** Lead-capture form: public /lead/:token (?embed=1 for the compact iframe layout). */
export const routes: FeatureRoutes = {
  public: [{ path: '/lead/:token', lazy: lazyPage(() => import('./LeadFormPage')) }],
};
