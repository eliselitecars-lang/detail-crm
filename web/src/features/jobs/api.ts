/**
 * Jobs data layer (SPEC §4.4). Numbers, totals, tax, statuses' timestamps
 * and coupon discounts are maintained by the jobs_* / job_line_items_*
 * triggers; this module only writes content and reads server values back.
 * Field operations (checklist, photos, inspections, forms, time, messages,
 * money panel) live in ./fieldApi.ts.
 */
import { keepPreviousData, useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { z } from 'zod';
import { pageRange } from '@/components/ui';
import { shopDateRangeUtc } from '@/lib/dates';
import { unwrap, unwrapRequired, type InsertRow, type Row, type UpdateRow } from '@/lib/db';
import { unwrapList } from './db';
import { AppError } from '@/lib/errors';
import { readCustomData } from '@/lib/customFields';
import { shopKey } from '@/lib/queryKeys';
import { supabase } from '@/lib/supabase';
import { cancelOpenPaymentsResultSchema } from '@/features/invoices/api';
import { invokeEdge } from '@/features/quotes/shared/edge';
import { useShop } from '@/features/shop/shopContext';
import {
  JOB_STATUSES,
  movedLineOrder,
  type JobFilters,
  type JobStatus,
  type StatusTransition,
} from './model';

export const JOB_PAGE_SIZE = 25;

export const jobKeys = {
  all: (shopId: string) => shopKey(shopId, 'jobs'),
  list: (shopId: string, filters: JobFilters) => [...jobKeys.all(shopId), 'list', filters] as const,
  detail: (shopId: string, id: string) => [...jobKeys.all(shopId), 'detail', id] as const,
  part: (shopId: string, id: string, part: string) =>
    [...jobKeys.detail(shopId, id), part] as const,
  transitions: () => ['reference', 'job_status_transitions'] as const,
  team: (shopId: string) => shopKey(shopId, 'team', 'directory'),
  resources: (shopId: string) => shopKey(shopId, 'settings', 'resources'),
  categories: (shopId: string) => shopKey(shopId, 'settings', 'vehicle_categories'),
  catalog: (shopId: string) => shopKey(shopId, 'catalog', 'job-picker'),
  coupons: (shopId: string) => shopKey(shopId, 'catalog', 'coupons', 'active'),
  pricing: (shopId: string, args: unknown) => shopKey(shopId, 'catalog', 'pricing', args),
  customerSearch: (shopId: string, q: string) => shopKey(shopId, 'customers', 'job-search', q),
  customer: (shopId: string, id: string) => shopKey(shopId, 'customers', 'job-customer', id),
  vehicles: (shopId: string, customerId: string) =>
    shopKey(shopId, 'vehicles', 'by-customer', customerId),
};

const jobStatusSchema = z.enum(JOB_STATUSES);
const locationSchema = z.enum(['shop', 'mobile']);

// ---------------------------------------------------------------------------
// Reference data
// ---------------------------------------------------------------------------

/** job_status_transitions — the same for every shop; read once. */
export function useStatusTransitions() {
  return useQuery({
    queryKey: jobKeys.transitions(),
    staleTime: Infinity,
    queryFn: async (): Promise<StatusTransition[]> =>
      unwrapList(
        await supabase
          .from('job_status_transitions')
          .select('from_status, to_status, direction, technician_allowed'),
      ),
  });
}

export interface TeamMember {
  memberId: string;
  name: string;
  role: Row<'shop_members'>['role'];
  color: string | null;
  active: boolean;
}

const teamRowSchema = z.object({
  member_id: z.string(),
  display_name: z.string(),
  role: z.enum(['owner', 'admin', 'manager', 'technician']),
  calendar_color: z.string().nullable(),
  active: z.boolean(),
});

/** Team directory (shop_team RPC: names/colours for every member, techs included). */
export function useTeam() {
  const { shopId } = useShop();
  return useQuery({
    queryKey: jobKeys.team(shopId),
    staleTime: 5 * 60_000,
    queryFn: async (): Promise<TeamMember[]> => {
      const rows = z
        .array(teamRowSchema)
        .parse(unwrap(await supabase.rpc('shop_team', { p_shop_id: shopId })));
      return rows
        .map((r) => ({
          memberId: r.member_id,
          name: r.display_name,
          role: r.role,
          color: r.calendar_color,
          active: r.active,
        }))
        .sort((a, b) => a.name.localeCompare(b.name));
    },
  });
}

export type Resource = Pick<Row<'resources'>, 'id' | 'name' | 'kind' | 'active' | 'archived_at'>;

export function useResources() {
  const { shopId } = useShop();
  return useQuery({
    queryKey: jobKeys.resources(shopId),
    staleTime: 5 * 60_000,
    queryFn: async (): Promise<Resource[]> =>
      unwrapList(
        await supabase
          .from('resources')
          .select('id, name, kind, active, archived_at')
          .eq('shop_id', shopId)
          .order('sort')
          .order('name'),
      ),
  });
}

export type VehicleCategory = Pick<Row<'vehicle_categories'>, 'id' | 'name' | 'sort'>;

export function useVehicleCategories() {
  const { shopId } = useShop();
  return useQuery({
    queryKey: jobKeys.categories(shopId),
    staleTime: 5 * 60_000,
    queryFn: async (): Promise<VehicleCategory[]> =>
      unwrapList(
        await supabase
          .from('vehicle_categories')
          .select('id, name, sort')
          .eq('shop_id', shopId)
          .order('sort')
          .order('name'),
      ),
  });
}

export type CatalogService = Pick<
  Row<'services'>,
  'id' | 'name' | 'kind' | 'duration_minutes' | 'category_id' | 'description' | 'sort'
>;

export interface CatalogData {
  services: CatalogService[];
  categories: Pick<Row<'service_categories'>, 'id' | 'name' | 'sort'>[];
}

/** Active, non-archived services + their categories (for pickers). */
export function useCatalog(enabled = true) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: jobKeys.catalog(shopId),
    enabled,
    staleTime: 60_000,
    queryFn: async (): Promise<CatalogData> => {
      const [services, categories] = await Promise.all([
        supabase
          .from('services')
          .select('id, name, kind, duration_minutes, category_id, description, sort')
          .eq('shop_id', shopId)
          .eq('active', true)
          .is('archived_at', null)
          .order('sort')
          .order('name'),
        supabase
          .from('service_categories')
          .select('id, name, sort')
          .eq('shop_id', shopId)
          .order('sort')
          .order('name'),
      ]);
      return { services: unwrapList(services), categories: unwrapList(categories) };
    },
  });
}

