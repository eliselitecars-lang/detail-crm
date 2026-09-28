/**
 * Recurring jobs (P-1) — pure helpers for the repeat form, the series JSON
 * sent to create_job_series / job_series_preview / update_job_series (0051)
 * and the human description of a rule. The server owns every date: the
 * client only describes the rule; occurrences come from the RPCs.
 */
import {
  formatLocalDate,
  isLocalDate,
  utcToShopLocal,
  WEEKDAY_NAMES,
  type LocalDate,
} from '@/lib/dates';

export type SeriesFreq = 'week' | 'month';
/**
 * Monthly: the same day number, the nth weekday, or the last weekday of the
 * month, all taken from the anchor date; or, when an existing series is
 * edited, its own rule unchanged ('current').
 */
export type MonthMode = 'current' | 'day' | 'nth' | 'last';
/** The monthly options that come from a date. */
export type AnchorMonthMode = Exclude<MonthMode, 'current'>;
export type RepeatEnd = 'never' | 'until' | 'count';

/** The repeat form (strings while typing). */
export interface RepeatDraft {
  freq: SeriesFreq;
  interval: string;
  /** 0 = Sunday … 6 = Saturday (weekly rules). */
  weekdays: number[];
  monthMode: MonthMode;
  end: RepeatEnd;
  untilDate: string;
  count: string;
}

/** The rule part of the series JSON (keys as job_series_apply reads them). */
export interface SeriesRuleFields {
  freq: SeriesFreq;
  interval: number;
  by_weekday?: number[];
  month_mode?: 'day_of_month' | 'nth_weekday';
  month_day?: number;
  month_nth?: number;
  month_weekday?: number;
  until_date: string | null;
  max_occurrences: number | null;
}

/** The job_series columns the web reads (managers+, RLS). */
export interface SeriesRow {
  id: string;
  freq: string;
  interval: number;
  by_weekday: number[];
  month_mode: string | null;
  month_day: number | null;
  month_nth: number | null;
  month_weekday: number | null;
  start_date: string;
  local_start: string;
  duration_minutes: number;
  until_date: string | null;
  max_occurrences: number | null;
  active: boolean;
  ended_at: string | null;
}

export const WEEKDAY_SHORT = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'] as const;
/** Monday-first order for the weekday chips. */
export const WEEKDAY_ORDER = [1, 2, 3, 4, 5, 6, 0] as const;

export const SERIES_LIMITS = {
  intervalMax: 12,
  countMax: 500,
  durationMin: 15,
  durationMax: 44640,
  templateLinesMax: 30,
} as const;

function parts(date: LocalDate): [number, number, number] {
  const [y = 1970, m = 1, d = 1] = date.split('-').map(Number);
  return [y, m, d];
}

/** Weekday (0 = Sunday) of a calendar date — no time zone involved. */
export function localWeekday(date: LocalDate): number {
  const [y, m, d] = parts(date);
  return new Date(Date.UTC(y, m - 1, d)).getUTCDay();
}

export function daysInMonth(year: number, month: number): number {
  return new Date(Date.UTC(year, month, 0)).getUTCDate();
}

/** Where a date sits in its month: day number, nth weekday (1-5), last weekday? */
export function monthPosition(date: LocalDate): {
  day: number;
  weekday: number;
  nth: number;
  isLast: boolean;
} {
  const [y, m, d] = parts(date);
  return {
    day: d,
    weekday: localWeekday(date),
    nth: Math.ceil(d / 7),
    isLast: d + 7 > daysInMonth(y, m),
  };
}

export function ordinal(n: number): string {
  const suffix =
    n % 10 === 1 && n !== 11
      ? 'st'
      : n % 10 === 2 && n !== 12
        ? 'nd'
        : n % 10 === 3 && n !== 13
          ? 'rd'
          : 'th';
  return `${n}${suffix}`;
}

/** Labels of the three monthly options for a start date. */
export function monthModeLabels(date: LocalDate): Record<AnchorMonthMode, string> {
  const p = monthPosition(date);
  const weekday = WEEKDAY_NAMES[p.weekday] ?? '';
  return {
    day: `On day ${p.day}`,
    nth: `On the ${ordinal(p.nth)} ${weekday}`,
    last: `On the last ${weekday}`,
  };
}

/** Which monthly options make sense for a date (the "last" one only in the last week). */
export function monthModesFor(date: LocalDate): AnchorMonthMode[] {
  const p = monthPosition(date);
  const modes: AnchorMonthMode[] = ['day'];
  if (p.nth <= 4) modes.push('nth');
  if (p.isLast) modes.push('last');
  return modes;
}

