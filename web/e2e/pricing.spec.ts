import { expect, test } from '@playwright/test';
import { mockSupabase } from './support/mockSupabase';

/**
 * Public /pricing (the platform's plans, signed out): everything shown comes
 * from public_billing_plans() (anon); without plans it says pricing is
 * coming soon and shows no numbers. Plans below are test data.
 */

const PLANS = [
  {
    id: '30000000-0000-4000-8000-000000000001',
    name: 'Solo',
    description: 'One detailer',
    amount_cents: 2900,
    currency: 'usd',
    interval: 'month',
    interval_count: 1,
    max_members: 1,
    features: ['online_booking'],
  },
  {
    id: '30000000-0000-4000-8000-000000000002',
    name: 'Shop',
    description: null,
    amount_cents: 99000,
    currency: 'usd',
    interval: 'year',
    interval_count: 1,
    max_members: null,
    features: [],
  },
];

test.describe('/pricing', () => {
  test('lists the server’s plans and links to sign-up', async ({ page }) => {
    let calls = 0;
    await mockSupabase(page, {
      rpc: {
        public_billing_plans: () => {
          calls += 1;
          return PLANS;
        },
      },
    });
    await page.goto('/pricing');
    await expect(page.getByRole('heading', { name: 'Pricing', level: 1 })).toBeVisible();
    await expect(page).toHaveTitle('Pricing · Detail CRM');
    const solo = page.getByRole('article', { name: 'Solo' });
    await expect(solo).toContainText('$29');
    await expect(solo).toContainText('per month');
    await expect(solo).toContainText('1 team member');
    await expect(solo).toContainText('Online booking');
    const shop = page.getByRole('article', { name: 'Shop' });
    await expect(shop).toContainText('$990');
    await expect(shop).toContainText('per year');
    await expect(shop).toContainText('Unlimited team members');
    expect(calls).toBe(1);

    await page.getByRole('link', { name: 'Create your shop' }).click();
    await expect(page).toHaveURL(/\/signup$/);
  });

  test('without plans (billing off) says pricing is coming soon, with no numbers', async ({
    page,
  }) => {
    await mockSupabase(page, { rpc: { public_billing_plans: [] } });
    await page.goto('/pricing');
    await expect(page.getByText('Pricing coming soon')).toBeVisible();
    await expect(page.getByRole('article')).toHaveCount(0);
    await expect(page.getByRole('main')).not.toContainText(/[$€£]\s?\d/);
    await expect(page.getByRole('link', { name: 'Create your shop' })).toHaveAttribute(
      'href',
      '/signup',
    );
    // legal links in the footer, like every public page
    await expect(page.getByRole('link', { name: 'Terms of Service' })).toBeVisible();
  });
});
