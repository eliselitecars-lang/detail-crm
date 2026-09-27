import { describe, expect, it } from 'vitest';
import { operatorName, operatorNameStart, readLegalOperator } from './operator';

describe('readLegalOperator', () => {
  it('reads the four VITE_LEGAL_* values, trimmed', () => {
    expect(
      readLegalOperator({
        VITE_LEGAL_ENTITY_NAME: '  Example Operator  LLC ',
        VITE_SUPPORT_EMAIL: ' privacy@example.com ',
        VITE_LEGAL_COUNTRY: 'the State of Delaware, United States',
        VITE_LEGAL_ADDRESS: '1 Example Way\\nSuite 2\n  Springfield ',
      }),
    ).toEqual({
      entityName: 'Example Operator LLC',
      supportEmail: 'privacy@example.com',
      country: 'the State of Delaware, United States',
      address: '1 Example Way\nSuite 2\nSpringfield',
    });
  });

  it('treats missing, blank and placeholder values as unset', () => {
    const unset = { entityName: null, supportEmail: null, country: null, address: null };
    expect(readLegalOperator({})).toEqual(unset);
    expect(
      readLegalOperator({
        VITE_LEGAL_ENTITY_NAME: '   ',
        VITE_SUPPORT_EMAIL: '',
        VITE_LEGAL_COUNTRY: 'YOUR_COUNTRY',
        VITE_LEGAL_ADDRESS: ' \n ',
      }),
    ).toEqual(unset);
    expect(readLegalOperator({ VITE_LEGAL_ENTITY_NAME: 42, VITE_SUPPORT_EMAIL: true })).toEqual(
      unset,
    );
  });

  it('drops a support email that is not an address', () => {
    for (const value of ['support', 'mailto:a@b.co', 'a@b', 'two words@example.com', 'a@b.c']) {
      expect(readLegalOperator({ VITE_SUPPORT_EMAIL: value }).supportEmail).toBeNull();
    }
  });

  it('drops implausibly long values', () => {
    expect(readLegalOperator({ VITE_LEGAL_ENTITY_NAME: 'x'.repeat(301) }).entityName).toBeNull();
  });
});

describe('operator wording', () => {
  it('names the entity when set', () => {
    const operator = readLegalOperator({ VITE_LEGAL_ENTITY_NAME: 'Example Operator LLC' });
    expect(operatorName(operator)).toBe('Example Operator LLC');
    expect(operatorNameStart(operator)).toBe('Example Operator LLC');
  });

  it('falls back to neutral wording, never an invented name', () => {
    const operator = readLegalOperator({});
    expect(operatorName(operator)).toBe('the operator of this service');
    expect(operatorNameStart(operator)).toBe('The operator of this service');
  });
});
