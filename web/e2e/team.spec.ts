import { expect, test, type Page } from '@playwright/test';
import { membershipRow, OWNER, TECH, type MockUser } from './support/fixtures';
import { mockSupabase, SUPABASE_URL } from './support/mockSupabase';

const MANAGER: MockUser = {
  id: '00000000-0000-4000-8000-000000000003',
  email: 'manager@glacier.test',
  fullName: 'Mia Manager',
};

const team = [
  {
    member_id: membershipRow(OWNER, 'owner').id,
    user_id: OWNER.id,
    role: 'owner',
    display_name: OWNER.fullName,
    calendar_color: null,
    active: true,
    phone: null,
    email: OWNER.email,
  },
  {
    member_id: membershipRow(TECH, 'technician').id,
    user_id: TECH.id,
    role: 'technician',
    display_name: TECH.fullName,
    calendar_color: '#1F9D55',
    active: true,
    phone: '+12055550123',
    email: TECH.email,
  },
];

async function mockInvites(page: Page) {
  const calls: unknown[] = [];
  await page.route(`${SUPABASE_URL}/functions/v1/invites`, async (route) => {
    const headers = {
      'access-control-allow-origin': '*',
      'access-control-allow-headers': '*',
      'access-control-allow-methods': 'POST, OPTIONS',
    };
    if (route.request().method() === 'OPTIONS') return route.fulfill({ status: 204, headers });
    calls.push(route.request().postDataJSON());
    const body = route.request().postDataJSON() as { email?: string };
    return route.fulfill({
      status: 200,
      headers,
      contentType: 'application/json',
      body: JSON.stringify({
        invite: {
          id: '70000000-0000-4000-8000-000000000001',
          shop_id: '10000000-0000-4000-8000-000000000001',
          email: body.email ?? 'x@example.com',
          role: 'manager',
          expires_at: '2099-01-01T00:00:00Z',
        },
        invite_url: 'http://localhost:5173/invite/70000000-0000-4000-8000-000000000009',
        email_sent: true,
      }),
    });
  });
  return calls;
}

test.describe('team', () => {
  test('owner invites a member and edits pay', async ({ page }) => {
    const upserts: unknown[] = [];
    await mockSupabase(page, {
      user: OWNER,
      tables: {
        shop_members: [membershipRow(OWNER, 'owner')],
        notifications: [],
        shop_invites: [],
        member_compensation: ({ method, body }) => {
          if (method === 'POST') upserts.push(body);
          return [];
        },
      },
      rpc: { shop_team: team },
    });
    const calls = await mockInvites(page);

    await page.goto('/app/team');
    const members = page.getByRole('table', { name: 'Team members' });
    await expect(members.getByRole('row', { name: /Theo Tech/ })).toContainText('Technician');
    await expect(page.getByText('No pending invites.')).toBeVisible();

    await page.getByRole('button', { name: 'Invite member' }).click();
    const dialog = page.getByRole('dialog', { name: 'Invite a team member' });
    await dialog.getByRole('textbox', { name: /Email/ }).fill('sam@example.com');
    await dialog.getByText('Manager', { exact: true }).click();
    await dialog.getByRole('button', { name: 'Send invite' }).click();
    await expect(page.getByText('Invite sent')).toBeVisible();
    expect(calls).toEqual([
      {
        action: 'send_invite',
        shop_id: expect.any(String),
        email: 'sam@example.com',
        role: 'manager',
      },
    ]);

    await members.getByRole('button', { name: 'Actions for Theo Tech' }).click();
    await page.getByRole('menuitem', { name: 'Edit pay…' }).click();
    const pay = page.getByRole('dialog', { name: /Pay · Theo Tech/ });
    await pay.getByRole('textbox', { name: /Hourly rate/ }).fill('24.50');
    await pay.getByRole('textbox', { name: /Commission/ }).fill('7.5');
    await pay.getByRole('button', { name: 'Save pay' }).click();
    await expect(page.getByText('Pay saved')).toBeVisible();
    expect(upserts).toEqual([
      {
        member_id: team[1]!.member_id,
        hourly_rate_cents: 2450,
        commission_bps: 750,
        shop_id: expect.any(String),
      },
    ]);
  });

  test('pending invite rows stay readable at 360px', async ({ page }) => {
    await page.setViewportSize({ width: 360, height: 780 });
    const email = 'someone.with.long.email@example.com';
    await mockSupabase(page, {
      user: OWNER,
      tables: {
        shop_members: [membershipRow(OWNER, 'owner')],
        notifications: [],
        shop_invites: [
          {
            id: '70000000-0000-4000-8000-000000000002',
            email,
            role: 'manager',
            token: '70000000-0000-4000-8000-000000000003',
            expires_at: '2019-12-31T18:00:00Z',
            created_at: '2019-12-24T18:00:00Z',
          },
        ],
      },
      rpc: { shop_team: team },
    });
    await page.goto('/app/team');
    const emailText = page.getByText(email, { exact: true });
    await expect(emailText).toBeVisible();
    const box = await emailText.boundingBox();
    expect(box?.width ?? 0).toBeGreaterThan(180);
    // The details line wraps as a sentence, not one word per line.
    const details = page.getByText(/Manager · sent/);
    const detailsBox = await details.boundingBox();
    expect(detailsBox?.height ?? 999).toBeLessThan(40);
    // The actions sit below the text, not beside it.
    const resend = page.getByRole('button', { name: `Resend invite to ${email}` });
    const resendBox = await resend.boundingBox();
    expect(resendBox?.y ?? 0).toBeGreaterThan((box?.y ?? 0) + (box?.height ?? 0));
    const overflow = await page.evaluate(
      () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
    );
    expect(overflow).toBeLessThanOrEqual(0);
  });

  test('manager sees a read-only team', async ({ page }) => {
    await mockSupabase(page, {
      user: MANAGER,
      tables: { shop_members: [membershipRow(MANAGER, 'manager')], notifications: [] },
      rpc: { shop_team: team },
    });
    await page.goto('/app/team');
    await expect(page.getByRole('table', { name: 'Team members' })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Invite member' })).toHaveCount(0);
    await expect(page.getByRole('button', { name: /Actions for/ })).toHaveCount(0);
    await expect(page.getByText('Pending invites')).toHaveCount(0);
  });
});