export type Coupon = Pick<
  Row<'coupons'>,
  'id' | 'code' | 'kind' | 'value' | 'online_only' | 'active' | 'starts_at' | 'ends_at'
>;

export function useActiveCoupons(enabled: boolean) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: jobKeys.coupons(shopId),
    enabled,
    queryFn: async (): Promise<Coupon[]> =>
      unwrapList(
        await supabase
          .from('coupons')
          .select('id, code, kind, value, online_only, active, starts_at, ends_at')
          .eq('shop_id', shopId)
          .eq('active', true)
          .eq('online_only', false)
          .order('code'),
      ),
  });
}

// ---------------------------------------------------------------------------
// Pricing (price_services RPC — manager+)
// ---------------------------------------------------------------------------

const pricedLineSchema = z.object({
  service_id: z.string(),
  name: z.string(),
  kind: z.string(),
  taxable: z.boolean(),
  duration_minutes: z.number().nullable(),
  catalog_price_cents: z.number().nullable(),
  unit_price_cents: z.number().nullable(),
  membership_included: z.boolean(),
  note: z.string().nullable(),
});

export const pricingSchema = z.object({
  vehicle_category_id: z.string().nullable(),
  tax_rate_bps: z.number().nullable(),
  duration_minutes: z.number().nullable(),
  priced: z.boolean().nullable(),
  lines: z.array(pricedLineSchema).nullable(),
  memberships: z
    .array(
      z.object({
        membership_id: z.string(),
        plan_id: z.string(),
        plan_name: z.string(),
        discount_bps: z.number(),
        vehicle_id: z.string().nullable(),
      }),
    )
    .nullable(),
  suggested_discount_kind: z.enum(['none', 'percent']),
  suggested_discount_value: z.number(),
  totals: z
    .object({
      subtotal_cents: z.number(),
      discount_cents: z.number(),
      tax_cents: z.number(),
      total_cents: z.number(),
    })
    .nullable(),
});

