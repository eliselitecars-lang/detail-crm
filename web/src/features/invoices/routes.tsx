import { Outlet } from 'react-router';
import { lazyPage } from '@/app/lazyPage';
import type { FeatureRoutes } from '@/app/routeTypes';
import { RequireRole } from '@/features/shop/RequireRole';

/**
 * Invoices routes (see web/README.md → Routing). The list and ad-hoc
 * creation are manager+; an invoice page is also open to technicians when
 * the shop lets them collect payments (RLS returns only invoices of jobs
 * assigned to them).
 */
export const routes: FeatureRoutes = {
  staff: [
    {
      path: 'invoices',
      element: (
        <RequireRole capability="invoices.viewAssigned">
          <Outlet />
        </RequireRole>
      ),
      children: [
        {
          // pathless layout: the list itself is manager+
          element: (
            <RequireRole capability="invoices.view">
              <Outlet />
            </RequireRole>
          ),
          children: [{ index: true, lazy: lazyPage(() => import('./InvoicesPage')) }],
        },
        {
          path: 'new',
          element: (
            <RequireRole capability="invoices.manage">
              <Outlet />
            </RequireRole>
          ),
          children: [{ index: true, lazy: lazyPage(() => import('./InvoiceNewPage')) }],
        },
        { path: ':invoiceId', lazy: lazyPage(() => import('./InvoiceDetailPage')) },
      ],
    },
  ],
};
