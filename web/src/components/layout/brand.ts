/**
 * Shop brand colour helpers for public pages. Brand colours come from
 * shops.brand_color (validated "#RRGGBB" server-side).
 */
const HEX_RE = /^#[0-9a-f]{6}$/i;

export function isHexColor(value: string | null | undefined): value is string {
  return typeof value === 'string' && HEX_RE.test(value);
}

function channel(hex: string, offset: number): number {
  const v = parseInt(hex.slice(offset, offset + 2), 16) / 255;
  return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
}

export function relativeLuminance(hex: string): number {
  return 0.2126 * channel(hex, 1) + 0.7152 * channel(hex, 3) + 0.0722 * channel(hex, 5);
}

/** Readable text colour (white or ink) on top of `hex` (WCAG contrast). */
export function readableTextOn(hex: string): '#FFFFFF' | '#0B1220' {
  const l = relativeLuminance(hex);
  const contrastWhite = 1.05 / (l + 0.05);
  const contrastInk = (l + 0.05) / (relativeLuminance('#0B1220') + 0.05);
  return contrastWhite >= contrastInk ? '#FFFFFF' : '#0B1220';
}

/** Inline CSS variables that re-point `--dc-brand` for a subtree. */
export function brandStyle(color: string | null | undefined): Record<string, string> | undefined {
  if (!isHexColor(color)) return undefined;
  return { '--dc-brand': color, '--dc-brand-fg': readableTextOn(color) };
}