export type Pricing = z.infer<typeof pricingSchema>;
export type PricedLine = z.infer<typeof pricedLineSchema>;

export interface PricingArgs {
  customerId: string;
  /** null when the shop has no vehicle sizes: base prices apply (argument omitted). */
  vehicleCategoryId: string | null;
  vehicleId: string | null;
  serviceIds: string[];
}

export async function fetchPricing(shopId: string, args: PricingArgs): Promise<Pricing> {
  const data = unwrap(
    await supabase.rpc('price_services', {
      p_shop: shopId,
      p_customer_id: args.customerId,
      ...(args.vehicleCategoryId ? { p_vehicle_category_id: args.vehicleCategoryId } : {}),
      p_service_ids: args.serviceIds,
      ...(args.vehicleId ? { p_vehicle_id: args.vehicleId } : {}),
    }),
  );
  return pricingSchema.parse(data);
}

export function usePricing(args: PricingArgs | null) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: jobKeys.pricing(shopId, args),
    enabled: args !== null && args.serviceIds.length > 0,
    placeholderData: keepPreviousData,
    queryFn: () => {
      if (!args) throw new Error('pricing arguments missing');
      return fetchPricing(shopId, args);
    },
  });
}

// ---------------------------------------------------------------------------
// Jobs list
// ---------------------------------------------------------------------------

const nameEmbed = z
  .object({
    id: z.string(),
    first_name: z.string().nullable(),
    last_name: z.string().nullable(),
    company: z.string().nullable(),
  })
  .nullable();

const vehicleEmbed = z
  .object({
    id: z.string(),
    year: z.number().nullable(),
    make: z.string().nullable(),
    model: z.string().nullable(),
  })
  .nullable();

const jobListRowSchema = z.object({
  id: z.string(),
  number: z.number(),
  status: jobStatusSchema,
  scheduled_start: z.string().nullable(),
  scheduled_end: z.string().nullable(),
  total_cents: z.number(),
  location_type: locationSchema,
  customer: nameEmbed,
  vehicle: vehicleEmbed,
  line_items: z.array(z.object({ name: z.string(), sort: z.number() })),
  assignments: z.array(z.object({ member_id: z.string() })),
});

export type JobListRow = z.infer<typeof jobListRowSchema>;

const LIST_COLUMNS =
  'id, number, status, scheduled_start, scheduled_end, total_cents, location_type, ' +
  'customer:customers!jobs_customer_fk(id, first_name, last_name, company), ' +
  'vehicle:vehicles!jobs_vehicle_fk(id, year, make, model), ' +
  'line_items:job_line_items(name, sort), assignments:job_assignments(member_id)';

const searchHitSchema = z.array(
  z.object({ kind: z.string(), id: z.string(), customer_id: z.string().nullable() }),
);

/** Resolves a free-text search to job / customer / vehicle ids (search_shop RPC). */
async function searchTargets(shopId: string, query: string) {
  const hits = searchHitSchema.parse(
    unwrap(await supabase.rpc('search_shop', { p_shop_id: shopId, p_query: query, p_limit: 50 })),
  );
  return {
    jobIds: hits.filter((h) => h.kind === 'job').map((h) => h.id),
    customerIds: hits.filter((h) => h.kind === 'customer').map((h) => h.id),
    vehicleIds: hits.filter((h) => h.kind === 'vehicle').map((h) => h.id),
  };
}

