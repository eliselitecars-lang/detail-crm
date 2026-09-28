import { describe, expect, it } from 'vitest';
import { codeSearchTerm, containsOperand, effectiveCardStatus } from './api';
import { expiryText } from './publicApi';

describe('gift card helpers', () => {
  it('shows a lapsed card as expired', () => {
    const now = new Date('2026-09-28T12:00:00Z');
    expect(effectiveCardStatus({ status: 'active', expires_at: '2026-09-01T00:00:00Z' }, now)).toBe(
      'expired',
    );
    expect(effectiveCardStatus({ status: 'active', expires_at: null }, now)).toBe('active');
    expect(effectiveCardStatus({ status: 'void', expires_at: '2026-09-01T00:00:00Z' }, now)).toBe(
      'void',
    );
  });

  it('searches codes by up to 4 letters or digits', () => {
    expect(codeSearchTerm(' q7-z ')).toBe('Q7Z');
    expect(codeSearchTerm('ABCDE')).toBeNull();
    expect(codeSearchTerm('--')).toBeNull();
  });

  it('quotes free-text search so commas and parentheses stay literal', () => {
    expect(containsOperand('Smith, John')).toBe('"%Smith, John%"');
    expect(containsOperand('Acme (fleet)')).toBe('"%Acme (fleet)%"');
    // LIKE wildcards escaped first, then PostgREST quoting escapes the backslash and quotes
    expect(containsOperand('50%_off')).toBe('"%50\\\\%\\\\_off%"');
    expect(containsOperand('say "hi"')).toBe('"%say \\"hi\\"%"');
    expect(containsOperand('a\\b')).toBe('"%a\\\\\\\\b%"');
  });

  it('describes expiry', () => {
    expect(expiryText(null)).toBe('Never expires.');
    expect(expiryText(60)).toBe('Valid for 5 years from purchase.');
    expect(expiryText(66)).toBe('Valid for 66 months from purchase.');
  });
});
