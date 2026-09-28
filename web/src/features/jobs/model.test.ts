import { describe, expect, it } from 'vitest';
import {
  addMinutesLocal,
  allowedTransitions,
  clampUnit,
  customerName,
  DEFAULT_JOB_FILTERS,
  describeFollowup,
  formatVideoLength,
  gateBlockers,
  isGatedMove,
  formatAddress,
  formatDuration,
  formLink,
  hasActiveFilters,
  inspectionDetailsDraft,
  jobFiltersToParams,
  jobPhotoPath,
  parseInspectionDetails,
  parseJobFilters,
  photoExtension,
  photoProblem,
  movedLineOrder,
  scheduleToUtc,
  servicesSummary,
  signaturePath,
  statusNeedsSchedule,
  statusSteps,
  sumDurations,
  vehicleLabel,
  type StatusTransition,
  waivedBlockers,
} from './model';

const T = (
  from: StatusTransition['from_status'],
  to: StatusTransition['to_status'],
  direction: 'forward' | 'backward',
  technician_allowed = false,
): StatusTransition => ({ from_status: from, to_status: to, direction, technician_allowed });

// A slice of job_status_transitions (reference data from 0006).
const TRANSITIONS: StatusTransition[] = [
  T('scheduled', 'confirmed', 'forward'),
  T('scheduled', 'en_route', 'forward', true),
  T('scheduled', 'in_progress', 'forward', true),
  T('scheduled', 'cancelled', 'forward'),
  T('scheduled', 'no_show', 'forward'),
  T('scheduled', 'requested', 'backward'),
  T('in_progress', 'completed', 'forward', true),
  T('in_progress', 'scheduled', 'backward'),
  T('cancelled', 'scheduled', 'backward'),
];

describe('status workflow', () => {
  it('gives technicians only technician-allowed forward edges', () => {
    const tech = allowedTransitions(TRANSITIONS, 'scheduled', 'technician').map((t) => t.to_status);
    expect(tech).toEqual(['en_route', 'in_progress']);
    const manager = allowedTransitions(TRANSITIONS, 'scheduled', 'manager').map((t) => t.to_status);
    expect(manager).toEqual([
      'confirmed',
      'en_route',
      'in_progress',
      'cancelled',
      'no_show',
      'requested',
    ]);
  });

  it('builds the stepper with done/current/upcoming states and clickable steps', () => {
    const allowed = allowedTransitions(TRANSITIONS, 'in_progress', 'owner');
    const steps = statusSteps('in_progress', allowed);
    expect(steps.map((s) => s.state)).toEqual([
      'done',
      'done',
      'done',
      'done',
      'current',
      'upcoming',
    ]);
    expect(steps.filter((s) => s.transition).map((s) => s.status)).toEqual([
      'scheduled',
      'completed',
    ]);
  });

  it('shows no current step for side exits but keeps reinstatement clickable', () => {
    const steps = statusSteps('cancelled', allowedTransitions(TRANSITIONS, 'cancelled', 'admin'));
    expect(steps.every((s) => s.state === 'upcoming')).toBe(true);
    expect(steps.find((s) => s.status === 'scheduled')?.transition).not.toBeNull();
    expect(
      statusSteps('cancelled', allowedTransitions(TRANSITIONS, 'cancelled', 'technician')).some(
        (s) => s.transition,
      ),
    ).toBe(false);
  });

  it('knows which statuses need a schedule', () => {
    expect(statusNeedsSchedule('requested')).toBe(false);
    expect(statusNeedsSchedule('cancelled')).toBe(false);
    expect(statusNeedsSchedule('confirmed')).toBe(true);
  });
});

describe('labels', () => {
  it('names customers and vehicles', () => {
    expect(customerName({ first_name: ' Jane ', last_name: 'Doe', company: 'Acme' })).toBe(
      'Jane Doe',
    );
    expect(customerName({ first_name: null, last_name: null, company: 'Acme' })).toBe('Acme');
    expect(customerName(null)).toBe('Unknown customer');
    expect(
      vehicleLabel({ year: 2021, make: 'Honda', model: 'Civic', trim: 'EX', color: 'Blue' }, true),
    ).toBe('2021 Honda Civic (EX, Blue)');
    expect(vehicleLabel(null)).toBe('No vehicle');
  });

  it('summarizes services and formats durations and addresses', () => {
    expect(servicesSummary([])).toBe('—');
    expect(servicesSummary(['Wash', 'Wax', 'Clay', 'Coat'])).toBe('Wash, Wax +2 more');
    expect(formatDuration(0)).toBe('0 min');
    expect(formatDuration(45)).toBe('45 min');
    expect(formatDuration(120)).toBe('2 h');
    expect(formatDuration(150)).toBe('2 h 30 min');
    expect(sumDurations([60, null, 30, -5, undefined])).toBe(90);
    expect(
      formatAddress({
        line1: '1 Main St',
        line2: 'Apt 2',
        city: 'Birmingham',
        region: 'AL',
        postalCode: '35203',
      }),
    ).toBe('1 Main St Apt 2, Birmingham, AL 35203');
    expect(formatAddress({ line1: ' ', city: null, region: null, postalCode: null })).toBeNull();
  });
});

