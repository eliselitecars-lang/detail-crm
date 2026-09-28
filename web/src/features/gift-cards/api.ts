/**
 * Gift cards & store credit (P-13, 0066). Cards are TENDER: a sale (online
 * order or staff issue) creates the card and its 'issue' transaction — never
 * a payment — and redeeming one pays an invoice (payments method gift_card).
 * Codes are never stored: only the last 4 characters are readable, and the
 * full code is shown once, when a card is issued. Every rule (amount limits,
 * expiry, brute-force limits, who may adjust or void) is the server's.
 */
import { keepPreviousData, useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { z } from 'zod';
import { pageRange } from '@/components/ui';
import { unwrap, unwrapRequired, type Row } from '@/lib/db';
import { shopKey } from '@/lib/queryKeys';
import { supabase } from '@/lib/supabase';
import { useShop } from '@/features/shop/shopContext';
import { escapeLike } from '@/features/quotes/shared/format';

export type GiftCardStatus = Row<'gift_cards'>['status'];
export type GiftCardKind = 'gift' | 'credit';
export type GiftCardTxnKind = Row<'gift_card_transactions'>['kind'];

export const GIFT_CARD_STATUSES = [
  'active',
  'depleted',
  'void',
  'expired',
] as const satisfies readonly GiftCardStatus[];

export const STATUS_LABELS: Record<GiftCardStatus, string> = {
  active: 'Active',
  depleted: 'Used up',
  void: 'Void',
  expired: 'Expired',
};

export const KIND_LABELS: Record<GiftCardKind, string> = {
  gift: 'Gift card',
  credit: 'Store credit',
};

export const TXN_LABELS: Record<GiftCardTxnKind, string> = {
  issue: 'Issued',
  redeem: 'Redeemed',
  refund: 'Refund',
  adjust: 'Adjustment',
  void: 'Voided',
  expire: 'Expired',
};

export const ISSUED_VIA_LABELS: Record<string, string> = {
  online: 'Bought online',
  staff: 'Issued by staff',
  referral: 'Referral reward',
  refund: 'Refund',
};

/** Card value limits of issue_gift_card (1 cent .. $10,000). */
export const MAX_CARD_CENTS = 1_000_000;

export const GIFT_CARD_PAGE_SIZE = 25;

export interface GiftCardFilters {
  kind: GiftCardKind | 'all';
  status: GiftCardStatus | 'all';
  /** Last 4 characters of the code (or part of the recipient's name / email). */
  search: string;
  page: number;
}

export const giftCardKeys = {
  all: (shopId: string) => shopKey(shopId, 'gift-cards'),
  list: (shopId: string, filters: GiftCardFilters) =>
    [...giftCardKeys.all(shopId), 'list', filters] as const,
  detail: (shopId: string, id: string) => [...giftCardKeys.all(shopId), 'detail', id] as const,
  settings: (shopId: string) => [...giftCardKeys.all(shopId), 'settings'] as const,
};

const personEmbed = z
  .object({
    id: z.string(),
    first_name: z.string().nullable(),
    last_name: z.string().nullable(),
    company: z.string().nullable(),
  })
  .nullable();

export const giftCardRowSchema = z.object({
  id: z.string(),
  kind: z.enum(['gift', 'credit']),
  code_last4: z.string(),
  initial_cents: z.number(),
  balance_cents: z.number(),
  sold_price_cents: z.number().nullable(),
  status: z.enum(GIFT_CARD_STATUSES),
  owner_customer_id: z.string().nullable(),
  purchaser_customer_id: z.string().nullable(),
  recipient_name: z.string().nullable(),
  recipient_email: z.string().nullable(),
  message: z.string().nullable(),
  issued_via: z.string(),
  expires_at: z.string().nullable(),
  voided_at: z.string().nullable(),
  void_reason: z.string().nullable(),
  created_at: z.string(),
  owner: personEmbed,
  purchaser: personEmbed,
});
export type GiftCardRow = z.infer<typeof giftCardRowSchema>;

const CARD_COLUMNS =
  'id, kind, code_last4, initial_cents, balance_cents, sold_price_cents, status, owner_customer_id, purchaser_customer_id, recipient_name, recipient_email, message, issued_via, expires_at, voided_at, void_reason, created_at, ' +
  'owner:customers!gift_cards_owner_fk(id, first_name, last_name, company), ' +
  'purchaser:customers!gift_cards_purchaser_fk(id, first_name, last_name, company)';

/**
 * The status to show: an active / used-up card past its expiry reads as
 * expired (the server refuses to redeem it; the column is not swept).
 */
export function effectiveCardStatus(
  card: Pick<GiftCardRow, 'status' | 'expires_at'>,
  now: Date = new Date(),
): GiftCardStatus {
  if (
    (card.status === 'active' || card.status === 'depleted') &&
    card.expires_at !== null &&
    new Date(card.expires_at).getTime() <= now.getTime()
  ) {
    return 'expired';
  }
  return card.status;
}

/**
 * A PostgREST or() operand matching `term` anywhere, literally: the LIKE
 * wildcards are escaped, then the value is double-quoted (backslash escapes
 * only work inside quotes, so a comma or parenthesis in a name cannot split
 * the logic tree).
 */
export function containsOperand(term: string): string {
  const pattern = `%${escapeLike(term)}%`;
  return `"${pattern.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;
}

/** Search by code: letters / digits only, upper-cased (codes are Crockford base32). */
export function codeSearchTerm(input: string): string | null {
  const cleaned = input.toUpperCase().replace(/[^A-Z0-9]/g, '');
  return cleaned.length >= 1 && cleaned.length <= 4 ? cleaned : null;
}

export function useGiftCards(filters: GiftCardFilters) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: giftCardKeys.list(shopId, filters),
    placeholderData: keepPreviousData,
    queryFn: async (): Promise<{ rows: GiftCardRow[]; total: number }> => {
      let request = supabase
        .from('gift_cards')
        .select(CARD_COLUMNS, { count: 'exact' })
        .eq('shop_id', shopId);
      if (filters.kind !== 'all') request = request.eq('kind', filters.kind);
      if (filters.status === 'expired') {
        request = request.or(
          `status.eq.expired,and(status.in.(active,depleted),expires_at.lte.${new Date().toISOString()})`,
        );
      } else if (filters.status === 'active') {
        request = request
          .eq('status', 'active')
          .or(`expires_at.is.null,expires_at.gt.${new Date().toISOString()}`);
      } else if (filters.status !== 'all') {
        request = request.eq('status', filters.status);
      }
      const term = filters.search.trim();
      if (term) {
        const code = codeSearchTerm(term);
        const text = containsOperand(term);
        const byText = `recipient_name.ilike.${text},recipient_email.ilike.${text}`;
        request = request.or(code ? `code_last4.ilike.%${code}%,${byText}` : byText);
      }
      const { from, to } = pageRange(filters.page, GIFT_CARD_PAGE_SIZE);
      const { data, error, count } = await request
        .order('created_at', { ascending: false })
        .range(from, to);
      const rows = z.array(giftCardRowSchema).parse(unwrap({ data, error }) ?? []);
      return { rows, total: count ?? rows.length };
    },
  });
}

export const transactionSchema = z.object({
  id: z.string(),
  kind: z.enum(['issue', 'redeem', 'refund', 'adjust', 'void', 'expire']),
  amount_cents: z.number(),
  balance_after_cents: z.number(),
  payment_id: z.string().nullable(),
  note: z.string().nullable(),
  created_at: z.string(),
  payment: z
    .object({
      id: z.string(),
      invoice_id: z.string().nullable(),
      invoice: z.object({ id: z.string(), number: z.number() }).nullable(),
    })
    .nullable(),
});
export type GiftCardTransaction = z.infer<typeof transactionSchema>;

export interface GiftCardDetail {
  card: GiftCardRow;
  transactions: GiftCardTransaction[];
}

export function useGiftCard(id: string) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: giftCardKeys.detail(shopId, id),
    queryFn: async (): Promise<GiftCardDetail> => {
      const card = giftCardRowSchema.parse(
        unwrapRequired(
          await supabase
            .from('gift_cards')
            .select(CARD_COLUMNS)
            .eq('shop_id', shopId)
            .eq('id', id)
            .maybeSingle(),
          'gift card',
        ),
      );
      const { data, error } = await supabase
        .from('gift_card_transactions')
        .select(
          'id, kind, amount_cents, balance_after_cents, payment_id, note, created_at, payment:payments(id, invoice_id, invoice:invoices(id, number))',
        )
        .eq('shop_id', shopId)
        .eq('gift_card_id', id)
        .order('created_at', { ascending: false })
        .order('id', { ascending: false });
      const transactions = z.array(transactionSchema).parse(unwrap({ data, error }) ?? []);
      return { card, transactions };
    },
  });
}

export type GiftCardSettings = Pick<
  Row<'gift_card_settings'>,
  'online_enabled' | 'offers' | 'allow_custom_amount' | 'expires_months'
>;

/** Online sale settings (managers read; shown as a pointer to the public page). */
export function useGiftCardSettings() {
  const { shopId } = useShop();
  return useQuery({
    queryKey: giftCardKeys.settings(shopId),
    staleTime: 60_000,
    queryFn: async (): Promise<GiftCardSettings | null> =>
      unwrap(
        await supabase
          .from('gift_card_settings')
          .select('online_enabled, offers, allow_custom_amount, expires_months')
          .eq('shop_id', shopId)
          .maybeSingle(),
      ),
  });
}

export const issueResultSchema = z.object({
  gift_card_id: z.string(),
  code: z.string(),
  last4: z.string(),
  balance_cents: z.number().int(),
  delivery_queued: z.boolean(),
});
export type IssueResult = z.infer<typeof issueResultSchema>;

export interface IssueInput {
  kind: GiftCardKind;
  amountCents: number;
  /** What the buyer paid, when it differs from the value (null = not sold / same). */
  soldPriceCents: number | null;
  /** Store credit: the customer it belongs to. */
  ownerCustomerId: string | null;
  recipient: { name?: string; email?: string; message?: string; sender_name?: string };
  /** Email the code to the recipient (gift_card_delivery). */
  send: boolean;
}

/** issue_gift_card (managers+): the plain code is in the result ONCE. */
export function useIssueGiftCard() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (input: IssueInput): Promise<IssueResult> =>
      issueResultSchema.parse(
        unwrap(
          await supabase.rpc('issue_gift_card', {
            p_shop_id: shopId,
            p_amount_cents: input.amountCents,
            p_recipient: input.recipient,
            p_kind: input.kind,
            p_send: input.send,
            ...(input.soldPriceCents !== null ? { p_sold_price_cents: input.soldPriceCents } : {}),
            ...(input.ownerCustomerId ? { p_owner_customer_id: input.ownerCustomerId } : {}),
          }),
        ),
      ),
    onSettled: () =>
      Promise.all([
        queryClient.invalidateQueries({ queryKey: giftCardKeys.all(shopId) }),
        queryClient.invalidateQueries({ queryKey: shopKey(shopId, 'invoices') }),
        queryClient.invalidateQueries({ queryKey: shopKey(shopId, 'customers') }),
      ]),
  });
}

function useInvalidateCards() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return () =>
    Promise.all([
      queryClient.invalidateQueries({ queryKey: giftCardKeys.all(shopId) }),
      queryClient.invalidateQueries({ queryKey: shopKey(shopId, 'invoices') }),
      queryClient.invalidateQueries({ queryKey: shopKey(shopId, 'customers') }),
    ]);
}

/** adjust_gift_card (owners / admins): moves the balance by a signed amount. */
export function useAdjustGiftCard(id: string) {
  const invalidate = useInvalidateCards();
  return useMutation({
    mutationFn: async (input: { deltaCents: number; note: string | null }) =>
      unwrap(
        await supabase.rpc('adjust_gift_card', {
          p_gift_card_id: id,
          p_delta_cents: input.deltaCents,
          ...(input.note ? { p_note: input.note } : {}),
        }),
      ),
    onSettled: invalidate,
  });
}

/** void_gift_card (owners / admins): takes the remaining balance off for good. */
export function useVoidGiftCard(id: string) {
  const invalidate = useInvalidateCards();
  return useMutation({
    mutationFn: async (reason: string | null) =>
      unwrap(
        await supabase.rpc('void_gift_card', {
          p_gift_card_id: id,
          ...(reason ? { p_reason: reason } : {}),
        }),
      ),
    onSettled: invalidate,
  });
}
