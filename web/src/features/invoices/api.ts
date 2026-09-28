/**
 * Invoices data layer (SPEC §4.5). Numbering, totals, amount paid, balance
 * and status are computed by the invoices_* triggers from lines and
 * payments; this module writes content (due date, notes, discount, lines),
 * calls the RPCs (create_invoice, mark_invoice_sent, record_manual_payment,
 * refund_manual_payment, void_invoice) and the `payments` edge function for
 * card money (charge_saved_card, refund, cancel_open_payments). Nothing money-related is computed
 * here.
 */
import { keepPreviousData, useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { z } from 'zod';
import { pageRange } from '@/components/ui';
import { unwrap, unwrapRequired, type Row, type UpdateRow } from '@/lib/db';
import { errorMessage } from '@/lib/errors';
import { shopKey } from '@/lib/queryKeys';
import { supabase } from '@/lib/supabase';
import { useShop } from '@/features/shop/shopContext';
import { unwrapList } from '@/features/quotes/shared/db';
import { EdgeFunctionError, invokeEdge } from '@/features/quotes/shared/edge';
import { escapeLike, newRequestNonce, parseDocNumber } from '@/features/quotes/shared/format';
import {
  nextSorts,
  type DocLine,
  type LineDraft,
  type LinePatch,
} from '@/features/quotes/shared/lines';
import type { Enums } from '@/features/quotes/shared/types';
import { isStripeMethod, type ManualMethod } from '@/features/payments/paymentFormat';
import { formatCents, sumCents } from '@/lib/money';

export type InvoiceStatus = Enums['invoice_status'];
/**
 * An invoice as staff read it: every column except public_token, the
 * customer's /i link credential (not readable by staff; managers+ get it
 * from `useInvoiceLinkToken`).
 */
export type InvoiceRow = Omit<Row<'invoices'>, 'public_token'>;
export type InvoicePayment = Row<'payments'>;
export type SavedCard = Pick<
  Row<'customer_payment_methods'>,
  'id' | 'stripe_payment_method_id' | 'brand' | 'last4' | 'exp_month' | 'exp_year' | 'is_default'
>;

export const INVOICE_PAGE_SIZE = 25;

export type InvoiceStatusFilter = 'all' | 'draft' | 'open' | 'overdue' | 'paid' | 'void';

export interface InvoiceFilters {
  status: InvoiceStatusFilter;
  search: string;
  page: number;
}

export const invoiceKeys = {
  all: (shopId: string) => shopKey(shopId, 'invoices'),
  list: (shopId: string, filters: InvoiceFilters) =>
    [...invoiceKeys.all(shopId), 'list', filters] as const,
  detail: (shopId: string, id: string) => [...invoiceKeys.all(shopId), 'detail', id] as const,
  lines: (shopId: string, id: string) => [...invoiceKeys.all(shopId), 'lines', id] as const,
  payments: (shopId: string, id: string) => [...invoiceKeys.all(shopId), 'payments', id] as const,
  cards: (shopId: string, customerId: string) =>
    [...invoiceKeys.all(shopId), 'cards', customerId] as const,
  jobs: (shopId: string, id: string) => [...invoiceKeys.all(shopId), 'jobs', id] as const,
  credits: (shopId: string, customerId: string) =>
    [...invoiceKeys.all(shopId), 'credits', customerId] as const,
  unbilled: (shopId: string, customerId: string) =>
    [...invoiceKeys.all(shopId), 'unbilled', customerId] as const,
};

/** Open or partially paid with a balance and a due date in the past. */
export function isInvoiceOverdue(
  invoice: Pick<InvoiceRow, 'status' | 'due_at' | 'balance_cents'>,
  now: Date = new Date(),
): boolean {
  return (
    (invoice.status === 'open' || invoice.status === 'partially_paid') &&
    invoice.balance_cents > 0 &&
    invoice.due_at !== null &&
    new Date(invoice.due_at).getTime() < now.getTime()
  );
}

/**
 * Lines and pricing change only while no money has been received and the
 * invoice is not void (invoice_line_items_guard / invoices_client_guard).
 */
export function areInvoiceLinesEditable(
  invoice: Pick<InvoiceRow, 'status' | 'amount_paid_cents'>,
): boolean {
  return (
    invoice.amount_paid_cents === 0 &&
    (invoice.status === 'draft' || invoice.status === 'open' || invoice.status === 'paid')
  );
}

const customerEmbed = z
  .object({
    id: z.string(),
    first_name: z.string().nullable(),
    last_name: z.string().nullable(),
    company: z.string().nullable(),
  })
  .nullable();

const invoiceListRowSchema = z.object({
  id: z.string(),
  number: z.number(),
  status: z.enum(['draft', 'open', 'partially_paid', 'paid', 'void']),
  customer_id: z.string(),
  job_id: z.string().nullable(),
  issued_at: z.string().nullable(),
  due_at: z.string().nullable(),
  total_cents: z.number(),
  balance_cents: z.number(),
  created_at: z.string(),
  customer: customerEmbed,
});

export type InvoiceListRow = z.infer<typeof invoiceListRowSchema>;

const INVOICE_LIST_COLUMNS =
  'id, number, status, customer_id, job_id, issued_at, due_at, total_cents, balance_cents, created_at, customer:customers(id, first_name, last_name, company)';

export function useInvoices(filters: InvoiceFilters) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: invoiceKeys.list(shopId, filters),
    placeholderData: keepPreviousData,
    queryFn: async (): Promise<{ rows: InvoiceListRow[]; total: number }> => {
      let request = supabase
        .from('invoices')
        .select(INVOICE_LIST_COLUMNS, { count: 'exact' })
        .eq('shop_id', shopId);
      switch (filters.status) {
        case 'all':
          break;
        case 'open':
          request = request.in('status', ['open', 'partially_paid']);
          break;
        case 'overdue':
          request = request
            .in('status', ['open', 'partially_paid'])
            .gt('balance_cents', 0)
            .lt('due_at', new Date().toISOString());
          break;
        default:
          request = request.eq('status', filters.status);
      }
      const term = filters.search.trim();
      if (term) {
        const number = parseDocNumber(term);
        if (number !== null) {
          request = request.eq('number', number);
        } else {
          const customers = unwrapList(
            await supabase
              .from('customers')
              .select('id')
              .eq('shop_id', shopId)
              .ilike('search_text', `%${escapeLike(term.toLowerCase())}%`)
              .limit(200),
          );
          if (customers.length === 0) return { rows: [], total: 0 };
          request = request.in(
            'customer_id',
            customers.map((c) => c.id),
          );
        }
      }
      const { from, to } = pageRange(filters.page, INVOICE_PAGE_SIZE);
      const { data, error, count } = await request
        .order('created_at', { ascending: false })
        .range(from, to);
      const rows = z.array(invoiceListRowSchema).parse(unwrap({ data, error }) ?? []);
      return { rows, total: count ?? rows.length };
    },
  });
}

