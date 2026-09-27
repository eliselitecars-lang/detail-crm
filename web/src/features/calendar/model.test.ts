import { describe, expect, it } from 'vitest';
import {
  blockEventId,
  columnEventInputs,
  describeRow,
  eventTitle,
  isCalendarView,
  isGridView,
  jobEventId,
  jobIdFromEventId,
  matchesFilters,
  resourceColumns,
  resourceDayBounds,
  scrollTimeFor,
  toBusinessHours,
  toEventInputs,
  type CalendarRow,
} from './model';

function row(overrides: Partial<CalendarRow> = {}): CalendarRow {
  return {
    event_type: 'job',
    id: 'job-1',
    job_number: 1001,
    status: 'scheduled',
    starts_at: '2026-09-28T14:00:00Z',
    ends_at: '2026-09-28T16:00:00Z',
    is_busy_block: false,
    customer_id: 'cust-1',
    customer_name: 'Jane Doe',
    vehicle_id: 'veh-1',
    vehicle_label: '2021 Honda Civic',
    location_type: 'shop',
    service_address: null,
    resource_id: 'bay-1',
    assigned_member_ids: ['m-1'],
    member_id: null,
    title: 'Jane Doe',
    ...overrides,
  };
}

const NO_FILTERS = { memberId: null, resourceId: null };

describe('calendar model', () => {
  it('filters jobs by team member and resource on the client', () => {
    const job = row();
    expect(matchesFilters(job, NO_FILTERS)).toBe(true);
    expect(matchesFilters(job, { memberId: 'm-1', resourceId: null })).toBe(true);
    expect(matchesFilters(job, { memberId: 'm-2', resourceId: null })).toBe(false);
    expect(matchesFilters(job, { memberId: null, resourceId: 'bay-2' })).toBe(false);
  });

  it('keeps shop-wide blocks for every member and member blocks for that member', () => {
    const shopBlock = row({ event_type: 'blocked_time', member_id: null });
    const memberBlock = row({ event_type: 'blocked_time', member_id: 'm-1' });
    expect(matchesFilters(shopBlock, { memberId: 'm-9', resourceId: 'bay-9' })).toBe(true);
    expect(matchesFilters(memberBlock, { memberId: 'm-1', resourceId: null })).toBe(true);
    expect(matchesFilters(memberBlock, { memberId: 'm-2', resourceId: null })).toBe(false);
  });

  it('maps jobs, anonymized busy blocks and blocked times to FullCalendar events', () => {
    const events = toEventInputs(
      [
        row(),
        row({ id: 'job-2', is_busy_block: true, job_number: null, status: null, title: null }),
        row({ id: 'blk-1', event_type: 'blocked_time', title: 'Holiday', member_id: null }),
      ],
      NO_FILTERS,
      true,
    );
    expect(events).toHaveLength(3);
    const [job, busy, block] = events;
    expect(job).toMatchObject({
      id: 'job:job-1',
      title: '#1001 · Jane Doe',
      editable: true,
      interactive: true,
    });
    expect(String(job?.backgroundColor)).toContain('var(--dc-');
    expect(busy).toMatchObject({
      id: 'job:job-2',
      title: 'Busy',
      editable: false,
      interactive: false,
    });
    expect(block).toMatchObject({ id: 'block:blk-1', display: 'background', title: 'Holiday' });
  });

  it('only lets managers move open jobs', () => {
    const open = row();
    const done = row({ id: 'job-3', status: 'completed' });
    expect(toEventInputs([open, done], NO_FILTERS, true).map((e) => e.editable)).toEqual([
      true,
      false,
    ]);
    expect(toEventInputs([open], NO_FILTERS, false)[0]?.editable).toBe(false);
  });

  it('round-trips event ids', () => {
    expect(jobIdFromEventId(jobEventId('abc'))).toBe('abc');
    expect(jobIdFromEventId(blockEventId('abc'))).toBeNull();
  });

  it('titles and describes rows without leaking busy-block details', () => {
    expect(eventTitle(row({ title: null }))).toBe('#1001');
    expect(eventTitle(row({ event_type: 'blocked_time', title: null }))).toBe('Blocked');
    expect(describeRow(row({ is_busy_block: true }))).toMatch(/Busy/);
    expect(
      describeRow(row({ location_type: 'mobile', service_address: '1 Main St, Birmingham' })),
    ).toContain('1 Main St, Birmingham');
  });

  it('converts business hours and picks a scroll time', () => {
    expect(toBusinessHours([])).toBe(false);
    expect(
      toBusinessHours([
        { weekday: 1, opens_at: '08:30:00', closes_at: '17:00:00' },
        { weekday: 6, opens_at: '09:00:00', closes_at: '24:00:00' },
      ]),
    ).toEqual([
      { daysOfWeek: [1], startTime: '08:30', endTime: '17:00' },
      { daysOfWeek: [6], startTime: '09:00', endTime: '24:00' },
    ]);
    expect(scrollTimeFor([{ weekday: 1, opens_at: '08:30:00', closes_at: '17:00:00' }])).toBe(
      '07:00:00',
    );
    expect(scrollTimeFor([{ weekday: 1, opens_at: '00:30:00', closes_at: '17:00:00' }])).toBe(
      '00:00:00',
    );
    expect(scrollTimeFor([])).toBe('07:00:00');
  });

  it('validates stored view names', () => {
    expect(isCalendarView('timeGridWeek')).toBe(true);
    expect(isCalendarView('resourceTimeline')).toBe(false);
    expect(isCalendarView(null)).toBe(false);
  });
});

