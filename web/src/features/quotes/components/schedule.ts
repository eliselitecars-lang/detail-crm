import { addLocalDays, localTimeToMinutes, minutesToLocalTime } from '@/lib/dates';

/** End = start + duration (default 2 h), rolling into the next local day(s) when needed. */
export function defaultEnd(date: string, start: string, durationMinutes: number) {
  const minutes = Math.max(15, durationMinutes || 120);
  const total = localTimeToMinutes(start) + minutes;
  const days = Math.floor(total / 1440);
  return { date: addLocalDays(date, days), time: minutesToLocalTime(total % 1440) };
}