const INVOICE_COLUMNS =
  'id, shop_id, number, job_id, customer_id, status, issued_at, due_at, sent_at, paid_at, voided_at, void_reason, notes, terms, internal_notes, discount_kind, discount_value, tax_rate_bps, subtotal_cents, discount_cents, tax_cents, total_cents, amount_paid_cents, balance_cents, tip_cents, created_by, created_at, updated_at';

export function useInvoice(invoiceId: string) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: invoiceKeys.detail(shopId, invoiceId),
    queryFn: async (): Promise<InvoiceRow> =>
      unwrapRequired(
        await supabase
          .from('invoices')
          .select(INVOICE_COLUMNS)
          .eq('shop_id', shopId)
          .eq('id', invoiceId)
          .maybeSingle(),
        'invoice',
      ),
  });
}

/**
 * The customer's /i/<token> pay-link credential (invoice_link_token):
 * owners/admins/managers only — pass `enabled` false for everyone else.
 */
export function useInvoiceLinkToken(invoiceId: string, enabled: boolean) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: [...invoiceKeys.detail(shopId, invoiceId), 'link-token'] as const,
    enabled,
    staleTime: Infinity,
    queryFn: async (): Promise<string> =>
      unwrapRequired(
        await supabase.rpc('invoice_link_token', { p_invoice_id: invoiceId }),
        'invoice',
      ),
  });
}

