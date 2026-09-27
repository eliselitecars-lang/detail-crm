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

  test('an unread reply stays listed after a campaign blast fills the newest page', async ({
    page,
  }) => {
    // 300 campaign sends (one INBOX_PAGE) newer than Casey's unread reply.
    const blast = Array.from({ length: 300 }, (_, i) => {
      const id = `50000000-0000-4000-8000-${String(i).padStart(12, '0')}`;
      return {
        ...inbound,
        id,
        customer_id: id,
        customer: { ...casey, id, first_name: 'Recipient', last_name: String(i) },
        campaign_id: '60000000-0000-4000-8000-000000000001',
        direction: 'outbound',
        status: 'queued',
        body: 'Spring special: 20% off',
        created_at: '2026-03-12T10:00:00Z',
      };
    });
    const unreadRow = {
      id: inbound.id,
      customer_id: casey.id,
      from_address: casey.phone,
      created_at: inbound.created_at,
    };
    await mockSupabase(page, {
      user: OWNER,
      tables: {
        shop_members: [membershipRow(OWNER, 'owner')],
        notifications: [],
        messages: ({ url }) => {
          const q = decodeURIComponent(url.search);
          if (q.includes('read_at=is.null')) return [unreadRow];
          if (q.includes('id=in.')) return q.includes(inbound.id) ? [inbound] : [];
          return blast;
        },
        customers: [casey],
        message_templates: [],
      },
    });
    await page.goto('/app/messages');
    await expect(page.getByText('1 unread message', { exact: true })).toBeVisible();
    const conversations = page.getByRole('navigation', { name: 'Conversations' });
    await conversations.getByRole('tab', { name: /Unread/ }).click();
    const links = conversations.getByRole('link');
    await expect(links).toHaveCount(1);
    await expect(links.first()).toContainText('Casey Jones');
    await expect(links.first()).toContainText('1 unread');
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
