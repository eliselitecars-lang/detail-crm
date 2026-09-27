/**
 * Catalog domain helpers (SPEC §4.3 / §4.6): labels, form schemas that mirror
 * the CHECK constraints in 0005_foundation_catalog.sql and
 * 0021_field_ops_checklists.sql, the price-grid diff, and small pure helpers
 * the screens share. No I/O here — see api.ts.
 */
import { z } from 'zod';
import { Constants } from '@/lib/database.types';
import type { Row } from '@/lib/db';
import { zOptionalText, zRequiredText } from '@/lib/validation';

export type ServiceRow = Row<'services'>;
export type ServiceKind = ServiceRow['kind'];
export type CategoryRow = Row<'service_categories'>;
export type PriceRow = Row<'service_prices'>;
export type VehicleCategoryRow = Pick<Row<'vehicle_categories'>, 'id' | 'name' | 'sort'>;
export type ChecklistTemplateRow = Row<'checklist_templates'>;

export const SERVICE_KINDS: readonly ServiceKind[] = Constants.public.Enums.service_kind;

export const KIND_LABELS: Record<ServiceKind, string> = {
  service: 'Service',
  package: 'Package',
  addon: 'Add-on',
  product: 'Product',
};

export const KIND_PLURALS: Record<ServiceKind, string> = {
  service: 'Services',
  package: 'Packages',
  addon: 'Add-ons',
  product: 'Products',
};

export function isServiceKind(value: unknown): value is ServiceKind {
  return typeof value === 'string' && (SERVICE_KINDS as readonly string[]).includes(value);
}

/** "90" → "1 h 30 min"; 0 → "No time"; 45 → "45 min". */
export function formatDuration(minutes: number | null | undefined): string {
  if (minutes === null || minutes === undefined || !Number.isFinite(minutes)) return '—';
  if (minutes <= 0) return 'No time';
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  if (h === 0) return `${m} min`;
  return m === 0 ? `${h} h` : `${h} h ${m} min`;
}

/** Sorts catalog rows the way every list shows them: sort, then name. */
export function bySortThenName<T extends { sort: number; name: string }>(a: T, b: T): number {
  return a.sort - b.sort || a.name.localeCompare(b.name, undefined, { sensitivity: 'base' });
}

// ------------------------------------------------------------------ forms

const MAX_MINUTES = 1440;

/** Whole minutes 0–1440 typed as text. */
export const zMinutes = z
  .string()
  .trim()
  .refine((v) => /^\d{1,4}$/.test(v) && Number(v) <= MAX_MINUTES, 'Enter minutes from 0 to 1440.')
  .transform((v) => Number(v));

/** Optional minutes (empty → null). */
export const zOptionalMinutes = z
  .string()
  .trim()
  .refine(
    (v) => v === '' || (/^\d{1,4}$/.test(v) && Number(v) <= MAX_MINUTES),
    'Enter minutes from 0 to 1440.',
  )
  .transform((v) => (v === '' ? null : Number(v)));

export const zSort = z
  .string()
  .trim()
  .refine((v) => /^-?\d{1,6}$/.test(v), 'Enter a whole number.')
  .transform((v) => Number(v));

export const serviceFormSchema = z.object({
  name: zRequiredText('Name', 120),
  description: zOptionalText(10000),
  kind: z.enum(['service', 'package', 'addon', 'product']),
  categoryId: z.string().transform((v) => (v === '' ? null : v)),
  durationMinutes: zMinutes,
  taxable: z.boolean(),
  onlineBookable: z.boolean(),
  active: z.boolean(),
  sort: zSort,
});

export type ServiceFormInput = z.input<typeof serviceFormSchema>;
export type ServiceFormOutput = z.output<typeof serviceFormSchema>;

export function serviceFormDefaults(service?: ServiceRow | null): ServiceFormInput {
  return {
    name: service?.name ?? '',
    description: service?.description ?? '',
    kind: service?.kind ?? 'service',
    categoryId: service?.category_id ?? '',
    durationMinutes: String(service?.duration_minutes ?? 60),
    taxable: service?.taxable ?? true,
    onlineBookable: service?.online_bookable ?? false,
    active: service?.active ?? true,
    sort: String(service?.sort ?? 0),
  };
}

