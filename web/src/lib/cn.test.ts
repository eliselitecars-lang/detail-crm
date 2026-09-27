import { describe, expect, it } from 'vitest';
import { cn } from './cn';

describe('cn', () => {
  it('joins conditional classes like clsx', () => {
    expect(cn('a', false, null, undefined, { b: true, c: false }, ['d'])).toBe('a b d');
  });

  it('lets later Tailwind classes override earlier ones', () => {
    expect(cn('px-2 py-1', 'px-4')).toBe('py-1 px-4');
    expect(cn('bg-surface text-ink', 'bg-primary')).toBe('text-ink bg-primary');
    expect(cn('text-sm text-ink', 'text-danger-ink')).toBe('text-sm text-danger-ink');
    expect(cn('shadow-card', 'shadow-pop')).toBe('shadow-pop');
  });

  it('knows the design-token radii', () => {
    expect(cn('rounded-card', 'rounded-control')).toBe('rounded-control');
    expect(cn('rounded-control', 'rounded-full')).toBe('rounded-full');
  });
});
