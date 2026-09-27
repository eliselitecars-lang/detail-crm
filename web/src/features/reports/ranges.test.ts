import { describe, expect, it } from 'vitest';
import { centsCell, csvCell, toCsv } from './csv';
import { outstandingReportSchema, teamHasPay, teamRowSchema } from './model';
import { bucketLabel, defaultBucket, presetRange, rangeError, readParams } from './ranges';

describe('presetRange', () => {
  // 2026-03-05 is a Thursday.
  const today = '2026-03-05';
  it('computes calendar presets', () => {
    expect(presetRange('today', today)).toEqual({ from: today, to: today });
    expect(presetRange('week', today)).toEqual({ from: '2026-03-02', to: today });
    expect(presetRange('month', today)).toEqual({ from: '2026-03-01', to: today });
    expect(presetRange('last_month', today)).toEqual({ from: '2026-02-01', to: '2026-02-28' });
    expect(presetRange('ytd', today)).toEqual({ from: '2026-01-01', to: today });
  });

  it('starts weeks on Monday (Sunday belongs to the previous week)', () => {
    expect(presetRange('week', '2026-03-08')).toEqual({ from: '2026-03-02', to: '2026-03-08' });
    expect(presetRange('week', '2026-03-09')).toEqual({ from: '2026-03-09', to: '2026-03-09' });
  });

  it('crosses year boundaries for last month', () => {
    expect(presetRange('last_month', '2026-01-15')).toEqual({
      from: '2025-12-01',
      to: '2025-12-31',
    });
  });
});

describe('readParams', () => {
  it('uses the shop time zone for "today", not the browser’s', () => {
    // 03:00 UTC on Mar 1 is still Feb 28 in Chicago.
    const now = new Date('2026-03-01T03:00:00Z');
    const result = readParams(new URLSearchParams('range=today'), 'America/Chicago', now);
    expect(result.range).toEqual({ from: '2026-02-28', to: '2026-02-28' });
    const tokyo = readParams(new URLSearchParams('range=today'), 'Asia/Tokyo', now);
    expect(tokyo.range).toEqual({ from: '2026-03-01', to: '2026-03-01' });
  });

  it('defaults to this month with an automatic bucket', () => {
    const now = new Date('2026-03-20T15:00:00Z');
    const result = readParams(new URLSearchParams(), 'America/Chicago', now);
    expect(result).toMatchObject({
      preset: 'month',
      range: { from: '2026-03-01', to: '2026-03-20' },
      bucket: 'day',
      valid: true,
    });
    expect(
      readParams(new URLSearchParams('range=ytd'), 'UTC', new Date('2026-05-01T12:00:00Z')).bucket,
    ).toBe('week');
  });

  it('validates custom ranges', () => {
    const bad = readParams(
      new URLSearchParams('range=custom&from=2026-03-10&to=2026-03-01'),
      'UTC',
    );
    expect(bad.valid).toBe(false);
    expect(bad.error).toMatch(/on or after/);
    const ok = readParams(
      new URLSearchParams('range=custom&from=2025-01-01&to=2025-12-31&bucket=month'),
      'UTC',
    );
    expect(ok).toMatchObject({ valid: true, bucket: 'month' });
  });
});

describe('rangeError / defaultBucket', () => {
  it('rejects missing, invalid and too-long ranges', () => {
    expect(rangeError({ from: '', to: '2026-01-01' })).toMatch(/Choose/);
    expect(rangeError({ from: '2026-02-30', to: '2026-03-01' })).toMatch(/valid dates/);
    expect(rangeError({ from: '2010-01-01', to: '2026-01-01' })).toMatch(/10 years/);
    expect(rangeError({ from: '2026-01-01', to: '2026-01-01' })).toBeNull();
  });

  it('picks day / week / month by length', () => {
    expect(defaultBucket({ from: '2026-01-01', to: '2026-01-31' })).toBe('day');
    expect(defaultBucket({ from: '2026-01-01', to: '2026-05-31' })).toBe('week');
    expect(defaultBucket({ from: '2025-01-01', to: '2025-12-31' })).toBe('month');
  });

  it('labels buckets as calendar dates', () => {
    expect(bucketLabel('2026-03-02', 'week')).toBe('Week of Mar 2, 2026');
    expect(bucketLabel('2026-03-01', 'month')).toBe('March 2026');
    expect(bucketLabel('2026-03-01', 'day', true)).toBe('Mar 1');
  });
});

describe('csv', () => {
  it('escapes cells and neutralises formulas', () => {
    expect(csvCell('a,b')).toBe('"a,b"');
    expect(csvCell('say "hi"')).toBe('"say ""hi"""');
    expect(csvCell('=SUM(A1)')).toBe("'=SUM(A1)");
    expect(csvCell(null)).toBe('');
    expect(csvCell(-5)).toBe('-5');
    expect(toCsv(['A', 'B'], [[1, 'x']])).toBe('A,B\r\n1,x\r\n');
  });

  it('writes cents as decimals', () => {
    expect(centsCell(12345)).toBe('123.45');
    expect(centsCell(-5)).toBe('-0.05');
    expect(centsCell(0)).toBe('0.00');
    expect(centsCell(null)).toBe('');
  });
});

describe('report schemas', () => {
  const base = {
    member_id: 'm1',
    display_name: 'Theo',
    role: 'technician',
    active: true,
    worked_seconds: 3600,
    hours: '1.00',
    jobs_completed: 1,
    revenue_cents: 1000,
    pre_tax_revenue_cents: 900,
    hourly_rate_cents: null,
    commission_bps: null,
    commission_cents: null,
    labor_cost_cents: null,
  };

  it('coerces numeric strings and detects pay columns', () => {
    const row = teamRowSchema.parse(base);
    expect(row.hours).toBe(1);
    expect(teamHasPay([row])).toBe(false);
    expect(teamHasPay([teamRowSchema.parse({ ...base, hourly_rate_cents: 2000 })])).toBe(true);
  });

  it('rejects malformed outstanding reports', () => {
    expect(outstandingReportSchema.safeParse({ count: 1 }).success).toBe(false);
  });
});
