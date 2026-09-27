import { Outlet } from 'react-router';
import { lazyPage } from '@/app/lazyPage';
import type { FeatureRoutes } from '@/app/routeTypes';
import { RequireRole } from '@/features/shop/RequireRole';

/** Campaigns routes (see web/README.md → Routing). */
export const routes: FeatureRoutes = {
  staff: [
    {
      path: 'campaigns',
      element: (
        <RequireRole capability="campaigns.manage">
          <Outlet />
        </RequireRole>
      ),
      children: [
        { index: true, lazy: lazyPage(() => import('./CampaignsPage')) },
        { path: 'new', lazy: lazyPage(() => import('./CampaignNewPage')) },
        { path: ':campaignId', lazy: lazyPage(() => import('./CampaignDetailPage')) },
      ],
    },
  ],
  public: [
    // Every marketing email's unsubscribe link ({{unsubscribe_link}} renders
    // as app_url('/u/<unsubscribe token>')); no sign-in.
    { path: '/u/:token', lazy: lazyPage(() => import('./UnsubscribePage')) },
  ],
};
