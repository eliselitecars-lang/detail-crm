import { expect, test } from '@playwright/test';
import { mockSupabase, reply } from './support/mockSupabase';

const TOKEN = '40000000-0000-4000-8000-0000000000aa';

const INFO = {
  shop_name: 'Glacier Detailing',
  shop_logo_path: null,
  unsubscribed: false,
  scope: null,
  can_resubscribe: true,
};
const STILL_SENT = 'booking confirmations, appointment reminders, quotes, invoices and receipts';

test.describe('campaign email unsubscribe page', () => {
  test('an anonymous visitor is told marketing stops (not receipts), confirms and is unsubscribed', async ({
    page,
  }) => {
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
      page.getByRole('heading', { name: 'Unsubscribe from Glacier Detailing marketing emails' }),
    ).toBeVisible();
    // 0126: the link ends marketing only; say so before the click.
    await expect(page.getByText(/campaigns, promotions and service follow-ups/)).toBeVisible();
    await expect(
      page.getByText(`You’ll still get ${STILL_SENT} from Glacier Detailing.`),
    ).toBeVisible();
    await expect(page.getByText(/all of their emails|can’t be undone/)).toHaveCount(0);
    // Opening the link (scanners, prefetchers) never unsubscribes.
    expect(calls).toEqual([]);

    await page.getByRole('button', { name: 'Unsubscribe' }).click();
    await expect(page.getByRole('heading', { name: 'You’re unsubscribed' })).toBeVisible();
    await expect(
      page.getByText(/Glacier Detailing won’t send marketing emails .* to this address any more/),
    ).toBeVisible();
    await expect(
      page.getByText(`You’ll still get ${STILL_SENT} from them.`, { exact: false }),
    ).toBeVisible();
    // No way back is promised: this page offers none, and the shop can't opt the address back in.
    await expect(page.getByText(/resubscribe|opt back in/i)).toHaveCount(0);
    expect(calls).toEqual([{ p_token: TOKEN }]);
  });

  test('an address that already unsubscribed from marketing sees the done state', async ({
    page,
  }) => {
    await mockSupabase(page, {
      rpc: { public_unsubscribe_info: { ...INFO, unsubscribed: true, scope: 'marketing' } },
    });
    await page.goto(`/u/${TOKEN}`);
    await expect(page.getByRole('heading', { name: 'You’re unsubscribed' })).toBeVisible();
    await expect(page.getByText(/You’ll still get booking confirmations/)).toBeVisible();
    await expect(page.getByRole('button', { name: 'Unsubscribe' })).toHaveCount(0);
  });

  test('an address opted out of every email is told nothing is sent to it', async ({ page }) => {
    await mockSupabase(page, {
      rpc: { public_unsubscribe_info: { ...INFO, unsubscribed: true, scope: 'all' } },
    });
    await page.goto(`/u/${TOKEN}`);
    await expect(page.getByRole('heading', { name: 'You’re unsubscribed' })).toBeVisible();
    await expect(
      page.getByText(`opted out of all emails from Glacier Detailing, including ${STILL_SENT}`, {
        exact: false,
      }),
    ).toBeVisible();
    await expect(page.getByText(/You’ll still get/)).toHaveCount(0);
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