/** Form output → the columns of `services` it edits (never shop_id / archived_at). */
export function serviceColumns(values: ServiceFormOutput) {
  return {
    name: values.name,
    description: values.description,
    kind: values.kind,
    category_id: values.categoryId,
    duration_minutes: values.durationMinutes,
    taxable: values.taxable,
    online_bookable: values.onlineBookable,
    active: values.active,
    sort: values.sort,
  };
}

export const categoryFormSchema = z.object({ name: zRequiredText('Name', 80) });
export type CategoryFormInput = z.input<typeof categoryFormSchema>;

// ------------------------------------------------------------- price grid

/** One editable row of the price grid (vehicleCategoryId null = base price). */
export interface PriceDraft {
  vehicleCategoryId: string | null;
  /** Existing service_prices.id, when the row is saved. */
  id: string | null;
  priceCents: number | null;
  /** Text of the duration override input ("" = use the service duration). */
  duration: string;
}

export function buildPriceDrafts(
  prices: readonly PriceRow[],
  categories: readonly VehicleCategoryRow[],
): PriceDraft[] {
  const byCategory = new Map(prices.map((p) => [p.vehicle_category_id ?? '', p]));
  const draft = (vehicleCategoryId: string | null): PriceDraft => {
    const row = byCategory.get(vehicleCategoryId ?? '');
    return {
      vehicleCategoryId,
      id: row?.id ?? null,
      priceCents: row?.price_cents ?? null,
      duration: row?.duration_minutes === null || !row ? '' : String(row.duration_minutes),
    };
  };
  return [draft(null), ...[...categories].sort(bySortThenName).map((c) => draft(c.id))];
}

export interface PricePlan {
  inserts: {
    vehicle_category_id: string | null;
    price_cents: number;
    duration_minutes: number | null;
  }[];
  updates: { id: string; price_cents: number; duration_minutes: number | null }[];
  deletes: string[];
  /** Per-row validation errors keyed by vehicleCategoryId ('' = base). */
  errors: Record<string, string>;
}

/**
 * Turns the edited grid into the minimal writes against service_prices:
 * a cleared price deletes the row, a new price inserts one, a changed one
 * updates it. Duration overrides need a price (price_cents is NOT NULL).
 */
export function planPriceChanges(
  drafts: readonly PriceDraft[],
  saved: readonly PriceRow[],
): PricePlan {
  const plan: PricePlan = { inserts: [], updates: [], deletes: [], errors: {} };
  const savedById = new Map(saved.map((p) => [p.id, p]));
  for (const d of drafts) {
    const key = d.vehicleCategoryId ?? '';
    const durationText = d.duration.trim();
    let duration: number | null = null;
    if (durationText !== '') {
      if (!/^\d{1,4}$/.test(durationText) || Number(durationText) > MAX_MINUTES) {
        plan.errors[key] = 'Duration must be 0–1440 minutes.';
        continue;
      }
      duration = Number(durationText);
    }
    if (d.priceCents === null) {
      if (duration !== null) {
        plan.errors[key] = 'Enter a price to set a duration.';
        continue;
      }
      if (d.id) plan.deletes.push(d.id);
      continue;
    }
    if (d.priceCents < 0 || !Number.isSafeInteger(d.priceCents)) {
      plan.errors[key] = 'Enter a valid price.';
      continue;
    }
    if (d.id) {
      const before = savedById.get(d.id);
      if (
        !before ||
        before.price_cents !== d.priceCents ||
        (before.duration_minutes ?? null) !== duration
      ) {
        plan.updates.push({ id: d.id, price_cents: d.priceCents, duration_minutes: duration });
      }
    } else {
      plan.inserts.push({
        vehicle_category_id: d.vehicleCategoryId,
        price_cents: d.priceCents,
        duration_minutes: duration,
      });
    }
  }
  return plan;
}

export function planHasChanges(plan: PricePlan): boolean {
  return plan.inserts.length + plan.updates.length + plan.deletes.length > 0;
}

/** Base price row (vehicle_category_id null) of a service, if any. */
export function basePrice(
  prices: readonly Pick<PriceRow, 'vehicle_category_id' | 'price_cents'>[],
) {
  return prices.find((p) => p.vehicle_category_id === null)?.price_cents ?? null;
}

// ------------------------------------------------------------- checklists