export function useInvoiceLines(invoiceId: string) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: invoiceKeys.lines(shopId, invoiceId),
    queryFn: async (): Promise<DocLine[]> =>
      unwrapList(
        await supabase
          .from('invoice_line_items')
          .select('*')
          .eq('shop_id', shopId)
          .eq('invoice_id', invoiceId)
          .order('sort', { ascending: true })
          .order('created_at', { ascending: true }),
      ).map((row) => ({
        id: row.id,
        service_id: row.service_id,
        vehicle_id: row.vehicle_id,
        name: row.name,
        description: row.description,
        quantity: row.quantity,
        unit_price_cents: row.unit_price_cents,
        discount_cents: row.discount_cents,
        taxable: row.taxable,
        total_cents: row.total_cents,
        sort: row.sort,
        optional: false,
        selected: true,
        duration_minutes: 0,
        discount_eligible: row.discount_eligible ?? true,
        fee_id: row.fee_id ?? null,
        option_id: null,
        job_id: row.job_id ?? null,
      })),
  });
}

export function useInvoicePayments(invoiceId: string) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: invoiceKeys.payments(shopId, invoiceId),
    queryFn: async (): Promise<InvoicePayment[]> =>
      unwrapList(
        await supabase
          .from('payments')
          .select('*')
          .eq('shop_id', shopId)
          .eq('invoice_id', invoiceId)
          .order('created_at', { ascending: false }),
      ),
  });
}

/** Saved cards (manager+; RLS returns nothing to technicians). */
export function useSavedCards(customerId: string | null, enabled: boolean) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: invoiceKeys.cards(shopId, customerId ?? ''),
    enabled: enabled && Boolean(customerId),
    queryFn: async (): Promise<SavedCard[]> =>
      unwrapList(
        await supabase
          .from('customer_payment_methods')
          .select('id, stripe_payment_method_id, brand, last4, exp_month, exp_year, is_default')
          .eq('shop_id', shopId)
          .eq('customer_id', customerId ?? '')
          .order('is_default', { ascending: false })
          .order('created_at', { ascending: false }),
      ),
  });
}

/** Invalidate everything a money change can touch (invoice, payments, jobs, customers). */
function useInvalidateMoney() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return () =>
    Promise.all([
      queryClient.invalidateQueries({ queryKey: invoiceKeys.all(shopId) }),
      queryClient.invalidateQueries({ queryKey: shopKey(shopId, 'payments') }),
      queryClient.invalidateQueries({ queryKey: shopKey(shopId, 'jobs') }),
      queryClient.invalidateQueries({ queryKey: shopKey(shopId, 'reports') }),
    ]);
}

export function useCreateInvoice() {
  const invalidate = useInvalidateMoney();
  return useMutation({
    mutationFn: async (input: { customerId: string; notes: string | null }) =>
      unwrapRequired(
        await supabase.rpc('create_invoice', {
          p_customer_id: input.customerId,
          p_lines: [],
          ...(input.notes ? { p_notes: input.notes } : {}),
        }),
        'invoice',
      ),
    onSettled: invalidate,
  });
}

export type InvoicePatch = Pick<
  UpdateRow<'invoices'>,
  'due_at' | 'notes' | 'terms' | 'internal_notes' | 'discount_kind' | 'discount_value'
>;

export function useUpdateInvoice(invoiceId: string) {
  const { shopId } = useShop();
  const invalidate = useInvalidateMoney();
  return useMutation({
    mutationFn: async (patch: InvoicePatch) =>
      unwrapRequired(
        await supabase
          .from('invoices')
          .update(patch)
          .eq('shop_id', shopId)
          .eq('id', invoiceId)
          .select(INVOICE_COLUMNS)
          .maybeSingle(),
        'invoice',
      ),
    onSettled: invalidate,
  });
}