export function useJobs(filters: JobFilters) {
  const { shopId, timezone } = useShop();
  return useQuery({
    queryKey: jobKeys.list(shopId, filters),
    placeholderData: keepPreviousData,
    queryFn: async (): Promise<{ rows: JobListRow[]; total: number }> => {
      const columns = filters.assigneeId
        ? `${LIST_COLUMNS}, assignee_filter:job_assignments!inner(member_id)`
        : LIST_COLUMNS;
      let request = supabase.from('jobs').select(columns, { count: 'exact' }).eq('shop_id', shopId);
      if (filters.statuses.length > 0) request = request.in('status', filters.statuses);
      if (filters.from || filters.to) {
        const range = shopDateRangeUtc(
          filters.from ?? filters.to ?? '',
          filters.to ?? filters.from ?? '',
          timezone,
        );
        if (filters.from) request = request.gte('scheduled_start', range.from);
        if (filters.to) request = request.lt('scheduled_start', range.to);
      }
      if (filters.assigneeId) request = request.eq('assignee_filter.member_id', filters.assigneeId);
      const search = filters.search.trim();
      if (search) {
        const t = await searchTargets(shopId, search);
        const clauses = [
          t.jobIds.length ? `id.in.(${t.jobIds.join(',')})` : null,
          t.customerIds.length ? `customer_id.in.(${t.customerIds.join(',')})` : null,
          t.vehicleIds.length ? `vehicle_id.in.(${t.vehicleIds.join(',')})` : null,
        ].filter((c): c is string => c !== null);
        if (clauses.length === 0) return { rows: [], total: 0 };
        request = request.or(clauses.join(','));
      }
      const column =
        filters.sort === 'number'
          ? 'number'
          : filters.sort === 'total'
            ? 'total_cents'
            : 'scheduled_start';
      request = request.order(column, {
        ascending: filters.ascending,
        nullsFirst: column === 'scheduled_start' ? !filters.ascending : false,
      });
      if (column !== 'number') request = request.order('number', { ascending: false });
      const { from, to } = pageRange(filters.page, JOB_PAGE_SIZE);
      const result = await request.range(from, to);
      const rows = z.array(jobListRowSchema).parse(unwrap(result) ?? []);
      return {
        rows: rows.map((r) => ({
          ...r,
          line_items: [...r.line_items].sort((a, b) => a.sort - b.sort),
        })),
        total: result.count ?? rows.length,
      };
    },
  });
}

// ---------------------------------------------------------------------------
// Job detail
// ---------------------------------------------------------------------------

const customerDetailSchema = z
  .object({
    id: z.string(),
    first_name: z.string().nullable(),
    last_name: z.string().nullable(),
    company: z.string().nullable(),
    email: z.string().nullable(),
    phone: z.string().nullable(),
    address_line1: z.string().nullable(),
    address_line2: z.string().nullable(),
    city: z.string().nullable(),
    region: z.string().nullable(),
    postal_code: z.string().nullable(),
    sms_opted_out_at: z.string().nullable(),
    email_opted_out_at: z.string().nullable(),
  })
  .nullable();

const vehicleDetailSchema = z
  .object({
    id: z.string(),
    year: z.number().nullable(),
    make: z.string().nullable(),
    model: z.string().nullable(),
    trim: z.string().nullable(),
    color: z.string().nullable(),
    vin: z.string().nullable(),
    license_plate: z.string().nullable(),
    category_id: z.string().nullable(),
  })
  .nullable();

const jobDetailSchema = z.object({
  id: z.string(),
  shop_id: z.string(),
  number: z.number(),
  customer_id: z.string(),
  vehicle_id: z.string().nullable(),
  status: jobStatusSchema,
  scheduled_start: z.string().nullable(),
  scheduled_end: z.string().nullable(),
  location_type: locationSchema,
  service_address_line1: z.string().nullable(),
  service_address_line2: z.string().nullable(),
  service_city: z.string().nullable(),
  service_region: z.string().nullable(),
  service_postal_code: z.string().nullable(),
  resource_id: z.string().nullable(),
  notes: z.string().nullable(),
  internal_notes: z.string().nullable(),
  source: z.string(),
  quote_id: z.string().nullable(),
  coupon_id: z.string().nullable(),
  discount_kind: z.enum(['none', 'percent', 'fixed']),
  discount_value: z.number(),
  subtotal_cents: z.number(),
  discount_cents: z.number(),
  tax_rate_bps: z.number(),
  tax_cents: z.number(),
  total_cents: z.number(),
  deposit_required_cents: z.number(),
  created_at: z.string(),
  updated_at: z.string(),
  confirmed_at: z.string().nullable(),
  en_route_at: z.string().nullable(),
  started_at: z.string().nullable(),
  completed_at: z.string().nullable(),
  cancelled_at: z.string().nullable(),
  cancel_reason: z.string().nullable(),
  reminder_sent_at: z.string().nullable(),
  review_requested_at: z.string().nullable(),
  // parity columns (0050 / 0061 / 0085); defaults keep older fixtures readable
  series_id: z.string().nullable().default(null),
  series_seq: z.number().nullable().default(null),
  series_detached: z.boolean().default(false),
  custom_data: z.unknown().default({}).transform(readCustomData),
  sold_by_member_id: z.string().nullable().default(null),
  deposit_followups_paused: z.boolean().default(false),
  customer: customerDetailSchema,
  vehicle: vehicleDetailSchema,
});

