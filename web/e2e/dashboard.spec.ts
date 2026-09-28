import { expect, test, type Page } from '@playwright/test';
import { membershipRow, OWNER, TECH } from './support/fixtures';
import { mockSupabase } from './support/mockSupabase';

const TECH_MEMBER_ID = membershipRow(TECH, 'technician').id;

function summary(scope: 'shop' | 'own') {
  const own = scope === 'own';
  return {
    shop_id: '10000000-0000-4000-8000-000000000001',
    timezone: 'America/Chicago',
    as_of: new Date().toISOString(),
    scope,
    today: '2026-09-27',
    week_start: '2026-09-21',
    month_start: '2026-09-01',
    jobs_today: { total: 1, by_status: { scheduled: 1 } },
    next_job: null,
    jobs_this_week: 4,
    pending_booking_requests: own ? null : 1,
    quotes_awaiting_response: own ? null : 2,
    open_invoices: own ? null : { count: 3, balance_cents: 98700 },
    overdue_invoices: own ? null : { count: 1, balance_cents: 25000 },
    revenue: own
      ? null
      : {
          today: { net_cents: 45000, tips_cents: 5000, payments_count: 3 },
          week: { net_cents: 210000, tips_cents: 12000, payments_count: 11 },
          month: { net_cents: 880000, tips_cents: 40000, payments_count: 40 },
        },
    unread_inbound_messages: own ? null : 0,
    clocked_in: { count: 0, members: [] },
  };
}

const JOB = {
  event_type: 'job',
  id: '40000000-0000-4000-8000-000000000001',
  job_number: 1001,
  status: 'scheduled',
  starts_at: '2026-09-27T15:00:00Z',
  ends_at: '2026-09-27T17:00:00Z',
  is_busy_block: false,
  customer_id: '30000000-0000-4000-8000-000000000001',
  customer_name: 'Jane Doe',
  vehicle_id: null,
  vehicle_label: '2021 Toyota Camry',
  location_type: 'shop',
  service_address: null,
  resource_id: null,
  assigned_member_ids: [TECH_MEMBER_ID],
  member_id: null,
  title: 'Jane Doe — Full Detail',
};

async function horizontalOverflow(page: Page) {
  return page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
}

