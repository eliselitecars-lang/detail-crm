/** CSV export of the payments ledger (RFC 4180, Excel-friendly). */
import { formatInTz } from '@/lib/dates';
import { centsToInputValue } from '@/lib/money';
import { customerName } from '@/features/quotes/shared/format';
import type { LedgerRow } from './api';
import { brandLabel, KIND_LABELS, METHOD_LABELS } from './paymentFormat';

/** Quotes a cell when needed; neutralises spreadsheet formulas (=, +, -, @). */
export function csvCell(value: string | number | null | undefined): string {
  if (value === null || value === undefined) return '';
  let text = String(value);
  if (typeof value === 'string' && /^[=+\-@\t\r]/.test(text)) text = `'${text}`;
  return /[",\r\n]/.test(text) ? `"${text.replace(/"/g, '""')}"` : text;
}

export const CSV_HEADER = [
  'Date',
  'Customer',
  'Invoice',
  'Job',
  'Kind',
  'Method',
  'Card',
  'Status',
  'Amount',
  'Tip',
  'Refunded',
  'Note',
] as const;

export function ledgerToCsv(rows: readonly LedgerRow[], timezone: string): string {
  const lines = [CSV_HEADER.join(',')];
  for (const row of rows) {
    const card = row.card_last4 !== null ? `${brandLabel(row.card_brand)} ${row.card_last4}` : '';
    lines.push(
      [
        csvCell(formatInTz(row.paid_at ?? row.created_at, timezone, 'yyyy-MM-dd HH:mm')),
        csvCell(customerName(row.customer)),
        csvCell(row.invoice ? row.invoice.number : ''),
        csvCell(row.job ? row.job.number : ''),
        csvCell(KIND_LABELS[row.kind]),
        csvCell(METHOD_LABELS[row.method]),
        csvCell(card),
        csvCell(row.status),
        csvCell(centsToInputValue(row.amount_cents)),
        csvCell(centsToInputValue(row.tip_cents)),
        csvCell(centsToInputValue(row.refunded_cents)),
        csvCell(row.note),
      ].join(','),
    );
  }
  return `${lines.join('\r\n')}\r\n`;
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
