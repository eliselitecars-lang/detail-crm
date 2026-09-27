/**
 * Timesheets — pure time math (unit-tested). Hours are not money: summing
 * durations for display is fine client-side. Days are SHOP-local calendar
 * days; an entry that crosses midnight is split between the two days.
 */
import { z } from 'zod';
import { Constants } from '@/lib/database.types';
import {
  addLocalDays,
  formatInTz,
  isLocalDate,
  isLocalTime,
  localDaysBetween,
  shopLocalToUtcIso,
} from '@/lib/dates';

export const TIME_ENTRY_KINDS = Constants.public.Enums.time_entry_kind;
export type TimeEntryKind = (typeof TIME_ENTRY_KINDS)[number];
export type TimeEntrySource = (typeof Constants.public.Enums.time_entry_source)[number];

export const timeEntrySchema = z.object({
  id: z.string(),
  member_id: z.string(),
  job_id: z.string().nullable(),
  kind: z.enum(Constants.public.Enums.time_entry_kind),
  clock_in: z.string(),
  clock_out: z.string().nullable(),
  source: z.enum(Constants.public.Enums.time_entry_source),
  notes: z.string().nullable(),
  job: z.object({ id: z.string(), number: z.number() }).nullable(),
});
export type TimeEntry = z.infer<typeof timeEntrySchema>;

export const TIME_ENTRY_COLUMNS =
  'id, member_id, job_id, kind, clock_in, clock_out, source, notes, job:jobs!time_entries_job_fk(id, number)';

export const MAX_RANGE_DAYS = 92;

export function entryEndMs(entry: Pick<TimeEntry, 'clock_out'>, nowMs: number): number {
  return entry.clock_out ? new Date(entry.clock_out).getTime() : nowMs;
}

export function entryDurationMs(entry: Pick<TimeEntry, 'clock_in' | 'clock_out'>, nowMs: number) {
  return Math.max(0, entryEndMs(entry, nowMs) - new Date(entry.clock_in).getTime());
}

/** 27_000_000 → "7h 30m"; under an hour → "45m"; 0 → "0m". */
export function formatDuration(ms: number): string {
  const totalMinutes = Math.floor(Math.max(0, ms) / 60_000);
  const h = Math.floor(totalMinutes / 60);
  const m = totalMinutes % 60;
  if (h === 0) return `${m}m`;
  return `${h}h ${String(m).padStart(2, '0')}m`;
}

/** Running timer text: "1:05:09". */
export function formatClock(ms: number): string {
  const total = Math.floor(Math.max(0, ms) / 1000);
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  return `${h}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`;
}

/** Decimal hours for payroll exports / totals: 27_000_000 → "7.50". */
export function formatHoursDecimal(ms: number): string {
  return (Math.max(0, ms) / 3_600_000).toFixed(2);
}

/**
 * Splits [startMs, endMs) into shop-local calendar days, clipped to
 * [rangeFromMs, rangeToMs). DST days are 23/25 h — boundaries come from the
 * zone, never from adding 24 h.
 */
export function splitByShopDay(
  startMs: number,
  endMs: number,
  timeZone: string,
  rangeFromMs = -Infinity,
  rangeToMs = Infinity,
): { day: string; ms: number }[] {
  const out: { day: string; ms: number }[] = [];
  let cursor = Math.max(startMs, rangeFromMs);
  const stop = Math.min(endMs, rangeToMs);
  let guard = 0;
  while (cursor < stop && guard < 400) {
    guard += 1;
    const day = formatInTz(cursor, timeZone, 'yyyy-MM-dd');
    const next = new Date(shopLocalToUtcIso(addLocalDays(day, 1), '00:00', timeZone)).getTime();
    const end = Math.min(stop, next);
    if (end > cursor) out.push({ day, ms: end - cursor });
    cursor = next;
  }
  return out;
}

export interface MemberTotals {
  memberId: string;
  shiftMs: number;
  jobMs: number;
  entries: number;
  open: number;
  /** day ("yyyy-MM-dd") → totals */
  days: Map<string, { shiftMs: number; jobMs: number }>;
}

/**
 * Totals per member and per shop-local day within [fromMs, toMs). Open
 * entries count up to `nowMs`. Shift and job time are kept apart: job time
 * runs inside a shift, so adding them would double count.
 */
