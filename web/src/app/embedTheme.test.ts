import { describe, expect, it } from 'vitest';
import { embedThemeFor } from './embedTheme';

describe('embedThemeFor', () => {
  it('pins embedded booking pages and lead forms to light by default', () => {
    expect(embedThemeFor('/book/glacier', '?embed=1')).toBe('light');
    expect(embedThemeFor('/lead/8c1f0f5e-3b1a-4d7c-9a0e-1f2e3d4c5b6a', '?embed=1')).toBe('light');
    expect(embedThemeFor('/book/glacier', '?embed=1&theme=bogus')).toBe('light');
  });

  it('honours the snippet’s data-theme (dark / auto)', () => {
    expect(embedThemeFor('/book/glacier', '?embed=1&theme=dark')).toBe('dark');
    expect(embedThemeFor('/book/glacier', '?embed=1&link=x&theme=auto')).toBe('auto');
  });

  it('leaves every other page to the saved / device theme', () => {
    expect(embedThemeFor('/book/glacier', '')).toBeNull();
    expect(embedThemeFor('/book/glacier', '?theme=dark')).toBeNull();
    expect(embedThemeFor('/app/customers', '?embed=1')).toBeNull();
  });
});
