/**
 * Online booking (/book/:slug) and the customer's booking page
 * (/booking/:token). Everything goes through the public SECURITY DEFINER
 * RPCs of 0007 (get_available_slots) and 0042 (public_shop_profile,
 * public_booking_catalog, public_validate_coupon, create_online_booking,
 * public_get_booking, public_cancel_booking) plus the payments edge function
 * (booking_deposit_checkout). Prices, totals, taxes and deposits are always
 * the server's: the wizard never sends or sums prices.
 */
import { keepPreviousData, useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { z } from 'zod';
import { unwrap } from '@/lib/db';
import { toAppError } from '@/lib/errors';
import { publicKey } from '@/lib/queryKeys';
import { supabase } from '@/lib/supabase';
import { createCheckout, navigation } from '@/features/public-docs/shared/checkout';
import {
  parseDocument,
  publicLineSchema,
  publicShopSchema,
  publicVehicleSchema,
  zBusinessType,
  zCentsValue,
  zCouponKind,
  zDepositType,
  zIntOrNull,
  zJobStatus,
  zLocationType,
  zText,
} from '@/features/public-docs/shared/schemas';
import type { BookingPayload } from './model';

export const bookingKeys = {
  profile: (slug: string) => publicKey('shop-profile', slug),
  catalog: (slug: string) => publicKey('booking-catalog', slug),
  slots: (slug: string, args: SlotArgs | null) => publicKey('booking-slots', slug, args),
  preview: (slug: string, args: PreviewArgs | null) => publicKey('booking-preview', slug, args),
  booking: (token: string) => publicKey('booking', token),
};

function retryTransient(failureCount: number, error: unknown): boolean {
  const kind = toAppError(error).kind;
  return failureCount < 2 && (kind === 'network' || kind === 'server' || kind === 'unknown');
}

// ---------------------------------------------------------------------------
// Shop profile + catalog
// ---------------------------------------------------------------------------

export const shopProfileSchema = z.object({
  name: z.string(),
  slug: z.string(),
  logo_path: zText,
  brand_color: zText,
  phone: zText,
  website: zText,
  city: zText,
  region: zText,
  country: zText,
  timezone: z.string(),
  currency: z
    .string()
    .nullish()
    .transform((v) => v ?? 'usd'),
  business_type: zBusinessType,
  tax_rate_bps: zIntOrNull,
  booking: z.object({
    enabled: z.boolean(),
    auto_confirm: z.boolean(),
    lead_time_minutes: zIntOrNull,
    max_days_ahead: zIntOrNull,
    slot_interval_minutes: zIntOrNull,
    require_deposit: z.boolean(),
    deposit_type: zDepositType.nullish().transform((v) => v ?? null),
    deposit_value: zIntOrNull,
    service_area_limited: z.boolean(),
    booking_message: zText,
    cancellation_policy: zText,
    allow_client_cancel_hours: zIntOrNull,
  }),
});
export type ShopProfile = z.output<typeof shopProfileSchema>;

export function useShopProfile(slug: string) {
  return useQuery({
    queryKey: bookingKeys.profile(slug),
    queryFn: async () =>
      parseDocument(
        shopProfileSchema,
        unwrap(await supabase.rpc('public_shop_profile', { p_slug: slug })),
      ),
    retry: retryTransient,
    staleTime: 5 * 60_000,
  });
}

const catalogPriceSchema = z.object({
  vehicle_category_id: z.string(),
  price_cents: zCentsValue,
  duration_minutes: zIntOrNull,
});

const catalogItemSchema = z.object({
  id: z.string(),
  category_id: zText,
  name: z.string(),
  description: zText,
  kind: z.enum(['service', 'package', 'addon']),
  image_path: zText,
  duration_minutes: zIntOrNull,
  base_price_cents: zIntOrNull,
  prices: z.array(catalogPriceSchema),
});

export const catalogSchema = z.object({
  vehicle_categories: z.array(z.object({ id: z.string(), name: z.string() })),
  service_categories: z.array(z.object({ id: z.string(), name: z.string() })),
  services: z.array(
    catalogItemSchema.extend({
      includes: z.array(z.string()),
      addon_ids: z.array(z.string()),
    }),
  ),
  addons: z.array(catalogItemSchema),
});
export type BookingCatalog = z.output<typeof catalogSchema>;
export type CatalogService = BookingCatalog['services'][number];
export type CatalogAddon = BookingCatalog['addons'][number];

export function useBookingCatalog(slug: string, enabled: boolean) {
  return useQuery({
    queryKey: bookingKeys.catalog(slug),
    queryFn: async () =>
      parseDocument(
        catalogSchema,
        unwrap(await supabase.rpc('public_booking_catalog', { p_slug: slug })),
      ),
    enabled,
    retry: retryTransient,
    staleTime: 5 * 60_000,
  });
}

// ---------------------------------------------------------------------------
// Availability
// ---------------------------------------------------------------------------

export interface SlotArgs {
  /** Services + add-ons (the server sizes the slot from all of them). */
  serviceIds: readonly string[];
  vehicleCategoryId: string;
  /** Shop-local dates, inclusive. */
  from: string;
  to: string;
}

export function useAvailableSlots(slug: string, args: SlotArgs | null) {
  return useQuery({
    queryKey: bookingKeys.slots(slug, args),
    queryFn: async () => {
      if (!args) return [];
      return unwrap(
        await supabase.rpc('get_available_slots', {
          p_shop_slug: slug,
          p_service_ids: [...args.serviceIds],
          p_vehicle_category_id: args.vehicleCategoryId,
          p_from: args.from,
          p_to: args.to,
        }),
      );
    },
    enabled: args !== null,
    retry: retryTransient,
    placeholderData: keepPreviousData,
    // Availability changes as other people book: keep it fresh.
    staleTime: 30_000,
  });
}

// ---------------------------------------------------------------------------
// Price / coupon preview
// ---------------------------------------------------------------------------

export const couponPreviewSchema = z.object({
  valid: z.boolean(),
  message: zText,
  code: zText,
  kind: zCouponKind.nullish().transform((v) => v ?? null),
  value: zIntOrNull,
  description: zText,
  subtotal_cents: zCentsValue,
  discount_cents: zCentsValue,
  tax_cents: zCentsValue,
  total_cents: zCentsValue,
});
export type CouponPreview = z.output<typeof couponPreviewSchema>;

export interface PreviewArgs {
  /** Services + add-ons. */
  serviceIds: readonly string[];
  vehicleCategoryId: string;
  /** Coupon code ("" = none: the server answers with undiscounted totals). */
  code: string;
}

async function fetchPreview(slug: string, args: PreviewArgs): Promise<CouponPreview> {
  return parseDocument(
    couponPreviewSchema,
    unwrap(
      await supabase.rpc('public_validate_coupon', {
        p_slug: slug,
        p_code: args.code,
        p_service_ids: [...args.serviceIds],
        p_vehicle_category_id: args.vehicleCategoryId,
      }),
    ),
  );
}

/**
 * Server price preview for the review step (public_validate_coupon answers
 * an invalid/empty code with the undiscounted catalog totals). Estimates
 * only: the confirmed total comes back from create_online_booking.
 */
export function usePricePreview(slug: string, args: PreviewArgs | null) {
  return useQuery({
    queryKey: bookingKeys.preview(slug, args),
    queryFn: () => (args ? fetchPreview(slug, args) : Promise.reject(new Error('no args'))),
    enabled: args !== null,
    retry: retryTransient,
    placeholderData: keepPreviousData,
  });
}

/** Explicit "Apply" of a coupon code on the details step. */
export function useValidateCoupon(slug: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (args: PreviewArgs) => fetchPreview(slug, args),
    onSuccess: (preview, args) => {
      queryClient.setQueryData(bookingKeys.preview(slug, args), preview);
    },
  });
}