test.describe('dashboard', () => {
  test('owner sees revenue, invoices and approves a booking request', async ({ page }) => {
    const updates: unknown[] = [];
    await mockSupabase(page, {
      user: OWNER,
      tables: {
        shop_members: [membershipRow(OWNER, 'owner')],
        notifications: [],
        time_entries: [],
        customers: [{ id: 'c-9', first_name: 'Sam', last_name: 'Lee', company: null }],
        jobs: ({ method, body }) => {
          if (method === 'PATCH') {
            updates.push(body);
            // `.select('id')`: the guarded update returns the changed row.
            return [{ id: 'job-9' }];
          }
          if (updates.length > 0) return [];
          return [
            {
              id: 'job-9',
              number: 1050,
              scheduled_start: '2026-09-29T14:00:00Z',
              scheduled_end: '2026-09-29T16:00:00Z',
              location_type: 'shop',
              created_at: '2026-09-26T10:00:00Z',
              customer_id: 'c-9',
            },
          ];
        },
      },
      rpc: {
        dashboard_summary: summary('shop'),
        calendar_events: [JOB],
        report_team: [],
      },
    });
    await page.goto('/app');
    await expect(page.getByRole('heading', { name: 'Dashboard', level: 1 })).toBeVisible();
    await expect(page.getByText('$450.00')).toBeVisible();
    await expect(page.getByText('3 payments · $50.00 tips (not in revenue)')).toBeVisible();
    await expect(page.getByText('$987.00')).toBeVisible();
    const schedule = page.getByRole('region', { name: 'Today’s schedule' });
    await expect(schedule.getByRole('link', { name: /Jane Doe/ })).toHaveAttribute(
      'href',
      `/app/jobs/${JOB.id}`,
    );

    const requests = page.getByRole('region', { name: 'Booking requests' });
    await requests.getByRole('button', { name: 'Approve booking from Sam Lee' }).click();
    await expect(page.getByText('Booking approved')).toBeVisible();
    expect(updates).toContainEqual({ status: 'scheduled' });
  });

  test('declining a booking request closes its open deposit link first', async ({ page }) => {
    const calls: string[] = [];
    await mockSupabase(page, {
      user: OWNER,
      tables: {
        shop_members: [membershipRow(OWNER, 'owner')],
        notifications: [],
        time_entries: [],
        customers: [{ id: 'c-9', first_name: 'Sam', last_name: 'Lee', company: null }],
        jobs: ({ method, body }) => {
          if (method === 'PATCH') {
            calls.push(`jobs:${JSON.stringify(body)}`);
            return [{ id: 'job-9' }];
          }
          if (calls.some((c) => c.startsWith('jobs:'))) return [];
          return [
            {
              id: 'job-9',
              number: 1050,
              scheduled_start: '2026-09-29T14:00:00Z',
              scheduled_end: '2026-09-29T16:00:00Z',
              location_type: 'shop',
              created_at: '2026-09-26T10:00:00Z',
              customer_id: 'c-9',
            },
          ];
        },
      },
      functions: {
        payments: ({ body }) => {
          calls.push(`payments:${JSON.stringify(body)}`);
          return {
            invoice_id: null,
            job_id: 'job-9',
            cancelled: 0,
            succeeded: 0,
            in_progress: 0,
            sessions_expired: 1,
          };
        },
      },
      rpc: {
        dashboard_summary: summary('shop'),
        calendar_events: [JOB],
        report_team: [],
      },
    });
    await page.goto('/app');
    const requests = page.getByRole('region', { name: 'Booking requests' });
    await requests.getByRole('button', { name: 'Decline booking from Sam Lee' }).click();
    const dialog = page.getByRole('alertdialog', { name: 'Decline this booking?' });
    await dialog.getByLabel(/Reason/).fill('Fully booked that day');
    await dialog.getByRole('button', { name: 'Decline booking' }).click();
    await expect(page.getByText('Booking declined')).toBeVisible();
    expect(calls).toEqual([
      `payments:${JSON.stringify({
        action: 'cancel_open_payments',
        shop_id: '10000000-0000-4000-8000-000000000001',
        job_id: 'job-9',
      })}`,
      `jobs:${JSON.stringify({ status: 'cancelled', cancel_reason: 'Fully booked that day' })}`,
    ]);
  });

  test('company-only customers show by name, and a stale approval is not reported as done', async ({
    page,
  }) => {
    let handledElsewhere = false;
    await mockSupabase(page, {
      user: OWNER,
      tables: {
        shop_members: [membershipRow(OWNER, 'owner')],
        notifications: [],
        time_entries: [],
        customers: [{ id: 'c-9', first_name: 'Sam', last_name: 'Lee', company: null }],
        jobs: ({ method }) => {
          if (method === 'PATCH') {
            // Another manager approved it first: the status guard matches nothing.
            handledElsewhere = true;
            return [];
          }
          if (handledElsewhere) return [];
          return [
            {
              id: 'job-9',
              number: 1050,
              scheduled_start: '2026-09-29T14:00:00Z',
              scheduled_end: '2026-09-29T16:00:00Z',
              location_type: 'shop',
              created_at: '2026-09-26T10:00:00Z',
              customer_id: 'c-9',
            },
          ];
        },
      },
      rpc: {
        dashboard_summary: summary('shop'),
        calendar_events: [{ ...JOB, customer_name: null, title: 'Acme Fleet — Exterior Wash' }],
        report_team: [],
      },
    });
    await page.goto('/app');
    const schedule = page.getByRole('region', { name: 'Today’s schedule' });
    await expect(schedule.getByRole('link', { name: /Acme Fleet · #1001/ })).toBeVisible();

    const requests = page.getByRole('region', { name: 'Booking requests' });
    await requests.getByRole('button', { name: 'Approve booking from Sam Lee' }).click();
    await expect(page.getByText(/This request was already handled/)).toBeVisible();
    await expect(page.getByText('Booking approved')).toHaveCount(0);
    await expect(requests.getByText('No requests waiting')).toBeVisible();
  });

  test('technician sees their jobs and clocks in', async ({ page }) => {
    let clockedIn = false;
    await mockSupabase(page, {
      user: TECH,
      tables: {
        shop_members: [membershipRow(TECH, 'technician')],
        notifications: [],
        time_entries: () =>
          clockedIn
            ? [{ id: 't-1', kind: 'shift', job_id: null, clock_in: new Date().toISOString() }]
            : [],
      },
      rpc: {
        dashboard_summary: summary('own'),
        calendar_events: [JOB],
        report_team: [{ member_id: TECH_MEMBER_ID, worked_seconds: 7200 }],
        clock_in: () => {
          clockedIn = true;
          return { id: 't-1' };
        },
      },
    });
    await page.goto('/app');
    await expect(
      page.getByRole('region', { name: 'My jobs today' }).getByText(/Jane Doe/),
    ).toBeVisible();
    await expect(page.getByText(/Revenue today/)).toHaveCount(0);
    await expect(page.getByText('2h 00m')).toBeVisible();
    await page.getByRole('button', { name: 'Clock in' }).click();
    await expect(page.getByText('You’re clocked in')).toBeVisible();
    await expect(page.getByRole('button', { name: 'Clock out' })).toBeVisible();
  });

  test.describe('at 360px', () => {
    test.use({ viewport: { width: 360, height: 740 } });

    test('dashboard fits the screen', async ({ page }) => {
      await mockSupabase(page, {
        user: OWNER,
        tables: {
          shop_members: [membershipRow(OWNER, 'owner')],
          notifications: [],
          time_entries: [],
        },
        rpc: { dashboard_summary: summary('shop'), calendar_events: [JOB], report_team: [] },
      });
      await page.goto('/app');
      await expect(page.getByText('$450.00')).toBeVisible();
      expect(await horizontalOverflow(page)).toBeLessThanOrEqual(0);
    });
  });
});
