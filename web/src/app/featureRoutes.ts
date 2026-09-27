/**
 * Route registry. Every feature exports `routes` from
 * src/features/<name>/routes.tsx; this is the only place they are collected,
 * so feature work never touches shared routing files.
 */
import type { RouteObject } from 'react-router';
import { routes as auth } from '@/features/auth/routes';
import { routes as booking } from '@/features/booking/routes';
import { routes as calendar } from '@/features/calendar/routes';
import { routes as campaigns } from '@/features/campaigns/routes';
import { routes as catalog } from '@/features/catalog/routes';
import { routes as customers } from '@/features/customers/routes';
import { routes as dashboard } from '@/features/dashboard/routes';
import { routes as invoices } from '@/features/invoices/routes';
import { routes as jobs } from '@/features/jobs/routes';
import { routes as legal } from '@/features/legal/routes';
import { routes as memberships } from '@/features/memberships/routes';
import { routes as messages } from '@/features/messages/routes';
import { routes as notifications } from '@/features/notifications/routes';
import { routes as payments } from '@/features/payments/routes';
import { routes as portal } from '@/features/portal/routes';
import { routes as publicDocs } from '@/features/public-docs/routes';
import { routes as quotes } from '@/features/quotes/routes';
import { routes as reports } from '@/features/reports/routes';
import { routes as settings } from '@/features/settings/routes';
import { routes as team } from '@/features/team/routes';
import { routes as timesheets } from '@/features/timesheets/routes';
import type { FeatureRoutes } from './routeTypes';
import { RouteErrorBoundary } from './RouteErrorBoundary';

export const FEATURES: Readonly<Record<string, FeatureRoutes>> = {
  auth,
  booking,
  calendar,
  campaigns,
  catalog,
  customers,
  dashboard,
  invoices,
  jobs,
  legal,
  memberships,
  messages,
  notifications,
  payments,
  portal,
  publicDocs,
  quotes,
  reports,
  settings,
  team,
  timesheets,
};

/** Adds the shared error boundary to routes that don't define their own. */
function withBoundary(route: RouteObject): RouteObject {
  if (route.ErrorBoundary || route.errorElement) return route;
  return { ...route, ErrorBoundary: RouteErrorBoundary };
}

export const staffRoutes: RouteObject[] = Object.values(FEATURES).flatMap((f) =>
  (f.staff ?? []).map(withBoundary),
);
export const publicRoutes: RouteObject[] = Object.values(FEATURES).flatMap((f) =>
  (f.public ?? []).map(withBoundary),
);
