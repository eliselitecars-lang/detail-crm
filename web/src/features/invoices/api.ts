/**
 * Invoices data layer (SPEC §4.5). Numbering, totals, amount paid, balance
 * and status are computed by the invoices_* triggers from lines and
 * payments; this module writes content (due date, notes, discount, lines),
 * calls the RPCs (create_invoice, mark_invoice_sent, record_manual_payment,
 * refund_manual_payment, void_invoice) and the `payments` edge function for
 * card money (charge_saved_card, refund). Nothing money-related is computed
 * here.
 */
import { keepPreviousData, useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { z } from 'zod';
import { pageRange } from '@/components/ui';
import { unwrap, unwrapRequired, type Row, type UpdateRow } from '@/lib/db';
import { shopKey } from '@/lib/queryKeys';
import { supabase } from '@/lib/supabase';
import { useShop } from '@/features/shop/shopContext';
import { unwrapList } from '@/features/quotes/shared/db';
import { invokeEdge } from '@/features/quotes/shared/edge';
import { escapeLike, newRequestNonce, parseDocNumber } from '@/features/quotes/shared/format';
import {
  nextSorts,
  type DocLine,
  type LineDraft,
  type LinePatch,
} from '@/features/quotes/shared/lines';
import type { Enums } from '@/features/quotes/shared/types';
import type { ManualMethod } from '@/features/payments/paymentFormat';

export type InvoiceStatus = Enums['invoice_status'];
export type InvoiceRow = Row<'invoices'>;
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

export function useInvoice(invoiceId: string) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: invoiceKeys.detail(shopId, invoiceId),
    queryFn: async (): Promise<InvoiceRow> =>
      unwrapRequired(
        await supabase
          .from('invoices')
          .select('*')
          .eq('shop_id', shopId)
          .eq('id', invoiceId)
          .maybeSingle(),
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
          .select('*')
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
}

/**
 * Owner/admin refunds: card payments through Stripe (payments.refund),
 * cash/check/bank/other through refund_manual_payment.
 */
export function useRefundPayment() {
  const { shopId } = useShop();
  const invalidate = useInvalidateMoney();
  return useMutation({
    mutationFn: async ({ payment, amountCents }: RefundInput) => {
      if (payment.method === 'card' || payment.method === 'card_present') {
        await invokeEdge(
          'payments',
          'refund',
          { shop_id: shopId, payment_id: payment.id, amount_cents: amountCents },
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

export { newRequestNonce };