export function useDeleteInvoice() {
  const { shopId } = useShop();
  const invalidate = useInvalidateMoney();
  return useMutation({
    mutationFn: async (invoiceId: string) => {
      unwrap(await supabase.from('invoices').delete().eq('shop_id', shopId).eq('id', invoiceId));
    },
    onSettled: invalidate,
  });
}

export function useInvoiceLineMutations(invoiceId: string, lines: readonly DocLine[]) {
  const { shopId } = useShop();
  const invalidate = useInvalidateMoney();
  const add = useMutation({
    mutationFn: async (drafts: LineDraft[]) => {
      const sorts = nextSorts(lines, drafts.length);
      unwrap(
        await supabase.from('invoice_line_items').insert(
          drafts.map((d, i) => ({
            shop_id: shopId,
            invoice_id: invoiceId,
            service_id: d.service_id,
            name: d.name,
            description: d.description,
            quantity: d.quantity,
            unit_price_cents: d.unit_price_cents,
            discount_cents: d.discount_cents,
            taxable: d.taxable,
            vehicle_id: d.vehicle_id ?? null,
            sort: sorts[i] ?? i + 1,
          })),
        ),
      );
    },
    onSettled: invalidate,
  });
  const update = useMutation({
    mutationFn: async ({ id, patch }: { id: string; patch: LinePatch }) => {
      const next: UpdateRow<'invoice_line_items'> = {
        ...(patch.name !== undefined ? { name: patch.name } : {}),
        ...(patch.description !== undefined ? { description: patch.description } : {}),
        ...(patch.quantity !== undefined ? { quantity: patch.quantity } : {}),
        ...(patch.unit_price_cents !== undefined
          ? { unit_price_cents: patch.unit_price_cents }
          : {}),
        ...(patch.discount_cents !== undefined ? { discount_cents: patch.discount_cents } : {}),
        ...(patch.taxable !== undefined ? { taxable: patch.taxable } : {}),
        ...(patch.vehicle_id !== undefined ? { vehicle_id: patch.vehicle_id } : {}),
      };
      unwrap(
        await supabase.from('invoice_line_items').update(next).eq('shop_id', shopId).eq('id', id),
      );
    },
    onSettled: invalidate,
  });
  const remove = useMutation({
    mutationFn: async (id: string) => {
      unwrap(await supabase.from('invoice_line_items').delete().eq('shop_id', shopId).eq('id', id));
    },
    onSettled: invalidate,
  });
  return { add, update, remove };
}

export function useMarkInvoiceSent(invoiceId: string) {
  const invalidate = useInvalidateMoney();
  return useMutation({
    mutationFn: async () =>
      unwrapRequired(
        await supabase.rpc('mark_invoice_sent', { p_invoice_id: invoiceId }),
        'invoice',
      ),
    onSettled: invalidate,
  });
}

export interface ManualPaymentInput {
  amountCents: number;
  method: ManualMethod;
  tipCents: number;
  note: string | null;
}

export function useRecordManualPayment(invoiceId: string) {
  const invalidate = useInvalidateMoney();
  return useMutation({
    mutationFn: async (input: ManualPaymentInput) =>
      unwrapRequired(
        await supabase.rpc('record_manual_payment', {
          p_invoice_id: invoiceId,
          p_amount_cents: input.amountCents,
          p_method: input.method,
          p_tip_cents: input.tipCents,
          ...(input.note ? { p_note: input.note } : {}),
        }),
        'payment',
      ),
    onSettled: invalidate,
  });
}

export function useVoidInvoice(invoiceId: string) {
  const invalidate = useInvalidateMoney();
  return useMutation({
    mutationFn: async (reason: string | null) =>
      unwrapRequired(
        await supabase.rpc('void_invoice', {
          p_invoice_id: invoiceId,
          ...(reason ? { p_reason: reason } : {}),
        }),
        'invoice',
      ),
    onSettled: invalidate,
  });
}

export const chargeResultSchema = z.object({
  payment_id: z.string().nullable(),
  payment_intent_id: z.string(),
  status: z.enum(['succeeded', 'processing']),
  amount_cents: z.number().int(),
  card_brand: z.string().nullable(),
  card_last4: z.string().nullable(),
});

