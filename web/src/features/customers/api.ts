/**
 * Customers data layer (TanStack Query hooks). RLS decides what each role
 * sees: owners/admins/managers get every customer; technicians only those on
 * jobs assigned to them (customers_select_assigned).
 */
import {
  keepPreviousData,
  useInfiniteQuery,
  useMutation,
  useQuery,
  useQueryClient,
} from '@tanstack/react-query';
import { z } from 'zod';
import { pageRange, type SortState } from '@/components/ui';
import { unwrap, unwrapRequired } from '@/lib/db';
import { AppError, edgeFunctionError, toAppError } from '@/lib/errors';
import { shopKey } from '@/lib/queryKeys';
import { supabase } from '@/lib/supabase';
import {
  HISTORY_PAGE_SIZE,
  normalizeTags,
  type CustomerLifecycle,
  type CustomerRow,
} from './model';
import type { CustomerWrite, VehicleWrite } from './schemas';
import { searchPatterns, searchTerms } from './search';

// ---------------------------------------------------------------- keys

export type CustomerSortKey = 'name' | 'created_at' | 'updated_at';
export type ArchivedFilter = 'active' | 'archived' | 'all';

export interface CustomerListFilters {
  search: string;
  tag: string | null;
  lifecycle: CustomerLifecycle | null;
  archived: ArchivedFilter;
  sort: SortState<CustomerSortKey>;
  page: number;
  pageSize: number;
}

export const customerKeys = {
  all: (shopId: string) => shopKey(shopId, 'customers'),
  list: (shopId: string, f: CustomerListFilters) =>
    [...customerKeys.all(shopId), 'list', f] as const,
  tags: (shopId: string) => [...customerKeys.all(shopId), 'tags'] as const,
  detail: (shopId: string, id: string) => [...customerKeys.all(shopId), 'detail', id] as const,
  summary: (shopId: string, id: string) => [...customerKeys.all(shopId), 'summary', id] as const,
};

export const vehicleKeys = {
  all: (shopId: string) => shopKey(shopId, 'vehicles'),
  byCustomer: (shopId: string, customerId: string, includeArchived: boolean) =>
    [...vehicleKeys.all(shopId), 'customer', customerId, includeArchived] as const,
  categories: (shopId: string) => shopKey(shopId, 'catalog', 'vehicle-categories'),
};

/** Per-customer history lists live under their own domains so realtime/other features refresh them. */
export const historyKeys = {
  jobs: (shopId: string, customerId: string) => shopKey(shopId, 'jobs', 'customer', customerId),
  quotes: (shopId: string, customerId: string) => shopKey(shopId, 'quotes', 'customer', customerId),
  invoices: (shopId: string, customerId: string) =>
    shopKey(shopId, 'invoices', 'customer', customerId),
  memberships: (shopId: string, customerId: string) =>
    shopKey(shopId, 'memberships', 'customer', customerId),
  cards: (shopId: string, customerId: string) => shopKey(shopId, 'customers', 'cards', customerId),
};

// ---------------------------------------------------------------- list

export const CUSTOMER_LIST_COLUMNS =
  'id, first_name, last_name, company, email, phone, tags, lifecycle, source, archived_at, portal_user_id, created_at, updated_at';

/** PostgREST: "Requested range not satisfiable" (offset beyond the total). */
const RANGE_NOT_SATISFIABLE = 'PGRST103';

/** The PostgREST filter methods the list uses (shared by rows + count queries). */
interface FilterableQuery<Q> {
  ilike(column: 'search_text', pattern: string): Q;
  contains(column: 'tags', value: string[]): Q;
  eq(column: 'lifecycle', value: CustomerLifecycle): Q;
  is(column: 'archived_at', value: null): Q;
  not(column: 'archived_at', operator: 'is', value: null): Q;
}

function applyListFilters<Q extends FilterableQuery<Q>>(
  initial: Q,
  filters: CustomerListFilters,
): Q {
  let query = initial;
  for (const pattern of searchPatterns(filters.search)) {
    query = query.ilike('search_text', pattern);
  }
  if (filters.tag) query = query.contains('tags', [filters.tag]);
  if (filters.lifecycle) query = query.eq('lifecycle', filters.lifecycle);
  if (filters.archived === 'active') query = query.is('archived_at', null);
  else if (filters.archived === 'archived') query = query.not('archived_at', 'is', null);
  return query;
}

