import type { BusinessHoursRow } from '@/features/shop/businessHours';

/** A stored business_hours row (times come back from Postgres as HH:MM:SS). */
export interface StoredHoursRow extends BusinessHoursRow {
  id: string;
}

export interface HoursPlan {
  /** Stored rows that are not in the new week — deleted first. */
  remove: StoredHoursRow[];
  /** New intervals that are not stored yet — inserted after the delete. */
  insert: BusinessHoursRow[];
}

/** "08:00", "08:00:00" → "08:00"; "24:00:00" → "24:00". */
function hhmm(time: string): string {
  return time.slice(0, 5);
}

function intervalKey(row: BusinessHoursRow): string {
  return `${row.weekday}|${hhmm(row.opens_at)}|${hhmm(row.closes_at)}`;
}

/**
 * Minimal replace of the weekly hours. Unchanged intervals are left alone, so
 * only days whose hours actually changed are ever briefly without rows (the
 * exclusion constraint forces delete-before-insert), and a no-op save writes
 * nothing. Removing unchanged rows from both sides cannot create an overlap:
 * they are part of the (validated, non-overlapping) new week.
 */
export function planHoursReplace(
  stored: readonly StoredHoursRow[],
  next: readonly BusinessHoursRow[],
): HoursPlan {
  const nextKeys = new Set(next.map(intervalKey));
  const storedKeys = new Set(stored.map(intervalKey));
  return {
    remove: stored.filter((row) => !nextKeys.has(intervalKey(row))),
    insert: next.filter((row) => !storedKeys.has(intervalKey(row))),
  };
}

export const HOURS_NOT_RESTORED_MESSAGE =
  'Your new hours could not be saved, and the previous hours for the changed days could not be put back. Those days now show as closed, so online booking offers no times on them. Please enter and save your hours again.';
