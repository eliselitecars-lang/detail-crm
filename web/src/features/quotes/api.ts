/**
 * Quotes data layer (SPEC §4.5). Totals, numbering, stamps and the status
 * machine are server-side (quotes_* triggers); this module only writes
 * content fields, lines and the status moves staff are allowed to make
 * directly (→ draft / approved / declined), and calls the RPCs for the rest.
 */
import { keepPreviousData, useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { z } from 'zod';
import { pageRange } from '@/components/ui';
import { shopToday } from '@/lib/dates';
import { unwrap, unwrapRequired, type Row, type UpdateRow } from '@/lib/db';
import { shopKey } from '@/lib/queryKeys';
import { supabase } from '@/lib/supabase';
import { useShop } from '@/features/shop/shopContext';
import { unwrapList } from './shared/db';
import { escapeLike, parseDocNumber } from './shared/format';
import { nextSorts, type DocLine, type LineDraft, type LinePatch } from './shared/lines';
import type { Enums } from './shared/types';

export type QuoteStatus = Enums['quote_status'];
export type QuoteRow = Row<'quotes'>;
export type QuoteLineRow = Row<'quote_line_items'>;

export const QUOTE_PAGE_SIZE = 25;

export type QuoteStatusFilter =
  'all' | 'draft' | 'sent' | 'approved' | 'declined' | 'expired' | 'converted';

export interface QuoteFilters {
  status: QuoteStatusFilter;
  search: string;
  page: number;
}

export const quoteKeys = {
  all: (shopId: string) => shopKey(shopId, 'quotes'),
  list: (shopId: string, filters: QuoteFilters) =>
    [...quoteKeys.all(shopId), 'list', filters] as const,
  detail: (shopId: string, id: string) => [...quoteKeys.all(shopId), 'detail', id] as const,
  lines: (shopId: string, id: string) => [...quoteKeys.all(shopId), 'lines', id] as const,
};

const customerEmbed = z
  .object({
    id: z.string(),
    first_name: z.string().nullable(),
    last_name: z.string().nullable(),
    company: z.string().nullable(),
  })
  .nullable();

const quoteListRowSchema = z.object({
  id: z.string(),
  number: z.number(),
  status: z.enum(['draft', 'sent', 'viewed', 'approved', 'declined', 'expired', 'converted']),
  customer_id: z.string(),
  valid_until: z.string().nullable(),
  total_cents: z.number(),
  sent_at: z.string().nullable(),
  created_at: z.string(),
  customer: customerEmbed,
});

export type QuoteListRow = z.infer<typeof quoteListRowSchema>;

const QUOTE_LIST_COLUMNS =
  'id, number, status, customer_id, valid_until, total_cents, sent_at, created_at, customer:customers(id, first_name, last_name, company)';

/**
 * A sent/viewed quote whose validity date has passed is expired even if the
 * nightly expire_quotes job has not flipped it yet (valid through the end of
 * valid_until in the shop time zone).
 */
export function effectiveQuoteStatus(
  quote: { status: QuoteStatus; valid_until: string | null },
  today: string,
): QuoteStatus {
  if (
    (quote.status === 'sent' || quote.status === 'viewed') &&
    quote.valid_until !== null &&
    quote.valid_until < today
  ) {
    return 'expired';
  }
  return quote.status;
}

/** Content (lines, pricing, validity…) is editable while draft/sent/viewed (SQL guard). */
export function isQuoteEditable(status: QuoteStatus): boolean {
  return status === 'draft' || status === 'sent' || status === 'viewed';
}

async function customerIdsMatching(shopId: string, term: string): Promise<string[]> {
  const rows = unwrapList(
    await supabase
      .from('customers')
      .select('id')
      .eq('shop_id', shopId)
      .ilike('search_text', `%${escapeLike(term.toLowerCase())}%`)
      .limit(200),
  );
  return rows.map((r) => r.id);
}

export function useQuotes(filters: QuoteFilters) {
  const { shopId, timezone } = useShop();
  return useQuery({
    queryKey: quoteKeys.list(shopId, filters),
    placeholderData: keepPreviousData,
    queryFn: async (): Promise<{ rows: QuoteListRow[]; total: number }> => {
      const today = shopToday(timezone);
      let request = supabase
        .from('quotes')
        .select(QUOTE_LIST_COLUMNS, { count: 'exact' })
        .eq('shop_id', shopId);

      switch (filters.status) {
        case 'all':
          break;
        case 'sent':
          request = request
            .in('status', ['sent', 'viewed'])
            .or(`valid_until.is.null,valid_until.gte.${today}`);
          break;
        case 'expired':
          request = request.or(
            `status.eq.expired,and(status.in.(sent,viewed),valid_until.lt.${today})`,
          );
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
          const ids = await customerIdsMatching(shopId, term);
          if (ids.length === 0) return { rows: [], total: 0 };
          request = request.in('customer_id', ids);
        }
      }

      const { from, to } = pageRange(filters.page, QUOTE_PAGE_SIZE);
      const { data, error, count } = await request
        .order('created_at', { ascending: false })
        .range(from, to);
      const rows = z.array(quoteListRowSchema).parse(unwrap({ data, error }) ?? []);
      return { rows, total: count ?? rows.length };
    },
  });
}

