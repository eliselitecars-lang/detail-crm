import { describe, expect, it } from 'vitest';
import {
  customerName,
  escapeLike,
  formatQuantity,
  newRequestNonce,
  parseDocNumber,
  parseQuantity,
  publicDocUrl,
  vehicleLabel,
} from './format';
import { nextSorts } from './lines';
import { describeDiscount, isDiscountKind } from './discount';

describe('customerName', () => {
  it('prefers the person, then the company', () => {
    expect(customerName({ first_name: ' Jane ', last_name: 'Doe', company: 'Acme' })).toBe(
      'Jane Doe',
    );
    expect(customerName({ first_name: null, last_name: null, company: 'Acme Fleet' })).toBe(
      'Acme Fleet',
    );
    expect(customerName({ first_name: '', last_name: '', company: '' })).toBe('Unnamed customer');
    expect(customerName(null)).toBe('Unknown customer');
  });
});

describe('vehicleLabel', () => {
  it('joins year/make/model/trim and falls back to the plate', () => {
    expect(vehicleLabel({ year: 2021, make: 'Toyota', model: 'Tacoma', trim: 'TRD' })).toBe(
      '2021 Toyota Tacoma TRD',
    );
    expect(vehicleLabel({ year: null, make: null, model: null, license_plate: 'ABC123' })).toBe(
      'ABC123',
    );
    expect(vehicleLabel({ year: null, make: null, model: null })).toBe('Vehicle');
    expect(vehicleLabel(undefined)).toBe('No vehicle');
  });
});

describe('parseQuantity', () => {
  it('accepts positive numbers with up to two decimals', () => {
    expect(parseQuantity('1')).toBe(1);
    expect(parseQuantity(' 2.5 ')).toBe(2.5);
    expect(parseQuantity('0.25')).toBe(0.25);
    expect(parseQuantity('.5')).toBeNull();
    expect(parseQuantity('0')).toBeNull();
    expect(parseQuantity('1.234')).toBeNull();
    expect(parseQuantity('-1')).toBeNull();
    expect(parseQuantity('abc')).toBeNull();
    expect(parseQuantity('')).toBeNull();
  });

  it('round-trips through formatQuantity', () => {
    expect(formatQuantity(1)).toBe('1');
    expect(formatQuantity(2.5)).toBe('2.5');
    expect(parseQuantity(formatQuantity(0.25))).toBe(0.25);
  });
});

describe('links and search helpers', () => {
  it('builds public quote and invoice links', () => {
    expect(publicDocUrl('quote', 'tok-1', 'https://app.test/')).toBe('https://app.test/q/tok-1');
    expect(publicDocUrl('invoice', 'tok 2', 'https://app.test')).toBe('https://app.test/i/tok%202');
  });

  it('parses document numbers', () => {
    expect(parseDocNumber('1042')).toBe(1042);
    expect(parseDocNumber('#1042')).toBe(1042);
    expect(parseDocNumber('Jane')).toBeNull();
    expect(parseDocNumber('10a')).toBeNull();
  });

  it('escapes LIKE wildcards', () => {
    expect(escapeLike('50%_off\\')).toBe('50\\%\\_off\\\\');
  });

  it('makes url-safe request nonces', () => {
    const nonce = newRequestNonce();
    expect(nonce).toMatch(/^[A-Za-z0-9_-]{8,64}$/);
    expect(newRequestNonce()).not.toBe(nonce);
  });
});

describe('lines & discount helpers', () => {
  it('appends sort values after the existing lines', () => {
    expect(nextSorts([{ sort: 3 }, { sort: 1 }], 2)).toEqual([4, 5]);
    expect(nextSorts([], 1)).toEqual([1]);
  });

  it('describes discounts', () => {
    expect(describeDiscount('percent', 1250, 'usd')).toBe('12.5% off');
    expect(describeDiscount('fixed', 2500, 'usd')).toBe('$25.00 off');
    expect(describeDiscount('none', 0, 'usd')).toBe('None');
    expect(isDiscountKind('fixed')).toBe(true);
    expect(isDiscountKind('bogus')).toBe(false);
  });
});
