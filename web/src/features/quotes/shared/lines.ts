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
  /** Whether the document discount applies to this line (server-stamped). */
  discount_eligible: boolean;
  /** The preset fee this line came from (shop_fees), if any. */
  fee_id: string | null;
  /** Quotes only: the proposal option the line belongs to (null = shared by every option). */
  option_id: string | null;
  /** Invoices only: the job this line bills (grouped invoices). */
  job_id: string | null;
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
  /** The customer's vehicle this line is for (null = none / the document's vehicle). */
  vehicle_id?: string | null;
  /** Quotes with options: the option the line belongs to (null = every option). */
  option_id?: string | null;
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
    | 'vehicle_id'
    | 'option_id'
  >
>;

/** Next sort values after the existing lines. */
export function nextSorts(lines: readonly Pick<DocLine, 'sort'>[], count: number): number[] {
  const max = lines.reduce((acc, line) => Math.max(acc, line.sort), 0);
  return Array.from({ length: count }, (_, i) => max + i + 1);
}

/**
 * Quote lines the quote counts: shared lines plus the effective option's
 * (optional ones only when chosen). `optionId` null = the quote has no
 * options (every line is shared).
 */
export function countedLines(lines: readonly DocLine[], optionId: string | null): DocLine[] {
  return lines.filter(
    (line) =>
      (!line.optional || line.selected) &&
      (line.option_id === null || optionId === null || line.option_id === optionId),
  );
}

/** A labelled run of lines (a proposal option, or one job of a grouped invoice). */
export interface LineGroup {
  key: string;
  title: string;
  lines: DocLine[];
}

/** The group key of lines `groupLines` finds no key for. */
export const UNGROUPED = '__none__';

/**
 * Groups lines under a label, keeping the lines' order inside each group and
 * the groups in the order of `order` (keys missing from `order` follow, in
 * the order they first appear). `keyOf` returns null for ungrouped lines,
 * which form the group UNGROUPED.
 */
export function groupLines(
  lines: readonly DocLine[],
  keyOf: (line: DocLine) => string | null,
  titleOf: (key: string) => string,
  order: readonly string[] = [],
): LineGroup[] {
  const buckets = new Map<string, DocLine[]>();
  for (const line of lines) {
    const key = keyOf(line) ?? UNGROUPED;
    const bucket = buckets.get(key);
    if (bucket) bucket.push(line);
    else buckets.set(key, [line]);
  }
  const keys = [
    ...order.filter((key) => buckets.has(key)),
    ...[...buckets.keys()].filter((key) => !order.includes(key)),
  ];
  return keys.map((key) => ({ key, title: titleOf(key), lines: buckets.get(key) ?? [] }));
}
