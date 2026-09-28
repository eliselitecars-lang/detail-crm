import { describe, expect, it } from 'vitest';
import {
  clockOrderError,
  entryEditPatch,
  entryFormSchema,
  entryFormTimes,
  entryFormToWrite,
  formatClock,
  formatDuration,
  formatAccuracy,
  formatHoursDecimal,
  geoStamp,
  mapLink,
  rangeError,
  splitByShopDay,
  summarize,
  weekStart,
  type TimeEntry,
} from './model';

const TZ = 'America/Chicago';
const H = 3_600_000;
const ms = (iso: string) => new Date(iso).getTime();

const entry = (over: Partial<TimeEntry>): TimeEntry => ({
  id: 'e',
  member_id: 'm1',
  job_id: null,
  kind: 'shift',
  clock_in: '2026-03-10T14:00:00Z',
  clock_out: '2026-03-10T22:00:00Z',
  source: 'app',
  notes: null,
  job: null,
  clock_in_lat: null,
  clock_in_lng: null,
  clock_in_accuracy_m: null,
  clock_out_lat: null,
  clock_out_lng: null,
  clock_out_accuracy_m: null,
  ...over,
});

describe('formatting', () => {
  it('formats durations, clocks and decimal hours', () => {
    expect(formatDuration(0)).toBe('0m');
    expect(formatDuration(45 * 60_000)).toBe('45m');
    expect(formatDuration(7.5 * H)).toBe('7h 30m');
    expect(formatDuration(-5)).toBe('0m');
    expect(formatClock(H + 5 * 60_000 + 9_000)).toBe('1:05:09');
    expect(formatHoursDecimal(7.5 * H)).toBe('7.50');
  });
});

describe('splitByShopDay', () => {
  it('splits an overnight entry at shop-local midnight (not UTC)', () => {
    // 10 PM → 2 AM Chicago (CDT, UTC-5) = 03:00Z → 07:00Z
    const parts = splitByShopDay(ms('2026-03-11T03:00:00Z'), ms('2026-03-11T07:00:00Z'), TZ);
    expect(parts).toEqual([
      { day: '2026-03-10', ms: 2 * H },
      { day: '2026-03-11', ms: 2 * H },
    ]);
  });

  it('handles the 23-hour spring-forward day', () => {
    // whole local day 2026-03-08 in Chicago is 23 hours long
    const parts = splitByShopDay(ms('2026-03-08T06:00:00Z'), ms('2026-03-09T05:00:00Z'), TZ);
    expect(parts).toEqual([{ day: '2026-03-08', ms: 23 * H }]);
  });

  it('clips to the range', () => {
    const parts = splitByShopDay(
      ms('2026-03-10T14:00:00Z'),
      ms('2026-03-10T22:00:00Z'),
      TZ,
      ms('2026-03-10T16:00:00Z'),
      ms('2026-03-10T18:00:00Z'),
    );
    expect(parts).toEqual([{ day: '2026-03-10', ms: 2 * H }]);
  });
});

describe('summarize', () => {
  it('totals shift and job time separately per member and day, open entries up to now', () => {
    const totals = summarize(
      [
        entry({ id: 'a' }), // 8h shift on the 10th
        entry({
          id: 'b',
          kind: 'job',
          job_id: 'j',
          clock_in: '2026-03-10T15:00:00Z',
          clock_out: '2026-03-10T17:00:00Z',
        }), // 2h job
        entry({ id: 'c', member_id: 'm2', clock_in: '2026-03-11T14:00:00Z', clock_out: null }),
      ],
      TZ,
      ms('2026-03-09T05:00:00Z'),
      ms('2026-03-16T05:00:00Z'),
      ms('2026-03-11T15:30:00Z'),
    );
    const m1 = totals.find((t) => t.memberId === 'm1');
    const m2 = totals.find((t) => t.memberId === 'm2');
    expect(m1).toMatchObject({ shiftMs: 8 * H, jobMs: 2 * H, entries: 2, open: 0 });
    expect(m1?.days.get('2026-03-10')).toEqual({ shiftMs: 8 * H, jobMs: 2 * H });
    expect(m2).toMatchObject({ shiftMs: 1.5 * H, open: 1 });
  });
});

describe('range + week helpers', () => {
  it('validates ranges', () => {
    expect(rangeError('2026-03-01', '2026-03-07')).toBeNull();
    expect(rangeError('2026-03-07', '2026-03-01')).toMatch(/before/);
    expect(rangeError('2026-01-01', '2026-06-01')).toMatch(/at most/);
    expect(rangeError('', '2026-03-01')).toMatch(/valid/);
  });

  it('finds Monday of the week', () => {
    expect(weekStart('2026-03-11')).toBe('2026-03-09'); // Wednesday
    expect(weekStart('2026-03-09')).toBe('2026-03-09'); // Monday
    expect(weekStart('2026-03-15')).toBe('2026-03-09'); // Sunday
  });
});