async function countOnly(
  filters: CustomerListFilters,
  shopId: string,
  signal: AbortSignal,
): Promise<number> {
  const result = await applyListFilters(
    supabase.from('customers').select('id', { count: 'exact', head: true }).eq('shop_id', shopId),
    filters,
  ).abortSignal(signal);
  unwrap(result);
  return result.count ?? 0;
}

export function useCustomerList(shopId: string, filters: CustomerListFilters) {
  // The search box keeps the raw text (trailing spaces included); key the
  // cache by the normalised terms so "jane" and "jane " share one request.
  const keyFilters = { ...filters, search: searchTerms(filters.search).join(' ') };
  return useQuery({
    queryKey: customerKeys.list(shopId, keyFilters),
    placeholderData: keepPreviousData,
    queryFn: async ({ signal }) => {
      const { from, to } = pageRange(filters.page, filters.pageSize);
      const ascending = filters.sort.direction === 'asc';
      let query = applyListFilters(
        supabase
          .from('customers')
          .select(CUSTOMER_LIST_COLUMNS, { count: 'exact' })
          .eq('shop_id', shopId),
        filters,
      );

      if (filters.sort.key === 'name') {
        // sort_name: generated "last (or company, or first) first" key, indexed
        // with (shop_id, sort_name, id) — company-only customers sort by company.
        query = query.order('sort_name', { ascending });
      } else {
        query = query.order(filters.sort.key, { ascending });
      }
      const result = await query.order('id').range(from, to).abortSignal(signal);
      if (result.error?.code === RANGE_NOT_SATISFIABLE) {
        // The page is past the end (stale link, or the list shrank after an
        // archive). PostgREST answers 416 with count=exact; report the real
        // total with no rows so the page can step back to the last page.
        return { rows: [], total: await countOnly(filters, shopId, signal) };
      }
      const rows = unwrap(result) ?? [];
      return { rows, total: result.count ?? from + rows.length };
    },
  });
}

/** Distinct tags in use (for the filter), from up to 1000 tagged customers. */
export function useKnownTags(shopId: string, enabled = true) {
  return useQuery({
    queryKey: customerKeys.tags(shopId),
    enabled,
    staleTime: 60_000,
    queryFn: async () => {
      const rows =
        unwrap(
          await supabase
            .from('customers')
            .select('tags')
            .eq('shop_id', shopId)
            .order('updated_at', { ascending: false })
            .limit(1000),
        ) ?? [];
      return normalizeTags(rows.flatMap((r) => r.tags)).sort((a, b) =>
        a.localeCompare(b, 'en', { sensitivity: 'base' }),
      );
    },
  });
}

// ---------------------------------------------------------------- detail & writes

export function useCustomer(shopId: string, customerId: string) {
  return useQuery({
    queryKey: customerKeys.detail(shopId, customerId),
    queryFn: async () =>
      unwrapRequired<CustomerRow>(
        await supabase
          .from('customers')
          .select('*')
          .eq('shop_id', shopId)
          .eq('id', customerId)
          .maybeSingle(),
        'customer',
      ),
  });
}

export function useCreateCustomer(shopId: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (values: CustomerWrite) =>
      unwrapRequired<{ id: string }>(
        await supabase
          .from('customers')
          .insert({ ...values, shop_id: shopId })
          .select('id')
          .single(),
        'customer',
      ),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: customerKeys.all(shopId) }),
  });
}

export function useUpdateCustomer(shopId: string, customerId: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (values: CustomerWrite) => {
      unwrap(
        await supabase.from('customers').update(values).eq('shop_id', shopId).eq('id', customerId),
      );
    },
    onSettled: () => queryClient.invalidateQueries({ queryKey: customerKeys.all(shopId) }),
  });
}

