import { lazyPage } from '@/app/lazyPage';
import type { FeatureRoutes } from '@/app/routeTypes';

/** Public booking routes (see web/README.md → Routing). */
export const routes: FeatureRoutes = {
  public: [
    { path: '/book/:slug', lazy: lazyPage(() => import('./BookingPage')) },
    { path: '/booking/:token', lazy: lazyPage(() => import('./ManageBookingPage')) },
  ],
};
