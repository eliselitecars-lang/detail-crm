import { expect, test } from '@playwright/test';
import { membershipRow, OWNER } from './support/fixtures';
import { mockSupabase } from './support/mockSupabase';

type Json = null | boolean | number | string | Json[] | { [key: string]: Json };
type Row = { [key: string]: Json };

const ID = '50000000-0000-4000-8000-000000000001';

test.describe('campaigns', () => {
  test('owner drafts, previews and launches a campaign', async ({ page }) => {
    let campaign: Row | null = null;
    const previews: unknown[] = [];
    const launched: unknown[] = [];

    await mockSupabase(page, {
      user: OWNER,
      tables: {
        shop_members: [membershipRow(OWNER, 'owner')],
        notifications: [],
        customers: [{ tags: ['VIP'] }],
        campaigns: ({ method, body }) => {
          if (method === 'POST') {
            campaign = {
              ...(body as Row),
              id: ID,
              status: 'draft',
              launched_at: null,
              cancelled_at: null,
              recipient_count: 0,
              created_at: '2026-03-01T15:00:00Z',
              updated_at: '2026-03-01T15:00:00Z',
            };
            return [campaign];
          }
          if (method === 'PATCH' && campaign) {
            campaign = { ...campaign, ...(body as Row) };
            return [campaign];
          }
          return campaign ? [campaign] : [];
        },
        messages: [],
      },
      counts: { messages: 0 },
      rpc: {
        preview_campaign_audience: ({ body }) => {
          previews.push(body);
          return 12;
        },
        launch_campaign: ({ body }) => {
          launched.push(body);
          campaign = {
            ...campaign,
            status: 'launched',
            launched_at: '2026-03-02T15:00:00Z',
            recipient_count: 12,
          };
          return campaign;
        },
      },
    });

    await page.goto('/app/campaigns');
    await expect(page.getByText('No campaigns yet')).toBeVisible();
    await page.getByRole('link', { name: 'New campaign' }).click();
    await expect(page.getByRole('heading', { name: 'New campaign', level: 1 })).toBeVisible();

    await page.getByRole('textbox', { name: /Campaign name/ }).fill('Spring special');
    await page.getByRole('textbox', { name: /^Message/ }).fill('Spring slots are open, ');
    await page.getByRole('button', { name: /Insert \{\{customer_first_name\}\}/ }).click();
    await expect(page.getByRole('textbox', { name: /^Message/ })).toHaveValue(
      'Spring slots are open, {{customer_first_name}}',
    );
    await page.getByRole('combobox', { name: /Tags/ }).fill('VIP');
    await page.getByRole('combobox', { name: /Tags/ }).press('Enter');
    await page.getByRole('combobox', { name: 'Lifecycle' }).selectOption('customer');
    await expect(page.getByText('Estimated recipients:')).toContainText('12');
    await expect
      .poll(() => previews.at(-1))
      .toEqual({
        p_shop_id: expect.any(String),
        p_channel: 'sms',
        p_audience: { tags: ['VIP'], lifecycle: 'customer' },
      });

    await page.getByRole('button', { name: 'Review & launch' }).click();
    const dialog = page.getByRole('dialog', { name: 'Launch this campaign?' });
    await expect(dialog).toContainText('Recipients right now: 12');
    await dialog.getByRole('button', { name: 'Launch campaign' }).click();

    await expect(page).toHaveURL(new RegExp(`/app/campaigns/${ID}$`));
    await expect(page.getByText('Campaign launched to 12 recipients')).toBeVisible();
    expect(launched).toEqual([{ p_campaign_id: ID }]);
    await expect(page.getByRole('heading', { name: 'Delivery' })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Cancel unsent messages' })).toBeVisible();
  });
});