// ---------------------------------------------------------------------------
// Create booking
// ---------------------------------------------------------------------------

export const createdBookingSchema = z.object({
  job_token: z.string(),
  job_number: z.number().int(),
  status: zJobStatus,
  total_cents: zCentsValue,
  deposit_required_cents: zCentsValue,
});
export type CreatedBooking = z.output<typeof createdBookingSchema>;

export function useCreateBooking(slug: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (payload: BookingPayload) =>
      parseDocument(
        createdBookingSchema,
        unwrap(await supabase.rpc('create_online_booking', { p_slug: slug, p_payload: payload })),
      ),
    onSettled: () => {
      // Either way the availability picture changed (our booking, or someone else's).
      void queryClient.invalidateQueries({ queryKey: publicKey('booking-slots', slug) });
    },
  });
}

// ---------------------------------------------------------------------------
// Booking page
// ---------------------------------------------------------------------------

export const bookingDocumentSchema = z.object({
  shop: publicShopSchema,
  booking_message: zText,
  booking: z.object({
    number: z.number().int(),
    status: zJobStatus,
    scheduled_start: zText,
    scheduled_end: zText,
    location_type: zLocationType,
    service_address: z
      .object({
        address_line1: zText,
        address_line2: zText,
        city: zText,
        region: zText,
        postal_code: zText,
      })
      .nullish()
      .transform((v) => v ?? null),
    notes: zText,
    created_at: zText,
    confirmed_at: zText,
    completed_at: zText,
    cancelled_at: zText,
    cancel_reason: zText,
  }),
  vehicle: publicVehicleSchema,
  line_items: z.array(publicLineSchema),
  totals: z.object({
    subtotal_cents: zCentsValue,
    discount_cents: zCentsValue,
    coupon_code: zText,
    tax_rate_bps: zIntOrNull,
    tax_cents: zCentsValue,
    total_cents: zCentsValue,
    paid_cents: zCentsValue,
    balance_cents: zCentsValue,
  }),
  deposit: z.object({
    required_cents: zCentsValue,
    paid_cents: zCentsValue,
    due_cents: zCentsValue,
    status: z.enum(['not_required', 'paid', 'due']),
    payment_pending: z.boolean(),
    card_payments_enabled: z.boolean(),
  }),
  cancellation: z.object({
    allowed: z.boolean(),
    deadline: zText,
    allow_client_cancel_hours: zIntOrNull,
    policy: zText,
  }),
  forms: z.array(
    z.object({
      title: z.string(),
      requires_signature: z.boolean(),
      status: z.enum(['signed', 'void', 'pending']),
      signed_at: zText,
      token: z.string(),
    }),
  ),
  invoice: z
    .object({
      token: z.string(),
      number: z.number().int(),
      status: z.string(),
      total_cents: zCentsValue,
      balance_cents: zCentsValue,
      due_at: zText,
    })
    .nullish()
    .transform((v) => v ?? null),
});
export type BookingDocument = z.output<typeof bookingDocumentSchema>;

