/**
 * Public document pages (/q/:token, /i/:token, /f/:token). Anonymous
 * visitors reach data only through the token-keyed SECURITY DEFINER RPCs
 * (0014 public_get_quote / public_respond_quote / public_get_invoice, 0023
 * public_get_form / public_sign_form) and the payments edge function.
 */
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { z } from 'zod';
import { unwrap } from '@/lib/db';
import { AppError, edgeFunctionError, isCheckoutOpenError, toAppError } from '@/lib/errors';
import { publicKey } from '@/lib/queryKeys';
import { supabase } from '@/lib/supabase';
import { cancelDepositCheckout, createCheckout, navigation } from './shared/checkout';
import {
  parseDocument,
  publicCustomerSchema,
  publicLineSchema,
  publicShopSchema,
  publicVehicleSchema,
  zCentsValue,
  zInvoiceStatus,
  zIntOrNull,
  zPaymentKind,
  zPaymentMethod,
  zPaymentStatus,
  zQuoteStatus,
  zText,
} from './shared/schemas';

export const publicDocKeys = {
  quote: (token: string) => publicKey('quote', token),
  quoteSlots: (token: string, from: string, to: string, location: string | null) =>
    [...publicKey('quote', token), 'slots', from, to, location] as const,
  invoice: (token: string) => publicKey('invoice', token),
  form: (token: string) => publicKey('form', token),
};

/** Polling after Stripe redirects back with ?paid=1 (the webhook lands asynchronously). */
export const PAID_POLL_INTERVAL_MS = 2500;
export const PAID_POLL_ATTEMPTS = 8;

/** Retry transient failures only (a missing link or a validation error never heals). */
function retryTransient(failureCount: number, error: unknown): boolean {
  const kind = toAppError(error).kind;
  return failureCount < 2 && (kind === 'network' || kind === 'server' || kind === 'unknown');
}

// ---------------------------------------------------------------------------
// Quote
// ---------------------------------------------------------------------------

export const quoteLineSchema = publicLineSchema.extend({
  id: z.string(),
  optional: z.boolean(),
  selected: z.boolean(),
  /** The proposal option the line belongs to (null = every option). */
  option_id: zText,
});
export type QuoteLine = z.output<typeof quoteLineSchema>;

/** A proposal option with its server totals (0067). */
export const quoteOptionSchema = z.object({
  id: z.string(),
  name: z.string(),
  description: zText,
  sort: z.number().int(),
  subtotal_cents: zCentsValue,
  discount_cents: zCentsValue,
  tax_cents: zCentsValue,
  total_cents: zCentsValue,
});
export type QuoteOption = z.output<typeof quoteOptionSchema>;

/**
 * Customer self-scheduling of an approved quote (0067): `available` = the
 * customer may pick a time now; job_token / deposit_due_cents /
 * payment_pending only once they scheduled on this page.
 */
export const selfScheduleSchema = z
  .object({
    available: z.boolean(),
    converted: z.boolean(),
    job_token: zText,
    deposit_due_cents: zIntOrNull,
    payment_pending: z
      .boolean()
      .nullish()
      .transform((v) => v ?? false),
  })
  .nullish()
  .transform(
    (v) =>
      v ?? {
        available: false,
        converted: false,
        job_token: null,
        deposit_due_cents: null,
        payment_pending: false,
      },
  );
export type SelfSchedule = z.output<typeof selfScheduleSchema>;

export const quoteDocumentSchema = z.object({
  shop: publicShopSchema,
  quote: z.object({
    number: z.number().int(),
    status: zQuoteStatus,
    valid_until: zText,
    expires_at: zText,
    notes: zText,
    terms: zText,
    subtotal_cents: zCentsValue,
    discount_cents: zCentsValue,
    tax_rate_bps: zIntOrNull,
    tax_cents: zCentsValue,
    total_cents: zCentsValue,
    sent_at: zText,
    viewed_at: zText,
    approved_at: zText,
    approved_by_name: zText,
    declined_at: zText,
    declined_reason: zText,
    expired_at: zText,
    can_respond: z.boolean(),
    has_options: z
      .boolean()
      .nullish()
      .transform((v) => v ?? false),
    /** The option the quote counts (the customer's choice, else the first). */
    selected_option_id: zText,
  }),
  customer: publicCustomerSchema,
  vehicle: publicVehicleSchema,
  options: z
    .array(quoteOptionSchema)
    .nullish()
    .transform((v) => v ?? []),
  line_items: z.array(quoteLineSchema),
  self_schedule: selfScheduleSchema,
});
export type QuoteDocument = z.output<typeof quoteDocumentSchema>;

