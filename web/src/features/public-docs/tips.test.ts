import { describe, expect, it } from 'vitest';
import { tipCents } from './tips';

describe('tipCents', () => {
  it('computes whole-cent percentage tips of the balance', () => {
    expect(tipCents('none', 20000, null)).toBe(0);
    expect(tipCents('15', 20000, null)).toBe(3000);
    expect(tipCents('20', 12345, null)).toBe(2469);
    expect(tipCents('15', 3, null)).toBe(0);
  });

  it('bounds custom tips to 0..balance', () => {
    expect(tipCents('custom', 20000, 500)).toBe(500);
    expect(tipCents('custom', 20000, 20000)).toBe(20000);
    expect(tipCents('custom', 20000, 20001)).toBeNull();
    expect(tipCents('custom', 20000, -1)).toBeNull();
    expect(tipCents('custom', 20000, null)).toBeNull();
  });
});