export interface ChargeCardInput {
  paymentMethodId: string;
  amountCents: number;
  /** Idempotency nonce: reuse for a retry of the same attempt. */
  nonce: string;
}

/** payments.charge_saved_card (manager+). Declines come back as EdgeFunctionError. */
export function useChargeSavedCard(invoiceId: string) {
  const { shopId } = useShop();
  const invalidate = useInvalidateMoney();
  return useMutation({
    mutationFn: (input: ChargeCardInput) =>
      invokeEdge(
        'payments',
        'charge_saved_card',
        {
          shop_id: shopId,
          invoice_id: invoiceId,
          payment_method_id: input.paymentMethodId,
          amount_cents: input.amountCents,
          request_nonce: input.nonce,
        },
        chargeResultSchema,
      ),
    onSettled: invalidate,
  });
}

export const cancelOpenPaymentsResultSchema = z.object({
  /** The released invoice (null for a job without a non-void invoice). */
  invoice_id: z.string().nullable(),
  /** Set when a job was released (or the invoice belongs to a job). */
  job_id: z.string().nullable().optional(),
  cancelled: z.number().int(),
  succeeded: z.number().int(),
  in_progress: z.number().int(),
  sessions_expired: z.number().int(),
});

export type CancelOpenPaymentsResult = z.infer<typeof cancelOpenPaymentsResultSchema>;

/**
 * payments.cancel_open_payments (manager+ in the UI): cancels the invoice's
 * unconfirmed card sheets and expires its open Checkout links, releasing the
 * hold that blocks void / line / discount edits and saved-card charges.
 * Payments already processing are reported (in_progress), never cancelled;
 * ones that already took the money are recorded (succeeded).
 */
export function useCancelOpenPayments(invoiceId: string) {
  const { shopId } = useShop();
  const invalidate = useInvalidateMoney();
  return useMutation({
    mutationFn: () =>
      invokeEdge(
        'payments',
        'cancel_open_payments',
        { shop_id: shopId, invoice_id: invoiceId },
        cancelOpenPaymentsResultSchema,
      ),
    onSettled: invalidate,
  });
}

const plural = (n: number, one: string, many: string) => `${n} ${n === 1 ? one : many}`;

/** Toast text for a cancel_open_payments result. */
export function cancelOpenPaymentsSummary(result: CancelOpenPaymentsResult): {
  title: string;
  description?: string;
} {
  const notes: string[] = [];
  if (result.succeeded > 0) {
    notes.push(
      `${plural(result.succeeded, 'payment had already gone through and was', 'payments had already gone through and were')} recorded.`,
    );
  }
  if (result.in_progress > 0) {
    notes.push(
      `${plural(result.in_progress, 'payment is', 'payments are')} still being processed by the bank and can’t be cancelled; the invoice updates when it finishes.`,
    );
  }
  if (result.sessions_expired > 0) {
    notes.push(
      `${plural(result.sessions_expired, 'open pay link was', 'open pay links were')} expired.`,
    );
  }
  const title =
    result.cancelled > 0
      ? `${plural(result.cancelled, 'open payment', 'open payments')} cancelled`
      : result.in_progress > 0
        ? 'A payment is still processing'
        : 'No open payments to cancel';
  return notes.length > 0 ? { title, description: notes.join(' ') } : { title };
}

/**
 * Mirrors public.payment_in_flight (0064): a bank / pay-later payment still
 * 'processing', or a pending card payment started within the last hour.
 */
export const PAYMENT_IN_FLIGHT_MS = 60 * 60 * 1000;

export function isPaymentInFlight(
  payment: Pick<InvoicePayment, 'status' | 'created_at'>,
  now: Date = new Date(),
): boolean {
  if (payment.status === 'processing') return true;
  return (
    payment.status === 'pending' &&
    now.getTime() - new Date(payment.created_at).getTime() < PAYMENT_IN_FLIGHT_MS
  );
}

/** A pending card payment in flight (the one staff can cancel), not a clearing bank payment. */
export function isCardAttemptInFlight(
  payment: Pick<InvoicePayment, 'status' | 'created_at'>,
  now: Date = new Date(),
): boolean {
  return payment.status === 'pending' && isPaymentInFlight(payment, now);
}

