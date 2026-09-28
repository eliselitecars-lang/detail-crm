import { describe, expect, it } from 'vitest';
import { isValidEmail, zEmail, zOptionalEmail } from './validation';

describe('email validation mirrors public.is_valid_email', () => {
  it('accepts what the database, CSV import and the iPhone accept', () => {
    for (const email of [
      'jane@example.com',
      "o'brien@example.com",
      'a+b@example.com',
      'josé@example.com',
      'user@münchen.de',
      'a!b@example.com',
      'x@y.z',
      '  Padded@Example.com  ',
    ]) {
      expect(isValidEmail(email), email).toBe(true);
    }
  });

  it('rejects what the database rejects', () => {
    for (const email of [
      '',
      'plain',
      'no-at.example.com',
      'a@b',
      'a@@b.com',
      'a@b@c.com',
      'a b@example.com',
      '@example.com',
      'a@.com',
      'a@example.',
    ]) {
      expect(isValidEmail(email), email).toBe(false);
    }
  });

  it('caps the length at 254 characters (code points, like char_length)', () => {
    const at254 = `${'a'.repeat(254 - '@example.com'.length)}@example.com`;
    expect(at254.length).toBe(254);
    expect(isValidEmail(at254)).toBe(true);
    expect(isValidEmail(`a${at254}`)).toBe(false);
    // 250 accented characters are 250 code points, so still within the cap.
    expect(isValidEmail(`${'é'.repeat(242)}@example.com`)).toBe(true);
  });

  it('keeps the schemas’ normalisation (trim + lowercase, blank → null)', () => {
    expect(zEmail.parse('  José@Example.COM ')).toBe('josé@example.com');
    expect(zOptionalEmail.parse('   ')).toBeNull();
    expect(zOptionalEmail.parse('X@Y.Z')).toBe('x@y.z');
    expect(zOptionalEmail.safeParse('nope').success).toBe(false);
    expect(zEmail.safeParse('').error?.issues[0]?.message).toBe('Email is required.');
  });
});