export function useQuote(quoteId: string) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: quoteKeys.detail(shopId, quoteId),
    queryFn: async (): Promise<QuoteRow> =>
      unwrapRequired(
        await supabase
          .from('quotes')
          .select('*')
          .eq('shop_id', shopId)
          .eq('id', quoteId)
          .maybeSingle(),
        'quote',
      ),
  });
}

export function toDocLine(row: QuoteLineRow): DocLine {
  return {
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
    optional: row.optional,
    selected: row.selected,
    duration_minutes: row.duration_minutes,
  };
}

export function useQuoteLines(quoteId: string) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: quoteKeys.lines(shopId, quoteId),
    queryFn: async (): Promise<DocLine[]> =>
      unwrapList(
        await supabase
          .from('quote_line_items')
          .select('*')
          .eq('shop_id', shopId)
          .eq('quote_id', quoteId)
          .order('sort', { ascending: true })
          .order('created_at', { ascending: true }),
      ).map(toDocLine),
  });
}

function useInvalidateQuotes() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return () => queryClient.invalidateQueries({ queryKey: quoteKeys.all(shopId) });
}

export interface NewQuoteInput {
  customerId: string;
  vehicleId: string | null;
  validUntil: string | null;
  notes: string | null;
  terms: string | null;
}

export function useCreateQuote() {
  const { shopId, shop } = useShop();
  const invalidate = useInvalidateQuotes();
  return useMutation({
    mutationFn: async (input: NewQuoteInput): Promise<QuoteRow> =>
      unwrapRequired(
        await supabase
          .from('quotes')
          .insert({
            shop_id: shopId,
            // number is assigned by the quotes_integrity trigger (always overwritten).
            number: 0,
            // the shop's current rate (the server default); editable later.
            tax_rate_bps: shop.tax_rate_bps,
            customer_id: input.customerId,
            vehicle_id: input.vehicleId,
            valid_until: input.validUntil,
            notes: input.notes,
            terms: input.terms,
          })
          .select('*')
          .maybeSingle(),
        'quote',
      ),
    onSettled: invalidate,
  });
}

export type QuotePatch = Pick<
  UpdateRow<'quotes'>,
  | 'vehicle_id'
  | 'valid_until'
  | 'notes'
  | 'terms'
  | 'internal_notes'
  | 'discount_kind'
  | 'discount_value'
>;

export function useUpdateQuote(quoteId: string) {
  const { shopId } = useShop();
  const invalidate = useInvalidateQuotes();
  return useMutation({
    mutationFn: async (patch: QuotePatch) =>
      unwrapRequired(
        await supabase
          .from('quotes')
          .update(patch)
          .eq('shop_id', shopId)
          .eq('id', quoteId)
          .select('*')
          .maybeSingle(),
        'quote',
      ),
    onSettled: invalidate,
  });
}

export type StaffQuoteStatus = 'draft' | 'approved' | 'declined';

export interface SetQuoteStatusInput {
  status: StaffQuoteStatus;
  approvedByName?: string | null;
  declinedReason?: string | null;
  /**
   * approved only: the customer's choice on optional lines (just the ones
   * that change). Written before the status move — lines lock once approved,
   * and convert_quote_to_job copies only required + selected optional lines.
   */
  optionalChoices?: ReadonlyArray<{ id: string; selected: boolean }>;
}

/** Staff status moves allowed by quotes_status_machine (revise / record response). */
export function useSetQuoteStatus(quoteId: string) {
  const { shopId } = useShop();
  const invalidate = useInvalidateQuotes();
  return useMutation({
    mutationFn: async (input: SetQuoteStatusInput) => {
      if (input.status === 'approved' && input.optionalChoices?.length) {
        for (const choice of input.optionalChoices) {
          unwrap(
            await supabase
              .from('quote_line_items')
              .update({ selected: choice.selected })
              .eq('shop_id', shopId)
              .eq('quote_id', quoteId)
              .eq('id', choice.id)
              .eq('optional', true),
          );
        }
      }
      return unwrapRequired(
        await supabase
          .from('quotes')
          .update({
            status: input.status,
            ...(input.status === 'approved'
              ? { approved_by_name: input.approvedByName ?? null }
              : {}),
            ...(input.status === 'declined'
              ? { declined_reason: input.declinedReason ?? null }
              : {}),
          })
          .eq('shop_id', shopId)
          .eq('id', quoteId)
          .select('*')
          .maybeSingle(),
        'quote',
      );
    },
    onSettled: invalidate,
  });
}

export function useMarkQuoteSent(quoteId: string) {
  const invalidate = useInvalidateQuotes();
  return useMutation({
    mutationFn: async () => unwrap(await supabase.rpc('mark_quote_sent', { p_quote_id: quoteId })),
    onSettled: invalidate,
  });
}

export interface ConvertQuoteInput {
  start: string | null;
  end: string | null;
}

