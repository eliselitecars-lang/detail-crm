/**
 * Payments ledger (manager+). Rows come straight from `payments` (card rows
 * are written by the webhook; manual rows by record_manual_payment); the
 * totals row comes from the report_payments RPC, which does the net/tip/
 * refund math server-side for the same shop-local date range.
 */
import { keepPreviousData, useQuery } from '@tanstack/react-query';
import { z } from 'zod';
import { pageRange } from '@/components/ui';
import { shopDateRangeUtc } from '@/lib/dates';
import { unwrap } from '@/lib/db';
import { sumCents } from '@/lib/money';
import { shopKey } from '@/lib/queryKeys';
import { supabase } from '@/lib/supabase';
import { useShop } from '@/features/shop/shopContext';
import { unwrapList } from '@/features/quotes/shared/db';
import {
  PAYMENT_KINDS,
  PAYMENT_METHODS,
  PAYMENT_STATUSES,
  type PaymentKind,
  type PaymentMethod,
  type PaymentStatus,
} from './paymentFormat';

export const LEDGER_PAGE_SIZE = 50;
/** CSV export cap (one request). */
export const EXPORT_LIMIT = 5000;

export interface LedgerFilters {
  /** Inclusive shop-local dates ("yyyy-MM-dd"). */
  from: string;
  to: string;
  method: PaymentMethod | 'all';
  status: PaymentStatus | 'all';
  kind: PaymentKind | 'all';
  page: number;
}

export const paymentKeys = {
  all: (shopId: string) => shopKey(shopId, 'payments'),
  ledger: (shopId: string, filters: LedgerFilters) =>
    [...paymentKeys.all(shopId), 'ledger', filters] as const,
  totals: (shopId: string, from: string, to: string) =>
    [...paymentKeys.all(shopId), 'totals', from, to] as const,
};

const nameEmbed = z.object({
  id: z.string(),
  first_name: z.string().nullable(),
  last_name: z.string().nullable(),
  company: z.string().nullable(),
});

export const ledgerRowSchema = z.object({
  id: z.string(),
  kind: z.enum(PAYMENT_KINDS),
  method: z.enum(PAYMENT_METHODS),
  status: z.enum(PAYMENT_STATUSES),
  amount_cents: z.number(),
  tip_cents: z.number(),
  refunded_cents: z.number(),
  card_brand: z.string().nullable(),
  card_last4: z.string().nullable(),
  /** Stripe's payment method type (card, us_bank_account, affirm…), set by the webhook. */
  stripe_method_type: z
    .string()
    .nullish()
    .transform((v) => v ?? null),
  note: z.string().nullable(),
  paid_at: z.string().nullable(),
  created_at: z.string(),
  invoice_id: z.string().nullable(),
  job_id: z.string().nullable(),
  membership_id: z.string().nullable(),
  customer_id: z.string(),
  customer: nameEmbed.nullable(),
  invoice: z.object({ id: z.string(), number: z.number() }).nullable(),
  job: z.object({ id: z.string(), number: z.number() }).nullable(),
});

export type LedgerRow = z.infer<typeof ledgerRowSchema>;

const LEDGER_COLUMNS =
  'id, kind, method, status, amount_cents, tip_cents, refunded_cents, card_brand, card_last4, stripe_method_type, note, paid_at, created_at, invoice_id, job_id, membership_id, customer_id, ' +
  'customer:customers(id, first_name, last_name, company), invoice:invoices(id, number), job:jobs(id, number)';

/**
 * PostgREST `or` filter: received payments by paid_at, others (pending /
 * failed…) by when they were created — both inside the shop-local range.
 */
export function ledgerDateFilter(fromIso: string, toIso: string): string {
  return (
    `and(paid_at.gte."${fromIso}",paid_at.lt."${toIso}"),` +
    `and(paid_at.is.null,created_at.gte."${fromIso}",created_at.lt."${toIso}")`
  );
}

function ledgerQuery(shopId: string, timezone: string, filters: LedgerFilters, count: boolean) {
  const range = shopDateRangeUtc(filters.from, filters.to, timezone);
  let request = supabase
    .from('payments')
    .select(LEDGER_COLUMNS, count ? { count: 'exact' } : undefined)
    .eq('shop_id', shopId)
    .or(ledgerDateFilter(range.from, range.to));
  if (filters.method !== 'all') request = request.eq('method', filters.method);
  if (filters.status !== 'all') request = request.eq('status', filters.status);
  if (filters.kind !== 'all') request = request.eq('kind', filters.kind);
  return request
    .order('paid_at', { ascending: false, nullsFirst: false })
    .order('created_at', { ascending: false });
}

export function useLedger(filters: LedgerFilters, enabled: boolean) {
  const { shopId, timezone } = useShop();
  return useQuery({
    queryKey: paymentKeys.ledger(shopId, filters),
    enabled,
    placeholderData: keepPreviousData,
    queryFn: async (): Promise<{ rows: LedgerRow[]; total: number }> => {
      const { from, to } = pageRange(filters.page, LEDGER_PAGE_SIZE);
      const { data, error, count } = await ledgerQuery(shopId, timezone, filters, true).range(
        from,
        to,
      );
      const rows = z.array(ledgerRowSchema).parse(unwrap({ data, error }) ?? []);
      return { rows, total: count ?? rows.length };
    },
  });
}

/** Every row matching the filters (up to EXPORT_LIMIT) for the CSV export. */
export async function fetchLedgerForExport(
  shopId: string,
  timezone: string,
  filters: LedgerFilters,
): Promise<LedgerRow[]> {
  const { data, error } = await ledgerQuery(shopId, timezone, filters, false).range(
    0,
    EXPORT_LIMIT - 1,
  );
  return z.array(ledgerRowSchema).parse(unwrap({ data, error }) ?? []);
}

export interface LedgerTotals {
  count: number;
  grossCents: number;
  refundsCents: number;
  tipsCents: number;
  collectedCents: number;
}

/**
 * Received-money totals for the date range from report_payments (per
 * method, computed server-side). With a method filter the matching row is
 * used; otherwise the per-method rows are added up.
 */
export function usePaymentTotals(
  from: string,
  to: string,
  method: PaymentMethod | 'all',
  enabled: boolean,
) {
  const { shopId } = useShop();
  const query = useQuery({
    queryKey: paymentKeys.totals(shopId, from, to),
    enabled,
    queryFn: async () =>
      unwrapList(
        await supabase.rpc('report_payments', { p_shop_id: shopId, p_from: from, p_to: to }),
      ),
  });
  const rows = (query.data ?? []).filter((r) => method === 'all' || r.method === method);
  const totals: LedgerTotals | undefined = query.data
    ? {
        count: sumCents(rows.map((r) => r.payments_count)),
        grossCents: sumCents(rows.map((r) => r.gross_cents)),
        refundsCents: sumCents(rows.map((r) => r.refunds_cents + r.tip_refunds_cents)),
        tipsCents: sumCents(rows.map((r) => r.tips_cents)),
        collectedCents: sumCents(rows.map((r) => r.collected_cents)),
      }
    : undefined;
  return { query, totals };
}
