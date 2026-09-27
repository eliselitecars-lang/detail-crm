/**
 * Report date ranges. Every range is an inclusive pair of shop-local
 * calendar dates ("yyyy-MM-dd") — the report RPCs convert them to instants in
 * the shop's time zone ([from 00:00, to + 1 00:00)). Weeks start on Monday
 * to match the server's date_trunc('week').
 */
import {
  addLocalDays,
  formatLocalDate,
  localDaysBetween,
  shopToday,
  type LocalDate,
} from '@/lib/dates';

export const PRESETS = ['today', 'week', 'month', 'last_month', 'ytd', 'custom'] as const;
export type Preset = (typeof PRESETS)[number];

export const PRESET_LABELS: Record<Preset, string> = {
  today: 'Today',
  week: 'This week',
  month: 'This month',
  last_month: 'Last month',
  ytd: 'Year to date',
  custom: 'Custom range',
};

export const BUCKETS = ['day', 'week', 'month'] as const;
export type Bucket = (typeof BUCKETS)[number];

export const BUCKET_LABELS: Record<Bucket, string> = {
  day: 'Daily',
  week: 'Weekly',
  month: 'Monthly',
};

export interface DateRange {
  from: LocalDate;
  to: LocalDate;
}

export function isPreset(value: unknown): value is Preset {
  return typeof value === 'string' && (PRESETS as readonly string[]).includes(value);
}

export function isBucket(value: unknown): value is Bucket {
  return typeof value === 'string' && (BUCKETS as readonly string[]).includes(value);
}

function parts(date: LocalDate): [number, number, number] {
  const [y = '1970', m = '01', d = '01'] = date.split('-');
  return [Number(y), Number(m), Number(d)];
}

function pad(n: number): string {
  return String(n).padStart(2, '0');
}

/** 0 = Monday … 6 = Sunday for a local date. */
function isoWeekdayIndex(date: LocalDate): number {
  const [y, m, d] = parts(date);
  return (new Date(Date.UTC(y, m - 1, d)).getUTCDay() + 6) % 7;
}

export function startOfMonth(date: LocalDate): LocalDate {
  const [y, m] = parts(date);
  return `${y}-${pad(m)}-01`;
}

/** Range for a preset relative to `today` (a shop-local date). */
export function presetRange(preset: Exclude<Preset, 'custom'>, today: LocalDate): DateRange {
  switch (preset) {
    case 'today':
      return { from: today, to: today };
    case 'week':
      return { from: addLocalDays(today, -isoWeekdayIndex(today)), to: today };
    case 'month':
      return { from: startOfMonth(today), to: today };
    case 'last_month': {
      const lastDay = addLocalDays(startOfMonth(today), -1);
      return { from: startOfMonth(lastDay), to: lastDay };
    }
    case 'ytd':
      return { from: `${parts(today)[0]}-01-01`, to: today };
  }
}

/** A sensible bucket for a range length: days up to ~2 months, weeks to ~6, then months. */
export function defaultBucket(range: DateRange): Bucket {
  const days = localDaysBetween(range.from, range.to) + 1;
  if (days <= 62) return 'day';
  if (days <= 190) return 'week';
  return 'month';
}

/** Longest range the server accepts (report_check_range: to − from ≤ 3660). */
export const MAX_RANGE_DAYS = 3660;

/** Validation message for a custom range, or null when it's usable. */
export function rangeError(range: Partial<DateRange>): string | null {
  const { from, to } = range;
  if (!from || !to) return 'Choose a start and end date.';
  if (!/^\d{4}-\d{2}-\d{2}$/.test(from) || !/^\d{4}-\d{2}-\d{2}$/.test(to))
    return 'Enter valid dates.';
  let span: number;
  try {
    span = localDaysBetween(from, to);
  } catch {
    return 'Enter valid dates.';
  }
  if (span < 0) return 'The end date must be on or after the start date.';
  if (span > MAX_RANGE_DAYS) return 'Reports are limited to 10 years.';
  return null;
}

export interface ReportParams {
  preset: Preset;
  range: DateRange;
  bucket: Bucket;
}

/**
 * Reads the report controls from URL search params, falling back to
 * "this month" in the shop's time zone. An invalid custom range keeps the
 * raw values (the picker shows the error) but `valid` is false.
 */
export function readParams(
  params: URLSearchParams,
  timeZone: string,
  now: Date = new Date(),
): ReportParams & { valid: boolean; error: string | null } {
  const today = shopToday(timeZone, now);
  const rawPreset = params.get('range');
  const preset: Preset = isPreset(rawPreset) ? rawPreset : 'month';
  let range: DateRange;
  let error: string | null = null;
  if (preset === 'custom') {
    const from = params.get('from') ?? '';
    const to = params.get('to') ?? '';
    error = rangeError({ from, to });
    range = { from, to };
  } else {
    range = presetRange(preset, today);
  }
  const rawBucket = params.get('bucket');
  const bucket: Bucket = isBucket(rawBucket) ? rawBucket : error ? 'day' : defaultBucket(range);
  return { preset, range, bucket, valid: error === null, error };
}

/** File-name part for CSV exports: "2026-03-01_to_2026-03-31". */
export function rangeFileSuffix(range: DateRange): string {
  return range.from === range.to ? range.from : `${range.from}_to_${range.to}`;
}

/** Label for a report bucket start date (short = chart axis). */
export function bucketLabel(date: string, bucket: Bucket, short = false): string {
  if (bucket === 'month') return formatLocalDate(date, short ? 'MMM yy' : 'MMMM yyyy');
  if (bucket === 'week')
    return short
      ? formatLocalDate(date, 'MMM d')
      : `Week of ${formatLocalDate(date, 'MMM d, yyyy')}`;
  return formatLocalDate(date, short ? 'MMM d' : 'EEE, MMM d, yyyy');
}
