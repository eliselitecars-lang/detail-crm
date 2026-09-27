import { describe, expect, it } from 'vitest';
import { membership } from '@/test/render';
import { selectMembership, sortMemberships } from './selection';

const shop = (id: string, name: string) =>
  membership({ shopId: id, shop: { ...membership().shop, id, name } });

describe('selectMembership', () => {
  const a = shop('a', 'Zephyr Coatings');
  const b = shop('b', 'alpha Tint');
  const c = shop('c', 'Mobile Shine');

  it('returns null without memberships', () => {
    expect(selectMembership([], 'a')).toBeNull();
  });

  it('prefers the remembered shop when the user still belongs to it', () => {
    expect(selectMembership([a, b, c], 'c')?.shopId).toBe('c');
  });

  it('falls back to the first shop by name (case-insensitive) when the remembered one is gone', () => {
    expect(selectMembership([a, b, c], 'deleted-shop')?.shopId).toBe('b');
    expect(selectMembership([a, b, c], null)?.shopId).toBe('b');
  });

  it('sorts deterministically by name then id', () => {
    const twin = shop('0', 'Mobile Shine');
    expect(sortMemberships([a, c, twin, b]).map((m) => m.shopId)).toEqual(['b', '0', 'c', 'a']);
  });
});
