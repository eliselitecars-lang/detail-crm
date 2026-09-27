import type { RouteObject } from 'react-router';

/**
 * What every `src/features/<name>/routes.tsx` exports as `routes`.
 *
 * - `staff`: children of `/app`, rendered inside AppShell for users with a
 *   current shop. Paths are RELATIVE ("jobs", "jobs/:jobId"; `index: true`
 *   for the dashboard).
 * - `public`: top-level routes with ABSOLUTE paths ("/book/:slug"). They
 *   render without the staff shell (use PublicLayout).
 *
 * Every top-level route gets RouteErrorBoundary unless it defines its own.
 */
export interface FeatureRoutes {
  staff?: RouteObject[];
  public?: RouteObject[];
}
