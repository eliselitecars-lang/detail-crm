import { Navigate, Outlet } from 'react-router';
import { lazyPage } from '@/app/lazyPage';
import type { FeatureRoutes } from '@/app/routeTypes';
import { RequireRole } from '@/features/shop/RequireRole';

/**
 * Settings routes (see web/README.md → Routing). /app/settings/<section>;
 * Stripe Connect onboarding returns to /app/settings/payments?stripe=return|refresh.
 */
export const routes: FeatureRoutes = {
  staff: [
    {
      path: 'settings',
      element: (
        <RequireRole capability="settings.view">
          <Outlet />
        </RequireRole>
      ),
      children: [
        {
          lazy: lazyPage(() => import('./SettingsPage')),
          children: [
            { index: true, element: <Navigate to="/app/settings/business" replace /> },
            { path: 'business', lazy: lazyPage(() => import('./pages/BusinessProfilePage')) },
            { path: 'booking', lazy: lazyPage(() => import('./pages/BookingSettingsPage')) },
            { path: 'hours', lazy: lazyPage(() => import('./pages/BusinessHoursPage')) },
            { path: 'blocked-times', lazy: lazyPage(() => import('./pages/BlockedTimesPage')) },
            { path: 'resources', lazy: lazyPage(() => import('./pages/ResourcesPage')) },
            { path: 'taxes', lazy: lazyPage(() => import('./pages/TaxesPage')) },
            {
              path: 'vehicle-categories',
              lazy: lazyPage(() => import('./pages/VehicleCategoriesPage')),
            },
            { path: 'coupons', lazy: lazyPage(() => import('./pages/CouponsPage')) },
            { path: 'templates', lazy: lazyPage(() => import('./pages/TemplatesPage')) },
            { path: 'forms', lazy: lazyPage(() => import('./pages/FormsPage')) },
            {
              path: 'payments',
              element: (
                <RequireRole capability="shop.connectStripe">
                  <Outlet />
                </RequireRole>
              ),
              children: [{ index: true, lazy: lazyPage(() => import('./pages/PaymentsPage')) }],
            },
            {
              path: 'sms',
              element: (
                <RequireRole capability="shop.manageSmsNumber">
                  <Outlet />
                </RequireRole>
              ),
              children: [{ index: true, lazy: lazyPage(() => import('./pages/SmsPage')) }],
            },
            {
              path: 'delete-shop',
              element: (
                <RequireRole capability="shop.delete">
                  <Outlet />
                </RequireRole>
              ),
              children: [{ index: true, lazy: lazyPage(() => import('./pages/DeleteShopPage')) }],
            },
            { path: '*', element: <Navigate to="/app/settings/business" replace /> },
          ],
        },
      ],
    },
  ],
};
