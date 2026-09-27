/**
 * Date/time helpers. RULE: every date a user sees is rendered in the SHOP's
 * timezone (shops.timezone, exposed by useShop().timezone) — never the
 * browser's. The database stores timestamptz (UTC instants); `date` and
 * `time` columns (business hours, report ranges, quotes.valid_until) are
 * shop-local wall-clock values.
 *
 * Date-only strings ("2026-03-08", Postgres `date`) are calendar dates, not
 * instants: every formatter here renders them as that exact day, whatever the
 * browser's or the shop's zone (see formatLocalDate).
 *
 * Postgres `time` allows "24:00:00" (end of day; business_hours.closes_at for
 * a shop open until midnight). The local-time helpers accept it as minute
 * 1440 / the next day's 00:00, and format it as "12:00 AM".
 *
 * One library everywhere: date-fns v4 + @date-fns/tz (`TZDate`, `tz()`).
 *
 * DST policy for wall-clock → instant conversion:
 * - Non-existent local times (spring-forward gap, e.g. 02:30 on the US
 *   change day) move FORWARD by the gap (02:30 → 03:30).
 * - Ambiguous local times (fall-back overlap, e.g. 01:30) resolve to the
 *   FIRST occurrence (the earlier, daylight-time instant).
 */
import { tz } from '@date-fns/tz';
import { format, formatDistanceToNowStrict, isValid, parseISO } from 'date-fns';

export type DateInput = string | number | Date;

/** "yyyy-MM-dd" */
export type LocalDate = string;
/** "HH:mm" (24h); "24:00" = end of day. */
export type LocalTime = string;

const LOCAL_DATE_RE = /^(\d{4})-(\d{2})-(\d{2})$/;
const LOCAL_TIME_RE = /^(?:([01]\d|2[0-3]):([0-5]\d)(?::([0-5]\d))?|(24):00(?::00)?)$/;

/**
 * Parses an instant. A date-only string becomes midnight UTC of that
 * calendar day — display it with formatLocalDate (formatDate/formatInTz
 * detect it too); never convert a calendar date through a timezone.
 */
export function toDate(value: DateInput): Date {
  if (value instanceof Date) return value;
  if (typeof value === 'number') return new Date(value);
  if (LOCAL_DATE_RE.test(value)) {
    try {
      const [y, mo, d] = parseLocalDate(value);
      return new Date(Date.UTC(y, mo - 1, d));
    } catch {
      return new Date(Number.NaN);
    }
  }
  return parseISO(value);
}

export function isValidTimeZone(timeZone: string): boolean {
  if (!timeZone) return false;
  try {
    new Intl.DateTimeFormat('en-US', { timeZone });
    return true;
  } catch {
    return false;
  }
}

/** The browser's IANA timezone (used as the default when creating a shop). */
export function browserTimeZone(): string {
  try {
    const zone = Intl.DateTimeFormat().resolvedOptions().timeZone;
    return zone && isValidTimeZone(zone) ? zone : 'America/New_York';
  } catch {
    return 'America/New_York';
  }
}

/** All IANA zones the runtime knows, for timezone pickers. */
export function listTimeZones(): string[] {
  const intl = Intl as typeof Intl & { supportedValuesOf?: (key: 'timeZone') => string[] };
  const zones = intl.supportedValuesOf?.('timeZone') ?? [];
  const list = zones.length > 0 ? [...zones] : ['UTC'];
  // Intl omits "UTC" in some engines; make sure it's selectable.
  if (!list.includes('UTC')) list.push('UTC');
  return list;
}

/**
 * Formats an instant in the shop timezone with a date-fns pattern. A
 * date-only string is a calendar date and is formatted as that day (no zone
 * conversion), so a `date` column never shows the neighbouring day.
 */
export function formatInTz(value: DateInput, timeZone: string, pattern: string): string {
  const date = toDate(value);
  if (!isValid(date)) return '';
  const calendarDate = typeof value === 'string' && LOCAL_DATE_RE.test(value);
  return format(date, pattern, { in: tz(calendarDate ? 'UTC' : timeZone) });
}

/**
 * A Postgres `date` / LocalDate ("2026-03-08") → "Mar 8, 2026" (or another
 * date-fns pattern). Timezone-independent by definition. null → "—",
 * invalid → "".
 */
export function formatLocalDate(
  date: LocalDate | null | undefined,
  pattern = 'MMM d, yyyy',
): string {
  if (date === null || date === undefined) return '—';
  if (!isLocalDate(date)) return '';
  return formatInTz(date, 'UTC', pattern);
}

/** "Mar 8, 2026" */
export function formatDate(value: DateInput | null | undefined, timeZone: string): string {
  return value === null || value === undefined ? '—' : formatInTz(value, timeZone, 'MMM d, yyyy');
}

/** "2:30 PM" */
export function formatTime(value: DateInput | null | undefined, timeZone: string): string {
  return value === null || value === undefined ? '—' : formatInTz(value, timeZone, 'h:mm a');
}

