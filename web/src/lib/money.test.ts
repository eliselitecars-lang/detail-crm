import { describe, expect, it } from 'vitest';
import {
  bpsToPercentInput,
  centsToInputValue,
  formatBps,
  formatCents,
  parseMoneyInput,
  parsePercentToBps,
  sumCents,
} from './money';

describe('formatCents', () => {
  it('formats integer cents as USD', () => {
    expect(formatCents(123456)).toBe('$1,234.56');
    expect(formatCents(5)).toBe('$0.05');
    expect(formatCents(0)).toBe('$0.00');
    expect(formatCents(-500)).toBe('-$5.00');
  });
  it('handles empty values', () => {
    expect(formatCents(null)).toBe('—');
    expect(formatCents(undefined)).toBe('—');
    expect(formatCents(Number.NaN)).toBe('—');
  });
  it('supports compact whole amounts and signed output', () => {
    expect(formatCents(15000, { compactWhole: true })).toBe('$150');
    expect(formatCents(15050, { compactWhole: true })).toBe('$150.50');
    expect(formatCents(250, { signed: true })).toBe('+$2.50');
  });
});

describe('parseMoneyInput', () => {
  it.each([
    ['19.99', 1999],
    ['$1,234.56', 123456],
    ['1234.5', 123450],
    ['.5', 50],
    ['12', 1200],
    [' 12.00 ', 1200],
    ['0.1', 10],
    ['0.29', 29], // float trap: 0.29 * 100 = 28.999999999999996
  ])('parses %s → %i cents', (input, cents) => {
    expect(parseMoneyInput(input)).toBe(cents);
  });

  it.each(['', '   ', 'abc', '1.234', '1..2', '$', '.', '12a'])('rejects %j', (input) => {
    expect(parseMoneyInput(input)).toBeNull();
  });

  it('rejects negatives unless allowed', () => {
    expect(parseMoneyInput('-5')).toBeNull();
    expect(parseMoneyInput('-5', { allowNegative: true })).toBe(-500);
    expect(parseMoneyInput('-$5.25', { allowNegative: true })).toBe(-525);
    expect(parseMoneyInput('(5.25)', { allowNegative: true })).toBe(-525);
    expect(parseMoneyInput('$-5', { allowNegative: true })).toBe(-500);
    expect(parseMoneyInput('($5)', { allowNegative: true })).toBe(-500);
  });

  it.each(['-$-5', '--5', '(-5)', '(-$5)', '($-5)', '-(5)', '$--5', '-$-0'])(
    'rejects doubled signs %j even when negatives are allowed',
    (input) => {
      expect(parseMoneyInput(input)).toBeNull();
      expect(parseMoneyInput(input, { allowNegative: true })).toBeNull();
    },
  );

  it('enforces the maximum', () => {
    expect(parseMoneyInput('100.01', { maxCents: 10000 })).toBeNull();
    expect(parseMoneyInput('100.00', { maxCents: 10000 })).toBe(10000);
  });

  it('round-trips through centsToInputValue', () => {
    for (const cents of [0, 1, 99, 100, 123456, 1999]) {
      expect(parseMoneyInput(centsToInputValue(cents))).toBe(cents);
    }
    expect(centsToInputValue(-525)).toBe('-5.25');
    expect(centsToInputValue(null)).toBe('');
  });
});

describe('percent / basis points', () => {
  it('parses percent strings to bps', () => {
    expect(parsePercentToBps('8.25')).toBe(825);
    expect(parsePercentToBps('7')).toBe(700);
    expect(parsePercentToBps('8.5%')).toBe(850);
    expect(parsePercentToBps('0')).toBe(0);
    expect(parsePercentToBps('100')).toBe(10000);
  });
  it('rejects invalid percents', () => {
    expect(parsePercentToBps('')).toBeNull();
    expect(parsePercentToBps('8.255')).toBeNull();
    expect(parsePercentToBps('101')).toBeNull();
    expect(parsePercentToBps('-1')).toBeNull();
    expect(parsePercentToBps('abc')).toBeNull();
  });
  it('formats bps', () => {
    expect(bpsToPercentInput(825)).toBe('8.25');
    expect(bpsToPercentInput(850)).toBe('8.5');
    expect(bpsToPercentInput(805)).toBe('8.05');
    expect(bpsToPercentInput(700)).toBe('7');
    expect(formatBps(825)).toBe('8.25%');
    expect(formatBps(null)).toBe('—');
  });
});

describe('sumCents', () => {
  it('sums and ignores nullish values', () => {
    expect(sumCents([100, null, 250, undefined, 1])).toBe(351);
  });
});
