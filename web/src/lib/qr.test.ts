import { describe, expect, it } from 'vitest';
import { qrSvg, svgDataUrl } from './qr';

describe('qr', () => {
  it('renders an SVG QR code in the browser', async () => {
    const svg = await qrSvg('https://example.com/book/glacier');
    expect(svg.startsWith('<svg')).toBe(true);
    expect(svg).toContain('viewBox');
    expect(svgDataUrl('<svg/>')).toBe('data:image/svg+xml;charset=utf-8,%3Csvg%2F%3E');
  });
});
