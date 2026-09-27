import { expect, test } from '@playwright/test';
import { membershipRow, OWNER, TECH } from './support/fixtures';
import { mockSupabase } from './support/mockSupabase';

type Json = null | boolean | number | string | Json[] | { [key: string]: Json };
type Row = { [key: string]: Json };

const techMember = membershipRow(TECH, 'technician');

test.describe('timesheets', () => {
  test('technician clocks in and out and sees only their own hours', async ({ page }) => {
    let open: Row | null = null;
    const listQueries: string[] = [];
    await mockSupabase(page, {
      user: TECH,
      tables: {
        shop_members: [techMember],
        notifications: [],
        time_entries: ({ url }) => {
          if (url.searchParams.has('or')) listQueries.push(url.search);
          return open ? [open] : [];
        },
      },
      rpc: {
        shop_team: [
          {
            member_id: techMember.id,
            display_name: TECH.fullName,
            role: 'technician',
            active: true,
            calendar_color: null,
          },
        ],
        clock_in: () => {
          open = {
            id: '60000000-0000-4000-8000-000000000001',
            member_id: techMember.id,
            job_id: null,
            kind: 'shift',
            clock_in: new Date(Date.now() - 5_000).toISOString(),
            clock_out: null,
            source: 'web',
            notes: null,
            job: null,
          };
          return open;
        },
        clock_out: () => {
          const closed = { ...open, clock_out: new Date().toISOString() };
          open = null;
          return closed;
        },
      },
    });

    await page.goto('/app/timesheets');
    await expect(page.getByText('You’re clocked out')).toBeVisible();
    await expect(page.getByRole('button', { name: 'Add entry' })).toHaveCount(0);
    await expect(page.getByRole('combobox', { name: 'Team member' })).toHaveCount(0);
    await expect.poll(() => listQueries.length).toBeGreaterThan(0);
    expect(listQueries[0]).toContain(`member_id=eq.${techMember.id}`);

    await page.getByRole('button', { name: 'Clock in' }).click();
    await expect(page.getByRole('timer', { name: 'Time on the clock' })).toHaveText(/^0:00:\d\d$/);
    await expect(page.getByRole('table', { name: 'Time entries' })).toContainText('Running');

    await page.getByRole('button', { name: 'Clock out' }).click();
    await expect(page.getByText('You’re clocked out')).toBeVisible();
  });

  test('owner sees everyone’s entries and totals', async ({ page }) => {
    await mockSupabase(page, {
      user: OWNER,
      tables: {
        shop_members: [membershipRow(OWNER, 'owner')],
        notifications: [],
        time_entries: ({ url }) =>
          url.searchParams.has('or')
            ? [
                {
                  id: '60000000-0000-4000-8000-000000000002',
                  member_id: techMember.id,
                  job_id: null,
                  kind: 'shift',
                  clock_in: '2026-03-10T13:00:00Z',
                  clock_out: '2026-03-10T21:00:00Z',
                  source: 'manual',
                  notes: null,
                  job: null,
                },
              ]
            : [],
      },
      rpc: {
        shop_team: [
          {
            member_id: techMember.id,
            display_name: TECH.fullName,
            role: 'technician',
            active: true,
            calendar_color: null,
          },
        ],
      },
    });
    await page.setViewportSize({ width: 360, height: 800 });
    await page.goto('/app/timesheets');
    await page.getByLabel('From', { exact: true }).fill('2026-03-09');
    await page.getByLabel('To', { exact: true }).fill('2026-03-15');
    // below md the Table renders as a stacked list with the same accessible name
    const totals = page.getByRole('list', { name: 'Totals per team member' });
    await expect(totals).toContainText('Theo Tech');
    await expect(totals).toContainText('8h 00m');
    await expect(page.getByRole('button', { name: 'Add entry' }).first()).toBeVisible();
    const overflow = await page.evaluate(
      () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
    );
    expect(overflow).toBeLessThanOrEqual(0);
  });
});
