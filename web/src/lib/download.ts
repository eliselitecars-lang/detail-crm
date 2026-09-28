/** Browser downloads of generated files (CSV exports, QR codes). */

/** Starts a download of a data: / blob: URL. */
export function downloadUrl(url: string, fileName: string): void {
  const link = document.createElement('a');
  link.href = url;
  link.download = fileName;
  link.rel = 'noopener';
  document.body.append(link);
  link.click();
  link.remove();
}

/** Starts a download of a Blob (the object URL is revoked afterwards). */
export function downloadBlob(blob: Blob, fileName: string): void {
  const url = URL.createObjectURL(blob);
  try {
    downloadUrl(url, fileName);
  } finally {
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  }
}

/** A safe file name stem from free text ("Glacier Detailing" → "glacier-detailing"). */
export function fileStem(text: string, fallback = 'download'): string {
  const stem = text
    .normalize('NFKD')
    .replace(/[̀-ͯ]/g, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 60)
    .replace(/-+$/, '');
  return stem === '' ? fallback : stem;
}
