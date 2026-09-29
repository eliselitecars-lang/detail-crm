import { render, screen } from '@testing-library/react';
import { describe, expect, it } from 'vitest';
import { contrastRatio, readableTextOn } from '@/components/layout/brand';
import { AVATAR_PALETTE, Avatar } from './Avatar';

/** jsdom reports inline colours as rgb(); back to "#RRGGBB" for the ratio. */
function hex(rgb: string): string {
  const m = /^rgb\((\d+),\s*(\d+),\s*(\d+)\)$/.exec(rgb);
  if (!m) throw new Error(`not an rgb() colour: ${rgb}`);
  return `#${m
    .slice(1, 4)
    .map((v) => Number(v).toString(16).padStart(2, '0'))
    .join('')}`;
}

function initialsContrast(name: string): number {
  const el = screen.getByRole('img', { name });
  return contrastRatio(hex(el.style.color), hex(el.style.backgroundColor));
}

describe('Avatar initials contrast (WCAG 1.4.3, 10-14px initials)', () => {
  it('white initials reach 4.5:1 on every fallback palette colour', () => {
    for (const colour of AVATAR_PALETTE) {
      expect(contrastRatio('#FFFFFF', colour), colour).toBeGreaterThanOrEqual(4.5);
    }
  });

  it('the header avatar of "Olivia Owner" (no calendar colour) is readable', () => {
    render(<Avatar name="Olivia Owner" />);
    expect(initialsContrast('Olivia Owner')).toBeGreaterThanOrEqual(4.5);
  });

  it.each(['#FACC15', '#FDE68A', '#A7F3D0', '#FFFFFF', '#22C55E', '#DD2590', '#0E9384', '#000000'])(
    'picks readable initials on a member-picked colour %s',
    (colour) => {
      render(<Avatar name="Pat Painter" color={colour} />);
      const el = screen.getByRole('img', { name: 'Pat Painter' });
      expect(hex(el.style.backgroundColor)).toBe(colour.toLowerCase());
      expect(initialsContrast('Pat Painter')).toBeGreaterThanOrEqual(4.5);
    },
  );

  it('uses dark initials on yellow instead of white', () => {
    render(<Avatar name="Yellow Member" color="#FACC15" />);
    expect(screen.getByRole('img', { name: 'Yellow Member' }).style.color).not.toBe(
      'rgb(255, 255, 255)',
    );
  });

  it('falls back to the palette for a value that is not "#RRGGBB"', () => {
    render(<Avatar name="Odd Colour" color="not-a-colour" />);
    const el = screen.getByRole('img', { name: 'Odd Colour' });
    expect(AVATAR_PALETTE.map((c) => c.toLowerCase())).toContain(hex(el.style.backgroundColor));
  });
});

describe('readableTextOn', () => {
  it('reaches 4.5:1 on every grey level and on a sweep of hues', () => {
    const colours: string[] = [];
    for (let v = 0; v <= 255; v += 1) {
      const h = v.toString(16).padStart(2, '0');
      colours.push(`#${h}${h}${h}`, `#${h}0000`, `#00${h}00`, `#0000${h}`, `#${h}${h}00`);
    }
    for (const colour of colours) {
      expect(contrastRatio(readableTextOn(colour), colour), colour).toBeGreaterThanOrEqual(4.5);
    }
  });

  it('keeps white and ink where they are readable', () => {
    expect(readableTextOn('#1F6FEB')).toBe('#FFFFFF');
    expect(readableTextOn('#FACC15')).toBe('#0B1220');
  });
});
