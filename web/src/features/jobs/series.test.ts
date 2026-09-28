import { describe, expect, it } from 'vitest';
import {
  currentMonthRule,
  defaultRepeatDraft,
  describeSeries,
  draftFromSeries,
  effectiveMonthMode,
  jobLocalDate,
  localWeekday,
  monthModeLabels,
  monthModesFor,
  monthOptions,
  monthPosition,
  repeatRuleFields,
  spanMinutes,
  visitLabel,
  type SeriesRow,
} from './series';

const SERIES: SeriesRow = {
  id: 'series-1',
  freq: 'week',
  interval: 2,
  by_weekday: [4, 2],
  month_mode: null,
  month_day: null,
  month_nth: null,
  month_weekday: null,
  start_date: '2026-09-29',
  local_start: '09:00:00',
  duration_minutes: 120,
  until_date: null,
  max_occurrences: 12,
  active: true,
  ended_at: null,
};

describe('series dates', () => {
  it('knows weekdays and month positions without a time zone', () => {
    expect(localWeekday('2026-09-28')).toBe(1); // Monday
    expect(localWeekday('2026-11-01')).toBe(0); // Sunday (DST ends that day in the US)
    expect(monthPosition('2026-09-29')).toEqual({ day: 29, weekday: 2, nth: 5, isLast: true });
    expect(monthPosition('2026-09-15')).toEqual({ day: 15, weekday: 2, nth: 3, isLast: false });
    expect(monthModesFor('2026-09-29')).toEqual(['day', 'last']);
    expect(monthModesFor('2026-09-24')).toEqual(['day', 'nth', 'last']);
    expect(monthModeLabels('2026-09-15')).toEqual({
      day: 'On day 15',
      nth: 'On the 3rd Tuesday',
      last: 'On the last Tuesday',
    });
  });

  it('defaults a weekly rule to the first visit’s weekday', () => {
    expect(defaultRepeatDraft('2026-09-28')).toMatchObject({
      freq: 'week',
      interval: '1',
      weekdays: [1],
      end: 'never',
    });
  });
});

describe('repeatRuleFields', () => {
  const draft = defaultRepeatDraft('2026-09-28');

  it('builds a weekly rule with sorted, distinct weekdays', () => {
    expect(
      repeatRuleFields({ ...draft, interval: '2', weekdays: [5, 1, 5] }, '2026-09-28'),
    ).toEqual({
      freq: 'week',
      interval: 2,
      by_weekday: [1, 5],
      until_date: null,
      max_occurrences: null,
    });
  });

  it('builds monthly rules from the anchor date', () => {
    expect(repeatRuleFields({ ...draft, freq: 'month' }, '2026-09-15')).toMatchObject({
      freq: 'month',
      month_mode: 'day_of_month',
      month_day: 15,
    });
    expect(
      repeatRuleFields({ ...draft, freq: 'month', monthMode: 'nth' }, '2026-09-15'),
    ).toMatchObject({
      month_mode: 'nth_weekday',
      month_nth: 3,
      month_weekday: 2,
    });
    expect(
      repeatRuleFields({ ...draft, freq: 'month', monthMode: 'last' }, '2026-09-29'),
    ).toMatchObject({
      month_mode: 'nth_weekday',
      month_nth: -1,
      month_weekday: 2,
    });
  });

  it('ends on a date or after a number of visits', () => {
    expect(
      repeatRuleFields({ ...draft, end: 'until', untilDate: '2026-12-31' }, '2026-09-28'),
    ).toMatchObject({ until_date: '2026-12-31', max_occurrences: null });
    expect(repeatRuleFields({ ...draft, end: 'count', count: '12' }, '2026-09-28')).toMatchObject({
      until_date: null,
      max_occurrences: 12,
    });
  });

  it('explains what is wrong instead of sending a bad rule', () => {
    expect(repeatRuleFields({ ...draft, interval: '13' }, '2026-09-28')).toEqual({
      error: 'Repeat every 1 to 12 weeks or months.',
    });
    expect(repeatRuleFields({ ...draft, weekdays: [] }, '2026-09-28')).toEqual({
      error: 'Pick at least one day of the week.',
    });
    expect(repeatRuleFields({ ...draft, end: 'count', count: '501' }, '2026-09-28')).toEqual({
      error: 'Enter 1 to 500 visits.',
    });
    expect(
      repeatRuleFields({ ...draft, end: 'until', untilDate: '2026-09-01' }, '2026-09-28'),
    ).toEqual({ error: 'The repeat must end on or after the first visit.' });
    expect(repeatRuleFields(draft, '')).toEqual({ error: 'Choose the date of the first visit.' });
  });

  it('saves the monthly option the form shows when the date no longer offers the chosen one', () => {
    // "the 2nd Tuesday" was picked, then the date moved to the 29th (fifth week):
    // the form shows "On day 29" checked, and that is what is sent
    expect(effectiveMonthMode('nth', '2026-09-29')).toBe('day');
    expect(repeatRuleFields({ ...draft, freq: 'month', monthMode: 'nth' }, '2026-09-29')).toEqual({
      freq: 'month',
      interval: 1,
      month_mode: 'day_of_month',
      month_day: 29,
      until_date: null,
      max_occurrences: null,
    });
    // "last" on a date outside the last week
    expect(effectiveMonthMode('last', '2026-09-15')).toBe('day');
    expect(
      repeatRuleFields({ ...draft, freq: 'month', monthMode: 'last' }, '2026-09-15'),
    ).toMatchObject({ month_mode: 'day_of_month', month_day: 15 });
    // an offered choice is kept
    expect(effectiveMonthMode('last', '2026-09-29')).toBe('last');
  });
});

