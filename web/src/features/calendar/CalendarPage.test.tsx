import { screen, waitFor, within } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { membership, renderRoute, shopValue } from '@/test/render';
import {
  builders,
  createBuilder,
  resetSupabaseMock,
  setTableResult,
  supabase,
} from '@/test/supabaseMock';
import { TEAM } from '@/features/jobs/testFixtures';
import CalendarPage from './CalendarPage';

vi.mock('@/lib/supabase', () => import('@/test/supabaseMock'));
// Leaflet needs a real layout engine; the day map's list and route are what matter here.
vi.mock('./LeafletMap', () => ({
  default: ({ stops }: { stops: { label: string }[] }) => (
    <div role="region" aria-label="Map of the day’s stops">
      {stops.map((s) => s.label).join(', ')}
    </div>
  ),
}));

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

  it('marks repeating jobs and shows calendar events by kind', async () => {
    setup('owner', [
      { ...JOB, series_id: 'series-1' },
      {
        ...BUSY,
        event_type: 'blocked_time',
        id: 'blk-1',
        is_busy_block: true,
        event_kind: 'meeting',
        title: 'Team meeting',
        starts_at: '2026-09-29T19:00:00Z',
        ends_at: '2026-09-29T20:00:00Z',
      },
    ]);
    expect(await screen.findByText('#1001 · Jane Doe')).toBeInTheDocument();
    expect(screen.getByText('Repeats:')).toBeInTheDocument();
    expect(screen.getByText('Team meeting')).toBeInTheDocument();
    expect(screen.getByText('Meeting:')).toBeInTheDocument();
  });

  it('lets a manager add a calendar event', async () => {
    const { user } = setup();
    setTableResult('blocked_times', { data: { id: 'blk-new' } });
    await screen.findByText('#1001 · Jane Doe');
    await user.click(screen.getByRole('button', { name: 'New event' }));
    const dialog = await screen.findByRole('dialog', { name: 'New event' });
    await user.type(within(dialog).getByLabelText('Title'), 'Staff training');
    await user.selectOptions(within(dialog).getByLabelText('Team member'), 'member-2');
    await user.click(within(dialog).getByRole('button', { name: 'Add event' }));
    await waitFor(() =>
      expect(builders.blocked_times?.some((b) => b.insert.mock.calls.length > 0)).toBe(true),
    );
    const insert = builders.blocked_times?.find((b) => b.insert.mock.calls.length > 0)?.insert;
    // today (Mon 28 Sep) 09:00–10:00 in America/Chicago, not the browser's zone
    expect(insert).toHaveBeenCalledWith({
      shop_id: 'shop-1',
      kind: 'meeting',
      member_id: 'member-2',
      customer_id: null,
      title: 'Staff training',
      reason: null,
      starts_at: '2026-09-28T14:00:00.000Z',
      ends_at: '2026-09-28T15:00:00.000Z',
      affects_capacity: false,
      color: null,
      recurrence: null,
    });
  });

  it('ends a repeating event before the opened occurrence', async () => {
    const { user } = setup('owner', [
      JOB,
      {
        ...BUSY,
        event_type: 'blocked_time',
        id: 'blk-1',
        event_kind: 'meeting',
        title: 'Weekly huddle',
        starts_at: '2026-09-29T14:00:00Z',
        ends_at: '2026-09-29T15:00:00Z',
      },
    ]);
    setTableResult('blocked_times', {
      data: {
        id: 'blk-1',
        member_id: null,
        starts_at: '2026-09-15T14:00:00Z',
        ends_at: '2026-09-15T15:00:00Z',
        reason: null,
        kind: 'meeting',
        title: 'Weekly huddle',
        customer_id: null,
        affects_capacity: false,
        color: null,
        recurrence: { freq: 'week', interval: 1, count: 10 },
      },
    });
    await user.click(await screen.findByText('Weekly huddle'));
    const dialog = await screen.findByRole('dialog', { name: 'Edit event' });
    // the opened occurrence, not the series' first date
    expect(within(dialog).getByLabelText('Start date')).toHaveValue('2026-09-29');
    await user.click(within(dialog).getByRole('button', { name: 'Delete' }));
    const confirm = await screen.findByRole('alertdialog', { name: 'Delete this event?' });
    await user.click(within(confirm).getByRole('radio', { name: 'This and later occurrences' }));
    await user.click(within(confirm).getByRole('button', { name: 'Delete' }));
    await waitFor(() =>
      expect((builders.blocked_times ?? []).flatMap((b) => b.update.mock.calls)).toContainEqual([
        { recurrence: { freq: 'week', interval: 1, until_date: '2026-09-28' } },
      ]),
    );
    expect((builders.blocked_times ?? []).some((b) => b.delete.mock.calls.length > 0)).toBe(false);
  });

  const WEEKLY_OFF = {
    id: 'blk-1',
    member_id: null,
    starts_at: '2026-09-15T14:00:00Z',
    ends_at: '2026-09-15T15:00:00Z',
    reason: null,
    kind: 'meeting',
    title: 'Weekly huddle',
    customer_id: null,
    affects_capacity: false,
    color: null,
    recurrence: { freq: 'week', interval: 1, count: 10, except_dates: ['2026-09-22'] },
  };
  const HUDDLE_OCCURRENCE = {
    ...BUSY,
    event_type: 'blocked_time',
    id: 'blk-1',
    event_kind: 'meeting',
    title: 'Weekly huddle',
    starts_at: '2026-09-29T14:00:00Z',
    ends_at: '2026-09-29T15:00:00Z',
  };

  it('deletes only the opened occurrence of a repeating event (even a count rule)', async () => {
    const { user } = setup('owner', [JOB, HUDDLE_OCCURRENCE]);
    setTableResult('blocked_times', { data: WEEKLY_OFF });
    await user.click(await screen.findByText('Weekly huddle'));
    const dialog = await screen.findByRole('dialog', { name: 'Edit event' });
    expect(within(dialog).getByText(/1 date skipped/)).toBeInTheDocument();
    await user.click(within(dialog).getByRole('button', { name: 'Delete' }));
    const confirm = await screen.findByRole('alertdialog', { name: 'Delete this event?' });
    // the least destructive choice is the default
    expect(
      within(confirm).getByRole('radio', { name: /Only this one \(Sep 29, 2026\)/ }),
    ).toBeChecked();
    await user.click(within(confirm).getByRole('button', { name: 'Delete' }));
    await waitFor(() =>
      expect((builders.blocked_times ?? []).flatMap((b) => b.update.mock.calls)).toContainEqual([
        {
          recurrence: {
            freq: 'week',
            interval: 1,
            count: 10,
            except_dates: ['2026-09-22', '2026-09-29'],
          },
        },
      ]),
    );
    expect((builders.blocked_times ?? []).some((b) => b.delete.mock.calls.length > 0)).toBe(false);
  });

  it('deletes only the first occurrence without deleting the series', async () => {
    const { user } = setup('owner', [JOB, HUDDLE_OCCURRENCE]);
    setTableResult('blocked_times', {
      data: {
        ...WEEKLY_OFF,
        starts_at: HUDDLE_OCCURRENCE.starts_at,
        ends_at: HUDDLE_OCCURRENCE.ends_at,
        recurrence: { freq: 'week', interval: 1 },
      },
    });
    await user.click(await screen.findByText('Weekly huddle'));
    const dialog = await screen.findByRole('dialog', { name: 'Edit event' });
    await user.click(within(dialog).getByRole('button', { name: 'Delete' }));
    const confirm = await screen.findByRole('alertdialog', { name: 'Delete this event?' });
    expect(within(confirm).queryByRole('radio', { name: 'This and later occurrences' })).toBeNull();
    await user.click(within(confirm).getByRole('button', { name: 'Delete' }));
    await waitFor(() =>
      expect((builders.blocked_times ?? []).flatMap((b) => b.update.mock.calls)).toContainEqual([
        { recurrence: { freq: 'week', interval: 1, except_dates: ['2026-09-29'] } },
      ]),
    );
    expect((builders.blocked_times ?? []).some((b) => b.delete.mock.calls.length > 0)).toBe(false);
  });

  it('changes only the opened occurrence: a one-off event, and the series skips that date', async () => {
    const { user } = setup('owner', [JOB, HUDDLE_OCCURRENCE]);
    setTableResult('blocked_times', { data: WEEKLY_OFF });
    await user.click(await screen.findByText('Weekly huddle'));
    const dialog = await screen.findByRole('dialog', { name: 'Edit event' });
    await user.click(within(dialog).getByRole('radio', { name: 'Only this one' }));
    // a one-off has no repeat of its own
    expect(within(dialog).queryByLabelText('Repeat')).toBeNull();
    const title = within(dialog).getByLabelText('Title');
    await user.clear(title);
    await user.type(title, 'Huddle moved online');
    await user.click(within(dialog).getByRole('button', { name: 'Save' }));
    await waitFor(() =>
      expect((builders.blocked_times ?? []).flatMap((b) => b.update.mock.calls)).toContainEqual([
        {
          recurrence: {
            freq: 'week',
            interval: 1,
            count: 10,
            except_dates: ['2026-09-22', '2026-09-29'],
          },
        },
      ]),
    );
    const inserts = (builders.blocked_times ?? []).flatMap((b) => b.insert.mock.calls);
    expect(inserts).toContainEqual([
      expect.objectContaining({
        title: 'Huddle moved online',
        starts_at: '2026-09-29T14:00:00.000Z',
        ends_at: '2026-09-29T15:00:00.000Z',
        recurrence: null,
      }),
    ]);
  });

  it('opens a closure from the calendar and shows calendar events once in the bay view', async () => {
    const closure = {
      ...BUSY,
      event_type: 'blocked_time',
      id: 'blk-closed',
      is_busy_block: true,
      event_kind: 'closed',
      title: 'Holiday',
      starts_at: '2026-09-28T19:00:00Z',
      ends_at: '2026-09-28T21:00:00Z',
    };
    const meeting = {
      ...closure,
      id: 'blk-meet',
      event_kind: 'meeting',
      title: 'Team meeting',
      starts_at: '2026-09-28T14:00:00Z',
      ends_at: '2026-09-28T15:00:00Z',
    };
    const { user } = setup(
      'owner',
      [JOB, closure, meeting],
      [
        { id: 'bay-1', name: 'Bay 1', kind: 'bay', active: true, archived_at: null },
        { id: 'van-1', name: 'Van 1', kind: 'van', active: true, archived_at: null },
      ],
    );
    setTableResult('blocked_times', {
      data: {
        id: 'blk-closed',
        member_id: null,
        starts_at: '2026-09-28T19:00:00Z',
        ends_at: '2026-09-28T21:00:00Z',
        reason: null,
        kind: 'closed',
        title: 'Holiday',
        customer_id: null,
        affects_capacity: true,
        color: null,
        recurrence: null,
      },
    });
    await screen.findByText('#1001 · Jane Doe');
    expect(screen.getByText('Closed:')).toBeInTheDocument();
    await user.click(screen.getByText('Holiday'));
    const dialog = await screen.findByRole('dialog', { name: 'Edit event' });
    expect(within(dialog).getByLabelText('Title')).toHaveValue('Holiday');
    await user.click(within(dialog).getByRole('button', { name: 'Cancel' }));

    await user.click(screen.getByRole('button', { name: 'Bays' }));
    const none = await screen.findByRole('region', { name: 'No bay / van' });
    expect(screen.getAllByText('Team meeting')).toHaveLength(1);
    expect(within(none).getByText('Team meeting')).toBeInTheDocument();
    expect(screen.getAllByText('Holiday')).toHaveLength(1);
    expect(
      within(screen.getByRole('region', { name: 'Bay 1' })).queryByText('Team meeting'),
    ).toBeNull();
  });

  it('keeps the day map to the filters and the jobs that start that day', async () => {
    const mobile = {
      ...JOB,
      location_type: 'mobile',
      starts_at: '2026-09-28T15:00:00Z',
      ends_at: '2026-09-28T16:00:00Z',
      service_address: '1 Main St, Birmingham',
      service_lat: 33.52,
      service_lng: -86.81,
    };
    const { user } = setup('owner', [
      mobile,
      {
        ...mobile,
        id: 'job-4',
        job_number: 1004,
        title: 'Sam Lee',
        assigned_member_ids: ['member-1'],
        starts_at: '2026-09-28T17:00:00Z',
        ends_at: '2026-09-28T18:00:00Z',
      },
      {
        // a two-day coating that began yesterday (shop time)
        ...mobile,
        id: 'job-5',
        job_number: 1005,
        title: 'Coating for Ann Poe',
        starts_at: '2026-09-27T14:00:00Z',
        ends_at: '2026-09-28T22:00:00Z',
      },
    ]);
    await screen.findByText('#1001 · Jane Doe');
    await user.click(screen.getByRole('button', { name: 'Map' }));
    const stops = await screen.findByRole('region', { name: 'Stops in route order' });
    expect(within(stops).getByText('2 stops')).toBeInTheDocument();
    const continuing = within(stops).getByRole('region', {
      name: 'Continuing from an earlier day',
    });
    expect(within(continuing).getByText('Coating for Ann Poe')).toBeInTheDocument();
    // notices meant for the other views stay away
    expect(screen.queryByText(/No bays or vans set up yet/)).not.toBeInTheDocument();
    expect(screen.queryByText(/No jobs in this range/)).not.toBeInTheDocument();

    // the route sent to the server holds only the jobs that start this day
    await user.click(within(stops).getByRole('button', { name: 'Move Sam Lee earlier' }));
    await waitFor(() =>
      expect(supabase.rpc).toHaveBeenCalledWith('set_route_order', {
        p_shop_id: 'shop-1',
        p_job_ids: ['job-4', 'job-1'],
      }),
    );

    // the Team member filter narrows the map too
    await user.selectOptions(screen.getByLabelText('Team member'), 'member-1');
    await waitFor(() =>
      expect(
        within(screen.getByRole('region', { name: 'Stops in route order' })).getByText('1 stop'),
      ).toBeInTheDocument(),
    );
    expect(screen.queryByText('Coating for Ann Poe')).not.toBeInTheDocument();
    expect(screen.queryByText('Jane Doe')).not.toBeInTheDocument();
  });

  it('maps the day’s mobile stops, reorders them and hands the route to Google Maps', async () => {
    const mobile = {
      ...JOB,
      location_type: 'mobile',
      starts_at: '2026-09-28T15:00:00Z',
      ends_at: '2026-09-28T16:00:00Z',
      service_address: '1 Main St, Birmingham',
      service_lat: 33.52,
      service_lng: -86.81,
    };
    const { user } = setup('owner', [
      mobile,
      {
        ...mobile,
        id: 'job-4',
        job_number: 1004,
        title: 'Sam Lee',
        starts_at: '2026-09-28T17:00:00Z',
        ends_at: '2026-09-28T18:00:00Z',
        service_address: '5 Oak Ave, Homewood',
        service_lat: null,
        service_lng: null,
      },
    ]);
    await screen.findByText('#1001 · Jane Doe');
    await user.click(screen.getByRole('button', { name: 'Map' }));
    const stops = await screen.findByRole('region', { name: 'Stops in route order' });
    expect(within(stops).getByText('2 stops')).toBeInTheDocument();
    expect(within(stops).getByText(/Not located yet/)).toBeInTheDocument();
    expect(await screen.findByRole('region', { name: 'Map of the day’s stops' })).toHaveTextContent(
      'Jane Doe',
    );
    const link = within(stops).getByRole('link', { name: /Open route in Google Maps/ });
    expect(link.getAttribute('href')).toContain('https://www.google.com/maps/dir/?api=1');

    await user.click(within(stops).getByRole('button', { name: 'Move Sam Lee earlier' }));
    await waitFor(() =>
      expect(supabase.rpc).toHaveBeenCalledWith('set_route_order', {
        p_shop_id: 'shop-1',
        p_job_ids: ['job-4', 'job-1'],
      }),
    );
  });
});
