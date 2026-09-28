/**
 * Customers feature: row types, enum labels and small pure helpers shared by
 * the list, detail and form screens.
 */
import type { Row } from '@/lib/db';

export type CustomerRow = Row<'customers'>;
export type VehicleRow = Row<'vehicles'>;
export type CustomerLifecycle = CustomerRow['lifecycle'];
export type CustomerSource = CustomerRow['source'];

export const LIFECYCLES = ['lead', 'customer'] as const satisfies readonly CustomerLifecycle[];

export const LIFECYCLE_LABELS: Record<CustomerLifecycle, string> = {
  lead: 'Lead',
  customer: 'Customer',
};

export const SOURCES = [
  'staff',
  'online_booking',
  'referral',
  'google',
  'facebook',
  'instagram',
  'walk_in',
  'import',
  'other',
] as const satisfies readonly CustomerSource[];

export const SOURCE_LABELS: Record<CustomerSource, string> = {
  staff: 'Added by staff',
  online_booking: 'Online booking',
  referral: 'Referral',
  google: 'Google',
  facebook: 'Facebook',
  instagram: 'Instagram',
  walk_in: 'Walk-in',
  import: 'Imported',
  other: 'Other',
};

export function isLifecycle(value: string | null | undefined): value is CustomerLifecycle {
  return value === 'lead' || value === 'customer';
}

interface NameParts {
  first_name: string | null;
  last_name: string | null;
  company: string | null;
}

/** "Jane Doe", or the company when there is no person name. */
export function customerName(c: NameParts): string {
  const person = [c.first_name, c.last_name]
    .map((part) => part?.trim() ?? '')
    .filter(Boolean)
    .join(' ');
  return person || c.company?.trim() || 'Unnamed customer';
}

interface AddressParts {
  address_line1: string | null;
  address_line2: string | null;
  city: string | null;
  region: string | null;
  postal_code: string | null;
}

/** One-line postal address, or '' when empty. */
export function customerAddress(c: AddressParts): string {
  const cityLine = [c.city, [c.region, c.postal_code].filter(Boolean).join(' ')]
    .map((part) => part?.trim() ?? '')
    .filter(Boolean)
    .join(', ');
  return [c.address_line1, c.address_line2, cityLine]
    .map((part) => part?.trim() ?? '')
    .filter(Boolean)
    .join(', ');
}

interface VehicleParts {
  year: number | null;
  make: string | null;
  model: string | null;
  trim?: string | null;
}

/** "2021 Toyota Camry SE" (trim optional). */
export function vehicleLabel(v: VehicleParts, withTrim = false): string {
  const parts = [v.year ? String(v.year) : '', v.make ?? '', v.model ?? ''];
  if (withTrim) parts.push(v.trim ?? '');
  const label = parts
    .map((p) => p.trim())
    .filter(Boolean)
    .join(' ');
  return label || 'Vehicle';
}

/** Normalises and de-duplicates tags (case-insensitive, first spelling wins). */
export function normalizeTags(tags: readonly string[]): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  for (const raw of tags) {
    const tag = raw.trim().replace(/\s+/g, ' ');
    if (!tag) continue;
    const key = tag.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(tag);
  }
  return out;
}

export const MAX_TAGS = 50;
export const MAX_TAG_LENGTH = 40;

/** The SMS text for a card-setup link. */
export function cardSetupMessage(shopName: string, firstName: string | null, url: string): string {
  const greeting = firstName?.trim() ? `Hi ${firstName.trim()}, ` : 'Hi, ';
  return `${greeting}${shopName} here. Add a card on file securely using this link: ${url}`;
}