export function usePublicQuote(token: string, options: { pollForDeposit?: boolean } = {}) {
  const queryClient = useQueryClient();
  const query = useQuery({
    queryKey: publicDocKeys.quote(token),
    queryFn: async () =>
      parseDocument(
        quoteDocumentSchema,
        unwrap(await supabase.rpc('public_get_quote', { p_token: token })),
      ),
    retry: retryTransient,
    // public_get_quote marks the quote viewed; no need to hammer it.
    refetchOnWindowFocus: false,
    // Back from Stripe with ?paid=1: the webhook lands asynchronously.
    refetchInterval: (query) => {
      if (!options.pollForDeposit) return false;
      const schedule = query.state.data?.self_schedule;
      if (schedule && !schedule.payment_pending && (schedule.deposit_due_cents ?? 0) <= 0) {
        return false;
      }
      return query.state.dataUpdateCount < PAID_POLL_ATTEMPTS ? PAID_POLL_INTERVAL_MS : false;
    },
  });
  /** How many times the document has been loaded (drives the ?paid=1 polling UI). */
  const loads = queryClient.getQueryState(publicDocKeys.quote(token))?.dataUpdateCount ?? 0;
  return { query, loads };
}

/** The booking facts the scheduling panel needs (public_shop_profile). */
export const bookingProfileSchema = z.object({
  business_type: z.enum(['fixed', 'mobile', 'both']),
  booking: z
    .object({
      max_days_ahead: zIntOrNull,
      booking_message: zText,
      cancellation_policy: zText,
    })
    .nullish()
    .transform(
      (v) => v ?? { max_days_ahead: null, booking_message: null, cancellation_policy: null },
    ),
});
export type BookingProfile = z.output<typeof bookingProfileSchema>;

export function useBookingProfile(slug: string, enabled: boolean) {
  return useQuery({
    queryKey: publicKey('shop-profile', slug),
    enabled,
    retry: retryTransient,
    staleTime: 5 * 60_000,
    queryFn: async () =>
      parseDocument(
        bookingProfileSchema,
        unwrap(await supabase.rpc('public_shop_profile', { p_slug: slug })),
      ),
  });
}

export type QuoteResponse =
  | {
      action: 'approve';
      signerName: string;
      selectedOptionalIds: string[];
      /** Required when the quote has proposal options. */
      optionId?: string | null;
    }
  | { action: 'decline'; reason: string };

export function useRespondQuote(token: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (response: QuoteResponse) => {
      const data = unwrap(
        await supabase.rpc(
          'public_respond_quote',
          response.action === 'approve'
            ? {
                p_token: token,
                p_action: 'approve',
                p_signer_name: response.signerName,
                p_selected_optional_line_ids: response.selectedOptionalIds,
                ...(response.optionId ? { p_option_id: response.optionId } : {}),
              }
            : {
                p_token: token,
                p_action: 'decline',
                ...(response.reason.trim() ? { p_declined_reason: response.reason.trim() } : {}),
              },
        ),
      );
      return parseDocument(quoteDocumentSchema, data);
    },
    onSuccess: (doc) => {
      queryClient.setQueryData(publicDocKeys.quote(token), doc);
    },
    onError: () => {
      // The quote may have changed (expired, answered elsewhere): show the truth.
      void queryClient.invalidateQueries({ queryKey: publicDocKeys.quote(token) });
    },
  });
}

// ---------------------------------------------------------------------------
// Quote self-scheduling (P-16)
// ---------------------------------------------------------------------------

export type ScheduleLocationType = 'shop' | 'mobile';

export const quoteSlotSchema = z.object({ starts_at: z.string(), ends_at: z.string() });
export type QuoteSlot = z.output<typeof quoteSlotSchema>;

/**
 * Start times the customer can book for their approved quote
 * (public_quote_slots over the online booking engine). `from` / `to` are
 * shop-local dates; `location` null = what the shop offers.
 */
export function useQuoteSlots(
  token: string,
  range: { from: string; to: string } | null,
  location: ScheduleLocationType | null,
) {
  return useQuery({
    queryKey: publicDocKeys.quoteSlots(token, range?.from ?? '', range?.to ?? '', location),
    enabled: range !== null,
    retry: retryTransient,
    queryFn: async (): Promise<QuoteSlot[]> => {
      if (!range) return [];
      const data = unwrap(
        await supabase.rpc('public_quote_slots', {
          p_token: token,
          p_from: range.from,
          p_to: range.to,
          ...(location ? { p_location_type: location } : {}),
        }),
      );
      return parseDocument(z.array(quoteSlotSchema), data ?? []);
    },
  });
}

