import { lazyPage } from '@/app/lazyPage';
import type { FeatureRoutes } from '@/app/routeTypes';

/** Public public-docs routes (see web/README.md → Routing). */
export const routes: FeatureRoutes = {
  public: [
    { path: '/q/:token', lazy: lazyPage(() => import('./QuotePage')) },
    { path: '/i/:token', lazy: lazyPage(() => import('./InvoicePage')) },
    { path: '/f/:token', lazy: lazyPage(() => import('./FormPage')) },
  ],
};