describe('editing a monthly series', () => {
  const DAY_31: SeriesRow = {
    ...SERIES,
    freq: 'month',
    interval: 1,
    by_weekday: [],
    month_mode: 'day_of_month',
    month_day: 31,
    start_date: '2027-01-31',
    max_occurrences: null,
  };

  it('keeps the series’ own day when the opened visit was clamped to a shorter month', () => {
    const current = currentMonthRule(DAY_31);
    expect(current).toEqual({
      label: 'On day 31',
      fields: { month_mode: 'day_of_month', month_day: 31 },
    });
    const draft = draftFromSeries(DAY_31);
    expect(draft.monthMode).toBe('current');
    // the April visit falls on Apr 30; only the end changes
    const rule = repeatRuleFields({ ...draft, end: 'count', count: '12' }, '2027-04-30', current);
    expect(rule).toEqual({
      freq: 'month',
      interval: 1,
      month_mode: 'day_of_month',
      month_day: 31,
      until_date: null,
      max_occurrences: 12,
    });
    // the visit's own options stay available, the current rule first
    expect(monthOptions('2027-04-30', current)).toEqual([
      { value: 'current', label: 'On day 31 (as now)' },
      { value: 'day', label: 'On day 30' },
      { value: 'last', label: 'On the last Friday' },
    ]);
    expect(repeatRuleFields({ ...draft, monthMode: 'day' }, '2027-04-30', current)).toMatchObject({
      month_day: 30,
    });
  });

  it('keeps an nth-weekday rule when the visit was moved to another day on its own', () => {
    const series: SeriesRow = {
      ...DAY_31,
      month_mode: 'nth_weekday',
      month_day: null,
      month_nth: -1,
      month_weekday: 5,
    };
    const current = currentMonthRule(series);
    expect(current?.label).toBe('On the last Friday');
    // moved to Wed Sep 16 2026 (not in the last week): the rule is still offered and sent
    const draft = draftFromSeries(series);
    expect(effectiveMonthMode(draft.monthMode, '2026-09-16', current)).toBe('current');
    expect(repeatRuleFields(draft, '2026-09-16', current)).toMatchObject({
      month_mode: 'nth_weekday',
      month_nth: -1,
      month_weekday: 5,
    });
    // an option identical to the current rule is not listed twice
    expect(monthOptions('2026-09-25', current).map((o) => o.value)).toEqual([
      'current',
      'day',
      'nth',
    ]);
  });

  it('has no current monthly rule for a weekly series', () => {
    expect(currentMonthRule(SERIES)).toBeNull();
    expect(draftFromSeries(SERIES).monthMode).toBe('day');
    expect(monthOptions('2026-09-15').map((o) => o.value)).toEqual(['day', 'nth']);
  });
});

describe('describing a series', () => {
  it('reads like a sentence', () => {
    expect(describeSeries(SERIES)).toBe('Every 2 weeks on Tue, Thu · 12 visits');
    expect(
      describeSeries({ ...SERIES, interval: 1, max_occurrences: null, until_date: '2027-03-31' }),
    ).toBe('Every week on Tue, Thu · until Mar 31, 2027');
    expect(
      describeSeries({
        ...SERIES,
        freq: 'month',
        interval: 1,
        by_weekday: [],
        month_mode: 'nth_weekday',
        month_nth: -1,
        month_weekday: 5,
        max_occurrences: null,
      }),
    ).toBe('Every month on the last Friday');
    expect(
      describeSeries({
        ...SERIES,
        freq: 'month',
        interval: 3,
        by_weekday: [],
        month_mode: 'day_of_month',
        month_day: 15,
        max_occurrences: null,
      }),
    ).toBe('Every 3 months on day 15');
    expect(visitLabel(3, 12)).toBe('Visit 3 of 12');
    expect(visitLabel(3, null)).toBe('Visit 3');
    expect(visitLabel(null, 12)).toBeNull();
  });

  it('round-trips an existing rule into the form', () => {
    expect(draftFromSeries(SERIES)).toMatchObject({
      freq: 'week',
      interval: '2',
      weekdays: [4, 2],
      end: 'count',
      count: '12',
    });
    expect(
      draftFromSeries({
        ...SERIES,
        freq: 'month',
        month_mode: 'nth_weekday',
        month_nth: -1,
        month_weekday: 5,
      }).monthMode,
    ).toBe('current');
  });

  it('measures visits and dates in the shop zone', () => {
    expect(spanMinutes('2026-09-28T14:00:00Z', '2026-09-28T16:30:00Z')).toBe(150);
    expect(spanMinutes('2026-09-28T16:00:00Z', '2026-09-28T14:00:00Z')).toBeNull();
    // 03:00Z is still the previous evening in Chicago
    expect(jobLocalDate({ scheduled_start: '2026-09-29T03:00:00Z' }, 'America/Chicago')).toBe(
      '2026-09-28',
    );
    expect(jobLocalDate({ scheduled_start: null }, 'America/Chicago')).toBe('');
  });
});
