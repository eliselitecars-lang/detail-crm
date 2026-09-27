import { describe, expect, it } from 'vitest';
import { effectiveQuoteStatus, isQuoteEditable } from './api';
import { defaultEnd } from './components/schedule';
import { quoteTimeline } from './components/timeline';
import { quoteRow } from './testFixtures';

describe('effectiveQuoteStatus', () => {
  const today = '2026-09-27';
  it('treats sent/viewed quotes past their validity date as expired', () => {
    expect(effectiveQuoteStatus({ status: 'sent', valid_until: '2026-09-26' }, today)).toBe(
      'expired',
    );
    expect(effectiveQuoteStatus({ status: 'viewed', valid_until: '2026-09-26' }, today)).toBe(
      'expired',
    );
  });
  it('keeps quotes valid through the end of valid_until', () => {
    expect(effectiveQuoteStatus({ status: 'sent', valid_until: today }, today)).toBe('sent');
    expect(effectiveQuoteStatus({ status: 'sent', valid_until: null }, today)).toBe('sent');
    expect(effectiveQuoteStatus({ status: 'approved', valid_until: '2020-01-01' }, today)).toBe(
      'approved',
    );
  });
});

describe('isQuoteEditable', () => {
  it('mirrors the SQL guard (draft/sent/viewed only)', () => {
    expect(isQuoteEditable('draft')).toBe(true);
    expect(isQuoteEditable('sent')).toBe(true);
    expect(isQuoteEditable('viewed')).toBe(true);
    for (const s of ['approved', 'declined', 'expired', 'converted'] as const) {
      expect(isQuoteEditable(s)).toBe(false);
    }
  });
});

describe('defaultEnd', () => {
  it('adds the duration on the same day', () => {
    expect(defaultEnd('2026-10-01', '09:00', 150)).toEqual({ date: '2026-10-01', time: '11:30' });
  });
  it('defaults to two hours and rolls into the next day', () => {
    expect(defaultEnd('2026-10-01', '09:00', 0)).toEqual({ date: '2026-10-01', time: '11:00' });
    expect(defaultEnd('2026-10-01', '22:00', 180)).toEqual({ date: '2026-10-02', time: '01:00' });
    expect(defaultEnd('2026-10-01', '09:00', 3 * 1440)).toEqual({
      date: '2026-10-04',
      time: '09:00',
    });
  });
});

describe('quoteTimeline', () => {
  it('lists stamped events in time order', () => {
    const events = quoteTimeline(
      quoteRow({
        created_at: '2026-09-01T10:00:00Z',
        sent_at: '2026-09-01T11:00:00Z',
        viewed_at: '2026-09-02T09:00:00Z',
        approved_at: '2026-09-02T09:05:00Z',
        approved_by_name: 'Jane Doe',
      }),
    );
    expect(events.map((e) => e.key)).toEqual(['created', 'sent', 'viewed', 'approved']);
    expect(events[3]?.detail).toBe('Signed by Jane Doe');
  });
});
