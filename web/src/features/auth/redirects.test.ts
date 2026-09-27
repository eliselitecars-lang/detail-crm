import { describe, expect, it } from 'vitest';
import { loginPath, readRecoveryLinkError, safeNext, signupPath } from './redirects';

describe('safeNext', () => {
  it.each([
    '/app/jobs/123',
    '/invite/abc?x=1',
    '/app/customers?q=100%', // a literal "%" (decoding again would throw)
    '/app?x=%2520', // an encoded "%" survives unchanged
    '/app/customers?q=o%27brien#notes',
    '/login-help',
  ])('returns same-origin path %s unchanged', (input) => {
    expect(safeNext(input)).toBe(input);
  });

  it('round-trips deep links through loginPath and URLSearchParams faithfully', () => {
    for (const target of ['/app/customers?q=100%25', '/app?x=%2520', '/app/jobs?tag=a%26b']) {
      const url = new URL(loginPath(target), 'https://app.test');
      expect(safeNext(url.searchParams.get('next'))).toBe(target);
    }
  });

  it.each([
    null,
    '',
    'https://evil.test',
    '//evil.test',
    '/\\evil.test',
    'app',
    '%2Fapp%2Fcustomers', // still encoded: not a path
    '%2F%2Fevil.test',
    '/login',
    '/login?next=/app',
    '/signup?next=/x',
    '%E0%A4%A',
    '/app\u0000x',
    '/\t/evil.test',
    '/app\u007f',
  ])('rejects %j', (input) => {
    expect(safeNext(input)).toBe('/app');
  });

  it('builds login/signup links', () => {
    expect(loginPath()).toBe('/login');
    expect(loginPath('/app')).toBe('/login');
    expect(loginPath('/app/jobs')).toBe('/login?next=%2Fapp%2Fjobs');
    expect(signupPath('/invite/t')).toBe('/signup?next=%2Finvite%2Ft');
    expect(loginPath('https://evil.test')).toBe('/login');
  });
});

describe('readRecoveryLinkError', () => {
  it('reads expired-link errors from the hash', () => {
    expect(
      readRecoveryLinkError(
        'https://x.test/reset-password#error=access_denied&error_code=otp_expired&error_description=Email+link+is+invalid+or+has+expired',
      ),
    ).toBe('This reset link is invalid or has expired. Request a new one.');
  });
  it('returns null for a clean URL', () => {
    expect(readRecoveryLinkError('https://x.test/reset-password')).toBeNull();
    expect(
      readRecoveryLinkError('https://x.test/reset-password#access_token=abc&type=recovery'),
    ).toBeNull();
  });
});
