import { localTimeToMinutes, WEEKDAY_NAMES } from '@/lib/dates';

/** One opening interval, shop-local "HH:mm". closesAt "00:00" means midnight (24:00). */
export interface HoursInterval {
  opensAt: string;
  closesAt: string;
}

export interface DayHours {
  /** 0 = Sunday … 6 = Saturday (matches business_hours.weekday). */
  weekday: number;
  open: boolean;
  intervals: HoursInterval[];
}

/** Row shape for `business_hours` inserts. */
export interface BusinessHoursRow {
  weekday: number;
  opens_at: string;
  closes_at: string;
}

/** Editor starting point for a new shop — a typical week the owner adjusts. */
export function defaultWeek(): DayHours[] {
  return WEEKDAY_NAMES.map((_, weekday) => ({
    weekday,
    open: weekday >= 1 && weekday <= 5,
    intervals: [{ opensAt: '08:00', closesAt: '17:00' }],
  }));
}

function closeMinutes(closesAt: string): number {
  return closesAt === '00:00' ? 24 * 60 : localTimeToMinutes(closesAt);
}

/**
 * Per-day error messages (index = weekday), or an empty object when valid.
 * Mirrors the DB constraints: closes after opens, no overlapping intervals.
 */
export function validateWeek(days: readonly DayHours[]): Record<number, string> {
  const errors: Record<number, string> = {};
  for (const day of days) {
    if (!day.open) continue;
    if (day.intervals.length === 0) {
      errors[day.weekday] = 'Add opening hours or mark the day closed.';
      continue;
    }
    const ranges: [number, number][] = [];
    for (const interval of day.intervals) {
      if (!/^\d{2}:\d{2}$/.test(interval.opensAt) || !/^\d{2}:\d{2}$/.test(interval.closesAt)) {
        errors[day.weekday] = 'Enter both an opening and closing time.';
        break;
      }
      const start = localTimeToMinutes(interval.opensAt);
      const end = closeMinutes(interval.closesAt);
      if (end <= start) {
        errors[day.weekday] = 'Closing time must be after opening time.';
        break;
      }
      ranges.push([start, end]);
    }
    if (errors[day.weekday]) continue;
    ranges.sort((a, b) => a[0] - b[0]);
    for (let i = 1; i < ranges.length; i += 1) {
      const prev = ranges[i - 1];
      const cur = ranges[i];
      if (prev && cur && cur[0] < prev[1]) {
        errors[day.weekday] = 'Opening hours overlap.';
        break;
      }
    }
  }
  return errors;
}

/** Editor state → business_hours rows (closed days produce no rows). */
export function weekToRows(days: readonly DayHours[]): BusinessHoursRow[] {
  return days.flatMap((day) =>
    day.open
      ? day.intervals.map((interval) => ({
          weekday: day.weekday,
          opens_at: interval.opensAt,
          closes_at: interval.closesAt === '00:00' ? '24:00' : interval.closesAt,
        }))
      : [],
  );
}

/** business_hours rows → editor state. */
export function rowsToWeek(rows: readonly BusinessHoursRow[]): DayHours[] {
  return WEEKDAY_NAMES.map((_, weekday) => {
    const intervals = rows
      .filter((r) => r.weekday === weekday)
      .map((r) => ({
        opensAt: r.opens_at.slice(0, 5),
        closesAt: r.closes_at.startsWith('24:00') ? '00:00' : r.closes_at.slice(0, 5),
      }))
      .sort((a, b) => a.opensAt.localeCompare(b.opensAt));
    return {
      weekday,
      open: intervals.length > 0,
      intervals: intervals.length > 0 ? intervals : [{ opensAt: '08:00', closesAt: '17:00' }],
    };
  });
}
