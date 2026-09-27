import { describe, expect, it } from 'vitest';
import { defaultWeek, rowsToWeek, validateWeek, weekToRows, type DayHours } from '../businessHours';
import { onboardingSchema, slugify, slugProblem, type OnboardingInput } from './schema';

const valid = (): OnboardingInput => ({
  name: 'Glacier Detailing',
  slug: 'glacier-detailing',
  businessType: 'mobile',
  timezone: 'America/Chicago',
  phone: '(205) 555-0123',
  email: 'Hello@Glacier.test',
  addressLine1: '',
  addressLine2: '',
  city: 'Birmingham',
  region: 'AL',
  postalCode: '35203',
  taxRate: '8.25',
  hours: defaultWeek(),
});

describe('slugify / slugProblem', () => {
  it('derives url-safe slugs from names', () => {
    expect(slugify("Joe's Mobile Detailing!")).toBe('joes-mobile-detailing');
    expect(slugify('  Crème & Coat  ')).toBe('creme-and-coat');
    expect(slugify('A'.repeat(80))).toHaveLength(50);
    expect(slugify('---')).toBe('');
  });

  it('matches the database slug rules', () => {
    expect(slugProblem('glacier-detailing')).toBeNull();
    expect(slugProblem('ab')).toMatch(/at least 3/);
    expect(slugProblem('-abc')).toMatch(/hyphen/);
    expect(slugProblem('abc-')).toMatch(/hyphen/);
    expect(slugProblem('ABC')).toMatch(/lowercase/);
    expect(slugProblem('app')).toMatch(/reserved/);
    expect(slugProblem('book')).toMatch(/reserved/);
    expect(slugProblem('a'.repeat(51))).toMatch(/50/);
    expect(slugProblem('')).toMatch(/Choose/);
  });
});

describe('onboardingSchema', () => {
  it('accepts a complete shop and normalizes values', () => {
    const result = onboardingSchema.parse(valid());
    expect(result.phone).toBe('+12055550123');
    expect(result.email).toBe('hello@glacier.test');
    expect(result.taxRate).toBe(825);
    expect(result.addressLine1).toBeNull();
    expect(result.city).toBe('Birmingham');
  });

  it('treats phone/email as optional', () => {
    const result = onboardingSchema.parse({ ...valid(), phone: '', email: '' });
    expect(result.phone).toBeNull();
    expect(result.email).toBeNull();
  });

  it.each([
    ['name', { name: '  ' }],
    ['slug', { slug: 'q' }],
    ['timezone', { timezone: 'Mars/Base' }],
    ['phone', { phone: '555-0123' }],
    ['email', { email: 'not-an-email' }],
    ['taxRate', { taxRate: '101' }],
    ['taxRate', { taxRate: '8.255' }],
    ['postalCode', { postalCode: '1'.repeat(21) }],
  ])('rejects an invalid %s', (field, patch) => {
    const result = onboardingSchema.safeParse({ ...valid(), ...patch });
    expect(result.success).toBe(false);
    expect(result.error?.issues.map((i) => i.path[0])).toContain(field);
  });

  it('rejects invalid business hours', () => {
    const hours = defaultWeek();
    hours[1] = { weekday: 1, open: true, intervals: [{ opensAt: '17:00', closesAt: '08:00' }] };
    const result = onboardingSchema.safeParse({ ...valid(), hours });
    expect(result.success).toBe(false);
    expect(result.error?.issues[0]?.path).toEqual(['hours']);
  });
});

describe('business hours', () => {
  const day = (weekday: number, intervals: [string, string][], open = true): DayHours => ({
    weekday,
    open,
    intervals: intervals.map(([opensAt, closesAt]) => ({ opensAt, closesAt })),
  });

  it('defaults to Monday–Friday open', () => {
    expect(defaultWeek().map((d) => d.open)).toEqual([false, true, true, true, true, true, false]);
  });

  it('validates order and overlaps per day', () => {
    expect(
      validateWeek([
        day(1, [
          ['08:00', '12:00'],
          ['13:00', '17:00'],
        ]),
      ]),
    ).toEqual({});
    expect(validateWeek([day(1, [['12:00', '08:00']])])[1]).toMatch(/after opening/);
    expect(
      validateWeek([
        day(2, [
          ['08:00', '12:00'],
          ['11:00', '17:00'],
        ]),
      ])[2],
    ).toMatch(/overlap/);
    expect(validateWeek([day(3, [])])[3]).toMatch(/closed/);
    expect(validateWeek([day(4, [['12:00', '08:00']], false)])).toEqual({});
  });

  it('treats a 00:00 close as midnight (24:00)', () => {
    expect(validateWeek([day(5, [['18:00', '00:00']])])).toEqual({});
    expect(weekToRows([day(5, [['18:00', '00:00']])])).toEqual([
      { weekday: 5, opens_at: '18:00', closes_at: '24:00' },
    ]);
  });

  it('converts to and from business_hours rows (closed days have no rows)', () => {
    const week = [
      day(0, [['09:00', '12:00']], false),
      day(1, [
        ['08:00', '12:00'],
        ['13:00', '17:00'],
      ]),
    ];
    const rows = weekToRows(week);
    expect(rows).toEqual([
      { weekday: 1, opens_at: '08:00', closes_at: '12:00' },
      { weekday: 1, opens_at: '13:00', closes_at: '17:00' },
    ]);
    const back = rowsToWeek([
      { weekday: 1, opens_at: '13:00:00', closes_at: '17:00:00' },
      { weekday: 1, opens_at: '08:00:00', closes_at: '12:00:00' },
      { weekday: 6, opens_at: '20:00:00', closes_at: '24:00:00' },
    ]);
    expect(back[1]).toEqual(
      day(1, [
        ['08:00', '12:00'],
        ['13:00', '17:00'],
      ]),
    );
    expect(back[6]?.intervals).toEqual([{ opensAt: '20:00', closesAt: '00:00' }]);
    expect(back[0]?.open).toBe(false);
  });
});
