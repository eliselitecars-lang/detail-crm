/**
 * Small, pure helpers shared by the quotes / invoices / payments /
 * memberships features (all owned by the same feature group). No money math
 * lives here: totals, tax and balances always come from the server.
 */

export interface CustomerNameFields {
  first_name: string | null;
  last_name: string | null;
  company: string | null;
}

/** "Jane Doe", or the company, or "Unnamed customer". */
export function customerName(customer: CustomerNameFields | null | undefined): string {
  if (!customer) return 'Unknown customer';
  const person = [customer.first_name, customer.last_name]
    .map((part) => part?.trim() ?? '')
    .filter(Boolean)
    .join(' ');
  if (person) return person;
  const company = customer.company?.trim();
  return company || 'Unnamed customer';
}

export interface VehicleLabelFields {
  year: number | null;
  make: string | null;
  model: string | null;
  trim?: string | null;
  color?: string | null;
  license_plate?: string | null;
}

/** "2021 Toyota Tacoma TRD" (falls back to the plate, then "Vehicle"). */
export function vehicleLabel(vehicle: VehicleLabelFields | null | undefined): string {
  if (!vehicle) return 'No vehicle';
  const text = [vehicle.year ? String(vehicle.year) : '', vehicle.make, vehicle.model, vehicle.trim]
    .map((part) => part?.trim() ?? '')
    .filter(Boolean)
    .join(' ');
  if (text) return text;
  return vehicle.license_plate?.trim() || 'Vehicle';
}

const QUANTITY_RE = /^(\d{1,8})(?:\.(\d{0,2}))?$/;

/**
 * Line quantity input (numeric(10,2) > 0): "1", "2.5", "0.25". Returns null
 * for empty/invalid/zero input or more than two decimals.
 */
export function parseQuantity(input: string | null | undefined): number | null {
  if (input === null || input === undefined) return null;
  const text = input.trim();
  const match = QUANTITY_RE.exec(text);
  if (!match) return null;
  const [, whole = '0', frac = ''] = match;
  const hundredths = Number(whole) * 100 + Number(frac.padEnd(2, '0'));
  if (hundredths <= 0) return null;
  return hundredths / 100;
}

/** 1 → "1", 2.5 → "2.5", 0.25 → "0.25". */
export function formatQuantity(quantity: number): string {
  if (!Number.isFinite(quantity)) return '';
  return String(Math.round(quantity * 100) / 100);
}

export type PublicDocKind = 'quote' | 'invoice';

/** Client-facing link for a document token (SPEC §6: /q/:token, /i/:token). */
export function publicDocUrl(kind: PublicDocKind, token: string, origin?: string): string {
  const base = (origin ?? window.location.origin).replace(/\/+$/, '');
  return `${base}/${kind === 'quote' ? 'q' : 'i'}/${encodeURIComponent(token)}`;
}

/** Copies text to the clipboard; resolves false when the browser refuses. */
export async function copyText(text: string): Promise<boolean> {
  try {
    if (navigator.clipboard?.writeText) {
      await navigator.clipboard.writeText(text);
      return true;
    }
  } catch {
    // fall through to the legacy path
  }
  try {
    const area = document.createElement('textarea');
    area.value = text;
    area.setAttribute('readonly', '');
    area.style.position = 'fixed';
    area.style.opacity = '0';
    document.body.appendChild(area);
    area.select();
    const ok = document.execCommand('copy');
    area.remove();
    return ok;
  } catch {
    return false;
  }
}

/** Url-safe idempotency nonce for edge-function money actions (8–64 chars). */
export function newRequestNonce(): string {
  if (typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function') {
    return crypto.randomUUID().replace(/-/g, '');
  }
  return `${Date.now().toString(36)}${Math.random().toString(36).slice(2, 12)}`;
}

/** Escapes LIKE wildcards so user input matches literally. */
export function escapeLike(text: string): string {
  return text.replace(/[\\%_]/g, (ch) => `\\${ch}`);
}

/** "42" / "#42" → 42 (document numbers); anything else → null. */
export function parseDocNumber(text: string): number | null {
  const match = /^#?\s*(\d{1,15})$/.exec(text.trim());
  if (!match?.[1]) return null;
  const value = Number(match[1]);
  return Number.isSafeInteger(value) ? value : null;
}
