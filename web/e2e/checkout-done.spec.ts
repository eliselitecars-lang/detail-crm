import { expect, test } from '@playwright/test';
import { mockSupabase } from './support/mockSupabase';

/**
 * Public /done/:slug: where a card-setup or membership sign-up link staff
 * texted returns after Stripe Checkout (payments setup_card_link /
 * membership_checkout, links.checkoutDone). No sign-in.
 */

const PROFILE = {
  name: 'Glacier Detailing',
  slug: 'glacier',
  logo_path: null,
  brand_color: '#1F6FEB',
  phone: '+12055550100',
  website: null,
  city: 'Birmingham',
  region: 'AL',
  country: 'US',
  timezone: 'America/Chicago',
  currency: 'usd',
  business_type: 'both',
  tax_rate_bps: 0,
  booking: {
    enabled: true,
    auto_confirm: true,
    lead_time_minutes: 60,
    max_days_ahead: 60,
    slot_interval_minutes: 30,
    require_deposit: false,
    deposit_type: null,
    deposit_value: null,
    service_area_limited: false,
    booking_message: null,
    cancellation_policy: null,
    allow_client_cancel_hours: 24,
  },
  tracking: { meta_pixel_id: null, ga4_measurement_id: null },
};

test('a saved card lands on the shop-branded confirmation, not a sign-in page', async ({
  page,
}) => {
  await mockSupabase(page, { rpc: { public_shop_profile: PROFILE } });
  await page.goto('/done/glacier?card=saved');
  await expect(
    page.getByText('Your card was saved. Glacier Detailing can now charge it for future visits.'),
  ).toBeVisible();
  await expect(page.getByText('You’re all set')).toBeVisible();
  await expect(page).toHaveURL(/\/done\/glacier\?card=saved$/);
});

test('a membership sign-up confirms and a cancelled one says nothing was charged', async ({
  page,
}) => {
  await mockSupabase(page, { rpc: { public_shop_profile: PROFILE } });
  await page.goto('/done/glacier?membership=active');
  await expect(page.getByText(/Your membership is being activated/)).toBeVisible();
  await page.goto('/done/glacier?membership=canceled');
  await expect(
    page.getByText('Membership sign-up was cancelled; nothing was charged.'),
  ).toBeVisible();
});
