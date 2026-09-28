import { Outlet } from 'react-router';
import { lazyPage } from '@/app/lazyPage';
import type { FeatureRoutes } from '@/app/routeTypes';
import { RequireRole } from '@/features/shop/RequireRole';

/** Gift cards: staff /app/gift-cards, public /gift/:slug and /gift/:slug/done. */
export const routes: FeatureRoutes = {
  staff: [
    {
      path: 'gift-cards',
      element: (
        <RequireRole capability="giftCards.view">
          <Outlet />
        </RequireRole>
      ),
      children: [
        { index: true, lazy: lazyPage(() => import('./GiftCardsPage')) },
        { path: ':giftCardId', lazy: lazyPage(() => import('./GiftCardDetailPage')) },
      ],
    },
  ],
  public: [
    { path: '/gift/:slug', lazy: lazyPage(() => import('./GiftCardShopPage')) },
    { path: '/gift/:slug/done', lazy: lazyPage(() => import('./GiftCardOrderDonePage')) },
  ],
};