export function useSetCustomerArchived(shopId: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async ({ id, archived }: { id: string; archived: boolean }) => {
      unwrap(
        await supabase
          .from('customers')
          .update({ archived_at: archived ? new Date().toISOString() : null })
          .eq('shop_id', shopId)
          .eq('id', id),
      );
    },
    onSettled: () => queryClient.invalidateQueries({ queryKey: customerKeys.all(shopId) }),
  });
}

/** 23503 on delete: jobs / invoices / payments / memberships restrict it (0006, 0011, 0012, 0050). */
export const CUSTOMER_IN_USE_MESSAGE =
  'This customer has jobs, invoices, payments or a membership on file. Those are kept for your records, so the customer can’t be deleted — archive them instead.';
export const CUSTOMER_HAS_CARDS_MESSAGE =
  'Remove this customer’s saved cards first (Saved cards tab), so they’re removed from Stripe too.';

/**
 * Deletes a customer for good (managers+, RLS customers_delete) — e.g. for a
 * customer's deletion request. Their vehicles, quotes, messages and files go
 * with them (ON DELETE CASCADE; files are queued for storage-purge). The
 * database refuses (23503) while jobs, invoices, payments or a membership
 * point at them. Saved cards must be removed first so they are detached in
 * Stripe too (deleting the rows alone would leave them on the shop's Stripe
 * customer).
 */
export function useDeleteCustomer(shopId: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (id: string) => {
      const cards = await supabase
        .from('customer_payment_methods')
        .select('id', { count: 'exact', head: true })
        .eq('shop_id', shopId)
        .eq('customer_id', id);
      if (cards.error) throw toAppError(cards.error);
      if ((cards.count ?? 0) > 0) {
        throw new AppError(CUSTOMER_HAS_CARDS_MESSAGE, { kind: 'conflict' });
      }
      const result = await supabase
        .from('customers')
        .delete()
        .eq('shop_id', shopId)
        .eq('id', id)
        .select('id');
      if (result.error) {
        const error = toAppError(result.error);
        if (error.code === '23503') {
          throw new AppError(CUSTOMER_IN_USE_MESSAGE, { kind: 'conflict', code: error.code });
        }
        throw error;
      }
      // RLS hides the row from a caller who may not delete it: nothing deleted.
      if ((result.data ?? []).length === 0) {
        throw new AppError('This customer couldn’t be deleted. Refresh and try again.', {
          kind: 'not_found',
        });
      }
    },
    onSuccess: (_data, id) => {
      queryClient.removeQueries({ queryKey: customerKeys.detail(shopId, id) });
    },
    onSettled: () => queryClient.invalidateQueries({ queryKey: customerKeys.all(shopId) }),
  });
}

// ---------------------------------------------------------------- vehicles

export const VEHICLE_COLUMNS =
  'id, shop_id, customer_id, year, make, model, trim, color, vin, license_plate, category_id, notes, archived_at, created_at, updated_at, search_text';

export function useCustomerVehicles(shopId: string, customerId: string, includeArchived = false) {
  return useQuery({
    queryKey: vehicleKeys.byCustomer(shopId, customerId, includeArchived),
    queryFn: async () => {
      let query = supabase
        .from('vehicles')
        .select(VEHICLE_COLUMNS)
        .eq('shop_id', shopId)
        .eq('customer_id', customerId);
      if (!includeArchived) query = query.is('archived_at', null);
      return (
        unwrap(await query.order('created_at', { ascending: false }).order('id').limit(200)) ?? []
      );
    },
  });
}

export function useVehicleCategories(shopId: string) {
  return useQuery({
    queryKey: vehicleKeys.categories(shopId),
    staleTime: 5 * 60_000,
    queryFn: async () =>
      unwrap(
        await supabase
          .from('vehicle_categories')
          .select('id, name, sort')
          .eq('shop_id', shopId)
          .order('sort')
          .order('name'),
      ) ?? [],
  });
}

