/**
 * Catalog domain helpers (SPEC §4.3 / §4.6): labels, form schemas that mirror
 * the CHECK constraints in 0005_foundation_catalog.sql and
 * 0021_field_ops_checklists.sql, the price-grid diff, and small pure helpers
 * the screens share. No I/O here — see api.ts.
 */
import { z } from 'zod';
import { Constants } from '@/lib/database.types';
import type { Row } from '@/lib/db';
import { bpsToPercentInput, formatBps, formatCents, parsePercentToBps } from '@/lib/money';
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

export type CommissionKind = ServiceRow['commission_kind'];

export const COMMISSION_KIND_LABELS: Record<CommissionKind, string> = {
  none: 'No service commission',
  percent: 'Percent of the line',
  flat: 'Flat amount per unit sold',
};

/** services.min_before_photos / min_after_photos CHECK (0..20). */
export const MAX_PHOTO_MINIMUM = 20;

/** 0–20 photos typed as text. */
export const zPhotoMinimum = z
  .string()
  .trim()
  .refine(
    (v) => /^\d{1,2}$/.test(v) && Number(v) <= MAX_PHOTO_MINIMUM,
    `Enter a number from 0 to ${MAX_PHOTO_MINIMUM}.`,
  )
  .transform((v) => Number(v));

export const serviceFormSchema = z
  .object({
    name: zRequiredText('Name', 120),
    description: zOptionalText(10000),
    kind: z.enum(['service', 'package', 'addon', 'product']),
    categoryId: z.string().transform((v) => (v === '' ? null : v)),
    durationMinutes: zMinutes,
    taxable: z.boolean(),
    onlineBookable: z.boolean(),
    active: z.boolean(),
    sort: zSort,
    minBeforePhotos: zPhotoMinimum,
    minAfterPhotos: zPhotoMinimum,
    commissionKind: z.enum(['none', 'percent', 'flat']),
    /** Percent text ("10", "12.5") when commissionKind is percent. */
    commissionPercent: z.string(),
    /** Cents per unit when commissionKind is flat. */
    commissionCents: z.number().int().min(0).nullable(),
  })
  .superRefine((v, ctx) => {
    if (v.commissionKind === 'percent' && parsePercentToBps(v.commissionPercent) === null) {
      ctx.addIssue({
        code: 'custom',
        path: ['commissionPercent'],
        message: 'Enter a percentage between 0 and 100.',
      });
    }
    if (v.commissionKind === 'flat' && v.commissionCents === null) {
      ctx.addIssue({
        code: 'custom',
        path: ['commissionCents'],
        message: 'Enter the amount paid per unit sold.',
      });
    }
  });

export type ServiceFormInput = z.input<typeof serviceFormSchema>;
export type ServiceFormOutput = z.output<typeof serviceFormSchema>;

export function serviceFormDefaults(service?: ServiceRow | null): ServiceFormInput {
  const kind = service?.commission_kind ?? 'none';
  const value = service?.commission_value ?? 0;
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
    minBeforePhotos: String(service?.min_before_photos ?? 0),
    minAfterPhotos: String(service?.min_after_photos ?? 0),
    commissionKind: kind,
    commissionPercent: kind === 'percent' ? bpsToPercentInput(value) : '',
    commissionCents: kind === 'flat' ? value : null,
  };
}

/** The commission columns a form sets (services_money_commission_guard: owners / admins only). */
export function commissionColumns(values: ServiceFormOutput): {
  commission_kind: CommissionKind;
  commission_value: number;
} {
  switch (values.commissionKind) {
    case 'percent':
      return {
        commission_kind: 'percent',
        commission_value: parsePercentToBps(values.commissionPercent) ?? 0,
      };
    case 'flat':
      return { commission_kind: 'flat', commission_value: values.commissionCents ?? 0 };
    default:
      return { commission_kind: 'none', commission_value: 0 };
  }
}

/**
 * Form output → the columns of `services` it edits (never shop_id /
 * archived_at). Commission columns only when the editor may set them
 * (owners / admins), so a manager's save never touches pay settings.
 */
export function serviceColumns(
  values: ServiceFormOutput,
  { commission = false }: { commission?: boolean } = {},
) {
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
    min_before_photos: values.minBeforePhotos,
    min_after_photos: values.minAfterPhotos,
    ...(commission ? commissionColumns(values) : {}),
  };
}