export const scheduleResultSchema = z.object({
  job_token: z.string(),
  job_number: z.number().int(),
  status: z.string(),
  total_cents: zCentsValue,
  deposit_required_cents: zCentsValue,
  deposit_due_cents: zCentsValue,
});
export type ScheduleResult = z.output<typeof scheduleResultSchema>;

export interface ScheduleQuoteInput {
  startsAt: string;
  location:
    | { type: 'shop' }
    | {
        type: 'mobile';
        address_line1: string;
        address_line2?: string;
        city: string;
        region?: string;
        postal_code: string;
      }
    | null;
}

/** public_schedule_quote: books the approved quote at one of the offered times. */
export function useScheduleQuote(token: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async ({ startsAt, location }: ScheduleQuoteInput) =>
      parseDocument(
        scheduleResultSchema,
        unwrap(
          await supabase.rpc('public_schedule_quote', {
            p_token: token,
            p_starts_at: startsAt,
            ...(location ? { p_location: location } : {}),
          }),
        ),
      ),
    onSettled: () => queryClient.invalidateQueries({ queryKey: publicDocKeys.quote(token) }),
  });
}

/** Pays a self-scheduled quote's deposit on Stripe Checkout (card saved for the balance). */
export function useQuoteDepositCheckout(token: string) {
  return useMutation({
    mutationFn: async () => {
      const session = await createCheckout({ action: 'quote_deposit_checkout', token });
      navigation.assign(session.url);
      return session;
    },
  });
}

/**
 * Back from Stripe with ?canceled=1 on /q: closes the scheduled job's open
 * deposit card page (payments deposit_checkout_cancel with the quote's
 * self_schedule.job_token), then reads the quote again.
 */
export function useCancelQuoteDepositCheckout(token: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (jobToken: string) => cancelDepositCheckout({ bookingToken: jobToken }),
    onSettled: () => queryClient.invalidateQueries({ queryKey: publicDocKeys.quote(token) }),
  });
}

// ---------------------------------------------------------------------------
// Invoice
// ---------------------------------------------------------------------------

export const invoicePaymentSchema = z.object({
  kind: zPaymentKind,
  method: zPaymentMethod,
  status: zPaymentStatus,
  /** A bank / pay-later payment still clearing (not in the balance yet). */
  processing: z
    .boolean()
    .nullish()
    .transform((v) => v ?? false),
  amount_cents: zCentsValue,
  tip_cents: zCentsValue.nullish().transform((v) => v ?? 0),
  refunded_cents: zCentsValue.nullish().transform((v) => v ?? 0),
  card_brand: zText,
  card_last4: zText,
  paid_at: zText,
});
export type InvoicePayment = z.output<typeof invoicePaymentSchema>;

/** An invoice line; job_number groups a grouped invoice's lines by job. */
export const invoiceLineSchema = publicLineSchema.extend({ job_number: zIntOrNull });
export type InvoiceLine = z.output<typeof invoiceLineSchema>;

export const invoiceDocumentSchema = z.object({
  shop: publicShopSchema,
  invoice: z.object({
    number: z.number().int(),
    status: zInvoiceStatus,
    issued_at: zText,
    due_at: zText,
    paid_at: zText,
    voided_at: zText,
    notes: zText,
    terms: zText,
    subtotal_cents: zCentsValue,
    discount_cents: zCentsValue,
    tax_rate_bps: zIntOrNull,
    tax_cents: zCentsValue,
    total_cents: zCentsValue,
    amount_paid_cents: zCentsValue,
    balance_cents: zCentsValue,
    tip_cents: zCentsValue,
    /** Money on bank / pay-later payments still clearing. */
    processing_cents: zCentsValue.nullish().transform((v) => v ?? 0),
    /** Open with a balance that clearing payments don't already cover. */
    payable: z.boolean(),
    /** Payable and the shop has gift cards / store credit that could pay it. */
    gift_card_redeemable: z
      .boolean()
      .nullish()
      .transform((v) => v ?? false),
    card_payments_enabled: z.boolean(),
  }),
  customer: publicCustomerSchema,
  job: z
    .object({ number: z.number().int(), scheduled_start: zText, scheduled_end: zText })
    .nullish()
    .transform((v) => v ?? null),
  vehicle: publicVehicleSchema,
  /** Every job the invoice bills (grouped invoices list several). */
  jobs: z
    .array(z.object({ number: z.number().int(), date: zText, vehicle_label: zText }))
    .nullish()
    .transform((v) => v ?? []),
  line_items: z.array(invoiceLineSchema),
  payments: z.array(invoicePaymentSchema),
});
export type InvoiceDocument = z.output<typeof invoiceDocumentSchema>;

