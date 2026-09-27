/** Line-item shapes shared by the quote and invoice editors. */

/** A saved line (quote_line_items / invoice_line_items), normalised. */
export interface DocLine {
  id: string;
  service_id: string | null;
  vehicle_id: string | null;
  name: string;
  description: string | null;
  quantity: number;
  unit_price_cents: number;
  discount_cents: number;
  taxable: boolean;
  /** Server-generated line total (generated column). */
  total_cents: number | null;
  sort: number;
  /** Quotes only: client-selectable upsell. */
  optional: boolean;
  /** Quotes only: counted toward totals (always true when not optional). */
  selected: boolean;
  duration_minutes: number;
}

/** A line about to be inserted (from the catalog or typed by hand). */
export interface LineDraft {
  service_id: string | null;
  name: string;
  description: string | null;
  quantity: number;
  unit_price_cents: number;
  discount_cents: number;
  taxable: boolean;
  optional: boolean;
  duration_minutes: number;
}

export type LinePatch = Partial<
  Pick<
    LineDraft,
    | 'name'
    | 'description'
    | 'quantity'
    | 'unit_price_cents'
    | 'discount_cents'
    | 'taxable'
    | 'optional'
  >
>;

/** Next sort values after the existing lines. */
export function nextSorts(lines: readonly Pick<DocLine, 'sort'>[], count: number): number[] {
  const max = lines.reduce((acc, line) => Math.max(acc, line.sort), 0);
  return Array.from({ length: count }, (_, i) => max + i + 1);
}
