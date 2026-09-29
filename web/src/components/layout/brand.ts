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

/** WCAG contrast ratio between two "#RRGGBB" colours. */
export function contrastRatio(a: string, b: string): number {
  const [hi, lo] = [relativeLuminance(a), relativeLuminance(b)].sort((x, y) => y - x) as [
    number,
    number,
  ];
  return (hi + 0.05) / (lo + 0.05);
}

/**
 * Readable text colour on top of `hex`: white or ink, whichever contrasts
 * more. For mid-tones where even the better of the two stays under 4.5:1
 * (luminance about 0.18-0.20, at best 4.3:1), pure black, which reaches
 * at least 4.6:1 there.
 */
export function readableTextOn(hex: string): '#FFFFFF' | '#0B1220' | '#000000' {
  const contrastWhite = contrastRatio(hex, '#FFFFFF');
  const contrastInk = contrastRatio(hex, '#0B1220');
  const best = contrastWhite >= contrastInk ? '#FFFFFF' : '#0B1220';
  return Math.max(contrastWhite, contrastInk) >= 4.5 ? best : '#000000';
}

/** Inline CSS variables that re-point `--dc-brand` for a subtree. */
export function brandStyle(color: string | null | undefined): Record<string, string> | undefined {
  if (!isHexColor(color)) return undefined;
  return { '--dc-brand': color, '--dc-brand-fg': readableTextOn(color) };
}