export function usePublicInvoice(token: string, options: { pollForPayment?: boolean } = {}) {
  const queryClient = useQueryClient();
  const query = useQuery({
    queryKey: publicDocKeys.invoice(token),
    queryFn: async () =>
      parseDocument(
        invoiceDocumentSchema,
        unwrap(await supabase.rpc('public_get_invoice', { p_token: token })),
      ),
    retry: retryTransient,
    refetchInterval: (query) => {
      if (!options.pollForPayment) return false;
      const doc = query.state.data;
      if (doc && (doc.invoice.status === 'paid' || !doc.invoice.payable)) return false;
      return query.state.dataUpdateCount < PAID_POLL_ATTEMPTS ? PAID_POLL_INTERVAL_MS : false;
    },
  });
  /** How many times the document has been loaded (drives the ?paid=1 polling UI). */
  const loads = queryClient.getQueryState(publicDocKeys.invoice(token))?.dataUpdateCount ?? 0;
  return { query, loads };
}

/** Creates a Checkout session for the balance (+ tip) and leaves for Stripe. */
export function useInvoiceCheckout(token: string) {
  return useMutation({
    mutationFn: async (tipCents: number) => {
      const session = await createCheckout({ action: 'invoice_checkout', token, tipCents });
      navigation.assign(session.url);
      return session;
    },
  });
}

export const giftCardResultSchema = z.object({
  redeemed: z.boolean(),
  message: zText,
  amount_cents: zCentsValue.nullish().transform((v) => v ?? 0),
  remaining_cents: zIntOrNull,
  last4: zText,
});
export type GiftCardResult = z.output<typeof giftCardResultSchema>;

const redeemResponseSchema = invoiceDocumentSchema.extend({
  gift_card_result: giftCardResultSchema,
});

/** The "(until 3:45 PM)" of a checkout_open refusal (shop time), or null. */
export function checkoutOpenUntil(error: unknown): string | null {
  return /\(until ([^)]+)\)/.exec(toAppError(error).message)?.[1] ?? null;
}

/**
 * public_redeem_gift_card's checkout_open refusal is worded for staff
 * ("cancel the open payments first"). The customer's way out is to finish
 * paying on the card page, or to close it from here (useCancelInvoiceCheckout,
 * which the gift card panel offers next to this message).
 */
export function checkoutOpenForCustomer(error: unknown): AppError {
  const until = checkoutOpenUntil(error);
  return new AppError(
    `A card payment page for this invoice is still open${
      until ? ` (until ${until})` : ''
    }. Finish paying there, or close that page to use your gift card now.`,
    { kind: 'conflict', code: '55000', cause: error },
  );
}

/**
 * payments `invoice_checkout_cancel` (PUBLIC by invoice token): expires the
 * invoice's open card payment pages (the Checkout Sessions invoice_checkout
 * opened for this /i link) and releases their holds, so a gift card or store
 * credit can pay the invoice right away instead of after the ~30-40 minutes
 * Stripe keeps a page alive. Staff payment sheets and terminal payments are
 * not the customer's to close and stay untouched. The edge refuses (409
 * payment_in_progress) when one of the pages was just paid.
 */
export async function cancelInvoiceCheckout(token: string): Promise<void> {
  let response: Awaited<ReturnType<typeof supabase.functions.invoke<unknown>>>;
  try {
    response = await supabase.functions.invoke<unknown>('payments', {
      body: { action: 'invoice_checkout_cancel', token },
    });
  } catch (error) {
    throw await edgeFunctionError(error);
  }
  if (response.error) throw await edgeFunctionError(response.error);
}

/** cancelInvoiceCheckout, then the invoice is read again (its payability may have moved). */
export function useCancelInvoiceCheckout(token: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: () => cancelInvoiceCheckout(token),
    onSettled: () => queryClient.invalidateQueries({ queryKey: publicDocKeys.invoice(token) }),
  });
}

