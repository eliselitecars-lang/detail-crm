import { afterEach, describe, expect, it, vi } from 'vitest';
import {
  addLocalDays,
  formatDate,
  formatDateTime,
  formatInTz,
  formatLocalDate,
  formatLocalTime,
  formatTime,
  formatTimeRange,
  isLocalDate,
  isLocalTime,
  isValidTimeZone,
  localDaysBetween,
  localTimeToMinutes,
  shopDateRangeUtc,
  shopDayRangeUtc,
  shopLocalToUtcIso,
  shopToday,
  shopWeekday,
  startOfNextShopDayUtc,
  startOfShopDayUtc,
  utcToShopLocal,
} from './dates';

const NY = 'America/New_York';
const CHI = 'America/Chicago';
const PHX = 'America/Phoenix';
const SYD = 'Australia/Sydney';

describe('shopLocalToUtcIso', () => {
  it('converts standard and daylight time correctly', () => {
    expect(shopLocalToUtcIso('2026-01-15', '09:00', NY)).toBe('2026-01-15T14:00:00.000Z');
    expect(shopLocalToUtcIso('2026-07-15', '09:00', NY)).toBe('2026-07-15T13:00:00.000Z');
    expect(shopLocalToUtcIso('2026-07-15', '09:00', PHX)).toBe('2026-07-15T16:00:00.000Z');
  });

  it('moves non-existent spring-forward times forward (US)', () => {
    // 2026-03-08 02:30 does not exist in New York → 03:30 EDT
    expect(shopLocalToUtcIso('2026-03-08', '02:30', NY)).toBe('2026-03-08T07:30:00.000Z');
    expect(shopLocalToUtcIso('2026-03-08', '01:59', NY)).toBe('2026-03-08T06:59:00.000Z');
    expect(shopLocalToUtcIso('2026-03-08', '03:00', NY)).toBe('2026-03-08T07:00:00.000Z');
  });

  it('resolves ambiguous fall-back times to the first occurrence', () => {
    // 2026-11-01 01:30 happens twice in New York; first is EDT (-04:00)
    expect(shopLocalToUtcIso('2026-11-01', '01:30', NY)).toBe('2026-11-01T05:30:00.000Z');
    expect(shopLocalToUtcIso('2026-11-01', '02:00', NY)).toBe('2026-11-01T07:00:00.000Z');
  });

  it('handles a DST change at midnight (Havana: 00:00 → 01:00)', () => {
    const { from } = shopDayRangeUtc('2026-03-08', 'America/Havana');
    expect(utcToShopLocal(from, 'America/Havana')).toEqual({ date: '2026-03-08', time: '01:00' });
  });

  it('is independent of the runtime time zone', () => {
    // vite.config pins TZ for tests to a zone different from every shop zone used here.
    expect(Intl.DateTimeFormat().resolvedOptions().timeZone).toBe('Pacific/Honolulu');
  });

  it('handles southern-hemisphere DST', () => {
    // Sydney: AEDT (+11) in January, AEST (+10) in July
    expect(shopLocalToUtcIso('2026-01-10', '10:00', SYD)).toBe('2026-01-09T23:00:00.000Z');
    expect(shopLocalToUtcIso('2026-07-10', '10:00', SYD)).toBe('2026-07-10T00:00:00.000Z');
  });

  it('rejects malformed input', () => {
    expect(() => shopLocalToUtcIso('2026-02-30', '09:00', NY)).toThrow(RangeError);
    expect(() => shopLocalToUtcIso('2026-02-10', '25:00', NY)).toThrow(RangeError);
    expect(() => shopLocalToUtcIso('02/10/2026', '09:00', NY)).toThrow(RangeError);
  });
});

describe('utcToShopLocal / formatting in the shop timezone', () => {
  it('renders the shop wall clock regardless of the browser zone', () => {
    expect(utcToShopLocal('2026-03-08T07:30:00.000Z', NY)).toEqual({
      date: '2026-03-08',
      time: '03:30',
    });
    expect(utcToShopLocal('2026-03-08T06:59:00.000Z', NY)).toEqual({
      date: '2026-03-08',
      time: '01:59',
    });
    // Late-evening UTC is still "yesterday" in Chicago
    expect(utcToShopLocal('2026-06-01T03:00:00Z', CHI)).toEqual({
      date: '2026-05-31',
      time: '22:00',
    });
  });

  it('round-trips local → UTC → local across both DST changes', () => {
    for (const [date, time] of [
      ['2026-03-07', '23:30'],
      ['2026-03-08', '03:15'],
      ['2026-11-01', '00:45'],
      ['2026-11-01', '03:00'],
      ['2026-12-31', '23:59'],
    ] as const) {
      expect(utcToShopLocal(shopLocalToUtcIso(date, time, NY), NY)).toEqual({ date, time });
    }
  });

  it('formats dates and times', () => {
    const iso = '2026-03-08T19:30:00.000Z';
    expect(formatDate(iso, NY)).toBe('Mar 8, 2026');
    expect(formatTime(iso, NY)).toBe('3:30 PM');
    expect(formatDateTime(iso, NY)).toBe('Sun, Mar 8, 2026 · 3:30 PM');
    expect(formatDate(null, NY)).toBe('—');
  });

  it('formats time ranges', () => {
    expect(formatTimeRange('2026-03-09T13:00:00Z', '2026-03-09T15:30:00Z', NY)).toBe(
      '9:00 – 11:30 AM',
    );
    expect(formatTimeRange('2026-03-09T15:00:00Z', '2026-03-09T19:00:00Z', NY)).toBe(
      '11:00 AM – 3:00 PM',
    );
    expect(formatTimeRange('2026-03-09T22:00:00Z', '2026-03-10T14:00:00Z', NY)).toBe(
      'Mar 9, 6:00 PM – Mar 10, 10:00 AM',
    );
  });
});