export function useSaveVehicle(shopId: string, customerId: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async ({ id, values }: { id: string | null; values: VehicleWrite }) => {
      if (id) {
        unwrap(await supabase.from('vehicles').update(values).eq('shop_id', shopId).eq('id', id));
        return id;
      }
      const row = unwrapRequired<{ id: string }>(
        await supabase
          .from('vehicles')
          .insert({ ...values, shop_id: shopId, customer_id: customerId })
          .select('id')
          .single(),
        'vehicle',
      );
      return row.id;
    },
    onSettled: () => queryClient.invalidateQueries({ queryKey: vehicleKeys.all(shopId) }),
  });
}

export function useSetVehicleArchived(shopId: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async ({ id, archived }: { id: string; archived: boolean }) => {
      unwrap(
        await supabase
          .from('vehicles')
          .update({ archived_at: archived ? new Date().toISOString() : null })
          .eq('shop_id', shopId)
          .eq('id', id),
      );
    },
    onSettled: () => queryClient.invalidateQueries({ queryKey: vehicleKeys.all(shopId) }),
  });
}

// ---------------------------------------------------------------- summary (manager+)

const cents = z.number().int();
export const customerSummarySchema = z.object({
  customer_id: z.string(),
  lifetime_paid_cents: cents,
  tips_cents: cents,
  refunded_cents: cents,
  open_balance_cents: cents,
  overdue_balance_cents: cents,
  completed_jobs: z.number().int(),
  upcoming_jobs: z.number().int(),
  first_visit_at: z.string().nullable(),
  last_visit_at: z.string().nullable(),
  next_job_at: z.string().nullable(),
  open_quotes: z.number().int(),
  active_memberships: z.number().int(),
});
export type CustomerSummary = z.infer<typeof customerSummarySchema>;

/**
 * customer_summary RPC (0092): lifetime paid, open / overdue balance, visit
 * counts and dates, computed server-side. Owner/admin/manager only (42501 for
 * technicians), so callers gate it with a manager+ capability.
 */
export function useCustomerSummary(shopId: string, customerId: string, enabled = true) {
  return useQuery({
    queryKey: customerKeys.summary(shopId, customerId),
    enabled,
    queryFn: async (): Promise<CustomerSummary> => {
      const rows = unwrap(await supabase.rpc('customer_summary', { p_customer_id: customerId }));
      const row = z.array(customerSummarySchema).parse(rows ?? [])[0];
      if (!row) throw new AppError('That customer could not be found.', { kind: 'not_found' });
      return row;
    },
  });
}

// ---------------------------------------------------------------- history tabs

/**
 * History tabs read newest first, a page at a time, with the exact count the
 * server reports (like the iPhone's DetailCore HistoryList): a fleet or
 * dealership customer can have more rows than one page, so the tab says how
 * many exist and offers the older ones ("Load more"; HISTORY_PAGE_SIZE rows
 * per page).
 *
 * One page: its rows and the server's exact count of every matching row.
 */
export interface HistoryPage<T> {
  rows: T[];
  total: number | null;
}

/** Every page read so far, flattened (an id listed twice is kept once). */
export interface HistoryList<T> {
  rows: T[];
  /** Every matching row (never less than `rows.length`). */
  total: number;
}

type PageResult<T> = {
  data: T[] | null;
  error: { code?: string; message: string } | null;
  count: number | null;
};

/** Reads rows [offset, offset + HISTORY_PAGE_SIZE) with the exact count. */
async function readHistoryPage<T>(
  run: (from: number, to: number) => PromiseLike<PageResult<T>>,
  offset: number,
): Promise<HistoryPage<T>> {
  const result = await run(offset, offset + HISTORY_PAGE_SIZE - 1);
  // Past the end (rows removed since the count): the list ends here.
  if (result.error?.code === RANGE_NOT_SATISFIABLE) return { rows: [], total: null };
  if (result.error) throw toAppError(result.error);
  return { rows: result.data ?? [], total: result.count };
}

/** Offset of the next page, or undefined when every row is loaded. */
export function nextHistoryOffset<T>(
  last: HistoryPage<T>,
  pages: HistoryPage<T>[],
): number | undefined {
  // An empty page ends the list even when the earlier count said more, so
  // Load more can't ask for the same page forever.
  if (last.rows.length === 0) return undefined;
  const loaded = pages.reduce((n, p) => n + p.rows.length, 0);
  if (last.total !== null) return loaded < last.total ? loaded : undefined;
  return last.rows.length >= HISTORY_PAGE_SIZE ? loaded : undefined;
}