describe('entry form', () => {
  const base = {
    memberId: 'm1',
    kind: 'shift' as const,
    jobId: '',
    inDate: '2026-03-10',
    inTime: '08:00',
    outDate: '2026-03-10',
    outTime: '16:30',
    notes: '',
  };

  it('converts shop-local wall clock to UTC instants', () => {
    expect(entryFormToWrite(entryFormSchema.parse(base), TZ)).toEqual({
      member_id: 'm1',
      kind: 'shift',
      job_id: null,
      clock_in: '2026-03-10T13:00:00.000Z',
      clock_out: '2026-03-10T21:30:00.000Z',
      notes: null,
    });
  });

  it('allows an open entry and requires a job for job time', () => {
    expect(
      entryFormToWrite(entryFormSchema.parse({ ...base, outDate: '', outTime: '' }), TZ).clock_out,
    ).toBeNull();
    const job = entryFormSchema.safeParse({ ...base, kind: 'job' });
    expect(job.error?.issues[0]?.path).toEqual(['jobId']);
  });

  it('rejects half-filled clock-outs; clock order is checked on instants', () => {
    expect(entryFormSchema.safeParse({ ...base, outTime: '' }).error?.issues[0]?.path).toEqual([
      'outTime',
    ]);
    const write = entryFormToWrite(entryFormSchema.parse({ ...base, outTime: '07:00' }), TZ);
    expect(clockOrderError(write.clock_in, write.clock_out)).toMatch(/after clock-in/);
    expect(clockOrderError('2026-03-10T13:00:00Z', '2026-03-10T13:00:00Z')).toBeNull();
    expect(clockOrderError('2026-03-10T13:00:00Z', null)).toBeNull();
    // Fall-back day in Chicago: 01:50 CDT (06:50Z) → 01:10 CST (07:10Z) is in order
    // although the wall-clock strings are not.
    expect(clockOrderError('2026-11-01T06:50:00Z', '2026-11-01T07:10:00Z')).toBeNull();
  });
});

describe('entry edit patch', () => {
  const stored = {
    job_id: 'j1',
    clock_in: '2026-03-10T15:15:52.123+00:00', // 10:15:52 Chicago (CDT)
    clock_out: '2026-03-10T17:40:31+00:00',
    notes: 'old',
  };
  const form = (over: Partial<Parameters<typeof entryFormSchema.parse>[0]> = {}) =>
    entryFormSchema.parse({
      memberId: 'm1',
      kind: 'job',
      jobId: 'j1',
      ...entryFormTimes(stored, TZ),
      notes: 'old',
      ...over,
    });

  it('shows minute-precision local times', () => {
    expect(entryFormTimes(stored, TZ)).toEqual({
      inDate: '2026-03-10',
      inTime: '10:15',
      outDate: '2026-03-10',
      outTime: '12:40',
    });
    expect(entryFormTimes({ ...stored, clock_out: null }, TZ)).toMatchObject({
      outDate: '',
      outTime: '',
    });
  });

  it('a notes-only edit leaves clock_in/clock_out (and their seconds) alone', () => {
    expect(entryEditPatch(form({ notes: 'new' }), TZ, stored)).toEqual({ notes: 'new' });
    expect(entryEditPatch(form(), TZ, stored)).toEqual({});
    expect(entryEditPatch(form({ jobId: 'j2' }), TZ, stored)).toEqual({ job_id: 'j2' });
    expect(entryEditPatch(form({ notes: '' }), TZ, stored)).toEqual({ notes: null });
  });

  it('sends only the clock field the user changed', () => {
    expect(entryEditPatch(form({ outTime: '13:00' }), TZ, stored)).toEqual({
      clock_out: '2026-03-10T18:00:00.000Z',
    });
    expect(entryEditPatch(form({ inTime: '10:00' }), TZ, stored)).toEqual({
      clock_in: '2026-03-10T15:00:00.000Z',
    });
    expect(entryEditPatch(form({ outDate: '', outTime: '' }), TZ, stored)).toEqual({
      clock_out: null,
    });
  });

  it('keeps an entry in the repeated fall-back hour where it is', () => {
    // 01:30 CST on 2026-11-01 (the SECOND 01:30 in Chicago).
    const dst = { job_id: null, clock_in: '2026-11-01T07:30:00Z', clock_out: null, notes: null };
    const v = entryFormSchema.parse({
      memberId: 'm1',
      kind: 'shift',
      jobId: '',
      ...entryFormTimes(dst, TZ),
      notes: 'fixed',
    });
    expect(entryEditPatch(v, TZ, dst)).toEqual({ notes: 'fixed' });
  });
});

describe('geostamps', () => {
  it('reads recorded locations and builds map links', () => {
    const e = entry({ clock_in_lat: 41.8781, clock_in_lng: -87.6298, clock_in_accuracy_m: 12.4 });
    expect(geoStamp(e, 'in')).toEqual({ lat: 41.8781, lng: -87.6298, accuracyM: 12.4 });
    expect(geoStamp(e, 'out')).toBeNull();
    expect(mapLink({ lat: 41.8781, lng: -87.6298 })).toBe(
      'https://www.google.com/maps/search/?api=1&query=41.878100%2C-87.629800',
    );
    expect(formatAccuracy(12.4)).toBe('±12 m');
    expect(formatAccuracy(1540)).toBe('±1.5 km');
    expect(formatAccuracy(null)).toBe('');
  });
});
