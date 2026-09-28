import { expect, test } from '@playwright/test';
import { mockSupabase } from './support/mockSupabase';

/**
 * WCAG 1.4.3 for the text colour tokens as the browser resolves them from the
 * built stylesheet: ink, muted and subtle (subtle carries real content — 12px
 * hints, keys, timestamps) reach 4.5:1 on every surface, in both themes.
 */

function luminance(hex: string): number {
  const channel = (i: number) => {
    const c = parseInt(hex.slice(1 + i * 2, 3 + i * 2), 16) / 255;
    return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
  };
  return 0.2126 * channel(0) + 0.7152 * channel(1) + 0.0722 * channel(2);
}

function contrast(a: string, b: string): number {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x) as [number, number];
  return (hi + 0.05) / (lo + 0.05);
}

const TEXT = ['ink', 'muted', 'subtle'];
const SURFACES = ['canvas', 'surface', 'surface-2', 'surface-3'];

for (const theme of ['light', 'dark'] as const) {
  test(`text tokens meet WCAG AA contrast in the ${theme} theme`, async ({ page }) => {
    await mockSupabase(page);
    await page.goto('/privacy');
    await expect(page.getByRole('heading', { level: 1 })).toBeVisible();
    const tokens = await page.evaluate(
      ({ names, dark }) => {
        const root = document.documentElement;
        if (dark) root.setAttribute('data-theme', 'dark');
        else root.removeAttribute('data-theme');
        const style = getComputedStyle(root);
        return Object.fromEntries(
          names.map((n) => [n, style.getPropertyValue(`--dc-${n}`).trim().toLowerCase()]),
        );
      },
      { names: [...TEXT, ...SURFACES], dark: theme === 'dark' },
    );
    for (const text of TEXT) {
      for (const surface of SURFACES) {
        const fg = tokens[text] ?? '';
        const bg = tokens[surface] ?? '';
        expect(fg, `--dc-${text}`).toMatch(/^#[0-9a-f]{6}$/);
        expect(bg, `--dc-${surface}`).toMatch(/^#[0-9a-f]{6}$/);
        expect(contrast(fg, bg), `${text} on ${surface} (${theme})`).toBeGreaterThanOrEqual(4.5);
      }
    }
  });
}
