import { expect, test } from '@playwright/test';
import { mockSupabase } from './support/mockSupabase';

/** Public /join/:slug (P-23): plans sold online → Stripe subscription Checkout. */

const CHECKOUT_URL = 'https://checkout.stripe.test/c/pay/cs_test_join';

const PLANS = {
  shop: { name: 'Glacier Detailing', logo_path: null, brand_color: '#1F6FEB' },
  plans: [
    {
      id: '71111111-1111-4111-8111-111111111111',
      name: 'Wash Club',
      description: 'A maintenance wash every other week.',
      price_cents: 4900,
      interval: 'month',
      interval_count: 1,
      included_services: ['Maintenance wash'],
      discount_bps: 1000,
      uses_per_period: 2,
      vehicle_scoped: false,
      terms: null,
    },
  ],
  currency: 'usd',
};

test('a customer joins a membership online', async ({ page }) => {
  const bodies: unknown[] = [];
  await mockSupabase(page, {
    rpc: { public_membership_plans: PLANS },
    functions: {
      payments: ({ body }) => {
        bodies.push(body);
        return {
          url: CHECKOUT_URL,
          expires_at: 1790000000,
          amount_cents: 4900,
          interval: 'month',
          interval_count: 1,
          currency: 'usd',
        };
      },
    },
  });
  await page.route(`${CHECKOUT_URL}**`, (route) =>
    route.fulfill({ status: 200, contentType: 'text/html', body: '<h1>Stripe checkout</h1>' }),
  );
  await page.goto('/join/glacier');
  await expect(page.getByRole('heading', { name: 'Memberships', level: 1 })).toBeVisible();
  await expect(page.getByText('$49.00 / month')).toBeVisible();
  await expect(page.getByText(/2 visits per billing period/)).toBeVisible();
  await page.getByRole('button', { name: 'Choose Wash Club' }).click();
  await page.getByLabel(/^First name/).fill('Ana');
  await page.getByLabel(/^Last name/).fill('Diaz');
  await page.getByRole('textbox', { name: 'Email' }).fill('ana@example.com');
  await page.getByLabel(/^Mobile phone/).fill('(205) 555-0123');
  await page.getByRole('button', { name: 'Continue to payment' }).click();
  await expect(page.getByRole('heading', { name: 'Stripe checkout' })).toBeVisible();
  expect(bodies[0]).toEqual({
    action: 'membership_join_checkout',
    slug: 'glacier',
    plan_id: '71111111-1111-4111-8111-111111111111',
    customer: {
      first_name: 'Ana',
      last_name: 'Diaz',
      email: 'ana@example.com',
      phone: '+12055550123',
      sms_opt_in: false,
      email_opt_in: false,
    },
    request_nonce: expect.stringMatching(/^[A-Za-z0-9_-]{8,64}$/),
  });
});

test('the join page fits a 360px phone', async ({ page }) => {
  await page.setViewportSize({ width: 360, height: 740 });
  await mockSupabase(page, { rpc: { public_membership_plans: PLANS } });
  await page.goto('/join/glacier?joined=1');
  await expect(page.getByText('Welcome aboard!')).toBeVisible();
  const overflow = await page.evaluate(
    () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
  );
  expect(overflow).toBeLessThanOrEqual(0);
});
