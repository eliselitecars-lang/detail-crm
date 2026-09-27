import { screen, waitFor, within } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { membership, renderRoute, shopValue } from '@/test/render';
import { createBuilder, resetSupabaseMock, setTableResult, supabase } from '@/test/supabaseMock';
import { TEAM } from '@/features/jobs/testFixtures';
import CalendarPage from './CalendarPage';

vi.mock('@/lib/supabase', () => import('@/test/supabaseMock'));

const JOB = {
  event_type: 'job',
  id: 'job-1',
  job_number: 1001,
  status: 'confirmed',
  starts_at: '2026-09-29T14:00:00Z',
  ends_at: '2026-09-29T16:00:00Z',
  is_busy_block: false,
  customer_id: 'cust-1',
  customer_name: 'Jane Doe',
  vehicle_id: 'veh-1',
  vehicle_label: '2021 Honda Civic',
  location_type: 'shop',
  service_address: null,
  resource_id: null,
  assigned_member_ids: ['member-2'],
  member_id: null,
  title: 'Jane Doe',
};

const BUSY = {
  ...JOB,
  id: 'job-2',
  job_number: null,
  status: null,
  starts_at: '2026-09-30T15:00:00Z',
  ends_at: '2026-09-30T17:00:00Z',
  is_busy_block: true,
  customer_id: null,
  customer_name: null,
  vehicle_id: null,
  vehicle_label: null,
  location_type: null,
  assigned_member_ids: null,
  title: null,
};

function setup(
  role: 'owner' | 'technician' = 'owner',
  rows: unknown[] | 'error' = [JOB, BUSY],
  resources: unknown[] = [],
) {
  const rpc: Record<string, unknown> = { shop_team: TEAM, calendar_events: rows };
  supabase.rpc.mockImplementation((...args: unknown[]) =>
    rows === 'error' && String(args[0]) === 'calendar_events'
      ? createBuilder({ error: { message: 'boom', code: 'XX000' } })
      : createBuilder({ data: rpc[String(args[0])] ?? null }),
  );
  setTableResult('business_hours', {
    data: [{ weekday: 2, opens_at: '08:00:00', closes_at: '17:00:00' }],
  });
  setTableResult('resources', { data: resources });
  return renderRoute(<CalendarPage />, {
    path: '/app/calendar',
    routePath: '/app/calendar',
    shop: shopValue({ membership: membership({ role }) }),
    routes: [
      { path: '/app/jobs/:jobId', element: <p>Job page</p> },
      { path: '/app/jobs/new', element: <p>New job page</p> },
    ],
  });
}

beforeEach(() => {
  resetSupabaseMock();
  vi.useFakeTimers({ toFake: ['Date'] });
  vi.setSystemTime(new Date('2026-09-28T18:00:00Z'));
});

afterEach(() => vi.useRealTimers());