/** Flattens the pages; a row added meanwhile shifts offsets, so ids dedupe. */
export function flattenHistory<T extends { id: string }>(pages: HistoryPage<T>[]): HistoryList<T> {
  const seen = new Set<string>();
  const rows: T[] = [];
  for (const page of pages) {
    for (const row of page.rows) {
      if (seen.has(row.id)) continue;
      seen.add(row.id);
      rows.push(row);
    }
  }
  const last = pages.at(-1);
  if (!last || last.rows.length === 0) return { rows, total: rows.length };
  const total =
    last.total ?? (last.rows.length >= HISTORY_PAGE_SIZE ? rows.length + 1 : rows.length);
  return { rows, total: Math.max(total, rows.length) };
}

function useHistoryQuery<T extends { id: string }>(
  queryKey: readonly unknown[],
  enabled: boolean,
  readPage: (offset: number) => Promise<HistoryPage<T>>,
) {
  return useInfiniteQuery({
    queryKey,
    enabled,
    initialPageParam: 0,
    queryFn: ({ pageParam }) => readPage(pageParam),
    getNextPageParam: nextHistoryOffset,
    select: (data) => flattenHistory(data.pages),
  });
}

export function useCustomerJobs(shopId: string, customerId: string) {
  return useHistoryQuery(historyKeys.jobs(shopId, customerId), true, (offset) =>
    readHistoryPage(
      (from, to) =>
        supabase
          .from('jobs')
          .select(
            'id, number, status, scheduled_start, scheduled_end, vehicle_id, total_cents, created_at',
            { count: 'exact' },
          )
          .eq('shop_id', shopId)
          .eq('customer_id', customerId)
          .order('scheduled_start', { ascending: false, nullsFirst: true })
          .order('number', { ascending: false })
          .range(from, to),
      offset,
    ),
  );
}

export function useCustomerQuotes(shopId: string, customerId: string, enabled: boolean) {
  return useHistoryQuery(historyKeys.quotes(shopId, customerId), enabled, (offset) =>
    readHistoryPage(
      (from, to) =>
        supabase
          .from('quotes')
          .select('id, number, status, created_at, sent_at, valid_until, total_cents, vehicle_id', {
            count: 'exact',
          })
          .eq('shop_id', shopId)
          .eq('customer_id', customerId)
          .order('number', { ascending: false })
          .range(from, to),
      offset,
    ),
  );
}

export function useCustomerInvoices(shopId: string, customerId: string, enabled: boolean) {
  return useHistoryQuery(historyKeys.invoices(shopId, customerId), enabled, (offset) =>
    readHistoryPage(
      (from, to) =>
        supabase
          .from('invoices')
          .select(
            'id, number, status, issued_at, due_at, created_at, total_cents, balance_cents, job_id',
            { count: 'exact' },
          )
          .eq('shop_id', shopId)
          .eq('customer_id', customerId)
          .order('number', { ascending: false })
          .range(from, to),
      offset,
    ),
  );
}

export function useCustomerMemberships(shopId: string, customerId: string, enabled: boolean) {
  return useHistoryQuery(historyKeys.memberships(shopId, customerId), enabled, async (offset) => {
    const page = await readHistoryPage(
      (from, to) =>
        supabase
          .from('memberships')
          .select(
            'id, plan_id, vehicle_id, status, current_period_end, cancel_at_period_end, started_at, created_at',
            { count: 'exact' },
          )
          .eq('shop_id', shopId)
          .eq('customer_id', customerId)
          .order('created_at', { ascending: false })
          .order('id')
          .range(from, to),
      offset,
    );
    const planIds = [...new Set(page.rows.map((m) => m.plan_id))];
    const plans =
      planIds.length === 0
        ? []
        : (unwrap(
            await supabase
              .from('membership_plans')
              .select('id, name, price_cents, interval, interval_count')
              .eq('shop_id', shopId)
              .in('id', planIds),
          ) ?? []);
    const byId = new Map(plans.map((p) => [p.id, p]));
    return {
      rows: page.rows.map((m) => ({ ...m, plan: byId.get(m.plan_id) ?? null })),
      total: page.total,
    };
  });
}