/** The monthly part of the rule JSON. */
export type MonthRuleFields =
  | { month_mode: 'day_of_month'; month_day: number }
  | { month_mode: 'nth_weekday'; month_nth: number; month_weekday: number };

/** A monthly option built from a date (as the server fills its defaults). */
export function anchorMonthFields(mode: AnchorMonthMode, date: LocalDate): MonthRuleFields {
  const p = monthPosition(date);
  if (mode === 'day') return { month_mode: 'day_of_month', month_day: p.day };
  return {
    month_mode: 'nth_weekday',
    month_nth: mode === 'last' ? -1 : p.nth,
    month_weekday: p.weekday,
  };
}

function sameMonthFields(a: MonthRuleFields, b: MonthRuleFields): boolean {
  if (a.month_mode === 'day_of_month' || b.month_mode === 'day_of_month') {
    return (
      a.month_mode === 'day_of_month' &&
      b.month_mode === 'day_of_month' &&
      a.month_day === b.month_day
    );
  }
  return a.month_nth === b.month_nth && a.month_weekday === b.month_weekday;
}

/**
 * An existing monthly series' own rule. The edit form keeps it exactly
 * (update_job_series compares the rule by value: rebuilding it from the
 * opened visit's date — a clamped "day 31" visit on Apr 30, or a visit moved
 * on its own — would re-anchor the series and move every later visit).
 */
export interface CurrentMonthRule {
  label: string;
  fields: MonthRuleFields;
}

export function currentMonthRule(
  series: Pick<SeriesRow, 'freq' | 'month_mode' | 'month_day' | 'month_nth' | 'month_weekday'>,
): CurrentMonthRule | null {
  if (series.freq !== 'month') return null;
  if (series.month_mode === 'nth_weekday') {
    if (series.month_nth === null || series.month_weekday === null) return null;
    const weekday = WEEKDAY_NAMES[series.month_weekday] ?? '';
    return {
      label:
        series.month_nth === -1
          ? `On the last ${weekday}`
          : `On the ${ordinal(series.month_nth)} ${weekday}`,
      fields: {
        month_mode: 'nth_weekday',
        month_nth: series.month_nth,
        month_weekday: series.month_weekday,
      },
    };
  }
  if (series.month_day === null) return null;
  return {
    label: `On day ${series.month_day}`,
    fields: { month_mode: 'day_of_month', month_day: series.month_day },
  };
}

export interface MonthOption {
  value: MonthMode;
  label: string;
}

/**
 * The monthly choices: the series' current rule first (when editing one),
 * then the date's options that would change it.
 */
export function monthOptions(
  date: LocalDate,
  current: CurrentMonthRule | null = null,
): MonthOption[] {
  const labels = monthModeLabels(date);
  const options: MonthOption[] = current
    ? [{ value: 'current', label: `${current.label} (as now)` }]
    : [];
  for (const mode of monthModesFor(date)) {
    if (current && sameMonthFields(anchorMonthFields(mode, date), current.fields)) continue;
    options.push({ value: mode, label: labels[mode] });
  }
  return options;
}

/**
 * The monthly option the form shows as chosen AND saves: a choice the date no
 * longer offers (the 2nd Tuesday after the date moved to a fifth week) falls
 * back to the first option, so what is selected is what is sent.
 */
export function effectiveMonthMode(
  mode: MonthMode,
  date: LocalDate,
  current: CurrentMonthRule | null = null,
): MonthMode {
  const options = monthOptions(date, current);
  return options.some((o) => o.value === mode) ? mode : (options[0]?.value ?? 'day');
}

export function defaultRepeatDraft(startDate: LocalDate): RepeatDraft {
  return {
    freq: 'week',
    interval: '1',
    weekdays: isLocalDate(startDate) ? [localWeekday(startDate)] : [],
    monthMode: 'day',
    end: 'never',
    untilDate: '',
    count: '10',
  };
}

/** The form for an existing series' rule (a monthly rule is kept as it is: 'current'). */
export function draftFromSeries(series: SeriesRow): RepeatDraft {
  return {
    freq: series.freq === 'month' ? 'month' : 'week',
    interval: String(series.interval),
    weekdays: [...series.by_weekday],
    monthMode: currentMonthRule(series) ? 'current' : 'day',
    end: series.until_date ? 'until' : series.max_occurrences ? 'count' : 'never',
    untilDate: series.until_date ?? '',
    count: String(series.max_occurrences ?? 10),
  };
}

function wholeNumber(text: string, min: number, max: number): number | null {
  if (!/^\d{1,4}$/.test(text.trim())) return null;
  const value = Number(text.trim());
  return value >= min && value <= max ? value : null;
}

