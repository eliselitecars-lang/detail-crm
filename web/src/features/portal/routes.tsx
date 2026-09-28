import { Outlet } from 'react-router';
import { lazyPage } from '@/app/lazyPage';
import type { FeatureRoutes } from '@/app/routeTypes';
import { RequireAuth } from '@/features/auth/RequireAuth';
import { CHECKOUT_DONE_PATH, CUSTOMER_PORTAL_PATH } from './paths';

/**
 * Client portal. Signed-out visitors go to /login?next=/portal (the auth
 * pages link to sign-up with the same `next`). /done/:slug is the public
 * (no sign-in) page a staff-sent card-setup or membership Checkout returns
 * to (the payments function's links.checkoutDone).
 */
export const routes: FeatureRoutes = {
  public: [
    { path: CHECKOUT_DONE_PATH, lazy: lazyPage(() => import('./CheckoutDonePage')) },
    {
      path: CUSTOMER_PORTAL_PATH,
      element: (
        <RequireAuth>
          <Outlet />
        </RequireAuth>
      ),
      children: [{ index: true, lazy: lazyPage(() => import('./PortalPage')) }],
    },
  ],
};
