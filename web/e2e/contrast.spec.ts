import { expect, test } from '@playwright/test';
import { OWNER, membershipRow } from './support/fixtures';
import { mockSupabase } from './support/mockSupabase';

/**
 * WCAG 1.4.3 for the text colour tokens as the browser resolves them from the
 * built stylesheet: ink, muted and subtle (subtle carries real content — 12px
 * hints, keys, timestamps) and primary-ink (links) reach 4.5:1 on every
 * surface, in both themes. Labels on filled controls (buttons, count pills,
 * numbered markers) use the fill's *-fg token, and those pairs reach 4.5:1 too,
 * hover fills included (12–16px medium labels are not large text).
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

// primary-ink is the link / text-button colour (the primary fill, --dc-primary,
// is for buttons and icons only: 3.7:1 on the dark surface).
const TEXT = ['ink', 'muted', 'subtle', 'primary-ink'];
const SURFACES = ['canvas', 'surface', 'surface-2', 'surface-3'];
/** [fill, label] pairs used by Button, IconButton, count pills and markers. */
const FILLS: [string, string][] = [
  ['primary', 'primary-fg'],
  ['primary-hover', 'primary-fg'],
  ['danger-solid', 'danger-fg'],
  ['danger-solid-hover', 'danger-fg'],
  ['money', 'money-fg'],
  ['money-hover', 'money-fg'],
];

function rgbToHex(rgb: string): string {
  const m = /^rgba?\((\d+),\s*(\d+),\s*(\d+)/.exec(rgb);
  if (!m) return rgb;
  return `#${m
    .slice(1, 4)
    .map((v) => Number(v).toString(16).padStart(2, '0'))
    .join('')}`;
}

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
      { names: [...TEXT, ...SURFACES, ...FILLS.flat()], dark: theme === 'dark' },
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
    for (const [fill, label] of FILLS) {
      const fg = tokens[label] ?? '';
      const bg = tokens[fill] ?? '';
      expect(fg, `--dc-${label}`).toMatch(/^#[0-9a-f]{6}$/);
      expect(bg, `--dc-${fill}`).toMatch(/^#[0-9a-f]{6}$/);
      expect(contrast(fg, bg), `${label} on ${fill} (${theme})`).toBeGreaterThanOrEqual(4.5);
    }
  });

  test(`a destructive button's label meets WCAG AA contrast in the ${theme} theme, hovered too`, async ({
    page,
  }) => {
    await page.emulateMedia({ colorScheme: theme });
    await mockSupabase(page, {
      user: OWNER,
      tables: { shop_members: [membershipRow(OWNER, 'owner')], notifications: [] },
    });
    await page.goto('/app/settings/delete-shop');
    const button = page.getByRole('button', { name: 'Delete shop…' });
    await expect(button).toBeVisible();
    await expect(page.locator('html')).toHaveAttribute('data-theme', theme);
    const colours = async () =>
      button.evaluate((el) => {
        const style = getComputedStyle(el);
        return { fg: style.color, bg: style.backgroundColor };
      });
    const rest = await colours();
    expect(
      contrast(rgbToHex(rest.fg), rgbToHex(rest.bg)),
      `${rest.fg} on ${rest.bg}`,
    ).toBeGreaterThanOrEqual(4.5);
    const hoverFill = await page.evaluate(() =>
      getComputedStyle(document.documentElement)
        .getPropertyValue('--dc-danger-solid-hover')
        .trim()
        .toLowerCase(),
    );
    await button.hover();
    // Wait for the colour transition to land on the hover fill.
    await expect.poll(async () => rgbToHex((await colours()).bg)).toBe(hoverFill);
    const hover = await colours();
    expect(
      contrast(rgbToHex(hover.fg), rgbToHex(hover.bg)),
      `hover: ${hover.fg} on ${hover.bg}`,
    ).toBeGreaterThanOrEqual(4.5);
  });
}