/**
 * Money on bank / pay-later payments still clearing ('processing'). It is not
 * in amount_paid_cents yet; used only to tell staff the balance is already
 * covered (the server applies the same rule when taking payments).
 */
export function processingCents(
  payments: readonly Pick<InvoicePayment, 'status' | 'amount_cents'>[],
) {
  return sumCents(payments.filter((p) => p.status === 'processing').map((p) => p.amount_cents));
}

/**
 * Money in flight toward the invoice (isPaymentInFlight: clearing bank /
 * pay-later payments and pending card attempts under an hour old).
 * record_manual_payment and redeem_gift_card (0064 / 0066) accept at most the
 * balance less this amount.
 */
export function inFlightCents(
  payments: readonly Pick<InvoicePayment, 'status' | 'created_at' | 'amount_cents'>[],
  now: Date = new Date(),
) {
  return sumCents(payments.filter((p) => isPaymentInFlight(p, now)).map((p) => p.amount_cents));
}

/** What can still be collected now: the balance less the given money in flight, never below 0. */
export function collectibleCents(balanceCents: number, heldCents: number) {
  return Math.max(0, balanceCents - Math.max(0, heldCents));
}

/** "Balance due: $X", or the collectible amount and why it is less than the balance. */
export function collectibleHelp(collectible: number, heldCents: number, currency: string) {
  if (heldCents <= 0) return `Balance due: ${formatCents(collectible, { currency })}`;
  return `Up to ${formatCents(collectible, { currency })} — ${formatCents(heldCents, { currency })} is still clearing or in progress`;
}

/**
 * Whether a failure was the server refusing because a card payment is in
 * flight on the invoice (line/discount guards, void_invoice, the payments
 * function's payment_in_progress conflict).
 */
export function isPaymentInProgressError(error: unknown): boolean {
  if (error instanceof EdgeFunctionError && error.reason === 'payment_in_progress') return true;
  return /payment is in progress on this invoice/i.test(errorMessage(error));
}

/** 55000 checkout_open (a card payment page is still open): see lib/errors. */
export { isCheckoutOpenError } from '@/lib/errors';

export const refundResultSchema = z.object({
  payment_id: z.string(),
  refund_id: z.string(),
  refund_status: z.string().nullable(),
  amount_cents: z.number().int(),
  refunded_cents_total: z.number().int(),
  payment_status: z.string().nullable(),
});

export interface RefundInput {
  payment: Pick<InvoicePayment, 'id' | 'method'>;
  amountCents: number;
  /**
   * Idempotency nonce of this refund attempt (card refunds). Reuse it only to
   * retry the same attempt after a network/server failure; a new refund gets
   * a new one, so a second partial refund of the same amount is never taken
   * for a replay of the first.
   */
  nonce: string;
}

/**
 * Owner/admin refunds: Stripe-backed payments (card, card present, bank
 * debit, pay later) through Stripe (payments.refund); cash / check / bank
 * transfer / other through refund_manual_payment, which also puts a gift
 * card payment back on its card.
 */
export function useRefundPayment() {
  const { shopId } = useShop();
  const invalidate = useInvalidateMoney();
  return useMutation({
    mutationFn: async ({ payment, amountCents, nonce }: RefundInput) => {
      if (isStripeMethod(payment.method)) {
        await invokeEdge(
          'payments',
          'refund',
          {
            shop_id: shopId,
            payment_id: payment.id,
            amount_cents: amountCents,
            request_nonce: nonce,
          },
          refundResultSchema,
        );
        return;
      }
      unwrap(
        await supabase.rpc('refund_manual_payment', {
          p_payment_id: payment.id,
          p_amount_cents: amountCents,
        }),
      );
    },
    onSettled: invalidate,
  });
}

// ---------------------------------------------------------------------------
// Unapplied money → an invoice (apply_payment_to_invoice, manager+)
// ---------------------------------------------------------------------------