export type JobDetail = z.infer<typeof jobDetailSchema>;

const DETAIL_COLUMNS =
  'id, shop_id, number, customer_id, vehicle_id, status, scheduled_start, scheduled_end, ' +
  'location_type, service_address_line1, service_address_line2, service_city, service_region, ' +
  'service_postal_code, resource_id, notes, internal_notes, source, quote_id, coupon_id, ' +
  'discount_kind, discount_value, subtotal_cents, discount_cents, tax_rate_bps, tax_cents, ' +
  'total_cents, deposit_required_cents, created_at, updated_at, confirmed_at, en_route_at, ' +
  'started_at, completed_at, cancelled_at, cancel_reason, reminder_sent_at, review_requested_at, ' +
  'series_id, series_seq, series_detached, custom_data, sold_by_member_id, deposit_followups_paused, ' +
  'customer:customers!jobs_customer_fk(id, first_name, last_name, company, email, phone, ' +
  'address_line1, address_line2, city, region, postal_code, sms_opted_out_at, email_opted_out_at), ' +
  'vehicle:vehicles!jobs_vehicle_fk(id, year, make, model, trim, color, vin, license_plate, category_id)';

export function useJob(jobId: string) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: jobKeys.part(shopId, jobId, 'job'),
    queryFn: async (): Promise<JobDetail> => {
      const data = unwrapRequired(
        await supabase
          .from('jobs')
          .select(DETAIL_COLUMNS)
          .eq('shop_id', shopId)
          .eq('id', jobId)
          .maybeSingle(),
        'job',
      );
      return jobDetailSchema.parse(data);
    },
  });
}

export type LineItem = Pick<
  Row<'job_line_items'>,
  | 'id'
  | 'service_id'
  | 'fee_id'
  | 'vehicle_id'
  | 'name'
  | 'description'
  | 'quantity'
  | 'unit_price_cents'
  | 'discount_cents'
  | 'taxable'
  | 'duration_minutes'
  | 'sort'
  | 'total_cents'
>;

export function useLineItems(jobId: string) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: jobKeys.part(shopId, jobId, 'lines'),
    queryFn: async (): Promise<LineItem[]> =>
      unwrapList(
        await supabase
          .from('job_line_items')
          .select(
            'id, service_id, fee_id, vehicle_id, name, description, quantity, unit_price_cents, discount_cents, taxable, duration_minutes, sort, total_cents',
          )
          .eq('shop_id', shopId)
          .eq('job_id', jobId)
          .order('sort')
          .order('created_at'),
      ),
  });
}

export function useAssignments(jobId: string) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: jobKeys.part(shopId, jobId, 'assignments'),
    queryFn: async (): Promise<Pick<Row<'job_assignments'>, 'id' | 'member_id'>[]> =>
      unwrapList(
        await supabase
          .from('job_assignments')
          .select('id, member_id')
          .eq('shop_id', shopId)
          .eq('job_id', jobId)
          .order('created_at'),
      ),
  });
}

// ---------------------------------------------------------------------------
// Job mutations
// ---------------------------------------------------------------------------

function useInvalidateJobs() {
  const queryClient = useQueryClient();
  const { shopId } = useShop();
  return () => queryClient.invalidateQueries({ queryKey: jobKeys.all(shopId) });
}