/**
 * Draft → rule JSON anchored at `anchorDate` (the first visit, or the visit a
 * "this and following" edit starts from). Monthly rules take the day number /
 * nth weekday from the anchor, as the server does for its defaults — except
 * the 'current' option, which sends the edited series' own rule unchanged.
 */
export function repeatRuleFields(
  draft: RepeatDraft,
  anchorDate: LocalDate,
  current: CurrentMonthRule | null = null,
): SeriesRuleFields | { error: string } {
  if (!isLocalDate(anchorDate)) return { error: 'Choose the date of the first visit.' };
  const interval = wholeNumber(draft.interval, 1, SERIES_LIMITS.intervalMax);
  if (interval === null) return { error: 'Repeat every 1 to 12 weeks or months.' };
  let untilDate: string | null = null;
  let max: number | null = null;
  if (draft.end === 'until') {
    if (!isLocalDate(draft.untilDate)) return { error: 'Choose the date the repeat ends.' };
    if (draft.untilDate < anchorDate) {
      return { error: 'The repeat must end on or after the first visit.' };
    }
    untilDate = draft.untilDate;
  } else if (draft.end === 'count') {
    max = wholeNumber(draft.count, 1, SERIES_LIMITS.countMax);
    if (max === null) return { error: 'Enter 1 to 500 visits.' };
  }
  if (draft.freq === 'week') {
    const days = [...new Set(draft.weekdays)].filter((d) => d >= 0 && d <= 6).sort();
    if (days.length === 0) return { error: 'Pick at least one day of the week.' };
    return {
      freq: 'week',
      interval,
      by_weekday: days,
      until_date: untilDate,
      max_occurrences: max,
    };
  }
  const mode = effectiveMonthMode(draft.monthMode, anchorDate, current);
  // (effectiveMonthMode offers 'current' only when there is a current rule)
  const fields =
    mode === 'current' && current
      ? current.fields
      : anchorMonthFields(mode === 'current' ? 'day' : mode, anchorDate);
  return {
    freq: 'month',
    interval,
    ...fields,
    until_date: untilDate,
    max_occurrences: max,
  };
}

/** "Every 2 weeks on Tue, Thu", "Every month on the last Friday · until Mar 31, 2027". */
export function describeSeries(
  series: Pick<
    SeriesRow,
    | 'freq'
    | 'interval'
    | 'by_weekday'
    | 'month_mode'
    | 'month_day'
    | 'month_nth'
    | 'month_weekday'
    | 'until_date'
    | 'max_occurrences'
  >,
): string {
  const n = series.interval;
  let text: string;
  if (series.freq === 'month') {
    text = n === 1 ? 'Every month' : `Every ${n} months`;
    if (series.month_mode === 'nth_weekday' && series.month_weekday !== null) {
      const weekday = WEEKDAY_NAMES[series.month_weekday] ?? '';
      text +=
        series.month_nth === -1
          ? ` on the last ${weekday}`
          : ` on the ${ordinal(series.month_nth ?? 1)} ${weekday}`;
    } else if (series.month_day !== null) {
      text += ` on day ${series.month_day}`;
    }
  } else {
    text = n === 1 ? 'Every week' : `Every ${n} weeks`;
    const days = WEEKDAY_ORDER.filter((d) => series.by_weekday.includes(d)).map(
      (d) => WEEKDAY_SHORT[d],
    );
    if (days.length > 0) text += ` on ${days.join(', ')}`;
  }
  if (series.until_date) text += ` · until ${formatLocalDate(series.until_date)}`;
  else if (series.max_occurrences) {
    text += ` · ${series.max_occurrences} visit${series.max_occurrences === 1 ? '' : 's'}`;
  }
  return text;
}

/** "Visit 3 of 12" / "Visit 3". */
export function visitLabel(seq: number | null, max: number | null): string | null {
  if (seq === null) return null;
  return max ? `Visit ${seq} of ${max}` : `Visit ${seq}`;
}

/** Minutes between two ISO instants (null when not a valid positive span). */
export function spanMinutes(startIso: string, endIso: string): number | null {
  const ms = Date.parse(endIso) - Date.parse(startIso);
  if (!Number.isFinite(ms) || ms <= 0) return null;
  return Math.round(ms / 60_000);
}

/** A visit's shop-local date ('' when unscheduled): the anchor of "this and following". */
export function jobLocalDate(job: { scheduled_start: string | null }, timeZone: string): LocalDate {
  return job.scheduled_start ? utcToShopLocal(job.scheduled_start, timeZone).date : '';
}
