import { Outlet } from 'react-router';
import type { RouteObject } from 'react-router';
import { lazyPage } from '@/app/lazyPage';
import type { FeatureRoutes } from '@/app/routeTypes';
import type { ComponentType } from 'react';
import { RequireRole } from '@/features/shop/RequireRole';
import { SettingsIndexRedirect } from './SettingsIndexRedirect';
import { sectionByPath, type SettingsSectionPath } from './sections';

type PageLoader = () => Promise<{ default: ComponentType }>;

/** One settings section, guarded by its `view` capability (sections.ts). */
function section(path: SettingsSectionPath, loader: PageLoader): RouteObject {
  return {
    path,
    element: (
      <RequireRole capability={sectionByPath(path).view}>
        <Outlet />
      </RequireRole>
    ),
    children: [{ index: true, lazy: lazyPage(loader) }],
  };
}

/**
 * Settings routes (see web/README.md → Routing). /app/settings/<section>;
 * Stripe Connect onboarding returns to /app/settings/payments?stripe=return|refresh.
 * Every section has its own guard: most are for managers and up, the
 * calendar feed is for every member (technicians see only that section).
 */
export const routes: FeatureRoutes = {
  staff: [
    {
      path: 'settings',
      lazy: lazyPage(() => import('./SettingsPage')),
      children: [
        { index: true, element: <SettingsIndexRedirect /> },
        section('business', () => import('./pages/BusinessProfilePage')),
        section('booking', () => import('./pages/BookingSettingsPage')),
        section('booking-links', () => import('./pages/BookingLinksPage')),
        section('hours', () => import('./pages/BusinessHoursPage')),
        section('blocked-times', () => import('./pages/BlockedTimesPage')),
        section('resources', () => import('./pages/ResourcesPage')),
        section('taxes', () => import('./pages/TaxesPage')),
        section('vehicle-categories', () => import('./pages/VehicleCategoriesPage')),
        section('custom-fields', () => import('./pages/CustomFieldsPage')),
        section('lead-forms', () => import('./pages/LeadFormsPage')),
        section('fees', () => import('./pages/FeesPage')),
        section('coupons', () => import('./pages/CouponsPage')),
        section('gift-cards', () => import('./pages/GiftCardSettingsPage')),
        section('referrals', () => import('./pages/ReferralSettingsPage')),
        section('templates', () => import('./pages/TemplatesPage')),
        section('followups', () => import('./pages/FollowupsPage')),
        section('forms', () => import('./pages/FormsPage')),
        section('payments', () => import('./pages/PaymentsPage')),
        section('sms', () => import('./pages/SmsPage')),
        section('import-export', () => import('./pages/ImportExportPage')),
        section('webhooks', () => import('./pages/WebhooksPage')),
        section('calendar-feed', () => import('./pages/CalendarFeedPage')),
        section('delete-shop', () => import('./pages/DeleteShopPage')),
        { path: '*', element: <SettingsIndexRedirect /> },
      ],
    },
  ],
};