/** "Sun, Mar 8, 2026 · 2:30 PM" */
export function formatDateTime(value: DateInput | null | undefined, timeZone: string): string {
  return value === null || value === undefined
    ? '—'
    : formatInTz(value, timeZone, "EEE, MMM d, yyyy '·' h:mm a");
}

/** "2:30 – 4:00 PM" / "Mar 8, 2:30 PM – Mar 9, 10:00 AM" */
export function formatTimeRange(start: DateInput, end: DateInput, timeZone: string): string {
  const sameDay =
    formatInTz(start, timeZone, 'yyyy-MM-dd') === formatInTz(end, timeZone, 'yyyy-MM-dd');
  if (sameDay) {
    const startMeridiem = formatInTz(start, timeZone, 'a');
    const endMeridiem = formatInTz(end, timeZone, 'a');
    const startText = formatInTz(
      start,
      timeZone,
      startMeridiem === endMeridiem ? 'h:mm' : 'h:mm a',
    );
    return `${startText} – ${formatInTz(end, timeZone, 'h:mm a')}`;
  }
  return `${formatInTz(start, timeZone, 'MMM d, h:mm a')} – ${formatInTz(end, timeZone, 'MMM d, h:mm a')}`;
}

/** "5 minutes ago" / "in 2 hours" — relative text is timezone-independent. */
export function formatRelative(value: DateInput, now: Date = new Date()): string {
  const date = toDate(value);
  if (!isValid(date)) return '';
  if (Math.abs(date.getTime() - now.getTime()) < 45_000) return 'just now';
  return formatDistanceToNowStrict(date, { addSuffix: true });
}

function parseLocalDate(date: LocalDate): [number, number, number] {
  const m = LOCAL_DATE_RE.exec(date);
  if (!m) throw new RangeError(`Invalid local date "${date}" (expected yyyy-MM-dd)`);
  const y = Number(m[1]);
  const mo = Number(m[2]);
  const d = Number(m[3]);
  const probe = new Date(Date.UTC(y, mo - 1, d));
  if (probe.getUTCFullYear() !== y || probe.getUTCMonth() !== mo - 1 || probe.getUTCDate() !== d) {
    throw new RangeError(`Invalid local date "${date}"`);
  }
  return [y, mo, d];
}

function parseLocalTime(time: LocalTime): [number, number, number] {
  const m = LOCAL_TIME_RE.exec(time);
  if (!m) throw new RangeError(`Invalid local time "${time}" (expected HH:mm)`);
  if (m[4] !== undefined) return [24, 0, 0]; // end of day
  return [Number(m[1]), Number(m[2]), Number(m[3] ?? '0')];
}

export function isLocalDate(value: string): boolean {
  try {
    parseLocalDate(value);
    return true;
  } catch {
    return false;
  }
}

/** "HH:mm" or "HH:mm:ss" clock time, or the end-of-day "24:00[:00]" Postgres allows. */
export function isLocalTime(value: string): boolean {
  return LOCAL_TIME_RE.test(value);
}

const wallFormatters = new Map<string, Intl.DateTimeFormat>();

/** Wall-clock fields of instant `ms` in `timeZone`, encoded as a UTC epoch. */
function wallClockAsUtcMs(ms: number, timeZone: string): number {
  let f = wallFormatters.get(timeZone);
  if (!f) {
    f = new Intl.DateTimeFormat('en-US', {
      timeZone,
      hourCycle: 'h23',
      year: 'numeric',
      month: 'numeric',
      day: 'numeric',
      hour: 'numeric',
      minute: 'numeric',
      second: 'numeric',
    });
    wallFormatters.set(timeZone, f);
  }
  const parts: Record<string, number> = {};
  for (const part of f.formatToParts(new Date(ms))) {
    if (part.type !== 'literal') parts[part.type] = Number(part.value);
  }
  return Date.UTC(
    parts.year ?? 1970,
    (parts.month ?? 1) - 1,
    parts.day ?? 1,
    (parts.hour ?? 0) % 24,
    parts.minute ?? 0,
    parts.second ?? 0,
  );
}

/** UTC offset (ms) of `timeZone` at instant `ms`. */
function offsetAt(ms: number, timeZone: string): number {
  return wallClockAsUtcMs(ms, timeZone) - Math.floor(ms / 1000) * 1000;
}

/**
 * Wall-clock time in `timeZone` → epoch ms, deterministic regardless of the
 * runtime's own zone (see the DST policy at the top of this file).
 */
function zonedWallTimeToMs(wall: number, timeZone: string): number {
  const HALF_DAY = 12 * 3_600_000;
  const before = offsetAt(wall - HALF_DAY, timeZone);
  const after = offsetAt(wall + HALF_DAY, timeZone);
  const candidates = [wall - before, wall - after].filter(
    (t, i, all) => all.indexOf(t) === i && wallClockAsUtcMs(t, timeZone) === wall,
  );
  if (candidates.length > 0) return Math.min(...candidates); // ambiguous → first occurrence
  return wall - before; // non-existent (gap) → shift forward by the gap
}

