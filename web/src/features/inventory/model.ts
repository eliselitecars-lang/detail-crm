/**
 * Inventory (P-28) — pure helpers (unit-tested). Stock is a ledger on the
 * server (0077): record_inventory_movement adds receipts, adjustments and
 * counts; completed jobs consume their services' materials automatically.
 * products.on_hand is never written by the client after creation.
 */
import type { Row } from '@/lib/db';

export type Product = Row<'products'>;
export type Movement = Pick<
  Row<'inventory_movements'>,
  'id' | 'kind' | 'quantity' | 'unit_cost_cents' | 'job_id' | 'note' | 'created_at'
> & { job: { id: string; number: number } | null };
export type MovementKind = Row<'inventory_movements'>['kind'];
export type ManualMovementKind = Exclude<MovementKind, 'consume'>;

export const MOVEMENT_LABELS: Record<MovementKind, string> = {
  receive: 'Received',
  consume: 'Used on a job',
  adjust: 'Adjusted',
  count: 'Counted',
};

/** At or below the reorder level (an active, unarchived product). */
export function isLowStock(p: Pick<Product, 'on_hand' | 'reorder_at' | 'active' | 'archived_at'>) {
  return p.active && p.archived_at === null && p.reorder_at !== null && p.on_hand <= p.reorder_at;
}

/** Quantities: numeric(12,3) → at most 3 decimals, no float noise. */
export function formatQty(value: number): string {
  return new Intl.NumberFormat('en-US', { maximumFractionDigits: 3 }).format(value);
}

/** "12" / "1.5" / "-2" → number with ≤ 3 decimals; null when invalid. */
export function parseQty(text: string, { allowNegative = false } = {}): number | null {
  const t = text.trim().replace(',', '.');
  const re = allowNegative ? /^-?\d{1,9}(\.\d{1,3})?$/ : /^\d{1,9}(\.\d{1,3})?$/;
  if (!re.test(t)) return null;
  return Number(t);
}

export interface ProductDraft {
  name: string;
  sku: string;
  unit: string;
  unitCostCents: number | null;
  reorderAt: string;
  reorderQty: string;
  supplier: string;
  notes: string;
  active: boolean;
  /** New products only: opening stock (recorded as a count). */
  openingStock: string;
}

export function productDraft(p: Product | null): ProductDraft {
  return {
    name: p?.name ?? '',
    sku: p?.sku ?? '',
    unit: p?.unit ?? '',
    unitCostCents: p?.unit_cost_cents ?? 0,
    reorderAt:
      p?.reorder_at === null || p?.reorder_at === undefined ? '' : formatQtyInput(p.reorder_at),
    reorderQty:
      p?.reorder_qty === null || p?.reorder_qty === undefined ? '' : formatQtyInput(p.reorder_qty),
    supplier: p?.supplier ?? '',
    notes: p?.notes ?? '',
    active: p?.active ?? true,
    openingStock: '',
  };
}

function formatQtyInput(value: number): string {
  return String(Math.round(value * 1000) / 1000);
}

export type ProductErrors = Partial<Record<keyof ProductDraft, string>>;

export interface ProductWrite {
  name: string;
  sku: string | null;
  unit: string;
  unit_cost_cents: number;
  reorder_at: number | null;
  reorder_qty: number | null;
  supplier: string | null;
  notes: string | null;
  active: boolean;
  on_hand?: number;
}

/** Validates like the products CHECKs; returns the row to write or the errors. */
export function productWrite(
  draft: ProductDraft,
  isNew: boolean,
): { values: ProductWrite; errors: null } | { values: null; errors: ProductErrors } {
  const errors: ProductErrors = {};
  const name = draft.name.trim();
  if (!name) errors.name = 'Name is required.';
  else if (name.length > 120) errors.name = 'Keep the name to 120 characters.';
  const sku = draft.sku.trim();
  if (sku.length > 60) errors.sku = 'Keep the SKU to 60 characters.';
  const unit = draft.unit.trim();
  if (!unit) errors.unit = 'Say how it’s counted (bottle, oz, pad…).';
  else if (unit.length > 20) errors.unit = 'Keep the unit to 20 characters.';
  if (draft.unitCostCents === null || draft.unitCostCents < 0) {
    errors.unitCostCents = 'Enter the cost per unit (0 if you don’t track it).';
  }
  const reorderAt = draft.reorderAt.trim() === '' ? null : parseQty(draft.reorderAt);
  if (draft.reorderAt.trim() !== '' && reorderAt === null) {
    errors.reorderAt = 'Enter 0 or more (up to 3 decimals).';
  }
  const reorderQty = draft.reorderQty.trim() === '' ? null : parseQty(draft.reorderQty);
  if (draft.reorderQty.trim() !== '' && (reorderQty === null || reorderQty <= 0)) {
    errors.reorderQty = 'Enter a quantity above 0.';
  }
  if (draft.supplier.trim().length > 120) errors.supplier = 'Keep it to 120 characters.';
  if (draft.notes.length > 5000) errors.notes = 'Keep the notes to 5,000 characters.';
  const opening = draft.openingStock.trim() === '' ? 0 : parseQty(draft.openingStock);
  if (isNew && opening === null) errors.openingStock = 'Enter 0 or more (up to 3 decimals).';
  if (Object.keys(errors).length > 0) return { values: null, errors };
  return {
    errors: null,
    values: {
      name,
      sku: sku || null,
      unit,
      unit_cost_cents: draft.unitCostCents ?? 0,
      reorder_at: reorderAt,
      reorder_qty: reorderQty,
      supplier: draft.supplier.trim() || null,
      notes: draft.notes.trim() || null,
      active: draft.active,
      ...(isNew && opening ? { on_hand: opening } : {}),
    },
  };
}

/** The quantity to send for a stock change, or an error message. */
export function movementQuantity(
  kind: ManualMovementKind,
  text: string,
): { quantity: number; error: null } | { quantity: null; error: string } {
  if (kind === 'adjust') {
    const q = parseQty(text, { allowNegative: true });
    if (q === null || q === 0) {
      return { quantity: null, error: 'Enter the change, e.g. -2 or 3 (not 0).' };
    }
    return { quantity: q, error: null };
  }
  const q = parseQty(text);
  if (q === null) return { quantity: null, error: 'Enter a quantity (up to 3 decimals).' };
  if (kind === 'receive' && q <= 0)
    return { quantity: null, error: 'Enter how many you received.' };
  return { quantity: q, error: null };
}

/** Stock value at cost (whole cents). */
export function stockValueCents(products: readonly Pick<Product, 'on_hand' | 'unit_cost_cents'>[]) {
  return products.reduce(
    (sum, p) => sum + Math.round(Math.max(0, p.on_hand) * p.unit_cost_cents),
    0,
  );
}
