import { describe, expect, it } from 'vitest';
import { formatLocalTime, localTimeToMinutes } from '@/lib/dates';
import { defaultWeek, rowsToWeek, validateWeek, weekToRows } from './businessHours';

describe('business hours', () => {
  it('round-trips a midnight close through Postgres "24:00:00"', () => {
    const week = rowsToWeek([{ weekday: 5, opens_at: '08:00:00', closes_at: '24:00:00' }]);
    const friday = week[5];
    expect(friday).toEqual({
      weekday: 5,
      open: true,
      intervals: [{ opensAt: '08:00', closesAt: '00:00' }],
    });
    expect(validateWeek(week)).toEqual({});
    const rows = weekToRows(week);
    expect(rows).toEqual([{ weekday: 5, opens_at: '08:00', closes_at: '24:00' }]);

    // What the database hands back must be displayable by the shared helpers.
    expect(formatLocalTime('24:00:00')).toBe('12:00 AM');
    expect(localTimeToMinutes('24:00:00') - localTimeToMinutes('08:00:00')).toBe(16 * 60);
  });

  it('validates order and overlaps like the database constraints', () => {
    const week = defaultWeek();
    week[1] = {
      weekday: 1,
      open: true,
      intervals: [
        { opensAt: '08:00', closesAt: '12:00' },
        { opensAt: '11:00', closesAt: '17:00' },
      ],
    };
    week[2] = { weekday: 2, open: true, intervals: [{ opensAt: '17:00', closesAt: '08:00' }] };
    week[3] = { weekday: 3, open: true, intervals: [{ opensAt: '18:00', closesAt: '00:00' }] };
    expect(validateWeek(week)).toEqual({
      1: 'Opening hours overlap.',
      2: 'Closing time must be after opening time.',
    });
  });
});
