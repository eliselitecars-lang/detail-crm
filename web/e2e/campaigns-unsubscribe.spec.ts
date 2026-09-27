import { expect, test } from '@playwright/test';
import { mockSupabase, reply } from './support/mockSupabase';

const TOKEN = '40000000-0000-4000-8000-0000000000aa';

const INFO = { shop_name: 'Glacier Detailing', shop_logo_path: null, unsubscribed: false };

test.describe('campaign email unsubscribe page', () => {
  test('an anonymous visitor sees the shop, confirms and is unsubscribed', async ({ page }) => {
    const calls: unknown[] = [];
    await mockSupabase(page, {
      rpc: {
        public_unsubscribe_info: INFO,
        public_unsubscribe: ({ body }) => {
          calls.push(body);
          return true;
        },
      },
    });
    await page.goto(`/u/${TOKEN}`);
    await expect(
      page.getByRole('heading', { name: 'Unsubscribe from Glacier Detailing emails' }),
    ).toBeVisible();
    // Opening the link (scanners, prefetchers) never unsubscribes.
    expect(calls).toEqual([]);

    await page.getByRole('button', { name: 'Unsubscribe' }).click();
    await expect(page.getByRole('heading', { name: 'You’re unsubscribed' })).toBeVisible();
    await expect(page.getByText(/any more emails from Glacier Detailing/)).toBeVisible();
    expect(calls).toEqual([{ p_token: TOKEN }]);
  });

  test('an address that already unsubscribed sees the done state', async ({ page }) => {
    await mockSupabase(page, {
      rpc: { public_unsubscribe_info: { ...INFO, unsubscribed: true } },
    });
    await page.goto(`/u/${TOKEN}`);
    await expect(page.getByRole('heading', { name: 'You’re unsubscribed' })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Unsubscribe' })).toHaveCount(0);
  });

  test('an unknown link (PT404) says so, and fits a 360px screen', async ({ page }) => {
    await page.setViewportSize({ width: 360, height: 740 });
    await mockSupabase(page, {
      rpc: {
        public_unsubscribe_info: reply(404, {
          code: 'PT404',
          message: 'unsubscribe link not found',
          details: null,
          hint: null,
        }),
      },
    });
    await page.goto(`/u/${TOKEN}`);
    await expect(
      page.getByRole('heading', { name: 'This unsubscribe link isn’t valid' }),
    ).toBeVisible();
    await expect(page.getByRole('button', { name: 'Unsubscribe' })).toHaveCount(0);
    const overflow = await page.evaluate(
      () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
    );
    expect(overflow).toBeLessThanOrEqual(0);
  });
});
