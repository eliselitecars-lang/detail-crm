/**
 * QR codes for shareable links (booking page, private booking links,
 * referral links, lead forms). Wraps `qrcode`; everything is generated in the
 * browser — no third-party QR service ever sees the link.
 */
import QRCode from 'qrcode';
import { downloadBlob, downloadUrl } from './download';

export interface QrOptions {
  /** Quiet zone in modules (the spec asks for 4; 2 prints fine at poster sizes). */
  margin?: number;
  /** Error correction: M (15%) survives smudges and small logos. */
  errorCorrectionLevel?: 'L' | 'M' | 'Q' | 'H';
}

const DEFAULTS = { margin: 2, errorCorrectionLevel: 'M' } as const satisfies Required<QrOptions>;

/** Black-on-white SVG markup (scales to any print size). */
export async function qrSvg(text: string, options: QrOptions = {}): Promise<string> {
  return QRCode.toString(text, {
    type: 'svg',
    margin: options.margin ?? DEFAULTS.margin,
    errorCorrectionLevel: options.errorCorrectionLevel ?? DEFAULTS.errorCorrectionLevel,
    color: { dark: '#000000', light: '#ffffff' },
  });
}

/** `data:image/svg+xml` URL of the SVG (for <img src>). */
export function svgDataUrl(svg: string): string {
  return `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`;
}

/** PNG data URL, `size` pixels wide (needs a browser canvas). */
export async function qrPngDataUrl(
  text: string,
  size = 1024,
  options: QrOptions = {},
): Promise<string> {
  return QRCode.toDataURL(text, {
    type: 'image/png',
    width: size,
    margin: options.margin ?? DEFAULTS.margin,
    errorCorrectionLevel: options.errorCorrectionLevel ?? DEFAULTS.errorCorrectionLevel,
    color: { dark: '#000000', light: '#ffffff' },
  });
}

/** Downloads the QR code of `text` as `<stem>.png` (1024 px) or `<stem>.svg`. */
export async function downloadQr(text: string, stem: string, format: 'png' | 'svg'): Promise<void> {
  if (format === 'png') {
    downloadUrl(await qrPngDataUrl(text), `${stem}.png`);
    return;
  }
  downloadBlob(new Blob([await qrSvg(text)], { type: 'image/svg+xml' }), `${stem}.svg`);
}