describe('shop day ranges', () => {
  it('spring-forward day is 23 hours long', () => {
    const { from, to } = shopDayRangeUtc('2026-03-08', NY);
    expect(from).toBe('2026-03-08T05:00:00.000Z');
    expect(to).toBe('2026-03-09T04:00:00.000Z');
    expect((Date.parse(to) - Date.parse(from)) / 3_600_000).toBe(23);
  });

  it('fall-back day is 25 hours long', () => {
    const { from, to } = shopDayRangeUtc('2026-11-01', NY);
    expect((Date.parse(to) - Date.parse(from)) / 3_600_000).toBe(25);
  });

  it('inclusive date ranges end at the next local midnight', () => {
    expect(shopDateRangeUtc('2026-03-01', '2026-03-31', CHI)).toEqual({
      from: '2026-03-01T06:00:00.000Z',
      to: '2026-04-01T05:00:00.000Z',
    });
  });

  it('start of the shop day for an instant', () => {
    expect(startOfShopDayUtc('2026-03-08T12:00:00Z', NY)).toBe('2026-03-08T05:00:00.000Z');
    expect(startOfNextShopDayUtc('2026-03-08T12:00:00Z', NY)).toBe('2026-03-09T04:00:00.000Z');
  });

  it('today and weekday are computed in the shop zone', () => {
    const now = new Date('2026-06-01T03:00:00Z'); // Sunday 22:00 in Chicago, Monday in UTC
    expect(shopToday(CHI, now)).toBe('2026-05-31');
    expect(shopWeekday(now, CHI)).toBe(0);
    expect(shopWeekday(now, 'UTC')).toBe(1);
  });
});

describe('local date helpers', () => {
  it('adds days with pure calendar math', () => {
    expect(addLocalDays('2026-03-07', 1)).toBe('2026-03-08');
    expect(addLocalDays('2026-03-08', 1)).toBe('2026-03-09');
    expect(addLocalDays('2026-12-31', 1)).toBe('2027-01-01');
    expect(addLocalDays('2026-03-01', -1)).toBe('2026-02-28');
    expect(localDaysBetween('2026-03-01', '2026-04-01')).toBe(31);
  });

  it('validates dates and zones', () => {
    expect(isLocalDate('2026-02-28')).toBe(true);
    expect(isLocalDate('2026-02-29')).toBe(false);
    expect(isValidTimeZone(NY)).toBe(true);
    expect(isValidTimeZone('Mars/Olympus')).toBe(false);
  });

  it('formats Postgres time values', () => {
    expect(formatLocalTime('09:00:00')).toBe('9:00 AM');
    expect(formatLocalTime('13:05')).toBe('1:05 PM');
    expect(formatLocalTime('00:00')).toBe('12:00 AM');
    expect(formatLocalTime(null)).toBe('—');
  });

  it('accepts the end-of-day "24:00:00" Postgres returns for a midnight close', () => {
    expect(formatLocalTime('24:00:00')).toBe('12:00 AM');
    expect(formatLocalTime('24:00')).toBe('12:00 AM');
    expect(localTimeToMinutes('24:00:00')).toBe(1440);
    expect(localTimeToMinutes('23:59:00')).toBe(1439);
    expect(isLocalTime('24:00')).toBe(true);
    expect(shopLocalToUtcIso('2026-03-07', '24:00', NY)).toBe(
      shopLocalToUtcIso('2026-03-08', '00:00', NY),
    );
    for (const bad of ['24:01', '24:00:01', '25:00', '24:30:00']) {
      expect(isLocalTime(bad)).toBe(false);
      expect(() => localTimeToMinutes(bad)).toThrow(RangeError);
    }
  });
});

describe('calendar dates (Postgres `date`) in any browser zone', () => {
  afterEach(() => {
    vi.unstubAllEnvs();
  });

  // West of every US shop (the suite default), UTC, and far east of it.
  it.each([
    ['Pacific/Honolulu', 600],
    ['Europe/London', 0],
    ['Asia/Tokyo', -540],
    ['Pacific/Kiritimati', -840],
  ])('shows the stored day when the browser is in %s', (browserZone, offsetMinutes) => {
    vi.stubEnv('TZ', browserZone);
    // The runtime zone switch took effect (Node re-reads TZ on assignment).
    expect(new Date('2026-03-08T12:00:00Z').getTimezoneOffset()).toBe(offsetMinutes);
    expect(formatLocalDate('2026-03-08')).toBe('Mar 8, 2026');
    expect(formatLocalDate('2026-03-08', 'EEE, MMM d')).toBe('Sun, Mar 8');
    expect(formatDate('2026-03-08', CHI)).toBe('Mar 8, 2026');
    expect(formatDate('2026-03-08', SYD)).toBe('Mar 8, 2026');
    expect(formatInTz('2026-12-31', 'Pacific/Honolulu', 'yyyy-MM-dd')).toBe('2026-12-31');
    expect(shopWeekday('2026-03-08', CHI)).toBe(0);
    expect(utcToShopLocal('2026-03-08', NY)).toEqual({ date: '2026-03-08', time: '00:00' });
    // Instants still convert to the shop zone.
    expect(formatDate('2026-03-08T03:00:00Z', CHI)).toBe('Mar 7, 2026');
  });

  it('handles empty and invalid calendar dates', () => {
    expect(formatLocalDate(null)).toBe('—');
    expect(formatLocalDate(undefined)).toBe('—');
    expect(formatLocalDate('2026-02-30')).toBe('');
    expect(formatDate('2026-02-30', CHI)).toBe('');
  });
});