describe('resource view', () => {
  const RESOURCES = [
    { id: 'bay-1', name: 'Bay 1', active: true, archived_at: null },
    { id: 'van-1', name: 'Van 1', active: true, archived_at: null },
    { id: 'bay-old', name: 'Old bay', active: false, archived_at: '2026-01-01T00:00:00Z' },
  ];

  it('is a view of its own, separate from the FullCalendar grid views', () => {
    expect(isCalendarView('resourceDay')).toBe(true);
    expect(isGridView('resourceDay')).toBe(false);
    expect(isGridView('timeGridWeek')).toBe(true);
  });

  it('builds a column per active bay / van, inactive ones still holding jobs, then unassigned', () => {
    const rows = [
      row(),
      row({ id: 'job-2', resource_id: 'bay-old' }),
      row({ id: 'job-3', resource_id: 'gone' }),
      row({ id: 'blk', event_type: 'blocked_time', resource_id: 'ignored' }),
    ];
    expect(resourceColumns(RESOURCES, rows, null)).toEqual([
      { id: 'bay-1', name: 'Bay 1', inactive: false },
      { id: 'van-1', name: 'Van 1', inactive: false },
      { id: 'bay-old', name: 'Old bay', inactive: true },
      { id: 'gone', name: 'Unavailable bay / van', inactive: true },
      { id: null, name: 'No bay / van', inactive: false },
    ]);
    expect(resourceColumns(RESOURCES, rows, 'van-1')).toEqual([
      { id: 'van-1', name: 'Van 1', inactive: false },
    ]);
    expect(resourceColumns([], [], null)).toEqual([
      { id: null, name: 'No bay / van', inactive: false },
    ]);
  });

  it('puts each job in its resource column and blocked time in every column', () => {
    const rows = [
      row(),
      row({ id: 'job-2', resource_id: null }),
      row({ id: 'blk', event_type: 'blocked_time', title: 'Holiday' }),
    ];
    const ids = (column: string | null) =>
      columnEventInputs(rows, NO_FILTERS, column, true).map((e) => e.id);
    expect(ids('bay-1')).toEqual(['job:job-1', 'block:blk']);
    expect(ids(null)).toEqual(['job:job-2', 'block:blk']);
    expect(ids('van-1')).toEqual(['block:blk']);
    // the team filter still applies inside a column
    expect(
      columnEventInputs(rows, { memberId: 'm-2', resourceId: null }, 'bay-1', true).map(
        (e) => e.id,
      ),
    ).toEqual(['block:blk']);
  });

  it('shows the business day ± 1 h, widened so no job is cut off (shop clock)', () => {
    const hours = [{ weekday: 1, opens_at: '08:00:00', closes_at: '17:30:00' }];
    // Mon 28 Sep 2026, America/Chicago (UTC−5)
    expect(resourceDayBounds(hours, [], '2026-09-28', 'America/Chicago')).toEqual({
      slotMinTime: '07:00:00',
      slotMaxTime: '19:00:00',
    });
    const early = row({ starts_at: '2026-09-28T10:30:00Z', ends_at: '2026-09-29T03:10:00Z' });
    expect(resourceDayBounds(hours, [early], '2026-09-28', 'America/Chicago')).toEqual({
      slotMinTime: '05:00:00',
      slotMaxTime: '23:00:00',
    });
    const overnight = row({ starts_at: '2026-09-28T03:00:00Z', ends_at: '2026-09-29T06:00:00Z' });
    expect(resourceDayBounds(hours, [overnight], '2026-09-28', 'America/Chicago')).toEqual({
      slotMinTime: '00:00:00',
      slotMaxTime: '24:00:00',
    });
    // closed day with no jobs → a sensible default window
    expect(resourceDayBounds(hours, [], '2026-09-27', 'America/Chicago')).toEqual({
      slotMinTime: '07:00:00',
      slotMaxTime: '19:00:00',
    });
  });
});
