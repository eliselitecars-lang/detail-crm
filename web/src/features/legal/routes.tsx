import { lazyPage } from '@/app/lazyPage';
import type { FeatureRoutes } from '@/app/routeTypes';
import { PRIVACY_PATH, TERMS_PATH } from './paths';

/**
 * The operator's Privacy Policy and Terms of Service: public, no sign-in
 * (App Store Connect asks for the privacy policy URL; see docs/LAUNCH.md).
 */
export const routes: FeatureRoutes = {
  public: [
    { path: PRIVACY_PATH, lazy: lazyPage(() => import('./PrivacyPage')) },
    { path: TERMS_PATH, lazy: lazyPage(() => import('./TermsPage')) },
  ],
};
