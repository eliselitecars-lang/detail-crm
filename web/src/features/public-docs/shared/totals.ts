import type { ReactNode } from 'react';
import { formatBps } from '@/lib/money';

export interface TotalRow {
  label: ReactNode;
  cents: number;
  /** Bold (total / balance). */
  emphasis?: boolean;
  /** Render as a negative ("−$10.00"). */
  negative?: boolean;
  /** Amber money tone (balance due). */
  money?: boolean;
  key: string;
}

/** Standard subtotal / discount / tax / total rows from a document's totals. */
export function standardTotals(totals: {
  subtotal_cents: number;
  discount_cents: number;
  tax_rate_bps?: number | null;
  tax_cents: number;
  total_cents: number;
  coupon_code?: string | null;
}): TotalRow[] {
  const rows: TotalRow[] = [{ key: 'subtotal', label: 'Subtotal', cents: totals.subtotal_cents }];
  if (totals.discount_cents > 0) {
    rows.push({
      key: 'discount',
      label: totals.coupon_code ? `Discount (${totals.coupon_code})` : 'Discount',
      cents: totals.discount_cents,
      negative: true,
    });
  }
  if (totals.tax_cents > 0 || (totals.tax_rate_bps ?? 0) > 0) {
    rows.push({
      key: 'tax',
      label: totals.tax_rate_bps ? `Tax (${formatBps(totals.tax_rate_bps)})` : 'Tax',
      cents: totals.tax_cents,
    });
  }
  rows.push({ key: 'total', label: 'Total', cents: totals.total_cents, emphasis: true });
  return rows;
}
