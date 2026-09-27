import { addLocalDays, formatInTz, formatTimeRange, shopToday, utcToShopLocal } from '@/lib/dates';
import type { BlockedTime } from './api';
import type { BlockedTimeFormInput } from './schemas';

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
  if (!block) {
    const today = shopToday(tz);
    return {
      memberId: '',
      allDay: true,
      startDate: today,
      startTime: '09:00',
      endDate: today,
      endTime: '17:00',
      reason: '',
    };
  }
  const start = utcToShopLocal(block.starts_at, tz);
  const end = utcToShopLocal(block.ends_at, tz);
  const allDay = isAllDayBlock(block, tz);
  return {
    memberId: block.member_id ?? '',
    allDay,
    startDate: start.date,
    startTime: allDay ? '09:00' : start.time,
    endDate: allDay ? addLocalDays(end.date, -1) : end.date,
    endTime: allDay ? '17:00' : end.time,
    reason: block.reason ?? '',
  };
}