/**
 * Shop-local wall clock → UTC ISO instant ("2026-03-08T07:30:00.000Z").
 * See the DST policy at the top of this file.
 */
export function shopLocalToUtcIso(date: LocalDate, time: LocalTime, timeZone: string): string {
  const [y, mo, d] = parseLocalDate(date);
  const [h, mi, s] = parseLocalTime(time);
  if (!isValidTimeZone(timeZone)) throw new RangeError(`Invalid time zone "${timeZone}"`);
  return new Date(zonedWallTimeToMs(Date.UTC(y, mo - 1, d, h, mi, s), timeZone)).toISOString();
}

/** UTC instant → shop-local `{ date: 'yyyy-MM-dd', time: 'HH:mm' }`. */
export function utcToShopLocal(
  value: DateInput,
  timeZone: string,
): { date: LocalDate; time: LocalTime } {
  return {
    date: formatInTz(value, timeZone, 'yyyy-MM-dd'),
    time: formatInTz(value, timeZone, 'HH:mm'),
  };
}

/** Today's date in the shop timezone ("yyyy-MM-dd"). */
export function shopToday(timeZone: string, now: Date = new Date()): LocalDate {
  return formatInTz(now, timeZone, 'yyyy-MM-dd');
}

/** Adds calendar days to a local date string (DST-proof: pure calendar math). */
export function addLocalDays(date: LocalDate, days: number): LocalDate {
  const [y, mo, d] = parseLocalDate(date);
  const next = new Date(Date.UTC(y, mo - 1, d + days));
  return next.toISOString().slice(0, 10);
}

/** Calendar-day difference between two local dates (b − a). */
export function localDaysBetween(a: LocalDate, b: LocalDate): number {
  const [ay, am, ad] = parseLocalDate(a);
  const [by, bm, bd] = parseLocalDate(b);
  return Math.round((Date.UTC(by, bm - 1, bd) - Date.UTC(ay, am - 1, ad)) / 86_400_000);
}

/**
 * UTC bounds of a shop-local day: [start, end) as ISO strings. A DST day is
 * 23 or 25 hours long — never assume 24.
 */
export function shopDayRangeUtc(date: LocalDate, timeZone: string): { from: string; to: string } {
  return {
    from: shopLocalToUtcIso(date, '00:00', timeZone),
    to: shopLocalToUtcIso(addLocalDays(date, 1), '00:00', timeZone),
  };
}

/** UTC bounds for an inclusive shop-local date range (e.g. report filters). */
export function shopDateRangeUtc(
  fromDate: LocalDate,
  toDateInclusive: LocalDate,
  timeZone: string,
): { from: string; to: string } {
  return {
    from: shopLocalToUtcIso(fromDate, '00:00', timeZone),
    to: shopLocalToUtcIso(addLocalDays(toDateInclusive, 1), '00:00', timeZone),
  };
}

/** Start of the shop-local day containing `value`, as a UTC ISO instant. */
export function startOfShopDayUtc(value: DateInput, timeZone: string): string {
  return shopLocalToUtcIso(formatInTz(value, timeZone, 'yyyy-MM-dd'), '00:00', timeZone);
}

/** Start of the next shop-local day after `value`, as a UTC ISO instant. */
export function startOfNextShopDayUtc(value: DateInput, timeZone: string): string {
  return shopLocalToUtcIso(
    addLocalDays(formatInTz(value, timeZone, 'yyyy-MM-dd'), 1),
    '00:00',
    timeZone,
  );
}

/** 0 = Sunday … 6 = Saturday, in the shop timezone (matches business_hours.weekday). */
export function shopWeekday(value: DateInput, timeZone: string): number {
  return Number(formatInTz(value, timeZone, 'i')) % 7;
}

/** "09:00:00" / "09:00" (Postgres time) → "9:00 AM"; "24:00:00" → "12:00 AM". */
export function formatLocalTime(time: string | null | undefined): string {
  if (!time) return '—';
  const [h, m] = parseLocalTime(time.slice(0, 8));
  const hour24 = h % 24;
  const suffix = hour24 >= 12 ? 'PM' : 'AM';
  const hour12 = hour24 % 12 === 0 ? 12 : hour24 % 12;
  return `${hour12}:${String(m).padStart(2, '0')} ${suffix}`;
}

/** Minutes since midnight for an "HH:mm[:ss]" string ("24:00" → 1440). */
export function localTimeToMinutes(time: LocalTime): number {
  const [h, m] = parseLocalTime(time.slice(0, 8));
  return h * 60 + m;
}

/** Minutes since midnight → "HH:mm". */
export function minutesToLocalTime(minutes: number): LocalTime {
  const clamped = Math.max(0, Math.min(24 * 60 - 1, Math.round(minutes)));
  return `${String(Math.floor(clamped / 60)).padStart(2, '0')}:${String(clamped % 60).padStart(2, '0')}`;
}

export const WEEKDAY_NAMES = [
  'Sunday',
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
] as const;
