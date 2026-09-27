import { expect, test } from '@playwright/test';
import { mockSupabase } from './support/mockSupabase';

const TOKEN = '40000000-0000-4000-8000-0000000000aa';

test.describe('campaign email unsubscribe page', () => {
  test('an anonymous visitor confirms and is unsubscribed', async ({ page }) => {
    const calls: unknown[] = [];
    await mockSupabase(page, {
      rpc: {
        public_unsubscribe: ({ body }) => {
          calls.push(body);
          return true;
        },
      },
    });
    await page.goto(`/u/${TOKEN}`);
    await expect(page.getByRole('heading', { name: 'Unsubscribe from emails' })).toBeVisible();
    expect(calls).toEqual([]);

    await page.getByRole('button', { name: 'Unsubscribe' }).click();
    await expect(page.getByRole('heading', { name: 'You’re unsubscribed' })).toBeVisible();
    expect(calls).toEqual([{ p_token: TOKEN }]);
  });

  test('an unknown link says so, and fits a 360px screen', async ({ page }) => {
    await page.setViewportSize({ width: 360, height: 740 });
    await mockSupabase(page, { rpc: { public_unsubscribe: false } });
    await page.goto(`/u/${TOKEN}`);
    await page.getByRole('button', { name: 'Unsubscribe' }).click();
    await expect(
      page.getByRole('heading', { name: 'This unsubscribe link isn’t valid' }),
    ).toBeVisible();
    const overflow = await page.evaluate(
      () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
    );
    expect(overflow).toBeLessThanOrEqual(0);
  });
});