export const checklistItemSchema = z.object({
  id: z.string().regex(/^[A-Za-z0-9_-]{1,64}$/),
  label: z.string(),
});
export const checklistItemsSchema = z.array(checklistItemSchema);
export type ChecklistItem = z.infer<typeof checklistItemSchema>;

/** Items stored on a template (validated at the boundary; bad data → []). */
export function parseChecklistItems(items: unknown): ChecklistItem[] {
  const parsed = checklistItemsSchema.safeParse(items);
  return parsed.success ? parsed.data : [];
}

/** An item in the editor: `id` null = new (the server generates one). */
export interface ChecklistDraftItem {
  key: string;
  id: string | null;
  label: string;
}

export const MAX_CHECKLIST_ITEMS = 200;

/** JSON sent to checklist_templates.items: trimmed labels, new items without id. */
export type ChecklistItemPayload = { id: string; label: string } | { label: string };

export function checklistPayload(items: readonly ChecklistDraftItem[]): ChecklistItemPayload[] {
  return items
    .map((item) => ({ ...item, label: item.label.trim() }))
    .filter((item) => item.label !== '')
    .map((item) => (item.id ? { id: item.id, label: item.label } : { label: item.label }));
}

/** Returns an error message for the editor, or null when the list can be saved. */
export function checklistItemsError(items: readonly ChecklistDraftItem[]): string | null {
  const labels = items.map((i) => i.label.trim()).filter((l) => l !== '');
  if (labels.length > MAX_CHECKLIST_ITEMS) return `Use at most ${MAX_CHECKLIST_ITEMS} items.`;
  if (labels.some((l) => l.length > 200)) return 'Each item must be 200 characters or fewer.';
  return null;
}

/** Returns a copy of `list` with the item at `from` moved to `to` (clamped). */
export function moveItem<T>(list: readonly T[], from: number, to: number): T[] {
  const next = [...list];
  if (from < 0 || from >= next.length) return next;
  const target = Math.max(0, Math.min(next.length - 1, to));
  const [item] = next.splice(from, 1);
  if (item !== undefined) next.splice(target, 0, item);
  return next;
}

/**
 * New `sort` values after reordering: rows whose position changed get their
 * index (×10 leaves room for manual numbers). Returns only the changed rows.
 */
export function resequence<T extends { id: string; sort: number }>(
  ordered: readonly T[],
): { id: string; sort: number }[] {
  return ordered
    .map((row, index) => ({ id: row.id, sort: (index + 1) * 10, before: row.sort }))
    .filter((r) => r.sort !== r.before)
    .map(({ id, sort }) => ({ id, sort }));
}

// ------------------------------------------------------------- images

export const IMAGE_TYPES: Record<string, string> = {
  'image/png': 'png',
  'image/jpeg': 'jpg',
  'image/webp': 'webp',
};
/** shop-assets bucket limit (5 MiB). */
export const MAX_IMAGE_BYTES = 5 * 1024 * 1024;

export function imageFileError(file: { type: string; size: number }): string | null {
  if (!IMAGE_TYPES[file.type]) return 'Use a PNG, JPEG or WebP image.';
  if (file.size > MAX_IMAGE_BYTES) return 'Images must be 5 MB or smaller.';
  return null;
}

/** Storage path for a service image: <shop_id>/services/<service_id>.<ext>. */
export function serviceImagePath(shopId: string, serviceId: string, mimeType: string): string {
  const ext = IMAGE_TYPES[mimeType] ?? 'png';
  return `${shopId}/services/${serviceId}.${ext}`;
}

/** Service usage (documents/packages/plans referencing it). */
export interface ServiceUsage {
  jobLines: number;
  quoteLines: number;
  invoiceLines: number;
  packages: number;
  plans: number;
}

export function usageTotal(u: ServiceUsage): number {
  return u.jobLines + u.quoteLines + u.invoiceLines + u.packages + u.plans;
}

export function describeUsage(u: ServiceUsage): string {
  const parts: string[] = [];
  const add = (n: number, one: string, many: string) => {
    if (n > 0) parts.push(`${n} ${n === 1 ? one : many}`);
  };
  add(u.jobLines, 'job line', 'job lines');
  add(u.quoteLines, 'quote line', 'quote lines');
  add(u.invoiceLines, 'invoice line', 'invoice lines');
  add(u.packages, 'package', 'packages');
  add(u.plans, 'membership plan', 'membership plans');
  return parts.join(', ');
}