/** "10% of the line" / "$5.00 per unit" / null (none). */
export function describeCommission(
  service: Pick<ServiceRow, 'commission_kind' | 'commission_value'>,
  currency: string,
): string | null {
  if (service.commission_kind === 'percent')
    return `${formatBps(service.commission_value)} of the line`;
  if (service.commission_kind === 'flat')
    return `${formatCents(service.commission_value, { currency })} per unit sold`;
  return null;
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

/** Of `serviceIds`, those whose links name no add-on other than `addonId`. */
export function soleAddonServices(
  addonId: string,
  serviceIds: readonly string[],
  links: readonly { service_id: string; addon_id: string }[],
): string[] {
  const hasOther = new Set(links.filter((l) => l.addon_id !== addonId).map((l) => l.service_id));
  return serviceIds.filter((id) => !hasOther.has(id));
}

// ------------------------------------------------------------ follow-ups

/** service_followups.offset_days CHECK. */
export const FOLLOWUP_MAX_DAYS = 1095;
/** A 5th follow-up per service and channel is refused (23514). */
export const MAX_FOLLOWUPS_PER_CHANNEL = 4;
/** "Months" are counted as 30 days (offsets are stored in days). */
export const MONTH_DAYS = 30;

export type OffsetUnit = 'days' | 'weeks' | 'months';

export const OFFSET_UNIT_LABELS: Record<OffsetUnit, string> = {
  days: 'days',
  weeks: 'weeks',
  months: 'months (30 days)',
};

export function daysToOffsetParts(days: number): { amount: string; unit: OffsetUnit } {
  if (days > 0 && days % MONTH_DAYS === 0)
    return { amount: String(days / MONTH_DAYS), unit: 'months' };
  if (days > 0 && days % 7 === 0) return { amount: String(days / 7), unit: 'weeks' };
  return { amount: String(days), unit: 'days' };
}

/** Whole days for an amount + unit, or an error message. */
export function offsetPartsToDays(
  amount: string,
  unit: OffsetUnit,
): { days: number; error: null } | { days: null; error: string } {
  const text = amount.trim();
  if (!/^\d{1,4}$/.test(text) || Number(text) < 1) {
    return { days: null, error: 'Enter a whole number, 1 or more.' };
  }
  const n = Number(text);
  const days = unit === 'months' ? n * MONTH_DAYS : unit === 'weeks' ? n * 7 : n;
  if (days > FOLLOWUP_MAX_DAYS) {
    return { days: null, error: 'Follow-ups can be at most 3 years (1095 days) after the visit.' };
  }
  return { days, error: null };
}

/** "2 weeks after the visit" / "6 months after the visit" / "10 days after the visit". */
export function describeFollowupOffset(days: number): string {
  const { amount, unit } = daysToOffsetParts(days);
  const n = Number(amount);
  const word =
    unit === 'months'
      ? n === 1
        ? 'month'
        : 'months'
      : unit === 'weeks'
        ? n === 1
          ? 'week'
          : 'weeks'
        : n === 1
          ? 'day'
          : 'days';
  return `${n} ${word} after the visit`;
}

// ---------------------------------------------------------- consumables

/** A quantity per unit sold: > 0, at most 3 decimals (numeric(12,3)). */
export function parseQuantity(text: string): number | null {
  const t = text.trim().replace(',', '.');
  if (!/^\d{1,9}(\.\d{1,3})?$/.test(t)) return null;
  const n = Number(t);
  return n > 0 ? n : null;
}

/** 1.5 → "1.5", 2 → "2" (no float noise). */
export function formatQuantity(value: number): string {
  return new Intl.NumberFormat('en-US', { maximumFractionDigits: 3 }).format(value);
}

// ------------------------------------------------ category bookable days

export const WEEKDAY_SHORT = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'] as const;
export const WEEKDAY_LONG = [
  'Sunday',
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
] as const;

/** "Every day" / "Mon, Wed, Fri" / "Never online" (bookable_weekdays: 0 = Sunday … 6). */
export function describeWeekdays(weekdays: readonly number[] | null | undefined): string {
  if (!weekdays || weekdays.length === 7) return 'Every day';
  if (weekdays.length === 0) return 'No days (not bookable online)';
  return [...weekdays]
    .sort((a, b) => a - b)
    .map((d) => WEEKDAY_SHORT[d] ?? '')
    .join(', ');
}

/** The value to store: every day selected → null (no restriction). */
export function weekdaysValue(selected: ReadonlySet<number>): number[] | null {
  if (selected.size === 7) return null;
  return [...selected].sort((a, b) => a - b);
}
