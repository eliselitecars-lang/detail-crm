import { afterEach, describe, expect, it } from 'vitest';
import {
  decideUrlSession,
  forgetCallbackLink,
  inspectStartupUrl,
  jwtSubject,
  scrubbedUrl,
  startupCallbackLink,
  startupRefusal,
  storedSessionUserId,
} from './authUrlSession';

function jwt(sub: string): string {
  const part = (value: object) =>
    btoa(JSON.stringify(value)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  return `${part({ alg: 'HS256' })}.${part({ sub, role: 'authenticated' })}.sig`;
}

const ORIGIN = 'https://app.example.com';
const link = (path: string, sub: string, type = 'recovery') =>
  `${ORIGIN}${path}#access_token=${jwt(sub)}&refresh_token=rt-${sub}&expires_in=3600&token_type=bearer&type=${type}`;

describe('decideUrlSession (login CSRF)', () => {
  it('ignores and removes a session planted on an ordinary page', () => {
    // The reported attack: another account's tokens on /app, victim signed in.
    const decision = decideUrlSession(link('/app', 'attacker', 'magiclink'), 'victim');
    expect(decision).toMatchObject({ detect: false, scrub: true, refused: 'not_a_callback' });
    // Signed out makes no difference: never auto-saved outside the landing pages.
    expect(decideUrlSession(link('/portal', 'attacker', 'signup'), null)).toMatchObject({
      detect: false,
      scrub: true,
    });
  });

  it('accepts a recovery link on /reset-password when nobody or the same account is signed in', () => {
    expect(decideUrlSession(link('/reset-password', 'u1'), null)).toMatchObject({
      detect: true,
      scrub: false,
      refused: null,
    });
    expect(decideUrlSession(link('/reset-password', 'u1'), 'u1').detect).toBe(true);
  });

  it('never lets a recovery link replace another signed-in account', () => {
    expect(decideUrlSession(link('/reset-password', 'attacker'), 'victim')).toMatchObject({
      detect: false,
      scrub: true,
      refused: 'other_account',
    });
  });

  it('refuses tokens on /reset-password that are not a recovery link', () => {
    expect(decideUrlSession(link('/reset-password', 'u1', 'magiclink'), null)).toMatchObject({
      detect: false,
      scrub: true,
    });
  });

  it('lets supabase-js report a recovery link error', () => {
    const decision = decideUrlSession(
      `${ORIGIN}/reset-password#error=access_denied&error_code=otp_expired`,
      'u1',
    );
    expect(decision).toMatchObject({ detect: true, scrub: false });
  });

  it('holds a confirmation link on /auth/callback for the page to confirm', () => {
    const decision = decideUrlSession(link('/auth/callback?next=%2Fapp', 'u1', 'signup'), 'u2');
    expect(decision.detect).toBe(false);
    expect(decision.scrub).toBe(true);
    expect(decision.callback).toMatchObject({
      accessToken: jwt('u1'),
      refreshToken: 'rt-u1',
      type: 'signup',
      error: null,
    });
    const failed = decideUrlSession(
      `${ORIGIN}/auth/callback#error=access_denied&error_code=otp_expired&error_description=Email+link+is+invalid`,
      null,
    );
    expect(failed.callback).toMatchObject({ accessToken: null, errorCode: 'otp_expired' });
  });

  it('leaves pages without auth parameters alone', () => {
    expect(decideUrlSession(`${ORIGIN}/app/jobs#section`, 'u1')).toEqual({
      detect: false,
      scrub: false,
      refused: null,
      callback: null,
    });
  });
});

describe('helpers', () => {
  it('reads the JWT subject and the stored session user', () => {
    expect(jwtSubject(jwt('abc'))).toBe('abc');
    expect(jwtSubject('not-a-jwt')).toBeNull();
    expect(jwtSubject(null)).toBeNull();
    expect(storedSessionUserId(JSON.stringify({ user: { id: 'u1' } }))).toBe('u1');
    expect(storedSessionUserId(JSON.stringify({ access_token: jwt('u2') }))).toBe('u2');
    expect(storedSessionUserId('{broken')).toBeNull();
    expect(storedSessionUserId(null)).toBeNull();
  });

  it('removes only the auth parameters from the URL', () => {
    expect(scrubbedUrl(link('/app/jobs?tab=open', 'u1'))).toBe('/app/jobs?tab=open');
    expect(scrubbedUrl(`${ORIGIN}/auth/callback?next=%2Fapp#access_token=x&other=1`)).toBe(
      '/auth/callback?next=%2Fapp#other=1',
    );
  });
});

describe('inspectStartupUrl', () => {
  const previous = window.location.href;
  afterEach(() => {
    window.history.replaceState(null, '', previous);
    window.localStorage.clear();
    forgetCallbackLink();
  });

  it('keeps the stored session and cleans the address bar', () => {
    window.localStorage.setItem('sb-test-auth-token', JSON.stringify({ user: { id: 'victim' } }));
    window.history.replaceState(null, '', link('/reset-password', 'attacker').slice(ORIGIN.length));
    const decision = inspectStartupUrl('sb-test-auth-token');
    expect(decision.detect).toBe(false);
    expect(window.location.hash).toBe('');
    expect(window.location.pathname).toBe('/reset-password');
    expect(startupRefusal()).toBe('other_account');
  });

  it('remembers a confirmation link for /auth/callback until it is used', () => {
    window.history.replaceState(
      null,
      '',
      link('/auth/callback?next=%2Fapp', 'u1', 'signup').slice(ORIGIN.length),
    );
    inspectStartupUrl('sb-test-auth-token');
    expect(window.location.search).toBe('?next=%2Fapp');
    expect(window.location.hash).toBe('');
    expect(startupCallbackLink()?.refreshToken).toBe('rt-u1');
    forgetCallbackLink();
    expect(startupCallbackLink()).toBeNull();
  });
});