export function useCustomerCards(shopId: string, customerId: string, enabled: boolean) {
  return useQuery({
    queryKey: historyKeys.cards(shopId, customerId),
    enabled,
    queryFn: async () =>
      unwrap(
        await supabase
          .from('customer_payment_methods')
          .select(
            'id, stripe_payment_method_id, brand, last4, exp_month, exp_year, is_default, created_at',
          )
          .eq('shop_id', shopId)
          .eq('customer_id', customerId)
          .order('is_default', { ascending: false })
          .order('created_at', { ascending: false }),
      ) ?? [],
  });
}

// ---------------------------------------------------------------- card-setup link (edge functions)

/** supabase.functions.invoke with the shared error mapping (functions README → Errors). */
async function invokeEdge(name: string, body: Record<string, unknown>): Promise<unknown> {
  const result = await supabase.functions.invoke<unknown>(name, { body });
  const error: unknown = result.error;
  if (error) throw await edgeFunctionError(error);
  return result.data;
}

const setupLinkSchema = z.object({
  url: z.url(),
  expires_at: z.number().nullish(),
});
export type CardSetupLink = z.infer<typeof setupLinkSchema>;

/** payments → setup_card_link (manager+): a Stripe Checkout setup-mode link. */
export function useCreateCardSetupLink(shopId: string, customerId: string) {
  return useMutation({
    mutationFn: async (requestNonce: string) => {
      const data = await invokeEdge('payments', {
        action: 'setup_card_link',
        shop_id: shopId,
        customer_id: customerId,
        request_nonce: requestNonce,
      });
      const parsed = setupLinkSchema.safeParse(data);
      if (!parsed.success) {
        throw new AppError('The payments service returned an unexpected response.', {
          kind: 'server',
        });
      }
      return parsed.data;
    },
  });
}

const removeCardSchema = z.object({ removed: z.boolean() });

/**
 * payments → remove_saved_card (manager+): detaches the card from the
 * customer's Stripe customer on the shop's account, then drops it from the
 * CRM. `removed: false` means it was already gone (a retry).
 */
export function useRemoveSavedCard(shopId: string, customerId: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (paymentMethodId: string) => {
      const data = await invokeEdge('payments', {
        action: 'remove_saved_card',
        shop_id: shopId,
        customer_id: customerId,
        payment_method_id: paymentMethodId,
      });
      const parsed = removeCardSchema.safeParse(data);
      if (!parsed.success) {
        throw new AppError('The payments service returned an unexpected response.', {
          kind: 'server',
        });
      }
      return parsed.data;
    },
    onSettled: () =>
      queryClient.invalidateQueries({ queryKey: historyKeys.cards(shopId, customerId) }),
  });
}

const sendResponseSchema = z.object({
  message_id: z.string(),
  status: z.string(),
  error: z.string().nullish(),
});

/**
 * messaging → send (functions README / messaging/send.ts): a free-form SMS to
 * the customer (manager+). The function queues it and tries delivery at once;
 * a failed or cancelled attempt is reported as an error.
 */
export function useSendCustomerSms(shopId: string, customerId: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (body: string) => {
      const data = await invokeEdge('messaging', {
        action: 'send',
        shop_id: shopId,
        customer_id: customerId,
        channel: 'sms',
        body,
      });
      const parsed = sendResponseSchema.safeParse(data);
      if (!parsed.success) {
        throw new AppError('The messaging service returned an unexpected response.', {
          kind: 'server',
        });
      }
      if (parsed.data.status === 'failed' || parsed.data.status === 'cancelled') {
        throw new AppError(parsed.data.error ?? 'The text message couldn’t be delivered.', {
          kind: 'server',
        });
      }
      return parsed.data;
    },
    onSettled: () => queryClient.invalidateQueries({ queryKey: shopKey(shopId, 'messages') }),
  });
}
