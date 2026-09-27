import { expect, test } from '@playwright/test';
import { membershipRow, OWNER, TECH } from './support/fixtures';
import { mockSupabase, type Json } from './support/mockSupabase';

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

/** One inbox_threads row (the newest message of a conversation + unread count). */
function threadRow(over: Record<string, Json> = {}): Record<string, Json> {
  return {
    thread_key: `c:${casey.id}`,
    customer_id: casey.id,
    from_address: casey.phone,
    customer_first_name: casey.first_name,
    customer_last_name: casey.last_name,
    customer_company: null,
    last_message_id: inbound.id,
    last_direction: 'inbound',
    last_channel: 'sms',
    last_status: 'received',
    last_body: inbound.body,
    last_created_at: inbound.created_at,
    unread_count: 1,
    ...over,
  };
}

/** The messaging function: records the JSON bodies it received. */
function messaging(calls: unknown[]) {
  return ({ body }: { body: unknown }) => {
    calls.push(body);
    return {
      message_id: '40000000-0000-4000-8000-000000000002',
      channel: 'sms',
      status: 'sent',
      error: null,
    };
  };
}

test.describe('messages inbox', () => {
  test('owner reads a thread and replies by text', async ({ page }) => {
    const patches: string[] = [];
    const calls: unknown[] = [];
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
      rpc: { inbox_threads: [threadRow()], inbox_unread_count: 1 },
      functions: { messaging: messaging(calls) },
    });

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
        request_nonce: expect.stringMatching(/^[A-Za-z0-9_-]{8,64}$/),
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
      rpc: { inbox_threads: [threadRow({ unread_count: 0 })], inbox_unread_count: 0 },
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

  test('pages older conversations with inbox_threads and counts every unread message', async ({
    page,
  }) => {
    // A campaign blast: 50 newer conversations fill the first page.
    const blast = Array.from({ length: 50 }, (_, i) => {
      const id = `50000000-0000-4000-8000-${String(i).padStart(12, '0')}`;
      return threadRow({
        thread_key: `c:${id}`,
        customer_id: id,
        customer_first_name: 'Recipient',
        customer_last_name: String(i),
        last_direction: 'outbound',
        last_status: 'queued',
        last_body: 'Spring special: 20% off',
        last_created_at: `2026-03-12T10:${String(59 - i).padStart(2, '0')}:00Z`,
        unread_count: 0,
      });
    });
    const pages: unknown[] = [];
    await mockSupabase(page, {
      user: OWNER,
      tables: {
        shop_members: [membershipRow(OWNER, 'owner')],
        notifications: [],
        message_templates: [],
      },
      rpc: {
        inbox_threads: ({ body }) => {
          pages.push(body);
          return (body as { p_before?: string }).p_before ? [threadRow()] : blast;
        },
        inbox_unread_count: 1,
      },
    });
    await page.goto('/app/messages');
    await expect(page.getByText('1 unread message', { exact: true })).toBeVisible();
    const conversations = page.getByRole('navigation', { name: 'Conversations' });
    await expect(conversations.getByRole('link')).toHaveCount(50);
    await conversations.getByRole('button', { name: 'Load older conversations' }).click();
    await expect(conversations.getByRole('link', { name: /Casey Jones/ })).toContainText(
      '1 unread',
    );
    expect(pages).toEqual([
      { p_shop_id: expect.any(String), p_limit: 50 },
      { p_shop_id: expect.any(String), p_limit: 50, p_before: '2026-03-12T10:10:00Z' },
    ]);
    await conversations.getByRole('tab', { name: /Unread/ }).click();
    await expect(conversations.getByRole('link')).toHaveCount(1);
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
