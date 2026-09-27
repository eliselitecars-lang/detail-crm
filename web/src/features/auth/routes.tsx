import { Outlet } from 'react-router';
import { lazyPage } from '@/app/lazyPage';
import type { FeatureRoutes } from '@/app/routeTypes';
import { RequireAuth } from './RequireAuth';

/** Sign-in, sign-up, password recovery, invite acceptance and the user's own account. */
export const routes: FeatureRoutes = {
  public: [
    { path: '/login', lazy: lazyPage(() => import('./pages/LoginPage')) },
    { path: '/signup', lazy: lazyPage(() => import('./pages/SignupPage')) },
    { path: '/forgot-password', lazy: lazyPage(() => import('./pages/ForgotPasswordPage')) },
    { path: '/reset-password', lazy: lazyPage(() => import('./pages/ResetPasswordPage')) },
    { path: '/invite/:token', lazy: lazyPage(() => import('./pages/InvitePage')) },
    {
      // Every signed-in role (staff and portal clients): delete account.
      path: '/account',
      element: (
        <RequireAuth>
          <Outlet />
        </RequireAuth>
      ),
      children: [{ index: true, lazy: lazyPage(() => import('./pages/AccountPage')) }],
    },
  ],
};