describe('CalendarPage', () => {
  it('loads the visible week in the SHOP timezone and renders jobs and busy blocks', async () => {
    setup();
    // Week of Sun 27 Sep 2026 in America/Chicago (UTC−5), not the Honolulu test browser.
    await waitFor(() =>
      expect(supabase.rpc).toHaveBeenCalledWith('calendar_events', {
        p_shop_id: 'shop-1',
        p_from: '2026-09-27T05:00:00.000Z',
        p_to: '2026-10-04T05:00:00.000Z',
        p_include_cancelled: false,
      }),
    );
    expect(await screen.findByText('#1001 · Jane Doe')).toBeInTheDocument();
    expect(screen.getByText('Busy')).toBeInTheDocument();
    expect(screen.getByRole('link', { name: /New job/ })).toBeInTheDocument();
  });

  it('opens the job when a job event is clicked', async () => {
    const { user, router } = setup();
    await user.click(await screen.findByText('#1001 · Jane Doe'));
    await waitFor(() => expect(router.state.location.pathname).toBe('/app/jobs/job-1'));
  });

  it('filters by team member on the client', async () => {
    const { user } = setup();
    await screen.findByText('#1001 · Jane Doe');
    await user.selectOptions(screen.getByLabelText('Team member'), 'member-1');
    await waitFor(() => expect(screen.queryByText('#1001 · Jane Doe')).not.toBeInTheDocument());
    await user.selectOptions(screen.getByLabelText('Team member'), 'member-2');
    expect(await screen.findByText('#1001 · Jane Doe')).toBeInTheDocument();
  });

  it('switches views and remembers the choice', async () => {
    const { user } = setup();
    await screen.findByText('#1001 · Jane Doe');
    await user.click(screen.getByRole('button', { name: 'Month' }));
    expect(screen.getByRole('button', { name: 'Month' })).toHaveAttribute('aria-pressed', 'true');
    expect(await screen.findByText('September 2026')).toBeInTheDocument();
    expect(window.localStorage.getItem('detailcrm:calendarView')).toContain('dayGridMonth');
  });

  it('hides job creation from technicians and shows an empty message', async () => {
    setup('technician', []);
    expect(await screen.findByText(/No jobs in this range/)).toBeInTheDocument();
    expect(screen.queryByRole('link', { name: /New job/ })).not.toBeInTheDocument();
  });

  it('shows an error with retry', async () => {
    setup('owner', 'error');
    expect(await screen.findByText('Couldn’t load the calendar')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /Try again|Retry/ })).toBeInTheDocument();
  });

  it('shows a bay / van view with one column per resource for a single shop day', async () => {
    const { user } = setup(
      'owner',
      [
        { ...JOB, resource_id: 'bay-1' },
        { ...JOB, id: 'job-3', job_number: 1003, title: 'Sam Lee' },
      ],
      [
        { id: 'bay-1', name: 'Bay 1', kind: 'bay', active: true, archived_at: null },
        { id: 'van-1', name: 'Van 1', kind: 'van', active: true, archived_at: null },
      ],
    );
    await screen.findByText('#1001 · Jane Doe');
    await user.click(screen.getByRole('button', { name: 'Bays' }));
    expect(screen.getByRole('button', { name: 'Bays' })).toHaveAttribute('aria-pressed', 'true');
    // today (Mon 28 Sep, shop time) is in the visible week → that day first
    expect(await screen.findByText('Monday, September 28, 2026')).toBeInTheDocument();
    await user.click(screen.getByRole('button', { name: 'Next day' }));
    expect(await screen.findByText('Tuesday, September 29, 2026')).toBeInTheDocument();
    await waitFor(() =>
      expect(supabase.rpc).toHaveBeenCalledWith('calendar_events', {
        p_shop_id: 'shop-1',
        p_from: '2026-09-29T05:00:00.000Z',
        p_to: '2026-09-30T05:00:00.000Z',
        p_include_cancelled: false,
      }),
    );
    const bay = screen.getByRole('region', { name: 'Bay 1' });
    const none = screen.getByRole('region', { name: 'No bay / van' });
    expect(within(bay).getByText('#1001 · Jane Doe')).toBeInTheDocument();
    expect(within(bay).getByText('1 job')).toBeInTheDocument();
    expect(within(none).getByText('#1003 · Sam Lee')).toBeInTheDocument();
    expect(
      within(screen.getByRole('region', { name: 'Van 1' })).getByText('0 jobs'),
    ).toBeInTheDocument();
    expect(window.localStorage.getItem('detailcrm:calendarView')).toContain('resourceDay');

    // back to a grid view on the same day
    await user.click(screen.getByRole('button', { name: 'Day' }));
    expect(await screen.findByText('September 29, 2026')).toBeInTheDocument();
  });

  it('explains the resource view when no bays or vans exist', async () => {
    const { user } = setup('owner', [JOB]);
    await screen.findByText('#1001 · Jane Doe');
    await user.click(screen.getByRole('button', { name: 'Bays' }));
    expect(await screen.findByText(/No bays or vans set up yet/)).toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'Add bays and vans' })).toHaveAttribute(
      'href',
      '/app/settings/resources',
    );
    expect(screen.getByRole('region', { name: 'No bay / van' })).toBeInTheDocument();
  });
});
