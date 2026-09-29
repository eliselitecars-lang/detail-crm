/**
 * Online booking (/book/:slug, private links /book/:slug?link=<token>) and
 * the customer's booking page (/booking/:token). Everything goes through the
 * public SECURITY DEFINER RPCs: 0042 (public_shop_profile,
 * public_booking_catalog, create_online_booking, public_get_booking,
 * public_cancel_booking), 0053 (public_booking_slots, public_booking_link),
 * 0062 (public_validate_coupon), 0075 (public_booking_documents), 0088
 * (public_booking_questions, tracking ids) plus the payments
 * (booking_deposit_checkout, deposit_checkout_cancel, booking_cancel) and public-media
 * (booking_documents) edge functions. Prices, totals, taxes and deposits are always the server's: the
 * wizard never sends or sums prices.
 */
import { keepPreviousData, useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { z } from 'zod';
import { unwrap } from '@/lib/db';
import { edgeFunctionError, toAppError } from '@/lib/errors';
import { publicKey } from '@/lib/queryKeys';
import { supabase } from '@/lib/supabase';
import {
  cancelDepositCheckout,
  createCheckout,
  navigation,
} from '@/features/public-docs/shared/checkout';
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
import {
  fetchBookingDocumentMedia,
  MEDIA_REFRESH_MS,
  MEDIA_STALE_MS,
} from '@/features/job-report/media';
import type { BookingPayload, LocationChoice } from './model';

export const bookingKeys = {
  profile: (slug: string) => publicKey('shop-profile', slug),
  catalog: (slug: string) => publicKey('booking-catalog', slug),
  slots: (slug: string, args: SlotArgs | null) => publicKey('booking-slots', slug, args),
  preview: (slug: string, args: PreviewArgs | null) => publicKey('booking-preview', slug, args),
  booking: (token: string) => publicKey('booking', token),
  link: (token: string) => publicKey('booking-link', token),
  questions: (slug: string) => publicKey('booking-questions', slug),
  documents: (token: string) => publicKey('booking-documents', token),
  documentMedia: (token: string) => publicKey('booking-document-media', token),
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
  /** The shop's Meta Pixel / GA4 ids (0088); null while booking is off. */
  tracking: z
    .object({ meta_pixel_id: zText, ga4_measurement_id: zText })
    .nullish()
    .transform((v) => v ?? { meta_pixel_id: null, ga4_measurement_id: null }),
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
  service_categories: z.array(
    z.object({
      id: z.string(),
      name: z.string(),
      /** Local weekdays (0 = Sunday) services of this category can start online; null = every day. */
      bookable_weekdays: z
        .array(z.number().int().min(0).max(6))
        .nullish()
        .transform((v) => v ?? null),
    }),
  ),
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

/** public_booking_link (0053): a private link's name, note and catalog (its services only). */
export const bookingLinkSchema = z.object({
  slug: z.string(),
  name: z.string(),
  note: zText,
  expires_at: zText,
  catalog: catalogSchema,
});
export type BookingLink = z.output<typeof bookingLinkSchema>;

export function useBookingLink(token: string | null) {
  return useQuery({
    queryKey: bookingKeys.link(token ?? ''),
    queryFn: async () =>
      parseDocument(
        bookingLinkSchema,
        unwrap(await supabase.rpc('public_booking_link', { p_token: token ?? '' })),
      ),
    enabled: token !== null,
    retry: retryTransient,
    staleTime: 5 * 60_000,
  });
}

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
  /** null when the shop has no vehicle categories: the argument is omitted. */
  vehicleCategoryId: string | null;
  /** Shop-local dates, inclusive. */
  from: string;
  to: string;
  /** Where the work happens (per-location capacity; 'both' shops pass the customer's pick). */
  locationType: LocationChoice;
  /** A private booking link's token (its services instead of online_bookable). */
  linkToken: string | null;
}

/** public_booking_slots (0053): availability v2 with location type and private links. */
export function useAvailableSlots(slug: string, args: SlotArgs | null) {
  return useQuery({
    queryKey: bookingKeys.slots(slug, args),
    queryFn: async () => {
      if (!args) return [];
      return unwrap(
        await supabase.rpc('public_booking_slots', {
          p_slug: slug,
          p_service_ids: [...args.serviceIds],
          p_from: args.from,
          p_to: args.to,
          ...(args.vehicleCategoryId ? { p_vehicle_category_id: args.vehicleCategoryId } : {}),
          p_location_type: args.locationType,
          ...(args.linkToken ? { p_link_token: args.linkToken } : {}),
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
  /** Plain-language coupon limits (0062), e.g. "for new customers only". */
  restrictions_text: zText,
});
export type CouponPreview = z.output<typeof couponPreviewSchema>;

export interface PreviewArgs {
  /** Services + add-ons. */
  serviceIds: readonly string[];
  /** null when the shop has no vehicle categories: the argument is omitted. */
  vehicleCategoryId: string | null;
  /** Coupon code ("" = none: the server answers with undiscounted totals). */
  code: string;
  /** Location of the work (auto-applied fees depend on it). */
  locationType: LocationChoice;
  linkToken: string | null;
}

async function fetchPreview(slug: string, args: PreviewArgs): Promise<CouponPreview> {
  return parseDocument(
    couponPreviewSchema,
    unwrap(
      await supabase.rpc('public_validate_coupon', {
        p_slug: slug,
        p_code: args.code,
        p_service_ids: [...args.serviceIds],
        ...(args.vehicleCategoryId ? { p_vehicle_category_id: args.vehicleCategoryId } : {}),
        p_location_type: args.locationType,
        ...(args.linkToken ? { p_link_token: args.linkToken } : {}),
      }),
    ),
  );
}

// ---------------------------------------------------------------------------
// Booking questions (0088): the shop's job custom fields shown online
// ---------------------------------------------------------------------------

export const bookingQuestionSchema = z.object({
  key: z.string(),
  label: z.string(),
  type: z.enum(['text', 'textarea', 'number', 'select', 'multiselect', 'checkbox', 'date']),
  options: z
    .array(z.string())
    .nullish()
    .transform((v) => v ?? []),
  help_text: zText,
  required: z.boolean(),
  /** 'shop' | 'mobile' = only for that location; null = both. */
  location_scope: zLocationType.nullish().transform((v) => v ?? null),
});
export type BookingQuestion = z.output<typeof bookingQuestionSchema>;

/** Answers the booking page's questions (answers even while booking is off). */
export function useBookingQuestions(slug: string) {
  return useQuery({
    queryKey: bookingKeys.questions(slug),
    queryFn: async () =>
      parseDocument(
        z.array(bookingQuestionSchema),
        unwrap(await supabase.rpc('public_booking_questions', { p_slug: slug })) ?? [],
      ),
    retry: retryTransient,
    staleTime: 5 * 60_000,
  });
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

/**
 * The customer's own cancel goes through the payments edge function
 * (`booking_cancel`), never public_cancel_booking directly: since 0106 the
 * RPC refuses (55000 checkout_open) while a deposit or invoice payment page
 * of the booking is still open — which is every time the customer has
 * clicked "Pay deposit" and come back, for as long as Stripe keeps that page
 * alive (~30–40 minutes). The edge expires and releases those pages first,
 * then runs public_cancel_booking as the caller (anonymous, or the signed-in
 * portal client), so the RPC's own rules — status, deadline, a payment going
 * through, technicians — still decide. Returns public_get_booking's document.
 */
export async function cancelBookingOnline(token: string, reason: string) {
  const note = reason.trim();
  const body = { action: 'booking_cancel', token, ...(note ? { reason: note } : {}) };
  let response: Awaited<ReturnType<typeof supabase.functions.invoke<unknown>>>;
  try {
    response = await supabase.functions.invoke<unknown>('payments', { body });
  } catch (error) {
    throw await edgeFunctionError(error);
  }
  if (response.error) throw await edgeFunctionError(response.error);
  return parseDocument(bookingDocumentSchema, response.data);
}

export function useCancelBooking(token: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (reason: string) => cancelBookingOnline(token, reason),
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

/**
 * Back from Stripe with ?canceled=1: closes the booking's open deposit card
 * page (payments deposit_checkout_cancel) instead of leaving the booking held
 * until Stripe expires it, then reads the booking again.
 */
export function useCancelDepositCheckout(token: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: () => cancelDepositCheckout({ bookingToken: token }),
    onSettled: () => queryClient.invalidateQueries({ queryKey: bookingKeys.booking(token) }),
  });
}

// ---------------------------------------------------------------------------
// Documents shared on a booking (0075 + public-media)
// ---------------------------------------------------------------------------

export const bookingDocumentRowSchema = z.object({
  id: z.string(),
  file_name: z.string(),
  content_type: zText,
  size_bytes: z
    .number()
    .int()
    .nullish()
    .transform((v) => v ?? null),
  created_at: zText,
});
export type BookingDocumentRow = z.output<typeof bookingDocumentRowSchema>;

export function useBookingDocuments(token: string, enabled: boolean) {
  return useQuery({
    queryKey: bookingKeys.documents(token),
    queryFn: async () =>
      parseDocument(
        z.array(bookingDocumentRowSchema),
        unwrap(await supabase.rpc('public_booking_documents', { p_token: token })) ?? [],
      ),
    enabled,
    retry: retryTransient,
  });
}

/** Short-lived download links for the booking's documents (refreshed before they expire). */
export function useBookingDocumentMedia(token: string, enabled: boolean) {
  return useQuery({
    queryKey: bookingKeys.documentMedia(token),
    queryFn: () => fetchBookingDocumentMedia(token),
    enabled,
    retry: retryTransient,
    staleTime: MEDIA_STALE_MS,
    refetchInterval: MEDIA_REFRESH_MS,
  });
}
