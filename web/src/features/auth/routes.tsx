import { lazyPage } from '@/app/lazyPage';
import type { FeatureRoutes } from '@/app/routeTypes';

/** Sign-in, sign-up, password recovery and invite acceptance. */
export const routes: FeatureRoutes = {
  public: [
    { path: '/login', lazy: lazyPage(() => import('./pages/LoginPage')) },
    { path: '/signup', lazy: lazyPage(() => import('./pages/SignupPage')) },
    { path: '/forgot-password', lazy: lazyPage(() => import('./pages/ForgotPasswordPage')) },
    { path: '/reset-password', lazy: lazyPage(() => import('./pages/ResetPasswordPage')) },
    { path: '/invite/:token', lazy: lazyPage(() => import('./pages/InvitePage')) },
  ],
};