export type JobPatch = Pick<
  UpdateRow<'jobs'>,
  | 'scheduled_start'
  | 'scheduled_end'
  | 'location_type'
  | 'service_address_line1'
  | 'service_address_line2'
  | 'service_city'
  | 'service_region'
  | 'service_postal_code'
  | 'resource_id'
  | 'notes'
  | 'internal_notes'
  | 'discount_kind'
  | 'discount_value'
  | 'coupon_id'
  | 'deposit_required_cents'
  | 'vehicle_id'
  | 'sold_by_member_id'
  | 'custom_data'
>;

export async function updateJob(shopId: string, jobId: string, patch: JobPatch): Promise<void> {
  const result = await supabase
    .from('jobs')
    .update(patch)
    .eq('shop_id', shopId)
    .eq('id', jobId)
    .select('id');
  const rows = unwrap(result);
  if (!rows || rows.length === 0) {
    throw new AppError('This job could not be updated. It may have been removed.', {
      kind: 'not_found',
    });
  }
}

export function useUpdateJob(jobId: string) {
  const { shopId } = useShop();
  const invalidate = useInvalidateJobs();
  return useMutation({
    mutationFn: (patch: JobPatch) => updateJob(shopId, jobId, patch),
    onSettled: invalidate,
  });
}

/** Reschedule (calendar drag/resize or schedule edit), optionally to another bay / van. */
export function useReschedule() {
  const { shopId } = useShop();
  const invalidate = useInvalidateJobs();
  return useMutation({
    mutationFn: ({
      jobId,
      start,
      end,
      resourceId,
    }: {
      jobId: string;
      start: string;
      end: string;
      /** Set only when the job also moves to another bay / van (resource view). */
      resourceId?: string | null;
    }) =>
      updateJob(
        shopId,
        jobId,
        resourceId === undefined
          ? { scheduled_start: start, scheduled_end: end }
          : { scheduled_start: start, scheduled_end: end, resource_id: resourceId },
      ),
    onSettled: invalidate,
  });
}

/**
 * payments.cancel_open_payments with `job_id`: before a job is cancelled or
 * marked no-show, releases every unsettled card attempt of the job (deposit
 * sheets, its invoice's sheets) and expires its open deposit / pay links, so
 * nobody can pay for an appointment that is not happening. Payments already
 * processing are reported (`in_progress`) — the caller must wait; payments
 * that already went through are recorded (`succeeded`). A shop without Stripe
 * answers with zeros. Collectors only (manager+, or a technician on an
 * assigned job when the shop lets technicians take payments).
 */
export function useReleaseJobPayments(jobId: string) {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: () =>
      invokeEdge(
        'payments',
        'cancel_open_payments',
        { shop_id: shopId, job_id: jobId },
        cancelOpenPaymentsResultSchema,
      ),
    onSettled: () =>
      Promise.all(
        (['jobs', 'invoices', 'payments'] as const).map((domain) =>
          queryClient.invalidateQueries({ queryKey: shopKey(shopId, domain) }),
        ),
      ),
  });
}

/**
 * set_job_status (0073): the status RPC for every role — the same transition
 * rules as a direct update (managers any edge; technicians the
 * technician_allowed forward edges of their jobs). `force` (managers+) moves
 * past the completion gates and records the override with `reason`; for a
 * move to cancelled the reason is also the job's cancel_reason.
 */
export function useSetStatus(jobId: string) {
  const invalidate = useInvalidateJobs();
  return useMutation({
    mutationFn: async ({
      status,
      reason,
      force,
    }: {
      status: JobStatus;
      reason?: string;
      force?: boolean;
    }) => {
      const text = reason?.trim() ?? '';
      unwrap(
        await supabase.rpc('set_job_status', {
          p_job_id: jobId,
          p_status: status,
          ...(force ? { p_force: true } : {}),
          ...(text ? { p_reason: text } : {}),
        }),
      );
    },
    onSettled: invalidate,
  });
}

const gateStateSchema = z.object({
  open_required_items: z.array(z.object({ id: z.string(), label: z.string() })),
  before_photos: z.object({ required: z.number(), have: z.number() }),
  after_photos: z.object({ required: z.number(), have: z.number() }),
});

export type GateState = z.infer<typeof gateStateSchema>;

