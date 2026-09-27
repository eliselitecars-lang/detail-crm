import { expect, test } from '@playwright/test';
import { membershipRow, OWNER } from './support/fixtures';
import { mockSupabase } from './support/mockSupabase';

const JOB_ID = '40000000-0000-4000-8000-000000000001';

test.describe('notifications page', () => {
  test('lists unread first, marks all read and deep-links to the job', async ({ page }) => {
    let allRead = false;
    const rows = () => [
      {
        id: 'n-1',
        kind: 'new_booking',
        title: 'New booking request from Jane Doe',
        body: 'Full Detail',
        job_id: JOB_ID,
        read_at: allRead ? '2026-09-27T15:00:00Z' : null,
        created_at: '2026-09-27T14:00:00Z',
      },
      {
        id: 'n-2',
        kind: 'payment_received',
        title: 'Payment received: $120.00 from Sam Lee',
        body: null,
        job_id: null,
        read_at: '2026-09-26T10:00:00Z',
        created_at: '2026-09-26T09:00:00Z',
      },
    ];
    await mockSupabase(page, {
      user: OWNER,
      tables: {
        shop_members: [membershipRow(OWNER, 'owner')],
        // The mock ignores filters: answer the unread (read_at=is.null) and
        // read (read_at=not.is.null) lists from the same rows.
        notifications: ({ url }) => {
          const readAt = url.searchParams.get('read_at');
          if (readAt === 'is.null') return rows().filter((r) => r.read_at === null);
          if (readAt === 'not.is.null') return rows().filter((r) => r.read_at !== null);
          return rows();
        },
      },
      rpc: {
        mark_all_notifications_read: () => {
          allRead = true;
          return 1;
        },
      },
    });

    await page.goto('/app/notifications');
    await expect(page.getByRole('heading', { name: 'Notifications', level: 1 })).toBeVisible();
    const unread = page.getByRole('list', { name: 'Unread notifications' });
    await expect(unread.getByText('New booking request from Jane Doe')).toBeVisible();
    const earlier = page.getByRole('list', { name: 'Earlier notifications' });
    await expect(earlier.getByRole('link', { name: 'Open payments' })).toHaveAttribute(
      'href',
      '/app/payments',
    );

    await page.getByRole('button', { name: 'Mark all read' }).click();
    await expect(page.getByText('You’re all caught up')).toBeVisible();
    await expect(earlier.getByText('New booking request from Jane Doe')).toBeVisible();

    await earlier.getByRole('link', { name: 'Open job' }).click();
    await expect(page).toHaveURL(new RegExp(`/app/jobs/${JOB_ID}$`));
  });
});
