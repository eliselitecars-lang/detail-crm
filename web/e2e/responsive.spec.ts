import { expect, test, type Page } from '@playwright/test';
import { membershipRow, OWNER } from './support/fixtures';
import { mockSupabase } from './support/mockSupabase';

/** Phone-width regressions: no screen may scroll sideways at 360px. */

const PHONE = { width: 360, height: 740 };

async function horizontalOverflow(page: Page): Promise<number> {
  return page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
}

/** Every matching element's box must sit inside `container`'s box. */
async function expectInside(page: Page, selector: string, container: string) {
  const outside = await page.evaluate(
    ({ selector, container }) => {
      const box = document.querySelector(container)?.getBoundingClientRect();
      if (!box) return ['<container missing>'];
      return Array.from(document.querySelectorAll(selector))
        .filter((el) => {
          const r = el.getBoundingClientRect();
          return r.left < box.left - 0.5 || r.right > box.right + 0.5;
        })
        .map((el) => el.getAttribute('aria-label') ?? el.textContent ?? el.tagName);
    },
    { selector, container },
  );
  expect(outside).toEqual([]);
}

test.describe('360px layouts', () => {
  test.use({ viewport: PHONE });

  test('onboarding business hours fit inside the card', async ({ page }) => {
    await mockSupabase(page, { user: OWNER, tables: { shop_members: [] } });
    await page.goto('/app/onboarding');
    await page.getByLabel(/Shop name/).fill('Glacier Detailing');
    await page.getByRole('button', { name: 'Continue' }).click();
    await expect(page.getByRole('heading', { name: 'Contact & location' })).toBeVisible();
    expect(await horizontalOverflow(page)).toBeLessThanOrEqual(0);
    await page.getByRole('button', { name: 'Continue' }).click();
    await expect(page.getByRole('heading', { name: 'Taxes & hours' })).toBeVisible();

    // Worst case: two ranges on a day (remove + add buttons on the same day).
    await page.getByRole('button', { name: 'Add time range for Monday' }).click();
    await expect(page.getByLabel('Monday opens at')).toHaveCount(2);

    expect(await horizontalOverflow(page)).toBeLessThanOrEqual(0);
    await expectInside(page, 'form [role="switch"], form button, form input', 'form');
    // Native time inputs clip "08:00 AM" silently (no overflow), so assert a
    // usable width: the pair shares the row instead of being squeezed.
    const widths = await page
      .locator('input[type="time"]')
      .evaluateAll((inputs) => inputs.map((input) => input.getBoundingClientRect().width));
    expect(widths.length).toBeGreaterThan(0);
    for (const width of widths) expect(width).toBeGreaterThanOrEqual(112);
  });

  const token = '6f1c2f7e-4c9b-4f55-9d7a-0b3e2a1c9d10';
  const longEmail = 'christopher.washington-montgomery@detailprofessionals.example.com';
  const invite = {
    shop_name: 'Glacier Detailing',
    shop_slug: 'glacier-detailing',
    role: 'technician',
    email: longEmail,
    expires_at: '2030-01-01T00:00:00Z',
    status: 'pending',
  };

  test('invite page wraps long email addresses (signed out)', async ({ page }) => {
    await mockSupabase(page, { rpc: { public_get_invite: [invite] } });
    await page.goto(`/invite/${token}`);
    await expect(page.getByRole('heading', { name: 'Join Glacier Detailing' })).toBeVisible();
    await expect(page.getByText(longEmail).first()).toBeVisible();
    expect(await horizontalOverflow(page)).toBeLessThanOrEqual(0);
    await expectInside(page, 'dt, dd, p', 'main');
  });

  test('invite email-mismatch alert wraps long addresses (signed in)', async ({ page }) => {
    await mockSupabase(page, { user: OWNER, rpc: { public_get_invite: [invite] } });
    await page.goto(`/invite/${token}`);
    await expect(page.getByRole('alert')).toContainText('signed in as');
    expect(await horizontalOverflow(page)).toBeLessThanOrEqual(0);
    await expectInside(page, '[role="alert"], dd', 'main');
  });

  // Shop subscription billing (test data: a long plan name and description,
  // a long feature key, a lapsed shop's banner).
  const plans = [
    {
      id: '30000000-0000-4000-8000-000000000001',
      name: 'Professional Detailing Studio Unlimited',
      description:
        'For multi-bay studios with mobile vans, ceramic coating, window tint and paint protection film crews',
      amount_cents: 1234500,
      currency: 'usd',
      interval: 'month',
      interval_count: 3,
      max_members: 25,
      features: ['online_booking_with_deposits_and_private_links', 'two-way-text-messages'],
    },
  ];
  const lapsed = {
    billing_enabled: true,
    state: 'lapsed',
    reason: 'trial_ended',
    plan_name: null,
    trial_ends_at: '2026-01-01T00:00:00Z',
    current_period_end: null,
    cancel_at_period_end: false,
    max_members: null,
    members_used: 3,
    can_write: false,
    is_owner: true,
  };

  test('pricing page cards fit (signed out)', async ({ page }) => {
    await mockSupabase(page, {
      rpc: { public_billing_offer: { plans, trial_days: 14, trial_available: null } },
    });
    await page.goto('/pricing');
    await expect(page.getByRole('article', { name: plans[0]!.name })).toBeVisible();
    expect(await horizontalOverflow(page)).toBeLessThanOrEqual(0);
    await expectInside(page, 'article, article li, main a', 'main');
  });

  test('pricing coming soon fits (signed out)', async ({ page }) => {
    await mockSupabase(page, {
      rpc: { public_billing_offer: { plans: [], trial_days: 0, trial_available: null } },
    });
    await page.goto('/pricing');
    await expect(page.getByText('Pricing coming soon')).toBeVisible();
    expect(await horizontalOverflow(page)).toBeLessThanOrEqual(0);
  });

  test('Settings > Billing and the lapsed banner fit', async ({ page }) => {
    await mockSupabase(page, {
      user: OWNER,
      tables: {
        shop_members: [membershipRow(OWNER, 'owner')],
        notifications: [],
        shop_billing: [
          {
            plan_id: null,
            status: 'canceled',
            trial_ends_at: null,
            current_period_end: '2026-01-01T00:00:00Z',
            cancel_at_period_end: false,
          },
        ],
      },
      rpc: { shop_entitlement: lapsed, public_billing_plans: plans },
    });
    await page.goto('/app/notifications');
    await expect(page.getByLabel('Subscription notice', { exact: true })).toBeVisible();
    expect(await horizontalOverflow(page)).toBeLessThanOrEqual(0);
    await expectInside(page, '[aria-label="Subscription notice"]', 'main');

    await page.goto('/app/settings/billing');
    await expect(page.getByRole('article', { name: plans[0]!.name })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Manage billing' })).toBeVisible();
    expect(await horizontalOverflow(page)).toBeLessThanOrEqual(0);
    await expectInside(page, 'article, dl, main button', 'main');
  });
});
