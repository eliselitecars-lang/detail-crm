import { addLocalDays, formatInTz, shopToday } from '@/lib/dates';

/** Thread list timestamp in the shop zone: "2:30 PM" today, "Mar 8" this year, else "3/8/25". */
export function formatListTime(iso: string, timeZone: string, now: Date = new Date()): string {
  const day = formatInTz(iso, timeZone, 'yyyy-MM-dd');
  if (day === shopToday(timeZone, now)) return formatInTz(iso, timeZone, 'h:mm a');
  if (day.slice(0, 4) === shopToday(timeZone, now).slice(0, 4))
    return formatInTz(iso, timeZone, 'MMM d');
  return formatInTz(iso, timeZone, 'M/d/yy');
}

/** Day separator label in the shop zone: "Today", "Yesterday" or "Sun, Mar 8, 2026". */
export function formatDayLabel(day: string, timeZone: string, now: Date = new Date()): string {
  const today = shopToday(timeZone, now);
  if (day === today) return 'Today';
  // Calendar math, not "now − 24 h" (DST days are 23 or 25 hours long).
  if (day === addLocalDays(today, -1)) return 'Yesterday';
  return formatInTz(day, timeZone, 'EEE, MMM d, yyyy');
}

/** Shop-local calendar day ("yyyy-MM-dd") of an instant. */
export function shopDay(iso: string, timeZone: string): string {
  return formatInTz(iso, timeZone, 'yyyy-MM-dd');
}
