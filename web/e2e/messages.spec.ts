import { expect, test, type Page } from '@playwright/test';
import { membershipRow, OWNER, TECH } from './support/fixtures';
import { mockSupabase, SUPABASE_URL } from './support/mockSupabase';

const casey = {
  id: '30000000-0000-4000-8000-000000000001',
  first_name: 'Casey',
  last_name: 'Jones',
  company: null,
  phone: '+12055550101',
  email: 'casey@example.com',
  sms_opt_in: true,
  email_opt_in: true,
  sms_opted_out_at: null,
  email_opted_out_at: null,
  archived_at: null,
};

const inbound = {
  id: '40000000-0000-4000-8000-000000000001',
  customer_id: casey.id,
  job_id: null,
  campaign_id: null,
  direction: 'inbound',
  channel: 'sms',
  to_address: '+12055550100',
  from_address: casey.phone,
  subject: null,
  body: 'Can you do Saturday instead?',
  status: 'received',
  error: null,
  template_key: null,
  read_at: null,
  send_after: '2026-03-10T14:00:00Z',
  sent_at: null,
  delivered_at: null,
  created_at: '2026-03-10T14:00:00Z',
  customer: casey,
};

/** Intercepts the messaging edge function; returns the JSON bodies it received. */
async function mockMessaging(page: Page) {
  const calls: unknown[] = [];
  await page.route(`${SUPABASE_URL}/functions/v1/messaging`, async (route) => {
    const headers = {
      'access-control-allow-origin': '*',
      'access-control-allow-headers': '*',
      'access-control-allow-methods': 'POST, OPTIONS',
    };
    if (route.request().method() === 'OPTIONS') return route.fulfill({ status: 204, headers });
    calls.push(route.request().postDataJSON());
    return route.fulfill({
      status: 200,
      headers,
      contentType: 'application/json',
      body: JSON.stringify({
        message_id: '40000000-0000-4000-8000-000000000002',
        channel: 'sms',
        status: 'sent',
        error: null,
      }),
    });
  });
  return calls;
}

test.describe('messages inbox', () => {
  test('owner reads a thread and replies by text', async ({ page }) => {
    const patches: string[] = [];
    await mockSupabase(page, {
      user: OWNER,
      tables: {
        shop_members: [membershipRow(OWNER, 'owner')],
        notifications: [],
        messages: ({ method, url }) => {
          if (method === 'PATCH') patches.push(url.search);
          return [inbound];
        },
        customers: [casey],
        message_templates: [],
      },
    });
    const calls = await mockMessaging(page);

    await page.goto('/app/messages');
    const conversations = page.getByRole('navigation', { name: 'Conversations' });
    await expect(conversations.getByRole('link', { name: /Casey Jones/ })).toContainText(
      'Can you do Saturday instead?',
    );
    await conversations.getByRole('link', { name: /Casey Jones/ }).click();
    await expect(page).toHaveURL(/\/app\/messages\?customer=/);

    const thread = page.getByRole('region', { name: 'Conversation with Casey Jones' });
    await expect(thread.getByRole('article', { name: /Received text/ })).toBeVisible();
    await expect.poll(() => patches.length).toBeGreaterThan(0);
    expect(patches[0]).toContain('direction=eq.inbound');

    await thread.getByRole('textbox', { name: 'Message' }).fill('Saturday at 9 works!');
    await thread.getByRole('button', { name: 'Send text' }).click();
    await expect(page.getByText('Message sent')).toBeVisible();
    expect(calls).toEqual([
      {
        action: 'send',
        shop_id: expect.any(String),
        customer_id: casey.id,
        channel: 'sms',
        body: 'Saturday at 9 works!',
      },
    ]);
  });

  test('works at 360px: list, then thread with a back link', async ({ page }) => {
    await page.setViewportSize({ width: 360, height: 740 });
    await mockSupabase(page, {
      user: OWNER,
      tables: {
        shop_members: [membershipRow(OWNER, 'owner')],
        notifications: [],
        messages: [{ ...inbound, read_at: '2026-03-10T15:00:00Z' }],
        customers: [casey],
        message_templates: [],
      },
    });
    await page.goto('/app/messages');
    await page.getByRole('link', { name: /Casey Jones/ }).click();
    const thread = page.getByRole('region', { name: 'Conversation with Casey Jones' });
    await expect(thread).toBeVisible();
    await expect(page.getByRole('navigation', { name: 'Conversations' })).toBeHidden();
    const overflow = await page.evaluate(
      () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
    );
    expect(overflow).toBeLessThanOrEqual(0);
    await thread.getByRole('link', { name: 'Back to conversations' }).click();
    await expect(page.getByRole('navigation', { name: 'Conversations' })).toBeVisible();
  });

  test('technicians have no inbox', async ({ page }) => {
    await mockSupabase(page, {
      user: TECH,
      tables: { shop_members: [membershipRow(TECH, 'technician')], notifications: [] },
    });
    await page.goto('/app/messages');
    await expect(page.getByText('You don’t have access to this page')).toBeVisible();
  });
});