export function useConvertQuote(quoteId: string) {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async ({ start, end }: ConvertQuoteInput) =>
      unwrapRequired(
        await supabase.rpc('convert_quote_to_job', {
          p_quote_id: quoteId,
          ...(start && end ? { p_start: start, p_end: end } : {}),
        }),
        'job',
      ),
    onSettled: () =>
      Promise.all([
        queryClient.invalidateQueries({ queryKey: quoteKeys.all(shopId) }),
        queryClient.invalidateQueries({ queryKey: shopKey(shopId, 'jobs') }),
      ]),
  });
}

export function useDeleteQuote() {
  const { shopId } = useShop();
  const invalidate = useInvalidateQuotes();
  return useMutation({
    mutationFn: async (quoteId: string) => {
      unwrap(await supabase.from('quotes').delete().eq('shop_id', shopId).eq('id', quoteId));
    },
    onSettled: invalidate,
  });
}

function lineInsert(shopId: string, quoteId: string, draft: LineDraft, sort: number) {
  return {
    shop_id: shopId,
    quote_id: quoteId,
    service_id: draft.service_id,
    name: draft.name,
    description: draft.description,
    quantity: draft.quantity,
    unit_price_cents: draft.unit_price_cents,
    discount_cents: draft.discount_cents,
    taxable: draft.taxable,
    optional: draft.optional,
    // Required lines always count; optional lines start unchosen (the customer picks).
    selected: !draft.optional,
    duration_minutes: draft.duration_minutes,
    sort,
  };
}

/**
 * Duplicates a quote as a new draft with the same content and lines, priced
 * with the shop's CURRENT tax rate (like a new quote), not the old quote's.
 * Line vehicles that no longer belong to the customer are dropped (the
 * validate trigger would reject them), and if the lines still fail to copy
 * the half-made draft is deleted so no empty quote is left behind.
 */
export function useDuplicateQuote() {
  const { shopId } = useShop();
  const invalidate = useInvalidateQuotes();
  return useMutation({
    mutationFn: async ({ quote, lines }: { quote: QuoteRow; lines: readonly DocLine[] }) => {
      const shopRow = unwrapRequired<Pick<Row<'shops'>, 'tax_rate_bps'>>(
        await supabase.from('shops').select('tax_rate_bps').eq('id', shopId).maybeSingle(),
        'shop',
      );
      const lineVehicles = new Set(
        lines.map((line) => line.vehicle_id).filter((id): id is string => id !== null),
      );
      const customerVehicles =
        lineVehicles.size === 0
          ? new Set<string>()
          : new Set(
              unwrapList(
                await supabase
                  .from('vehicles')
                  .select('id')
                  .eq('shop_id', shopId)
                  .eq('customer_id', quote.customer_id)
                  .in('id', [...lineVehicles]),
              ).map((v) => v.id),
            );
      const copy = unwrapRequired<QuoteRow>(
        await supabase
          .from('quotes')
          .insert({
            shop_id: shopId,
            number: 0, // assigned by the server
            tax_rate_bps: shopRow.tax_rate_bps,
            customer_id: quote.customer_id,
            vehicle_id: quote.vehicle_id,
            notes: quote.notes,
            terms: quote.terms,
            internal_notes: quote.internal_notes,
            discount_kind: quote.discount_kind,
            discount_value: quote.discount_value,
          })
          .select('*')
          .maybeSingle(),
        'quote',
      );
      if (lines.length > 0) {
        const inserted = await supabase.from('quote_line_items').insert(
          lines.map((line, index) => ({
            ...lineInsert(shopId, copy.id, line, index + 1),
            vehicle_id:
              line.vehicle_id !== null && customerVehicles.has(line.vehicle_id)
                ? line.vehicle_id
                : null,
          })),
        );
        if (inserted.error) {
          // Don't leave an empty draft behind; the original error is what matters.
          await supabase.from('quotes').delete().eq('shop_id', shopId).eq('id', copy.id);
          unwrap(inserted);
        }
      }
      return copy;
    },
    onSettled: invalidate,
  });
}

export function useQuoteLineMutations(quoteId: string, lines: readonly DocLine[]) {
  const { shopId } = useShop();
  const invalidate = useInvalidateQuotes();
  const add = useMutation({
    mutationFn: async (drafts: LineDraft[]) => {
      const sorts = nextSorts(lines, drafts.length);
      unwrap(
        await supabase
          .from('quote_line_items')
          .insert(drafts.map((d, i) => lineInsert(shopId, quoteId, d, sorts[i] ?? i + 1))),
      );
    },
    onSettled: invalidate,
  });
  const update = useMutation({
    mutationFn: async ({ id, patch }: { id: string; patch: LinePatch }) => {
      const next: UpdateRow<'quote_line_items'> = { ...patch };
      if (patch.optional === false) next.selected = true;
      unwrap(
        await supabase.from('quote_line_items').update(next).eq('shop_id', shopId).eq('id', id),
      );
    },
    onSettled: invalidate,
  });
  const remove = useMutation({
    mutationFn: async (id: string) => {
      unwrap(await supabase.from('quote_line_items').delete().eq('shop_id', shopId).eq('id', id));
    },
    onSettled: invalidate,
  });
  return { add, update, remove };
}
