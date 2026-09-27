/**
 * Public document pages (/q/:token, /i/:token, /f/:token). Anonymous
 * visitors reach data only through the token-keyed SECURITY DEFINER RPCs
 * (0014 public_get_quote / public_respond_quote / public_get_invoice, 0023
 * public_get_form / public_sign_form) and the payments edge function.
 */
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { z } from 'zod';
import { unwrap } from '@/lib/db';
import { AppError, toAppError } from '@/lib/errors';
import { publicKey } from '@/lib/queryKeys';
import { supabase } from '@/lib/supabase';
import { createCheckout, navigation } from './shared/checkout';
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
  invoice: (token: string) => publicKey('invoice', token),
  form: (token: string) => publicKey('form', token),
};

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
});
export type QuoteLine = z.output<typeof quoteLineSchema>;

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
  }),
  customer: publicCustomerSchema,
  vehicle: publicVehicleSchema,
  line_items: z.array(quoteLineSchema),
});
export type QuoteDocument = z.output<typeof quoteDocumentSchema>;

export function usePublicQuote(token: string) {
  return useQuery({
    queryKey: publicDocKeys.quote(token),
    queryFn: async () =>
      parseDocument(
        quoteDocumentSchema,
        unwrap(await supabase.rpc('public_get_quote', { p_token: token })),
      ),
    retry: retryTransient,
    // public_get_quote marks the quote viewed; no need to hammer it.
    refetchOnWindowFocus: false,
  });
}

export type QuoteResponse =
  | { action: 'approve'; signerName: string; selectedOptionalIds: string[] }
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
// Invoice
// ---------------------------------------------------------------------------

export const invoicePaymentSchema = z.object({
  kind: zPaymentKind,
  method: zPaymentMethod,
  status: zPaymentStatus,
  amount_cents: zCentsValue,
  tip_cents: zCentsValue.nullish().transform((v) => v ?? 0),
  refunded_cents: zCentsValue.nullish().transform((v) => v ?? 0),
  card_brand: zText,
  card_last4: zText,
  paid_at: zText,
});
export type InvoicePayment = z.output<typeof invoicePaymentSchema>;

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
    payable: z.boolean(),
    card_payments_enabled: z.boolean(),
  }),
  customer: publicCustomerSchema,
  job: z
    .object({ number: z.number().int(), scheduled_start: zText, scheduled_end: zText })
    .nullish()
    .transform((v) => v ?? null),
  vehicle: publicVehicleSchema,
  line_items: z.array(publicLineSchema),
  payments: z.array(invoicePaymentSchema),
});
export type InvoiceDocument = z.output<typeof invoiceDocumentSchema>;

/** Polling after Stripe redirects back with ?paid=1 (the webhook lands asynchronously). */
export const PAID_POLL_INTERVAL_MS = 2500;
export const PAID_POLL_ATTEMPTS = 8;

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
