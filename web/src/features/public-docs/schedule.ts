/**
 * Pure helpers for picking a time for an approved quote on /q (P-16). The
 * start times come from the server (public_quote_slots); this only groups
 * them into shop-local days for display.
 */
import { addLocalDays, formatInTz, utcToShopLocal, type LocalDate } from '@/lib/dates';
import type { QuoteSlot } from './api';

/** Days shown (and fetched) at a time. */
export const SCHEDULE_WINDOW_DAYS = 7;
/** How far ahead the customer may page when the shop sets no limit. */
export const DEFAULT_MAX_DAYS_AHEAD = 60;

/** `length` consecutive local dates starting at `start`. */
export function dayWindow(start: LocalDate, length: number = SCHEDULE_WINDOW_DAYS): LocalDate[] {
  return Array.from({ length }, (_, i) => addLocalDays(start, i));
}

/** Slots by their shop-local start date, each day's slots in time order. */
export function groupSlotsByDay(
  slots: readonly QuoteSlot[],
  timeZone: string,
): Map<LocalDate, QuoteSlot[]> {
  const days = new Map<LocalDate, QuoteSlot[]>();
  const sorted = [...slots].sort((a, b) => a.starts_at.localeCompare(b.starts_at));
  for (const slot of sorted) {
    const day = utcToShopLocal(slot.starts_at, timeZone).date;
    const list = days.get(day);
    if (list) list.push(slot);
    else days.set(day, [slot]);
  }
  return days;
}

/** "Tue" / "Sep 30" labels of a local date (timezone-independent). */
export function dayLabels(date: LocalDate): { weekday: string; day: string } {
  return {
    weekday: formatInTz(date, 'UTC', 'EEE'),
    day: formatInTz(date, 'UTC', 'MMM d'),
  };
}

/**
 * The window start after moving `direction` windows from `start`, kept
 * within [today, today + maxDaysAhead].
 */
export function shiftWindow(
  start: LocalDate,
  direction: -1 | 1,
  today: LocalDate,
  maxDaysAhead: number,
): LocalDate {
  const next = addLocalDays(start, direction * SCHEDULE_WINDOW_DAYS);
  if (next < today) return today;
  const last = addLocalDays(today, Math.max(0, maxDaysAhead - SCHEDULE_WINDOW_DAYS + 1));
  return next > last ? last : next;
}
