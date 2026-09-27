import { describe, expect, it } from 'vitest';
import {
  formatPhone,
  formatPhoneAsYouType,
  isValidPhone,
  normalizePhone,
  phoneHref,
} from './phone';

describe('normalizePhone', () => {
  it.each([
    ['(205) 555-0123', '+12055550123'],
    ['205.555.0123', '+12055550123'],
    ['2055550123', '+12055550123'],
    ['1-205-555-0123', '+12055550123'],
    ['+1 205 555 0123', '+12055550123'],
    ['+12055550123', '+12055550123'],
    ['+44 20 7946 0958', '+442079460958'],
    ['0044 20 7946 0958', '+442079460958'],
  ])('%s → %s', (input, expected) => {
    expect(normalizePhone(input)).toBe(expected);
  });

  it.each([
    '',
    '   ',
    '555-0123',
    '123-456-7890',
    '(205) 055-0123',
    '+1 205 555 012',
    '205-555-0123 x12',
    'call me',
    '+0 123',
  ])('rejects %j', (input) => {
    expect(normalizePhone(input)).toBeNull();
    expect(isValidPhone(input)).toBe(false);
  });
});

describe('formatPhone', () => {
  it('formats NANP numbers', () => {
    expect(formatPhone('+12055550123')).toBe('(205) 555-0123');
    expect(formatPhone('2055550123')).toBe('(205) 555-0123');
  });
  it('leaves international numbers in E.164', () => {
    expect(formatPhone('+442079460958')).toBe('+442079460958');
  });
  it('returns unparseable input unchanged', () => {
    expect(formatPhone('ext 5')).toBe('ext 5');
    expect(formatPhone(null)).toBe('');
  });
});

describe('formatPhoneAsYouType', () => {
  it('progressively formats US digits', () => {
    expect(formatPhoneAsYouType('2')).toBe('(2');
    expect(formatPhoneAsYouType('2055')).toBe('(205) 5');
    expect(formatPhoneAsYouType('2055550')).toBe('(205) 555-0');
    expect(formatPhoneAsYouType('205555012345')).toBe('(205) 555-0123');
    expect(formatPhoneAsYouType('12055550123')).toBe('(205) 555-0123');
    expect(formatPhoneAsYouType('')).toBe('');
  });
  it('does not touch international input', () => {
    expect(formatPhoneAsYouType('+44 20')).toBe('+44 20');
  });
});

describe('phoneHref', () => {
  it('builds tel/sms links', () => {
    expect(phoneHref('(205) 555-0123')).toBe('tel:+12055550123');
    expect(phoneHref('+12055550123', 'sms')).toBe('sms:+12055550123');
    expect(phoneHref('nope')).toBeUndefined();
  });
});
