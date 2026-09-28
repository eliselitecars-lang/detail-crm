import { describe, expect, it } from 'vitest';
import { AppError } from './errors';
import {
  isUncertainOutcome,
  newRequestNonce,
  payloadFingerprint,
  RequestNonces,
} from './requestNonce';

const NONCE_RE = /^[A-Za-z0-9_-]{8,64}$/;

describe('newRequestNonce', () => {
  it('is url-safe, 8-64 characters and fresh each time', () => {
    const a = newRequestNonce();
    expect(a).toMatch(NONCE_RE);
    expect(newRequestNonce()).not.toBe(a);
  });
});

describe('isUncertainOutcome', () => {
  it('keeps network, server and unknown failures (the first try may have landed)', () => {
    expect(isUncertainOutcome(new TypeError('Failed to fetch'))).toBe(true);
    expect(isUncertainOutcome(new AppError('x', { kind: 'server' }))).toBe(true);
    expect(isUncertainOutcome(new Error('boom'))).toBe(true);
    // 55000 "this request is still being processed" (0095) reads as unknown
    expect(
      isUncertainOutcome({ code: '55000', message: 'this request is still being processed' }),
    ).toBe(true);
  });

  it('treats refusals as definitive', () => {
    expect(isUncertainOutcome({ code: '22023', message: 'fee is archived' })).toBe(false);
    expect(isUncertainOutcome({ code: '42501', message: 'only managers can add fees' })).toBe(
      false,
    );
    expect(isUncertainOutcome({ code: 'PT402', message: 'inactive' })).toBe(false);
  });
});

describe('RequestNonces', () => {
  it('reuses the nonce of an action retried after an uncertain failure', () => {
    const nonces = new RequestNonces();
    const first = nonces.take('invoice:1:fee:a');
    nonces.settle('invoice:1:fee:a', new TypeError('Failed to fetch'));
    expect(nonces.take('invoice:1:fee:a')).toBe(first);
  });

  it('renews after a success or a definitive refusal, and per action', () => {
    const nonces = new RequestNonces();
    const first = nonces.take('k');
    expect(nonces.take('other')).not.toBe(first);
    nonces.settle('k');
    const second = nonces.take('k');
    expect(second).not.toBe(first);
    nonces.settle('k', { code: '22023', message: 'nope' });
    expect(nonces.take('k')).not.toBe(second);
  });
});

describe('payloadFingerprint', () => {
  it('is stable for equal payloads and differs for different ones', () => {
    expect(payloadFingerprint([{ a: 1 }])).toBe(payloadFingerprint([{ a: 1 }]));
    expect(payloadFingerprint([{ a: 1 }])).not.toBe(payloadFingerprint([{ a: 2 }]));
    expect(payloadFingerprint('x')).toMatch(/^[0-9a-f]{8}$/);
  });
});
