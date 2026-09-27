/**
 * Customers data layer (TanStack Query hooks). RLS decides what each role
 * sees: owners/admins/managers get every customer; technicians only those on
 * jobs assigned to them (customers_select_assigned).
 */
import { keepPreviousData, useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { z } from 'zod';
import { pageRange, type SortState } from '@/components/ui';
import { unwrap, unwrapRequired } from '@/lib/db';
import { AppError, edgeFunctionError } from '@/lib/errors';
import { shopKey } from '@/lib/queryKeys';
import { supabase } from '@/lib/supabase';
import { normalizeTags, type CustomerLifecycle, type CustomerRow } from './model';
import type { CustomerWrite, VehicleWrite } from './schemas';
import { searchPatterns } from './search';

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

export function useCustomerList(shopId: string, filters: CustomerListFilters) {
  return useQuery({
    queryKey: customerKeys.list(shopId, filters),
    placeholderData: keepPreviousData,
    queryFn: async ({ signal }) => {
      const { from, to } = pageRange(filters.page, filters.pageSize);
      const ascending = filters.sort.direction === 'asc';
      let query = supabase
        .from('customers')
        .select(CUSTOMER_LIST_COLUMNS, { count: 'exact' })
        .eq('shop_id', shopId);
      for (const pattern of searchPatterns(filters.search)) {
        query = query.ilike('search_text', pattern);
      }
      if (filters.tag) query = query.contains('tags', [filters.tag]);
      if (filters.lifecycle) query = query.eq('lifecycle', filters.lifecycle);
      if (filters.archived === 'active') query = query.is('archived_at', null);
      else if (filters.archived === 'archived') query = query.not('archived_at', 'is', null);

      if (filters.sort.key === 'name') {
        query = query
          .order('last_name', { ascending, nullsFirst: false })
          .order('first_name', { ascending, nullsFirst: false })
          .order('company', { ascending, nullsFirst: false });
      } else {
        query = query.order(filters.sort.key, { ascending });
      }
      const result = await query.order('id').range(from, to).abortSignal(signal);
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

// ---------------------------------------------------------------- history tabs

const HISTORY_LIMIT = 100;

export function useCustomerJobs(shopId: string, customerId: string) {
  return useQuery({
    queryKey: historyKeys.jobs(shopId, customerId),
    queryFn: async () =>
      unwrap(
        await supabase
          .from('jobs')
          .select(
            'id, number, status, scheduled_start, scheduled_end, vehicle_id, total_cents, created_at',
          )
          .eq('shop_id', shopId)
          .eq('customer_id', customerId)
          .order('scheduled_start', { ascending: false, nullsFirst: true })
          .order('number', { ascending: false })
          .limit(HISTORY_LIMIT),
      ) ?? [],
  });
}

export function useCustomerQuotes(shopId: string, customerId: string, enabled: boolean) {
  return useQuery({
    queryKey: historyKeys.quotes(shopId, customerId),
    enabled,
    queryFn: async () =>
      unwrap(
        await supabase
          .from('quotes')
          .select('id, number, status, created_at, sent_at, valid_until, total_cents, vehicle_id')
          .eq('shop_id', shopId)
          .eq('customer_id', customerId)
          .order('number', { ascending: false })
          .limit(HISTORY_LIMIT),
      ) ?? [],
  });
}

export function useCustomerInvoices(shopId: string, customerId: string, enabled: boolean) {
  return useQuery({
    queryKey: historyKeys.invoices(shopId, customerId),
    enabled,
    queryFn: async () =>
      unwrap(
        await supabase
          .from('invoices')
          .select(
            'id, number, status, issued_at, due_at, created_at, total_cents, balance_cents, job_id',
          )
          .eq('shop_id', shopId)
          .eq('customer_id', customerId)
          .order('number', { ascending: false })
          .limit(HISTORY_LIMIT),
      ) ?? [],
  });
}

export function useCustomerMemberships(shopId: string, customerId: string, enabled: boolean) {
  return useQuery({
    queryKey: historyKeys.memberships(shopId, customerId),
    enabled,
    queryFn: async () => {
      const memberships =
        unwrap(
          await supabase
            .from('memberships')
            .select(
              'id, plan_id, vehicle_id, status, current_period_end, cancel_at_period_end, started_at, created_at',
            )
            .eq('shop_id', shopId)
            .eq('customer_id', customerId)
            .order('created_at', { ascending: false })
            .limit(HISTORY_LIMIT),
        ) ?? [];
      const planIds = [...new Set(memberships.map((m) => m.plan_id))];
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
      return memberships.map((m) => ({ ...m, plan: byId.get(m.plan_id) ?? null }));
    },
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
          .select('id, brand, last4, exp_month, exp_year, is_default, created_at')
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