export function summarize(
  entries: readonly TimeEntry[],
  timeZone: string,
  fromMs: number,
  toMs: number,
  nowMs: number,
): MemberTotals[] {
  const byMember = new Map<string, MemberTotals>();
  for (const entry of entries) {
    let t = byMember.get(entry.member_id);
    if (!t) {
      t = { memberId: entry.member_id, shiftMs: 0, jobMs: 0, entries: 0, open: 0, days: new Map() };
      byMember.set(entry.member_id, t);
    }
    t.entries += 1;
    if (!entry.clock_out) t.open += 1;
    const parts = splitByShopDay(
      new Date(entry.clock_in).getTime(),
      entryEndMs(entry, nowMs),
      timeZone,
      fromMs,
      toMs,
    );
    for (const { day, ms } of parts) {
      const d = t.days.get(day) ?? { shiftMs: 0, jobMs: 0 };
      if (entry.kind === 'shift') {
        d.shiftMs += ms;
        t.shiftMs += ms;
      } else {
        d.jobMs += ms;
        t.jobMs += ms;
      }
      t.days.set(day, d);
    }
  }
  return [...byMember.values()];
}

// ---------------------------------------------------------------------------
// Range filter
// ---------------------------------------------------------------------------

export function rangeError(from: string, to: string): string | null {
  if (!isLocalDate(from) || !isLocalDate(to)) return 'Choose a valid start and end date.';
  const days = localDaysBetween(from, to);
  if (days < 0) return 'The end date is before the start date.';
  if (days >= MAX_RANGE_DAYS) return `Choose at most ${MAX_RANGE_DAYS} days.`;
  return null;
}

/** Monday of the week containing `day` (a shop-local date). */
export function weekStart(day: string): string {
  const weekday = new Date(`${day}T00:00:00Z`).getUTCDay(); // 0 = Sunday
  return addLocalDays(day, -((weekday + 6) % 7));
}

// ---------------------------------------------------------------------------
// Manual entry form
// ---------------------------------------------------------------------------

export const entryFormSchema = z
  .object({
    memberId: z.string().min(1, 'Choose a team member.'),
    kind: z.enum(Constants.public.Enums.time_entry_kind),
    jobId: z.string(),
    inDate: z.string().refine(isLocalDate, 'Choose a date.'),
    inTime: z.string().refine(isLocalTime, 'Choose a time.'),
    outDate: z.string(),
    outTime: z.string(),
    notes: z.string().trim().max(2000, 'Keep notes under 2,000 characters.'),
  })
  .superRefine((v, ctx) => {
    if (v.kind === 'job' && v.jobId === '')
      ctx.addIssue({ code: 'custom', path: ['jobId'], message: 'Choose the job.' });
    const hasOutDate = v.outDate !== '';
    const hasOutTime = v.outTime !== '';
    if (hasOutDate !== hasOutTime) {
      ctx.addIssue({
        code: 'custom',
        path: [hasOutDate ? 'outTime' : 'outDate'],
        message: 'Set both a clock-out date and time, or leave both empty for an open entry.',
      });
      return;
    }
    if (hasOutDate && (!isLocalDate(v.outDate) || !isLocalTime(v.outTime))) {
      ctx.addIssue({ code: 'custom', path: ['outTime'], message: 'Choose a valid clock-out.' });
      return;
    }
    if (hasOutDate && `${v.outDate}T${v.outTime}` < `${v.inDate}T${v.inTime}`)
      ctx.addIssue({
        code: 'custom',
        path: ['outTime'],
        message: 'Clock-out must be after clock-in.',
      });
  });
export type EntryFormValues = z.input<typeof entryFormSchema>;

export interface EntryWrite {
  member_id: string;
  kind: TimeEntryKind;
  job_id: string | null;
  clock_in: string;
  clock_out: string | null;
  notes: string | null;
}

/** Form (shop-local wall clock) → row values (UTC instants). */
export function entryFormToWrite(
  v: z.output<typeof entryFormSchema>,
  timeZone: string,
): EntryWrite {
  return {
    member_id: v.memberId,
    kind: v.kind,
    job_id: v.kind === 'job' ? v.jobId : null,
    clock_in: shopLocalToUtcIso(v.inDate, v.inTime, timeZone),
    clock_out: v.outDate ? shopLocalToUtcIso(v.outDate, v.outTime, timeZone) : null,
    notes: v.notes === '' ? null : v.notes,
  };
}