describe('list filters <-> URL', () => {
  it('round-trips filters and drops invalid values', () => {
    const params = new URLSearchParams(
      'status=scheduled,bogus,confirmed,scheduled&from=2026-09-01&to=nope&assignee=m-1&q=civic&sort=total&dir=asc&page=3',
    );
    const filters = parseJobFilters(params);
    expect(filters).toEqual({
      statuses: ['scheduled', 'confirmed'],
      from: '2026-09-01',
      to: null,
      assigneeId: 'm-1',
      search: 'civic',
      sort: 'total',
      ascending: true,
      page: 3,
    });
    expect(parseJobFilters(jobFiltersToParams(filters))).toEqual(filters);
    expect(jobFiltersToParams(DEFAULT_JOB_FILTERS).toString()).toBe('');
    expect(hasActiveFilters(DEFAULT_JOB_FILTERS)).toBe(false);
    expect(hasActiveFilters(filters)).toBe(true);
    expect(parseJobFilters(new URLSearchParams('page=-2')).page).toBe(1);
  });
});

describe('schedule math in the shop timezone', () => {
  const tz = 'America/Chicago';

  it('converts shop-local wall clock to UTC regardless of the browser zone', () => {
    expect(
      scheduleToUtc(
        { date: '2026-09-28', time: '09:00' },
        { date: '2026-09-28', time: '11:30' },
        tz,
      ),
    ).toEqual({ start: '2026-09-28T14:00:00.000Z', end: '2026-09-28T16:30:00.000Z' });
  });

  it('adds minutes across the DST change', () => {
    // 00:30 CDT + 3 h of real time = 02:30 CST (clocks fall back at 02:00).
    expect(addMinutesLocal({ date: '2026-11-01', time: '00:30' }, 180, tz)).toEqual({
      date: '2026-11-01',
      time: '02:30',
    });
    expect(addMinutesLocal({ date: '', time: '09:00' }, 60, tz)).toBeNull();
  });

  it('rejects incomplete, reversed and over-long schedules', () => {
    expect(
      scheduleToUtc({ date: '', time: '09:00' }, { date: '2026-09-28', time: '10:00' }, tz),
    ).toEqual({
      error: 'Enter a start date and time.',
    });
    expect(
      scheduleToUtc(
        { date: '2026-09-28', time: '10:00' },
        { date: '2026-09-28', time: '10:00' },
        tz,
      ),
    ).toEqual({ error: 'The end must be after the start.' });
    expect(
      scheduleToUtc(
        { date: '2026-09-01', time: '10:00' },
        { date: '2026-10-05', time: '10:00' },
        tz,
      ),
    ).toEqual({ error: 'A job can span at most 31 days.' });
  });
});

describe('storage object names', () => {
  it('validates photo files', () => {
    expect(photoExtension({ type: 'image/jpeg', name: 'a.bin' })).toBe('jpg');
    expect(photoExtension({ type: '', name: 'IMG_1.JPEG' })).toBe('jpg');
    expect(photoExtension({ type: 'application/pdf', name: 'a.pdf' })).toBeNull();
    expect(photoProblem({ type: 'image/png', name: 'a.png', size: 10 })).toBeNull();
    expect(photoProblem({ type: 'image/png', name: 'a.png', size: 21 * 1024 * 1024 })).toMatch(
      /20 MB/,
    );
    expect(photoProblem({ type: 'text/plain', name: 'a.txt', size: 1 })).toMatch(/JPEG/);
  });

  it('builds bucket paths the storage policies accept', () => {
    expect(jobPhotoPath('shop', 'job', 'jpg', 'id')).toBe('shop/job/id.jpg');
    expect(signaturePath('shop', 'inspections', 'insp', 'id')).toBe('shop/inspections/insp/id.png');
    expect(formLink('https://app.test/', 'tok')).toBe('https://app.test/f/tok');
  });

  it('clamps diagram taps to 0..1', () => {
    expect(clampUnit(-0.2)).toBe(0);
    expect(clampUnit(1.7)).toBe(1);
    expect(clampUnit(0.12345)).toBe(0.123);
    expect(clampUnit(Number.NaN)).toBe(0);
  });
});

describe('parseInspectionDetails', () => {
  it('turns the form strings into columns', () => {
    expect(parseInspectionDetails({ mileage: ' 45210 ', fuel: '50', notes: '  ok ' })).toEqual({
      ok: true,
      details: { mileage: 45210, fuel_level: 50, notes: 'ok' },
    });
    expect(parseInspectionDetails({ mileage: '', fuel: '', notes: ' ' })).toEqual({
      ok: true,
      details: { mileage: null, fuel_level: null, notes: null },
    });
  });

  it('rejects bad mileage and fuel', () => {
    expect(parseInspectionDetails({ mileage: '12.5', fuel: '', notes: '' })).toMatchObject({
      ok: false,
    });
    expect(parseInspectionDetails({ mileage: '', fuel: '101', notes: '' })).toMatchObject({
      ok: false,
      error: 'Fuel level is a percentage from 0 to 100.',
    });
  });

  it('round-trips a server row', () => {
    expect(inspectionDetailsDraft({ mileage: 45210, fuel_level: 0, notes: null })).toEqual({
      mileage: '45210',
      fuel: '0',
      notes: '',
    });
  });
});

