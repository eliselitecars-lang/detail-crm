/**
 * Shared CSV writer for exports (RFC 4180, Excel-friendly): CRLF line ends,
 * a UTF-8 byte-order mark so Excel reads accents, cells quoted when needed and
 * spreadsheet formulas neutralised (CSV injection: a text cell starting with
 * =, +, -, @, tab or CR is prefixed with an apostrophe). Plain decimal numbers
 * such as centsCell's "-12.50" are never formulas and stay numbers.
 *
 * Phone numbers are stored as E.164 ("+15551234567") and keep the guard: a
 * spreadsheet would otherwise read them as numbers, drop the "+" and, for
 * long international numbers, save them back in scientific notation. The
 * CSV importer removes the guard again (stripFormulaGuard), so an export
 * re-imports as it was written.
 */
import { downloadBlob } from './download';
import { centsToInputValue } from './money';

export type CsvValue = string | number | boolean | null | undefined;

/** A plain decimal number ("-0.05", "12", "123.45"): never a formula. */
const PLAIN_NUMBER = /^-?\d+(\.\d+)?$/;
/** First characters a spreadsheet treats as the start of a formula. */
const FORMULA_START = /^[=+\-@\t\r]/;

/** One cell. Numbers and plain decimal strings are never formula-escaped. */
export function csvCell(value: CsvValue): string {
  if (value === null || value === undefined) return '';
  let text = typeof value === 'boolean' ? (value ? 'true' : 'false') : String(value);
  if (typeof value === 'string' && !PLAIN_NUMBER.test(text) && FORMULA_START.test(text))
    text = `'${text}`;
  return /[",\r\n]/.test(text) ? `"${text.replace(/"/g, '""')}"` : text;
}

/**
 * Undoes csvCell's formula guard on import: one leading apostrophe followed
 * by a formula character is removed ("'+15551234567" → "+15551234567").
 * Any other apostrophe ("'Tis Detailing") is kept.
 */
export function stripFormulaGuard(text: string): string {
  return text.startsWith("'") && FORMULA_START.test(text.slice(1)) ? text.slice(1) : text;
}

/** Integer cents → "12.50" (blank for null). */
export function centsCell(cents: number | null | undefined): string {
  return cents === null || cents === undefined ? '' : centsToInputValue(cents);
}

export interface CsvColumn<T> {
  header: string;
  value: (row: T) => CsvValue;
}

/** Header + one line per row, CRLF-terminated. */
export function toCsv<T>(columns: readonly CsvColumn<T>[], rows: readonly T[]): string {
  const lines = [columns.map((c) => csvCell(c.header)).join(',')];
  for (const row of rows) lines.push(columns.map((c) => csvCell(c.value(row))).join(','));
  return `${lines.join('\r\n')}\r\n`;
}

/** Plain rows (first row = header) → CSV text. */
export function rowsToCsv(rows: readonly (readonly CsvValue[])[]): string {
  return `${rows.map((row) => row.map(csvCell).join(',')).join('\r\n')}\r\n`;
}

/** Triggers a browser download of `text` as a UTF-8 CSV file (with BOM). */
export function downloadCsv(fileName: string, text: string): void {
  downloadBlob(new Blob([`\uFEFF${text}`], { type: 'text/csv;charset=utf-8' }), fileName);
}