/** An issued invoice of the customer that can still take money. */
export type ApplicableInvoice = Pick<
  InvoiceRow,
  'id' | 'number' | 'status' | 'total_cents' | 'balance_cents' | 'due_at' | 'issued_at'
>;

/**
 * The customer's open / partially paid invoices with a balance: the targets
 * apply_payment_to_invoice accepts (it re-checks the customer, status and
 * that the payment fits the balance less card payments in flight).
 */
export function useApplicableInvoices(customerId: string, enabled: boolean) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: [...invoiceKeys.all(shopId), 'applicable', customerId] as const,
    enabled: enabled && Boolean(customerId),
    queryFn: async (): Promise<ApplicableInvoice[]> =>
      unwrapList(
        await supabase
          .from('invoices')
          .select('id, number, status, total_cents, balance_cents, due_at, issued_at')
          .eq('shop_id', shopId)
          .eq('customer_id', customerId)
          .in('status', ['open', 'partially_paid'])
          .gt('balance_cents', 0)
          .order('issued_at', { ascending: true })
          .limit(100),
      ),
  });
}

/**
 * Moves received money that pays nothing (an unapplied payment, kept on the
 * customer with a note) onto one of the customer's open invoices. The server
 * validates everything and appends "Applied to invoice #N" to the note.
 */
export function useApplyPaymentToInvoice() {
  const invalidate = useInvalidateMoney();
  return useMutation({
    mutationFn: async ({ paymentId, invoiceId }: { paymentId: string; invoiceId: string }) =>
      unwrapRequired(
        await supabase.rpc('apply_payment_to_invoice', {
          p_payment_id: paymentId,
          p_invoice_id: invoiceId,
        }),
        'payment',
      ),
    onSettled: invalidate,
  });
}

// ---------------------------------------------------------------------------
// Grouped invoices (P-7): the jobs an invoice bills
// ---------------------------------------------------------------------------

const invoiceJobSchema = z.object({
  job_id: z.string(),
  voided: z.boolean(),
  job: z
    .object({
      id: z.string(),
      number: z.number(),
      vehicle_id: z.string().nullable(),
      scheduled_start: z.string().nullable(),
      completed_at: z.string().nullable(),
    })
    .nullable(),
});
export type InvoiceJob = z.infer<typeof invoiceJobSchema>;

/** Jobs billed by the invoice (one for a job invoice, several for a grouped one). */
export function useInvoiceJobs(invoiceId: string) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: invoiceKeys.jobs(shopId, invoiceId),
    queryFn: async (): Promise<InvoiceJob[]> => {
      const { data, error } = await supabase
        .from('invoice_jobs')
        .select('job_id, voided, job:jobs(id, number, vehicle_id, scheduled_start, completed_at)')
        .eq('shop_id', shopId)
        .eq('invoice_id', invoiceId)
        .order('created_at', { ascending: true });
      const rows = z.array(invoiceJobSchema).parse(unwrap({ data, error }) ?? []);
      return rows.sort((a, b) => (a.job?.number ?? 0) - (b.job?.number ?? 0));
    },
  });
}

export const unbilledJobSchema = z.object({
  job_id: z.string(),
  number: z.number(),
  status: z.string(),
  scheduled_start: z.string().nullable(),
  completed_at: z.string().nullable(),
  vehicle_label: z.string().nullable(),
  total_cents: z.number().int(),
  paid_cents: z.number().int(),
});
export type UnbilledJob = z.infer<typeof unbilledJobSchema>;

/** A customer's jobs with no live invoice (unbilled_jobs, managers+). */
export function useUnbilledJobs(customerId: string, enabled: boolean) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: invoiceKeys.unbilled(shopId, customerId),
    enabled,
    queryFn: async (): Promise<UnbilledJob[]> =>
      z
        .array(unbilledJobSchema)
        .parse(unwrap(await supabase.rpc('unbilled_jobs', { p_customer_id: customerId })) ?? []),
  });
}

/** Most jobs one grouped invoice may bill (create_invoice_from_jobs). */
export const MAX_GROUPED_JOBS = 100;