export const DEPOSIT_POLL_INTERVAL_MS = 2500;
export const DEPOSIT_POLL_ATTEMPTS = 8;

/** True once the deposit webhook has landed (or nothing more is due). */
export function depositSettled(doc: BookingDocument): boolean {
  return doc.deposit.status !== 'due' && !doc.deposit.payment_pending;
}

export function usePublicBooking(token: string, options: { pollForDeposit?: boolean } = {}) {
  const queryClient = useQueryClient();
  const query = useQuery({
    queryKey: bookingKeys.booking(token),
    queryFn: async () =>
      parseDocument(
        bookingDocumentSchema,
        unwrap(await supabase.rpc('public_get_booking', { p_token: token })),
      ),
    retry: retryTransient,
    refetchInterval: (query) => {
      if (!options.pollForDeposit) return false;
      const doc = query.state.data;
      if (doc && depositSettled(doc)) return false;
      return query.state.dataUpdateCount < DEPOSIT_POLL_ATTEMPTS ? DEPOSIT_POLL_INTERVAL_MS : false;
    },
  });
  /** How many times the document has been loaded (drives the ?paid=1 polling UI). */
  const loads = queryClient.getQueryState(bookingKeys.booking(token))?.dataUpdateCount ?? 0;
  return { query, loads };
}

export function useCancelBooking(token: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (reason: string) =>
      parseDocument(
        bookingDocumentSchema,
        unwrap(
          await supabase.rpc('public_cancel_booking', {
            p_token: token,
            ...(reason.trim() ? { p_reason: reason.trim() } : {}),
          }),
        ),
      ),
    onSuccess: (doc) => queryClient.setQueryData(bookingKeys.booking(token), doc),
    onError: () => void queryClient.invalidateQueries({ queryKey: bookingKeys.booking(token) }),
  });
}

/** Deposit Checkout for the amount still due (server-computed), then off to Stripe. */
export function useDepositCheckout(token: string) {
  return useMutation({
    mutationFn: async () => {
      const session = await createCheckout({ action: 'booking_deposit_checkout', token });
      navigation.assign(session.url);
      return session;
    },
  });
}
