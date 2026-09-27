import { describe, expect, it } from 'vitest';
import {
  entryFormSchema,
  entryFormToWrite,
  formatClock,
  formatDuration,
  formatHoursDecimal,
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

  it('rejects clock-out before clock-in and half-filled clock-outs', () => {
    expect(
      entryFormSchema.safeParse({ ...base, outTime: '07:00' }).error?.issues[0]?.message,
    ).toMatch(/after clock-in/);
    expect(entryFormSchema.safeParse({ ...base, outTime: '' }).error?.issues[0]?.path).toEqual([
      'outTime',
    ]);
  });
});
