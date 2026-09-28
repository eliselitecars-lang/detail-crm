import { describe, expect, it } from 'vitest';
import { effectiveOptionId } from '../api';
import { followupAttemptsText, followupStageLabel } from './followups';
import { countedLines, groupLines, UNGROUPED, type DocLine } from './lines';
import { pdfFileName, publicPdfUrl } from './pdf';

function line(overrides: Partial<DocLine> = {}): DocLine {
  return {
    id: 'l1',
    service_id: null,
    vehicle_id: null,
    name: 'Line',
    description: null,
    quantity: 1,
    unit_price_cents: 1000,
    discount_cents: 0,
    taxable: true,
    total_cents: 1000,
    sort: 1,
    optional: false,
    selected: true,
    duration_minutes: 60,
    discount_eligible: true,
    fee_id: null,
    option_id: null,
    job_id: null,
    ...overrides,
  };
}

describe('countedLines', () => {
  const lines = [
    line({ id: 'shared' }),
    line({ id: 'a', option_id: 'opt-a' }),
    line({ id: 'b', option_id: 'opt-b' }),
    line({ id: 'upsell', optional: true, selected: false }),
    line({ id: 'upsell-a', option_id: 'opt-a', optional: true, selected: true }),
  ];

  it('counts shared lines plus the effective option’s, optional ones only when chosen', () => {
    expect(countedLines(lines, 'opt-a').map((l) => l.id)).toEqual(['shared', 'a', 'upsell-a']);
    expect(countedLines(lines, 'opt-b').map((l) => l.id)).toEqual(['shared', 'b']);
  });

  it('treats every line as shared when the quote has no options', () => {
    expect(countedLines(lines, null).map((l) => l.id)).toEqual(['shared', 'a', 'b', 'upsell-a']);
  });
});

describe('groupLines', () => {
  it('groups in the given order, then by first appearance, keeping line order', () => {
    const lines = [
      line({ id: '1', job_id: 'j2' }),
      line({ id: '2', job_id: null }),
      line({ id: '3', job_id: 'j1' }),
      line({ id: '4', job_id: 'j2' }),
    ];
    const groups = groupLines(
      lines,
      (l) => l.job_id,
      (key) => (key === UNGROUPED ? 'Other' : `Job ${key}`),
      ['j1', 'j2'],
    );
    expect(groups.map((g) => [g.title, g.lines.map((l) => l.id)])).toEqual([
      ['Job j1', ['3']],
      ['Job j2', ['1', '4']],
      ['Other', ['2']],
    ]);
  });
});

describe('effectiveOptionId', () => {
  const options = [{ id: 'o1' }, { id: 'o2' }];
  it('is the chosen option, else the first', () => {
    expect(effectiveOptionId({ selected_option_id: 'o2' }, options)).toBe('o2');
    expect(effectiveOptionId({ selected_option_id: null }, options)).toBe('o1');
    expect(effectiveOptionId({ selected_option_id: 'gone' }, options)).toBe('o1');
    expect(effectiveOptionId({ selected_option_id: null }, [])).toBeNull();
  });
});

describe('follow-up text', () => {
  it('describes attempts and stages', () => {
    expect(followupAttemptsText({ attempts_sent: 0, max_attempts: 2 })).toBe('None sent yet');
    expect(followupAttemptsText({ attempts_sent: 1, max_attempts: 2 })).toBe('1 of 2 sent');
    expect(followupAttemptsText({ attempts_sent: 3, max_attempts: 2 })).toBe('2 of 2 sent');
    expect(followupAttemptsText({ attempts_sent: 0, max_attempts: 0 })).toBeNull();
    expect(followupStageLabel('invoice_overdue')).toBe('Past-due notices');
  });
});

describe('pdf links', () => {
  it('builds the public GET link and the file name', () => {
    const url = publicPdfUrl('quote', 'tok-1');
    expect(url).toMatch(/\/functions\/v1\/pdf\?action=quote&token=tok-1$/);
    expect(pdfFileName('invoice', 2001)).toBe('invoice-2001.pdf');
  });
});