describe('movedLineOrder', () => {
  const rows = [{ id: 'a' }, { id: 'b' }, { id: 'c' }];

  it('returns the full id list with the line moved one step', () => {
    expect(movedLineOrder(rows, 1, -1)).toEqual(['b', 'a', 'c']);
    expect(movedLineOrder(rows, 1, 1)).toEqual(['a', 'c', 'b']);
    expect(movedLineOrder(rows, 0, 1)).toEqual(['b', 'a', 'c']);
  });

  it('ignores moves off either end', () => {
    expect(movedLineOrder(rows, 0, -1)).toBeNull();
    expect(movedLineOrder(rows, 2, 1)).toBeNull();
    expect(movedLineOrder([], 0, 1)).toBeNull();
  });
});

describe('completion gates (P-11)', () => {
  const state = {
    open_required_items: [
      { id: 'i1', label: 'Vacuum interior' },
      { id: 'i2', label: 'Tire shine' },
    ],
    before_photos: { required: 2, have: 0 },
    after_photos: { required: 3, have: 1 },
  };

  it('gates completing and starting, never backward moves', () => {
    expect(isGatedMove('in_progress', 'completed')).toBe(true);
    expect(isGatedMove('confirmed', 'in_progress')).toBe(true);
    expect(isGatedMove('completed', 'in_progress')).toBe(false);
    expect(isGatedMove('scheduled', 'confirmed')).toBe(false);
  });

  it('lists what blocks the move, like the server does', () => {
    expect(gateBlockers(state, 'in_progress', 'completed')).toEqual([
      { key: 'checklist', text: 'Required checklist items not done: Vacuum interior, Tire shine' },
      { key: 'after_photos', text: '3 “after” photos needed (1 so far)' },
    ]);
    expect(gateBlockers(state, 'scheduled', 'in_progress')).toEqual([
      { key: 'before_photos', text: '2 “before” photos needed (0 so far)' },
    ]);
    expect(
      gateBlockers(
        {
          open_required_items: [],
          before_photos: { required: 0, have: 0 },
          after_photos: { required: 1, have: 1 },
        },
        'in_progress',
        'completed',
      ),
    ).toEqual([]);
    expect(gateBlockers(state, 'completed', 'in_progress')).toEqual([]);
  });
});

describe('deposit follow-ups and videos', () => {
  const status = { enabled: true, paused: false, attempts_sent: 1, max_attempts: 3, next_at: null };

  it('describes the reminder state in the shop zone', () => {
    expect(describeFollowup({ ...status, enabled: false }, 'America/Chicago')).toBe(
      'Automatic deposit reminders are off.',
    );
    expect(describeFollowup({ ...status, paused: true }, 'America/Chicago')).toBe(
      'Deposit reminders are paused · 1 of 3 sent.',
    );
    expect(
      describeFollowup({ ...status, next_at: '2026-10-06T15:00:00Z' }, 'America/Chicago'),
    ).toBe('Next reminder Tue, Oct 6, 2026 · 10:00 AM · 1 of 3 sent.');
    expect(describeFollowup({ ...status, attempts_sent: 3 }, 'America/Chicago')).toBe(
      'All deposit reminders sent (3 of 3 sent).',
    );
    expect(describeFollowup(status, 'America/Chicago')).toBe('No deposit reminder is scheduled.');
  });

  it('formats video lengths', () => {
    expect(formatVideoLength(65)).toBe('1:05');
    expect(formatVideoLength(null)).toBeNull();
    expect(formatVideoLength(0)).toBeNull();
  });
});

describe('waivedBlockers', () => {
  it('describes the stored snapshot of what was waived', () => {
    expect(
      waivedBlockers({
        open_required_items: [
          { id: 'a', label: 'Vacuum' },
          { id: 'b', label: 'Wipe glass' },
        ],
        after_photos: { required: 3, have: 0 },
      }).map((b) => b.text),
    ).toEqual([
      'Required checklist items not done: Vacuum, Wipe glass',
      '3 “after” photos needed (0 so far)',
    ]);
    expect(waivedBlockers({ before_photos: { required: 1, have: 0 } })).toEqual([
      { key: 'before_photos', text: '1 “before” photo needed (0 so far)' },
    ]);
  });

  it('skips malformed parts', () => {
    expect(waivedBlockers(null)).toEqual([]);
    expect(waivedBlockers([])).toEqual([]);
    expect(waivedBlockers({ open_required_items: 'x', after_photos: { required: '2' } })).toEqual(
      [],
    );
  });
});
