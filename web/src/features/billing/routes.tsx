import { lazyPage } from '@/app/lazyPage';
import type { FeatureRoutes } from '@/app/routeTypes';
import { PRICING_PATH } from './model';

/**
 * Platform billing. Public: /pricing (the platform's plans, no sign-in).
 * Staff: Settings > Billing is a settings section (features/settings/routes.tsx,
 * /app/settings/billing), so it lives in the settings layout and sub-nav.
 */
export const routes: FeatureRoutes = {
  public: [{ path: PRICING_PATH, lazy: lazyPage(() => import('./PricingPage')) }],
};