/** job_completion_blockers: required checklist items still open + photo counts (images only). */
export async function fetchCompletionBlockers(jobId: string): Promise<GateState> {
  return gateStateSchema.parse(
    unwrap(await supabase.rpc('job_completion_blockers', { p_job_id: jobId })),
  );
}

// Line items -----------------------------------------------------------------

export type LineDraft = Pick<
  InsertRow<'job_line_items'>,
  | 'service_id'
  | 'vehicle_id'
  | 'name'
  | 'description'
  | 'quantity'
  | 'unit_price_cents'
  | 'discount_cents'
  | 'taxable'
  | 'duration_minutes'
>;

export function useAddLineItems(jobId: string) {
  const { shopId } = useShop();
  const invalidate = useInvalidateJobs();
  return useMutation({
    mutationFn: async ({ lines, startSort }: { lines: LineDraft[]; startSort: number }) => {
      if (lines.length === 0) return;
      unwrap(
        await supabase.from('job_line_items').insert(
          lines.map((line, i) => ({
            ...line,
            shop_id: shopId,
            job_id: jobId,
            sort: startSort + i,
          })),
        ),
      );
    },
    onSettled: invalidate,
  });
}

export type LinePatch = Pick<
  UpdateRow<'job_line_items'>,
  | 'vehicle_id'
  | 'name'
  | 'description'
  | 'quantity'
  | 'unit_price_cents'
  | 'discount_cents'
  | 'taxable'
  | 'duration_minutes'
  | 'sort'
>;

export function useUpdateLineItem() {
  const { shopId } = useShop();
  const invalidate = useInvalidateJobs();
  return useMutation({
    mutationFn: async ({ id, patch }: { id: string; patch: LinePatch }) => {
      unwrap(
        await supabase.from('job_line_items').update(patch).eq('shop_id', shopId).eq('id', id),
      );
    },
    onSettled: invalidate,
  });
}

/**
 * Moves a line one step up / down: reorder_job_line_items (0092) rewrites
 * the whole order atomically from the complete id list (manager+; 22023 when
 * the list is stale — another tab added or removed a line — so the refetch
 * after an error shows the current lines).
 */
export function useMoveLineItem(jobId: string) {
  const invalidate = useInvalidateJobs();
  return useMutation({
    mutationFn: async ({
      rows,
      index,
      delta,
    }: {
      rows: readonly Pick<LineItem, 'id'>[];
      index: number;
      delta: -1 | 1;
    }) => {
      const ids = movedLineOrder(rows, index, delta);
      if (!ids) return;
      unwrap(await supabase.rpc('reorder_job_line_items', { p_job_id: jobId, p_ids: ids }));
    },
    onSettled: invalidate,
  });
}

/** add_fee_line('job', …) (0068, manager+): the fee becomes an ordinary line. */
export function useAddFeeLine(jobId: string) {
  const invalidate = useInvalidateJobs();
  return useMutation({
    mutationFn: async (feeId: string) => {
      unwrap(
        await supabase.rpc('add_fee_line', { p_doc_kind: 'job', p_doc_id: jobId, p_fee_id: feeId }),
      );
    },
    onSettled: invalidate,
  });
}

export function useDeleteLineItem() {
  const { shopId } = useShop();
  const invalidate = useInvalidateJobs();
  return useMutation({
    mutationFn: async (id: string) => {
      unwrap(await supabase.from('job_line_items').delete().eq('shop_id', shopId).eq('id', id));
    },
    onSettled: invalidate,
  });
}

// Assignments ----------------------------------------------------------------

export function useSetAssigned(jobId: string) {
  const { shopId } = useShop();
  const invalidate = useInvalidateJobs();
  return useMutation({
    mutationFn: async ({ memberId, assigned }: { memberId: string; assigned: boolean }) => {
      if (assigned) {
        unwrap(
          await supabase
            .from('job_assignments')
            .upsert(
              { shop_id: shopId, job_id: jobId, member_id: memberId },
              { onConflict: 'shop_id,job_id,member_id', ignoreDuplicates: true },
            ),
        );
      } else {
        unwrap(
          await supabase
            .from('job_assignments')
            .delete()
            .eq('shop_id', shopId)
            .eq('job_id', jobId)
            .eq('member_id', memberId),
        );
      }
    },
    onSettled: invalidate,
  });
}
