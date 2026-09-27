/**
 * zod schemas for the curated JSON documents the public (anon) RPCs return
 * (0014 money_public_*_json, 0023 form_submission_public_json, 0042
 * booking_public_json). Shared by the booking, public-docs and portal
 * features. Objects are not strict: extra keys the server adds later are
 * dropped instead of breaking the page.
 */
import { z } from 'zod';
import type { PublicShopBranding } from '@/components/layout/PublicLayout';
import { Constants } from '@/lib/database.types';
import { AppError } from '@/lib/errors';

const Enums = Constants.public.Enums;

/** Integer cents (jsonb bigint → JSON number). */
export const zCentsValue = z.number().int();
/** Nullable text. Missing keys read as null. */
export const zText = z
  .string()
  .nullish()
  .transform((v) => v ?? null);
/** Nullable integer. */
export const zIntOrNull = z
  .number()
  .int()
  .nullish()
  .transform((v) => v ?? null);

export const zJobStatus = z.enum(Enums.job_status);
export const zQuoteStatus = z.enum(Enums.quote_status);
export const zInvoiceStatus = z.enum(Enums.invoice_status);
export const zPaymentStatus = z.enum(Enums.payment_status);
export const zPaymentKind = z.enum(Enums.payment_kind);
export const zPaymentMethod = z.enum(Enums.payment_method);
export const zLocationType = z.enum(Enums.location_type);
export const zBusinessType = z.enum(Enums.business_type);
export const zMembershipStatus = z.enum(Enums.membership_status);
export const zMembershipInterval = z.enum(Enums.membership_interval);
export const zCouponKind = z.enum(Enums.coupon_kind);
export const zDepositType = z.enum(Enums.deposit_type);

/** money_public_shop_json (0014) — also a superset of the form page's shop. */
export const publicShopSchema = z.object({
  name: z.string(),
  slug: z.string(),
  logo_path: zText,
  brand_color: zText,
  email: zText,
  phone: zText,
  website: zText,
  address_line1: zText,
  address_line2: zText,
  city: zText,
  region: zText,
  postal_code: zText,
  country: zText,
  timezone: z.string(),
  currency: z
    .string()
    .nullish()
    .transform((v) => v ?? 'usd'),
  review_url: zText,
});
export type PublicShop = z.output<typeof publicShopSchema>;

/** money_public_vehicle_json (0014); null when the document has no vehicle. */
export const publicVehicleSchema = z
  .object({
    year: zIntOrNull,
    make: zText,
    model: zText,
    trim: zText,
    color: zText,
  })
  .nullish()
  .transform((v) => v ?? null);
export type PublicVehicle = z.output<typeof publicVehicleSchema>;

/** Line of a public job / invoice / quote document. */
export const publicLineSchema = z.object({
  name: z.string(),
  description: zText,
  vehicle_label: zText,
  quantity: z.number(),
  unit_price_cents: zCentsValue,
  discount_cents: zCentsValue.nullish().transform((v) => v ?? 0),
  taxable: z
    .boolean()
    .nullish()
    .transform((v) => v ?? false),
  total_cents: zCentsValue.nullish().transform((v) => v ?? 0),
});
export type PublicLine = z.output<typeof publicLineSchema>;

export const publicCustomerSchema = z
  .object({ first_name: zText, last_name: zText, company: zText })
  .nullish()
  .transform((v) => v ?? null);

/** Shop branding for PublicLayout from any public shop document. */
export function toBranding(shop: {
  name: string;
  logo_path?: string | null;
  brand_color?: string | null;
  phone?: string | null;
  email?: string | null;
  website?: string | null;
}): PublicShopBranding {
  return {
    name: shop.name,
    logoPath: shop.logo_path ?? null,
    brandColor: shop.brand_color ?? null,
    phone: shop.phone ?? null,
    email: shop.email ?? null,
    website: shop.website ?? null,
  };
}

/** "2021 Toyota Camry · Blue" */
export function vehicleLabel(vehicle: PublicVehicle): string | null {
  if (!vehicle) return null;
  const base = [vehicle.year, vehicle.make, vehicle.model, vehicle.trim]
    .filter((part) => part !== null && part !== '')
    .join(' ');
  if (!base) return null;
  return vehicle.color ? `${base} · ${vehicle.color}` : base;
}

/** Multi-line postal address from nullable parts. */
export function addressLines(parts: {
  address_line1?: string | null;
  address_line2?: string | null;
  city?: string | null;
  region?: string | null;
  postal_code?: string | null;
}): string[] {
  const cityLine = [parts.city, [parts.region, parts.postal_code].filter(Boolean).join(' ')]
    .filter(Boolean)
    .join(', ');
  return [parts.address_line1, parts.address_line2, cityLine].filter(
    (line): line is string => typeof line === 'string' && line.trim() !== '',
  );
}

/**
 * Validates an untyped RPC result. A shape mismatch is a server/client
 * version skew — reported as a friendly error, never rendered half-parsed.
 */
export function parseDocument<S extends z.ZodType>(schema: S, data: unknown): z.output<S> {
  const parsed = schema.safeParse(data);
  if (!parsed.success) {
    throw new AppError(
      'This page received an unexpected response from the server. Please try again.',
      { kind: 'server', cause: parsed.error },
    );
  }
  return parsed.data;
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** Public link tokens are UUIDs; anything else is a broken link (never sent to the server). */
export function isLinkToken(value: string | undefined): value is string {
  return typeof value === 'string' && UUID_RE.test(value);
}
