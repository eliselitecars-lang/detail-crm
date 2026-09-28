import { describe, expect, it } from 'vitest';
import { dayLabels, dayWindow, groupSlotsByDay, shiftWindow } from './schedule';

describe('quote scheduling helpers', () => {
  it('lists consecutive local days across a month end', () => {
    expect(dayWindow('2026-09-29', 4)).toEqual([
      '2026-09-29',
      '2026-09-30',
      '2026-10-01',
      '2026-10-02',
    ]);
  });

  it('groups start times by the shop-local day, in time order', () => {
    const slots = [
      { starts_at: '2026-10-02T15:00:00Z', ends_at: '2026-10-02T17:00:00Z' },
      // 00:30 UTC on Oct 2 is still Oct 1 in Chicago
      { starts_at: '2026-10-02T00:30:00Z', ends_at: '2026-10-02T02:30:00Z' },
      { starts_at: '2026-10-01T14:00:00Z', ends_at: '2026-10-01T16:00:00Z' },
    ];
    const byDay = groupSlotsByDay(slots, 'America/Chicago');
    expect([...byDay.keys()]).toEqual(['2026-10-01', '2026-10-02']);
    expect(byDay.get('2026-10-01')?.map((s) => s.starts_at)).toEqual([
      '2026-10-01T14:00:00Z',
      '2026-10-02T00:30:00Z',
    ]);
  });

  it('pages the window without going before today or past the booking horizon', () => {
    expect(shiftWindow('2026-10-01', -1, '2026-09-28', 60)).toBe('2026-09-28');
    expect(shiftWindow('2026-09-28', 1, '2026-09-28', 60)).toBe('2026-10-05');
    // the last window ends on day 60
    expect(shiftWindow('2026-11-20', 1, '2026-09-28', 60)).toBe('2026-11-21');
  });

  it('labels days without a time zone shift', () => {
    expect(dayLabels('2026-10-01')).toEqual({ weekday: 'Thu', day: 'Oct 1' });
  });
});
