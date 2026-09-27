/** CSV export for report tables (RFC 4180, Excel-friendly, formula-safe). */

export type CsvValue = string | number | null | undefined;

/** Quotes a cell when needed; neutralises spreadsheet formulas (=, +, -, @). */
export function csvCell(value: CsvValue): string {
  if (value === null || value === undefined) return '';
  let text = String(value);
  if (typeof value === 'string' && /^[=+\-@\t\r]/.test(text)) text = `'${text}`;
  return /[",\r\n]/.test(text) ? `"${text.replace(/"/g, '""')}"` : text;
}

export function toCsv(header: readonly string[], rows: readonly (readonly CsvValue[])[]): string {
  const lines = [header.map(csvCell).join(',')];
  for (const row of rows) lines.push(row.map(csvCell).join(','));
  return `${lines.join('\r\n')}\r\n`;
}

/** Cents → plain decimal for spreadsheets (12345 → "123.45", -5 → "-0.05"). */
export function centsCell(cents: number | null | undefined): string {
  if (cents === null || cents === undefined || !Number.isFinite(cents)) return '';
  const whole = Math.round(cents);
  const abs = Math.abs(whole);
  return `${whole < 0 ? '-' : ''}${Math.trunc(abs / 100)}.${String(abs % 100).padStart(2, '0')}`;
}

/** Triggers a browser download of `text` as a UTF-8 CSV file. */
export function downloadCsv(filename: string, text: string): void {
  const blob = new Blob([`\uFEFF${text}`], { type: 'text/csv;charset=utf-8' });
  const url = URL.createObjectURL(blob);
  const link = document.createElement('a');
  link.href = url;
  link.download = filename;
  document.body.appendChild(link);
  link.click();
  link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