/**
 * payments `deposit_checkout_cancel` by invoice token: closes the open
 * deposit card pages of the jobs this invoice bills (opened from the booking
 * or quote link, which invoice_checkout_cancel leaves alone), then reads the
 * invoice again.
 */
export function useCancelInvoiceDepositCheckout(token: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: () => cancelDepositCheckout({ invoiceToken: token }),
    onSettled: () => queryClient.invalidateQueries({ queryKey: publicDocKeys.invoice(token) }),
  });
}

/**
 * public_redeem_gift_card: pays the invoice from a gift card (or the
 * customer's store credit, by its code). A wrong or unusable code is an
 * answer (redeemed false + message), not an error; PT429 after too many.
 */
export function useRedeemInvoiceGiftCard(token: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (input: { code: string; amountCents: number | null }) => {
      const result = await supabase.rpc('public_redeem_gift_card', {
        p_token: token,
        p_code: input.code,
        ...(input.amountCents !== null ? { p_amount_cents: input.amountCents } : {}),
      });
      if (result.error && isCheckoutOpenError(result.error)) {
        throw checkoutOpenForCustomer(result.error);
      }
      const data = unwrap(result);
      const { gift_card_result, ...doc } = parseDocument(redeemResponseSchema, data);
      queryClient.setQueryData(publicDocKeys.invoice(token), doc);
      return gift_card_result;
    },
    onError: () => {
      void queryClient.invalidateQueries({ queryKey: publicDocKeys.invoice(token) });
    },
  });
}

// ---------------------------------------------------------------------------
// Form
// ---------------------------------------------------------------------------

export const formDocumentSchema = z.object({
  shop: z.object({
    name: z.string(),
    slug: z.string(),
    logo_path: zText,
    brand_color: zText,
    timezone: z.string(),
  }),
  form: z.object({
    title: z.string(),
    body: z.string(),
    requires_signature: z.boolean(),
    status: z.enum(['pending', 'signed', 'void']),
    signer_name: zText,
    signed_at: zText,
  }),
  job: z
    .object({
      number: z.number().int(),
      scheduled_start: zText,
      scheduled_end: zText,
      vehicle: zText,
    })
    .nullish()
    .transform((v) => v ?? null),
  customer: publicCustomerSchema,
  signature_upload_prefix: zText,
});
export type FormDocument = z.output<typeof formDocumentSchema>;

export function usePublicForm(token: string) {
  return useQuery({
    queryKey: publicDocKeys.form(token),
    queryFn: async () =>
      parseDocument(
        formDocumentSchema,
        unwrap(await supabase.rpc('public_get_form', { p_token: token })),
      ),
    retry: retryTransient,
    refetchOnWindowFocus: false,
  });
}

/**
 * Object name for a public signature upload: directly inside the folder the
 * server published ("<shop_id>/forms/<token>/"), which is exactly what the
 * `field_ops_signatures_insert_public_form` storage policy and
 * public_sign_form accept.
 */
export function signatureObjectPath(prefix: string): string {
  const folder = prefix.endsWith('/') ? prefix : `${prefix}/`;
  return `${folder}signature-${crypto.randomUUID()}.png`;
}

export interface SignFormInput {
  signerName: string;
  /** PNG of the drawn signature (required when the form requires one). */
  signature: Blob | null;
  /** From the form document; null once signed. */
  uploadPrefix: string | null;
}

export function useSignForm(token: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async ({ signerName, signature, uploadPrefix }: SignFormInput) => {
      let path: string | undefined;
      if (signature) {
        if (!uploadPrefix) {
          throw new AppError('This form can no longer be signed.', { kind: 'validation' });
        }
        path = signatureObjectPath(uploadPrefix);
        const upload = await supabase.storage.from('signatures').upload(path, signature, {
          contentType: 'image/png',
          upsert: false,
          cacheControl: '3600',
        });
        if (upload.error) {
          throw new AppError(
            'Your signature could not be saved. Check your connection and try again.',
            { kind: 'server', cause: upload.error },
          );
        }
      }
      const data = unwrap(
        await supabase.rpc('public_sign_form', {
          p_token: token,
          p_signer_name: signerName,
          ...(path ? { p_signature_path: path } : {}),
        }),
      );
      return parseDocument(formDocumentSchema, data);
    },
    onSuccess: (doc) => {
      queryClient.setQueryData(publicDocKeys.form(token), doc);
    },
    onError: () => {
      void queryClient.invalidateQueries({ queryKey: publicDocKeys.form(token) });
    },
  });
}
