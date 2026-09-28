import { addLocalDays, formatInTz, formatTimeRange, shopToday, utcToShopLocal } from '@/lib/dates';
import type { BlockedTime, CalendarEventKind } from './api';
import type { BlockedTimeFormInput, RecurrenceRule } from './schemas';

export const EVENT_KIND_LABELS: Record<CalendarEventKind, string> = {
  closed: 'Closed',
  time_off: 'Time off',
  meeting: 'Meeting',
  consultation: 'Consultation',
  reminder: 'Reminder',
  other: 'Other',
};

const WEEKDAY_SHORT = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

/** Reads blocked_times.recurrence (null when absent or malformed). */
export function readRecurrence(value: unknown): RecurrenceRule | null {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) return null;
  const v = value as Record<string, unknown>;
  if (v.freq !== 'day' && v.freq !== 'week' && v.freq !== 'month') return null;
  const rule: RecurrenceRule = { freq: v.freq };
  if (typeof v.interval === 'number') rule.interval = v.interval;
  if (Array.isArray(v.by_weekday)) {
    rule.by_weekday = v.by_weekday.filter((d): d is number => typeof d === 'number');
  }
  if (typeof v.until_date === 'string') rule.until_date = v.until_date;
  if (typeof v.count === 'number') rule.count = v.count;
  if (Array.isArray(v.except_dates)) {
    const dates = v.except_dates.filter((d): d is string => typeof d === 'string');
    if (dates.length > 0) rule.except_dates = dates;
  }
  return rule;
}

/** The rule with the occurrence starting on local `date` skipped (0115). */
export function skipOccurrence(rule: RecurrenceRule, date: string): RecurrenceRule {
  return { ...rule, except_dates: [...new Set([...(rule.except_dates ?? []), date])].sort() };
}

/** "Every 2 weeks on Mon, Wed · until Mar 31, 2027" */
export function describeRecurrence(rule: RecurrenceRule | null): string | null {
  if (!rule) return null;
  const n = rule.interval ?? 1;
  const unit = rule.freq === 'day' ? 'day' : rule.freq === 'week' ? 'week' : 'month';
  let text = n === 1 ? `Every ${unit}` : `Every ${n} ${unit}s`;
  if (rule.freq === 'week' && rule.by_weekday && rule.by_weekday.length > 0) {
    text += ` on ${[...rule.by_weekday]
      .sort()
      .map((d) => WEEKDAY_SHORT[d] ?? '')
      .join(', ')}`;
  }
  if (rule.until_date) text += ` · until ${formatInTz(rule.until_date, 'UTC', 'MMM d, yyyy')}`;
  else if (rule.count) text += ` · ${rule.count} time${rule.count === 1 ? '' : 's'}`;
  const skipped = rule.except_dates?.length ?? 0;
  if (skipped > 0) text += ` · ${skipped} date${skipped === 1 ? '' : 's'} skipped`;
  return text;
}

/** True when a block starts and ends at shop-local midnight (whole days). */
export function isAllDayBlock(
  block: Pick<BlockedTime, 'starts_at' | 'ends_at'>,
  tz: string,
): boolean {
  return (
    utcToShopLocal(block.starts_at, tz).time === '00:00' &&
    utcToShopLocal(block.ends_at, tz).time === '00:00'
  );
}

/** "Mon, Mar 9, 2026 · all day", "Mar 9 – Mar 11, 2026 · all day", "Mar 9, 2026 · 1:00 – 3:00 PM". */
export function describeBlock(
  block: Pick<BlockedTime, 'starts_at' | 'ends_at'>,
  tz: string,
): string {
  if (isAllDayBlock(block, tz)) {
    const first = utcToShopLocal(block.starts_at, tz).date;
    const last = addLocalDays(utcToShopLocal(block.ends_at, tz).date, -1);
    if (first === last) return `${formatInTz(first, tz, 'EEE, MMM d, yyyy')} · all day`;
    const sameYear = first.slice(0, 4) === last.slice(0, 4);
    return `${formatInTz(first, tz, sameYear ? 'MMM d' : 'MMM d, yyyy')} – ${formatInTz(last, tz, 'MMM d, yyyy')} · all day`;
  }
  const sameDay =
    utcToShopLocal(block.starts_at, tz).date === utcToShopLocal(block.ends_at, tz).date;
  if (sameDay) {
    return `${formatInTz(block.starts_at, tz, 'EEE, MMM d, yyyy')} · ${formatTimeRange(block.starts_at, block.ends_at, tz)}`;
  }
  return formatTimeRange(block.starts_at, block.ends_at, tz);
}

/** Form values for a new block (today, all day) or an existing one. */
export function blockToFormInput(block: BlockedTime | null, tz: string): BlockedTimeFormInput {
  const repeatDefaults = {
    repeat: '' as const,
    interval: '1',
    weekdays: [] as number[],
    repeatEnd: 'never' as const,
    untilDate: '',
    count: '10',
  };
  if (!block) {
    const today = shopToday(tz);
    return {
      kind: 'closed',
      memberId: '',
      title: '',
      allDay: true,
      startDate: today,
      startTime: '09:00',
      endDate: today,
      endTime: '17:00',
      reason: '',
      affectsCapacity: true,
      ...repeatDefaults,
    };
  }
  const start = utcToShopLocal(block.starts_at, tz);
  const end = utcToShopLocal(block.ends_at, tz);
  const allDay = isAllDayBlock(block, tz);
  const rule = readRecurrence(block.recurrence);
  return {
    kind: block.kind,
    memberId: block.member_id ?? '',
    title: block.title ?? '',
    allDay,
    startDate: start.date,
    startTime: allDay ? '09:00' : start.time,
    endDate: allDay ? addLocalDays(end.date, -1) : end.date,
    endTime: allDay ? '17:00' : end.time,
    reason: block.reason ?? '',
    affectsCapacity:
      block.affects_capacity ?? (block.kind === 'closed' || block.kind === 'time_off'),
    ...(rule
      ? {
          repeat: rule.freq,
          interval: String(rule.interval ?? 1),
          weekdays: rule.by_weekday ?? [],
          repeatEnd: rule.until_date ? 'until' : rule.count ? 'count' : 'never',
          untilDate: rule.until_date ?? '',
          count: String(rule.count ?? 10),
        }
      : repeatDefaults),
  };
}
