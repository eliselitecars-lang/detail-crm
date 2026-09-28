import { screen } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { publicRoutes } from '@/app/featureRoutes';
import { renderRoute } from '@/test/render';
import { mockRpc, pgError, resetSupabaseMock } from '@/test/supabaseMock';
import { profileFixture } from '@/features/booking/testFixtures';
import CheckoutDonePage from './CheckoutDonePage';
import { CHECKOUT_DONE_PATH } from './paths';
import { checkoutOutcome } from './returnNotice';

vi.mock('@/lib/supabase', () => import('@/test/supabaseMock'));

function render(path: string) {
  return renderRoute(<CheckoutDonePage />, { path, routePath: CHECKOUT_DONE_PATH, shop: null });
}

beforeEach(() => {
  resetSupabaseMock();
});

describe('checkoutOutcome', () => {
  it('reads the card and membership return values the payments function sets', () => {
    expect(checkoutOutcome(new URLSearchParams('card=saved'))).toEqual({
      kind: 'card',
      value: 'saved',
    });
    expect(checkoutOutcome(new URLSearchParams('membership=canceled'))).toEqual({
      kind: 'membership',
      value: 'canceled',
    });
    expect(checkoutOutcome(new URLSearchParams('card=stolen'))).toBeNull();
    expect(checkoutOutcome(new URLSearchParams(''))).toBeNull();
  });
});

describe('CheckoutDonePage', () => {
  it('is a public route at the path the payments function returns to', () => {
    // supabase/functions/_shared/links.ts checkoutDone: APP_BASE_URL/done/<slug>
    expect(CHECKOUT_DONE_PATH).toBe('/done/:slug');
    expect(publicRoutes.map((r) => r.path)).toContain(CHECKOUT_DONE_PATH);
  });

  it('confirms a saved card with the shop branding, no sign-in needed', async () => {
    const calls = mockRpc({ public_shop_profile: { data: profileFixture() } });
    render('/done/Glacier?card=saved');
    expect(
      await screen.findByText(
        'Your card was saved. Glacier Detailing can now charge it for future visits.',
      ),
    ).toBeInTheDocument();
    expect(screen.getByText('You’re all set')).toBeInTheDocument();
    expect(calls[0]).toEqual({ fn: 'public_shop_profile', args: { p_slug: 'glacier' } });
  });

  it('confirms a membership sign-up and points to the portal for later changes', async () => {
    mockRpc({ public_shop_profile: { data: profileFixture() } });
    render('/done/glacier?membership=active');
    expect(await screen.findByText(/Your membership is being activated/)).toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'sign in to your account' })).toHaveAttribute(
      'href',
      '/portal',
    );
  });

  it('explains a cancelled checkout', async () => {
    mockRpc({ public_shop_profile: { data: profileFixture() } });
    render('/done/glacier?membership=canceled');
    expect(
      await screen.findByText('Membership sign-up was cancelled; nothing was charged.'),
    ).toBeInTheDocument();
    expect(screen.getByText(/open the link you were sent again/)).toBeInTheDocument();
  });

  it('still shows the outcome when the shop profile cannot be read', async () => {
    mockRpc({ public_shop_profile: pgError('PT404', 'shop not found') });
    render('/done/glacier?card=saved');
    expect(
      await screen.findByText('Your card was saved. The shop can now charge it for future visits.'),
    ).toBeInTheDocument();
  });

  it('is a calm not-found for a link without an outcome', () => {
    mockRpc({});
    render('/done/glacier');
    expect(screen.getByText('We couldn’t find this page')).toBeInTheDocument();
  });
});
