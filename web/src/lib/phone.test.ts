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
    // 7-digit numbers are valid E.164 (the database and the iPhone app accept them).
    ['+6831234', '+6831234'],
    ['+690 1234', '+6901234'],
    // Extensions are dropped, as the iPhone app does.
    ['205-555-0123 x12', '+12055550123'],
    ['(205) 555-0123 ext. 4', '+12055550123'],
    ['205 555 0123 EXT 9', '+12055550123'],
    ['+44 20 7946 0958 #22', '+442079460958'],
    [' ( +44 ) 20 7946 0958', '+442079460958'],
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
    'call me',
    '+0 123',
    '+683123',
    '+1234567890123456',
    '205+555+0123',
    '205_555_0123',
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
  it('links short international numbers', () => {
    expect(phoneHref('+6831234')).toBe('tel:+6831234');
  });
  it('builds tel/sms links', () => {
    expect(phoneHref('(205) 555-0123')).toBe('tel:+12055550123');
    expect(phoneHref('+12055550123', 'sms')).toBe('sms:+12055550123');
    expect(phoneHref('nope')).toBeUndefined();
  });
});

describe('phone form fields', () => {
  it('saves a customer whose stored number is a valid 7-digit E.164 (e.g. from the iPhone app)', async () => {
    const { zOptionalPhone, zPhone } = await import('./validation');
    expect(zOptionalPhone.parse('+6831234')).toBe('+6831234');
    expect(zPhone.parse('(205) 555-0123 ext. 4')).toBe('+12055550123');
    expect(zOptionalPhone.safeParse('555-0123').success).toBe(false);
  });
});