/**
 * create_invoice_from_jobs (managers+): one issued invoice for 2..100 jobs of
 * the customer, lines grouped per job (every job must share a tax rate).
 */
export function useCreateInvoiceFromJobs(customerId: string) {
  const invalidate = useInvalidateMoney();
  return useMutation({
    mutationFn: async (input: { jobIds: string[]; notes?: string | null }) =>
      unwrapRequired<InvoiceRow>(
        await supabase.rpc('create_invoice_from_jobs', {
          p_customer_id: customerId,
          p_job_ids: input.jobIds,
          ...(input.notes ? { p_notes: input.notes } : {}),
        }),
        'invoice',
      ),
    onSettled: invalidate,
  });
}

// ---------------------------------------------------------------------------
// Gift cards & store credit as tender (P-13)
// ---------------------------------------------------------------------------

export const giftCardLookupSchema = z.object({
  gift_card_id: z.string(),
  kind: z.enum(['gift', 'credit']),
  last4: z.string(),
  balance_cents: z.number().int(),
  status: z.enum(['active', 'depleted', 'void', 'expired']),
  expires_at: z.string().nullable(),
});
export type GiftCardLookup = z.infer<typeof giftCardLookupSchema>;

/**
 * lookup_gift_card: the card behind a code (null = no card has it). The
 * server limits misses (PT429 after 10 an hour per user).
 */
export function useLookupGiftCard() {
  const { shopId } = useShop();
  return useMutation({
    mutationFn: async (code: string): Promise<GiftCardLookup | null> => {
      const data = unwrap(
        await supabase.rpc('lookup_gift_card', { p_shop_id: shopId, p_code: code }),
      );
      return data === null || data === undefined ? null : giftCardLookupSchema.parse(data);
    },
  });
}

/** redeem_gift_card: pays the invoice from the card; null = no card has that code. */
export function useRedeemGiftCard(invoiceId: string) {
  const invalidate = useInvalidateMoney();
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (input: { code: string; amountCents: number | null }) =>
      unwrap(
        await supabase.rpc('redeem_gift_card', {
          p_invoice_id: invoiceId,
          p_code: input.code,
          ...(input.amountCents !== null ? { p_amount_cents: input.amountCents } : {}),
        }),
      ),
    onSettled: () =>
      Promise.all([
        invalidate(),
        queryClient.invalidateQueries({ queryKey: shopKey(shopId, 'gift-cards') }),
      ]),
  });
}

export type StoreCredit = Pick<
  Row<'gift_cards'>,
  'id' | 'code_last4' | 'balance_cents' | 'expires_at' | 'created_at'
>;

/** The customer's usable store credit (gift_cards kind 'credit', managers+). */
export function useCustomerCredits(customerId: string, enabled: boolean) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: invoiceKeys.credits(shopId, customerId),
    enabled,
    queryFn: async (): Promise<StoreCredit[]> => {
      const rows = unwrapList(
        await supabase
          .from('gift_cards')
          .select('id, code_last4, balance_cents, expires_at, created_at')
          .eq('shop_id', shopId)
          .eq('kind', 'credit')
          .eq('owner_customer_id', customerId)
          .eq('status', 'active')
          .gt('balance_cents', 0)
          .order('created_at', { ascending: true }),
      );
      const now = Date.now();
      return rows.filter((r) => r.expires_at === null || new Date(r.expires_at).getTime() > now);
    },
  });
}

/** redeem_customer_credit: applies the customer's store credit (no code needed). */
export function useRedeemCustomerCredit(invoiceId: string) {
  const invalidate = useInvalidateMoney();
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (input: { giftCardId: string; amountCents: number | null }) =>
      unwrapRequired(
        await supabase.rpc('redeem_customer_credit', {
          p_invoice_id: invoiceId,
          p_gift_card_id: input.giftCardId,
          ...(input.amountCents !== null ? { p_amount_cents: input.amountCents } : {}),
        }),
        'payment',
      ),
    onSettled: () =>
      Promise.all([
        invalidate(),
        queryClient.invalidateQueries({ queryKey: shopKey(shopId, 'gift-cards') }),
      ]),
  });
}

export { newRequestNonce };
