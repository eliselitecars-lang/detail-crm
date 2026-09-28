/**
 * Settings data layer (SPEC §4.1, §4.3 coupons, §4.6 forms, §4.7 templates,
 * §5 stripe-connect). Every query is scoped to the current shop; RLS enforces
 * the SPEC §3 matrix (owner/admin write, managers read, blocked times are
 * manager+). Components never call `supabase` directly.
 */
import type { PostgrestError } from '@supabase/supabase-js';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { z } from 'zod';
import { useShop, useShopContext } from '@/features/shop/shopContext';
import type { BusinessHoursRow } from '@/features/shop/businessHours';
import { replaceBusinessHours } from '@/features/shop/onboarding/api';
import type { Json } from '@/lib/database.types';
import type { RecurrenceRule } from './schemas';
import { unwrap, unwrapRequired, type InsertRow, type Row, type UpdateRow } from '@/lib/db';
import { AppError, edgeFunctionError, errorMessage, toAppError } from '@/lib/errors';
import { EdgeFunctionError, invokeEdge } from '@/features/quotes/shared/edge';
import { shopKey } from '@/lib/queryKeys';
import { supabase } from '@/lib/supabase';

/** `unwrap` for list selects: a successful select never yields null rows. */
function unwrapList<T>(result: { data: T[] | null; error: PostgrestError | null }): T[] {
  return unwrap(result) ?? [];
}

// ---------------------------------------------------------------------------
// Query keys
// ---------------------------------------------------------------------------

export const settingsKeys = {
  all: (shopId: string) => shopKey(shopId, 'settings'),
  shop: (shopId: string) => [...settingsKeys.all(shopId), 'shop'] as const,
  booking: (shopId: string) => [...settingsKeys.all(shopId), 'booking'] as const,
  hours: (shopId: string) => [...settingsKeys.all(shopId), 'hours'] as const,
  blocked: (shopId: string, showPast: boolean) =>
    [...settingsKeys.all(shopId), 'blocked', { showPast }] as const,
  members: (shopId: string) => [...settingsKeys.all(shopId), 'members'] as const,
  /**
   * NOT `'resources'`: `shopKey(shopId, 'settings', 'resources')` is the jobs
   * feature's picker list (all rows incl. archived, no `sort`). Sharing it would
   * serve one feature the other's differently shaped rows.
   */
  resources: (shopId: string) => [...settingsKeys.all(shopId), 'resource-admin'] as const,
  categories: (shopId: string) => [...settingsKeys.all(shopId), 'vehicle-categories'] as const,
  categoryUsage: (shopId: string, categoryId: string) =>
    [...settingsKeys.all(shopId), 'vehicle-category-usage', categoryId] as const,
  coupons: (shopId: string) => [...settingsKeys.all(shopId), 'coupons'] as const,
  templates: (shopId: string) => [...settingsKeys.all(shopId), 'templates'] as const,
  templateDefaults: (shopId: string) => [...settingsKeys.all(shopId), 'template-defaults'] as const,
  forms: (shopId: string) => [...settingsKeys.all(shopId), 'forms'] as const,
  stripe: (shopId: string) => [...settingsKeys.all(shopId), 'stripe'] as const,
};

/**
 * Other features' caches that read settings tables (keys owned by those
 * features; prefixes so every variant matches):
 *   - calendar events + blocked-time busy blocks: `jobs/calendar/…`
 *     (calendar/api.ts calendarKeys.events)
 *   - calendar hours, job resource/category/form-template pickers live under
 *     the `settings` domain (`settings/business_hours`, `settings/resources`,
 *     `settings/vehicle_categories`, `settings/form_templates/active`), so
 *     `settingsKeys.all` covers them
 *   - job coupon picker: `catalog/coupons/active` (jobs/api.ts)
 *   - inbox template list and rendered previews: `messages/templates`,
 *     `messages/preview/…` (messages/api.ts)
 */
export const dependentKeys = {
  calendarEvents: (shopId: string) => shopKey(shopId, 'jobs', 'calendar'),
  coupons: (shopId: string) => shopKey(shopId, 'catalog', 'coupons'),
  messageTemplates: (shopId: string) => shopKey(shopId, 'messages', 'templates'),
  messagePreviews: (shopId: string) => shopKey(shopId, 'messages', 'preview'),
  /**
   * Quote / deposit / invoice follow-up status cards (followupKeys.all in
   * features/quotes/shared/followups): whether a follow-up is on depends on
   * Settings -> Follow-ups and on its template's channels.
   */
  documentFollowups: (shopId: string) => shopKey(shopId, 'followups'),
};

type QueryClient = ReturnType<typeof useQueryClient>;

function invalidateAll(queryClient: QueryClient, keys: readonly (readonly unknown[])[]) {
  return Promise.all(keys.map((queryKey) => queryClient.invalidateQueries({ queryKey })));
}

// ---------------------------------------------------------------------------
// Shop profile / taxes / SMS number (the `shops` row)
// ---------------------------------------------------------------------------

const SHOP_COLUMNS =
  'id, name, slug, email, phone, website, address_line1, address_line2, city, region, postal_code, country, timezone, currency, logo_path, brand_color, business_type, tax_rate_bps, techs_can_collect_payments, techs_can_share_reports, review_url, quote_terms, invoice_terms, invoice_due_days, sms_from_number, updated_at';

export type ShopSettings = Pick<
  Row<'shops'>,
  | 'id'
  | 'name'
  | 'slug'
  | 'email'
  | 'phone'
  | 'website'
  | 'address_line1'
  | 'address_line2'
  | 'city'
  | 'region'
  | 'postal_code'
  | 'country'
  | 'timezone'
  | 'currency'
  | 'logo_path'
  | 'brand_color'
  | 'business_type'
  | 'tax_rate_bps'
  | 'techs_can_collect_payments'
  | 'techs_can_share_reports'
  | 'review_url'
  | 'quote_terms'
  | 'invoice_terms'
  | 'invoice_due_days'
  | 'sms_from_number'
  | 'updated_at'
>;

export type ShopPatch = Omit<
  UpdateRow<'shops'>,
  'id' | 'created_at' | 'created_by' | 'updated_at' | 'slug'
>;

export function useShopSettings() {
  const { shopId } = useShop();
  return useQuery({
    queryKey: settingsKeys.shop(shopId),
    queryFn: async (): Promise<ShopSettings> =>
      unwrapRequired(
        await supabase.from('shops').select(SHOP_COLUMNS).eq('id', shopId).maybeSingle(),
        'shop',
      ),
  });
}

/**
 * Updates the shop row. The shell's shop summary (name, logo, brand colour,
 * timezone, tax rate, techs_can_collect_payments…) is refreshed afterwards.
 */
export function useUpdateShop() {
  const { shopId } = useShop();
  const { refetch } = useShopContext();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (patch: ShopPatch): Promise<ShopSettings> =>
      unwrapRequired(
        await supabase
          .from('shops')
          .update(patch)
          .eq('id', shopId)
          .select(SHOP_COLUMNS)
          .maybeSingle(),
        'shop',
      ),
    onSuccess: async (row) => {
      queryClient.setQueryData(settingsKeys.shop(shopId), row);
      await Promise.all([
        queryClient.invalidateQueries({ queryKey: shopKey(shopId, 'shop') }),
        refetch(),
      ]);
    },
  });
}

export const LOGO_TYPES = {
  'image/png': 'png',
  'image/jpeg': 'jpg',
  'image/webp': 'webp',
} as const satisfies Record<string, string>;
export const LOGO_MAX_BYTES = 5 * 1024 * 1024;

export function isLogoType(type: string): type is keyof typeof LOGO_TYPES {
  return Object.hasOwn(LOGO_TYPES, type);
}

/** `<shop_id>/logo.<ext>` in the public `shop-assets` bucket (SPEC §4.6). */
export function logoPath(shopId: string, type: keyof typeof LOGO_TYPES): string {
  return `${shopId}/logo.${LOGO_TYPES[type]}`;
}

/** Validates a logo file before upload; returns a message or null. */
export function logoFileProblem(file: File): string | null {
  if (!isLogoType(file.type)) return 'Use a PNG, JPG or WebP image.';
  if (file.size > LOGO_MAX_BYTES) return 'The logo must be 5 MB or smaller.';
  if (file.size === 0) return 'That file is empty.';
  return null;
}

/** Uploads (or removes, with `null`) the shop logo and stores its path. */
export function useSaveLogo() {
  const { shopId } = useShop();
  const update = useUpdateShop();
  return useMutation({
    mutationFn: async ({
      file,
      previousPath,
    }: {
      file: File | null;
      previousPath: string | null;
    }): Promise<ShopSettings> => {
      const bucket = supabase.storage.from('shop-assets');
      let nextPath: string | null = null;
      if (file) {
        const problem = logoFileProblem(file);
        if (problem || !isLogoType(file.type)) {
          throw new AppError(problem ?? 'Use a PNG, JPG or WebP image.', { kind: 'validation' });
        }
        nextPath = logoPath(shopId, file.type);
        const { error } = await bucket.upload(nextPath, file, {
          upsert: true,
          contentType: file.type,
          cacheControl: '60',
        });
        if (error) throw toAppError(error);
      }
      const row = await update.mutateAsync({ logo_path: nextPath });
      // Best effort: drop the old object when the path changed (other extension or removed).
      if (previousPath && previousPath !== nextPath && previousPath.startsWith(`${shopId}/`)) {
        await bucket.remove([previousPath]).catch(() => undefined);
      }
      return row;
    },
  });
}

// ---------------------------------------------------------------------------
// Booking settings
// ---------------------------------------------------------------------------

export type BookingSettings = Row<'booking_settings'>;
export type BookingPatch = Omit<
  UpdateRow<'booking_settings'>,
  'shop_id' | 'created_at' | 'updated_at'
>;

export function useBookingSettings() {
  const { shopId } = useShop();
  return useQuery({
    queryKey: settingsKeys.booking(shopId),
    queryFn: async (): Promise<BookingSettings> =>
      unwrapRequired(
        await supabase.from('booking_settings').select('*').eq('shop_id', shopId).maybeSingle(),
        'booking settings',
      ),
  });
}

export function useUpdateBookingSettings() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (patch: BookingPatch): Promise<BookingSettings> =>
      unwrapRequired(
        await supabase
          .from('booking_settings')
          .update(patch)
          .eq('shop_id', shopId)
          .select('*')
          .maybeSingle(),
        'booking settings',
      ),
    onSuccess: (row) => {
      queryClient.setQueryData(settingsKeys.booking(shopId), row);
    },
  });
}

// ---------------------------------------------------------------------------
// Business hours
// ---------------------------------------------------------------------------

export function useBusinessHours() {
  const { shopId } = useShop();
  return useQuery({
    queryKey: settingsKeys.hours(shopId),
    queryFn: async (): Promise<BusinessHoursRow[]> =>
      unwrapList(
        await supabase
          .from('business_hours')
          .select('weekday, opens_at, closes_at')
          .eq('shop_id', shopId)
          .order('weekday')
          .order('opens_at'),
      ),
  });
}

/** Replaces the weekly hours in one transaction (replace_business_hours, owner/admin). */
export function useSaveBusinessHours() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({ rows }: { rows: readonly BusinessHoursRow[] }): Promise<void> =>
      replaceBusinessHours(shopId, rows),
    // settings/* covers this page and the calendar's hours shading
    // (settings/business_hours); jobs/calendar re-reads availability.
    onSettled: () =>
      invalidateAll(queryClient, [settingsKeys.all(shopId), dependentKeys.calendarEvents(shopId)]),
  });
}

// ---------------------------------------------------------------------------
// Team members (for per-member blocked times)
// ---------------------------------------------------------------------------

export type MemberOption = Pick<Row<'shop_members'>, 'id' | 'display_name' | 'active' | 'role'>;

export function useShopMembers() {
  const { shopId } = useShop();
  return useQuery({
    queryKey: settingsKeys.members(shopId),
    queryFn: async (): Promise<MemberOption[]> =>
      unwrapList(
        await supabase
          .from('shop_members')
          .select('id, display_name, active, role')
          .eq('shop_id', shopId)
          .order('display_name'),
      ),
  });
}

// ---------------------------------------------------------------------------
// Blocked times
// ---------------------------------------------------------------------------

export type BlockedTime = Pick<
  Row<'blocked_times'>,
  | 'id'
  | 'member_id'
  | 'starts_at'
  | 'ends_at'
  | 'reason'
  | 'kind'
  | 'title'
  | 'customer_id'
  | 'affects_capacity'
  | 'color'
  | 'recurrence'
>;
export type CalendarEventKind = Row<'blocked_times'>['kind'];

const BLOCKED_COLUMNS =
  'id, member_id, starts_at, ends_at, reason, kind, title, customer_id, affects_capacity, color, recurrence';

export function useBlockedTimes(showPast: boolean) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: settingsKeys.blocked(shopId, showPast),
    queryFn: async (): Promise<BlockedTime[]> => {
      let query = supabase.from('blocked_times').select(BLOCKED_COLUMNS).eq('shop_id', shopId);
      query = showPast
        ? query.order('starts_at', { ascending: false })
        : // repeating events stay listed while they may still occur
          query
            .or(`ends_at.gte.${new Date().toISOString()},recurrence.not.is.null`)
            .order('starts_at');
      return unwrapList(await query.limit(500));
    },
  });
}

export interface BlockedTimeInput {
  id?: string | undefined;
  member_id: string | null;
  starts_at: string;
  ends_at: string;
  reason: string | null;
  kind?: CalendarEventKind;
  title?: string | null;
  affects_capacity?: boolean;
  recurrence?: RecurrenceRule | null;
}

export function useSaveBlockedTime() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async ({ id, recurrence, ...rest }: BlockedTimeInput): Promise<void> => {
      const values = {
        ...rest,
        ...(recurrence === undefined ? {} : { recurrence: recurrence as Json | null }),
      };
      if (id) {
        unwrap(
          await supabase.from('blocked_times').update(values).eq('id', id).eq('shop_id', shopId),
        );
      } else {
        unwrap(await supabase.from('blocked_times').insert({ ...values, shop_id: shopId }));
      }
    },
    onSuccess: () => invalidateBlocked(queryClient, shopId),
  });
}

export function useDeleteBlockedTime() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (id: string): Promise<void> => {
      unwrap(await supabase.from('blocked_times').delete().eq('id', id).eq('shop_id', shopId));
    },
    onSuccess: () => invalidateBlocked(queryClient, shopId),
  });
}

function invalidateBlocked(queryClient: QueryClient, shopId: string) {
  return invalidateAll(queryClient, [
    [...settingsKeys.all(shopId), 'blocked'],
    dependentKeys.calendarEvents(shopId),
  ]);
}

// ---------------------------------------------------------------------------
// Resources (bays / vans) — soft-deleted via archived_at (SPEC §4)
// ---------------------------------------------------------------------------

export type Resource = Pick<Row<'resources'>, 'id' | 'name' | 'kind' | 'active' | 'sort'>;
export type ResourceKind = Row<'resources'>['kind'];

export function useResources() {
  const { shopId } = useShop();
  return useQuery({
    queryKey: settingsKeys.resources(shopId),
    queryFn: async (): Promise<Resource[]> =>
      unwrapList(
        await supabase
          .from('resources')
          .select('id, name, kind, active, sort')
          .eq('shop_id', shopId)
          .is('archived_at', null)
          .order('sort')
          .order('name'),
      ),
  });
}

export interface ResourceInput {
  id?: string | undefined;
  name?: string;
  kind?: ResourceKind;
  active?: boolean;
  sort?: number;
}

export function useSaveResource() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async ({ id, ...values }: ResourceInput): Promise<void> => {
      if (id) {
        unwrap(await supabase.from('resources').update(values).eq('id', id).eq('shop_id', shopId));
      } else {
        const insert: InsertRow<'resources'> = {
          shop_id: shopId,
          name: values.name ?? '',
          ...(values.kind ? { kind: values.kind } : {}),
          ...(values.active !== undefined ? { active: values.active } : {}),
          ...(values.sort !== undefined ? { sort: values.sort } : {}),
        };
        unwrap(await supabase.from('resources').insert(insert));
      }
    },
    onSuccess: () => invalidateResources(queryClient, shopId),
  });
}

export function useArchiveResource() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (id: string): Promise<void> => {
      unwrap(
        await supabase
          .from('resources')
          .update({ archived_at: new Date().toISOString(), active: false })
          .eq('id', id)
          .eq('shop_id', shopId),
      );
    },
    onSuccess: () => invalidateResources(queryClient, shopId),
  });
}

/** settings/* = this page + the jobs resource picker (settings/resources). */
function invalidateResources(queryClient: QueryClient, shopId: string) {
  return invalidateAll(queryClient, [
    settingsKeys.all(shopId),
    dependentKeys.calendarEvents(shopId),
  ]);
}

// ---------------------------------------------------------------------------
// Vehicle categories
// ---------------------------------------------------------------------------

export type VehicleCategory = Pick<Row<'vehicle_categories'>, 'id' | 'name' | 'sort'>;

export function useVehicleCategories() {
  const { shopId } = useShop();
  return useQuery({
    queryKey: settingsKeys.categories(shopId),
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

/**
 * settings/* also covers the job editor's picker (settings/vehicle_categories);
 * catalog/customers/vehicles hold prices and vehicles keyed by category.
 */
function invalidateCategories(queryClient: QueryClient, shopId: string) {
  return invalidateAll(queryClient, [
    settingsKeys.all(shopId),
    shopKey(shopId, 'catalog'),
    shopKey(shopId, 'vehicles'),
    shopKey(shopId, 'customers'),
  ]);
}

export function useSaveVehicleCategory() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async ({
      id,
      name,
      sort,
    }: {
      id?: string | undefined;
      name: string;
      sort?: number;
    }): Promise<void> => {
      if (id) {
        unwrap(
          await supabase
            .from('vehicle_categories')
            .update({ name })
            .eq('id', id)
            .eq('shop_id', shopId),
        );
      } else {
        unwrap(
          await supabase
            .from('vehicle_categories')
            .insert({ shop_id: shopId, name, ...(sort !== undefined ? { sort } : {}) }),
        );
      }
    },
    onSuccess: () => invalidateCategories(queryClient, shopId),
  });
}

/** Writes `sort` = position (1-based) for every category whose position changed. */
export function useReorderVehicleCategories() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (ordered: readonly VehicleCategory[]): Promise<void> => {
      const changes = ordered
        .map((category, index) => ({ id: category.id, sort: index + 1, before: category.sort }))
        .filter((c) => c.sort !== c.before);
      for (const change of changes) {
        unwrap(
          await supabase
            .from('vehicle_categories')
            .update({ sort: change.sort })
            .eq('id', change.id)
            .eq('shop_id', shopId),
        );
      }
    },
    onSettled: () => invalidateCategories(queryClient, shopId),
  });
}

export interface CategoryUsage {
  prices: number;
  vehicles: number;
}

/**
 * How many catalog prices / vehicles use a category. Deleting a category
 * CASCADE-deletes its service_prices and clears vehicles.category_id (FKs in
 * 0004/0005), so the server will not refuse — the UI must warn first.
 */
export function useCategoryUsage(categoryId: string | null) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: settingsKeys.categoryUsage(shopId, categoryId ?? ''),
    enabled: categoryId !== null,
    queryFn: async (): Promise<CategoryUsage> => {
      const id = categoryId ?? '';
      const [prices, vehicles] = await Promise.all([
        supabase
          .from('service_prices')
          .select('id', { count: 'exact', head: true })
          .eq('shop_id', shopId)
          .eq('vehicle_category_id', id),
        supabase
          .from('vehicles')
          .select('id', { count: 'exact', head: true })
          .eq('shop_id', shopId)
          .eq('category_id', id),
      ]);
      if (prices.error) throw toAppError(prices.error);
      if (vehicles.error) throw toAppError(vehicles.error);
      return { prices: prices.count ?? 0, vehicles: vehicles.count ?? 0 };
    },
  });
}

export function useDeleteVehicleCategory() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (id: string): Promise<void> => {
      unwrap(await supabase.from('vehicle_categories').delete().eq('id', id).eq('shop_id', shopId));
    },
    onSuccess: () => invalidateCategories(queryClient, shopId),
  });
}

// ---------------------------------------------------------------------------
// Coupons
// ---------------------------------------------------------------------------

export type Coupon = Pick<
  Row<'coupons'>,
  | 'id'
  | 'code'
  | 'description'
  | 'kind'
  | 'value'
  | 'starts_at'
  | 'ends_at'
  | 'max_redemptions'
  | 'redemptions'
  | 'online_only'
  | 'active'
  | 'service_ids'
  | 'min_subtotal_cents'
  | 'once_per_customer'
  | 'customer_id'
  | 'new_customers_only'
>;
export type CouponKind = Row<'coupons'>['kind'];

export function useCoupons() {
  const { shopId } = useShop();
  return useQuery({
    queryKey: settingsKeys.coupons(shopId),
    queryFn: async (): Promise<Coupon[]> =>
      unwrapList(
        await supabase
          .from('coupons')
          .select(
            'id, code, description, kind, value, starts_at, ends_at, max_redemptions, redemptions, online_only, active, service_ids, min_subtotal_cents, once_per_customer, customer_id, new_customers_only',
          )
          .eq('shop_id', shopId)
          // customers' personal referral codes are managed by the referral programme
          .is('referrer_customer_id', null)
          .order('active', { ascending: false })
          .order('code'),
      ),
  });
}

export type CouponInput = Omit<Coupon, 'id' | 'redemptions'> & { id?: string | undefined };

export function useSaveCoupon() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async ({ id, ...values }: Partial<CouponInput>): Promise<void> => {
      if (id) {
        unwrap(await supabase.from('coupons').update(values).eq('id', id).eq('shop_id', shopId));
      } else {
        if (values.code === undefined || values.kind === undefined || values.value === undefined) {
          throw new AppError('Code, discount type and value are required.', { kind: 'validation' });
        }
        unwrap(
          await supabase.from('coupons').insert({
            ...values,
            code: values.code,
            kind: values.kind,
            value: values.value,
            shop_id: shopId,
          }),
        );
      }
    },
    onSuccess: () => invalidateCoupons(queryClient, shopId),
  });
}

/** Plus the job editor's coupon picker (catalog/coupons/active). */
function invalidateCoupons(queryClient: QueryClient, shopId: string) {
  return invalidateAll(queryClient, [settingsKeys.coupons(shopId), dependentKeys.coupons(shopId)]);
}

export function useDeleteCoupon() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (id: string): Promise<void> => {
      unwrap(await supabase.from('coupons').delete().eq('id', id).eq('shop_id', shopId));
    },
    onSuccess: () => invalidateCoupons(queryClient, shopId),
  });
}

// ---------------------------------------------------------------------------
// Message templates & automations
// ---------------------------------------------------------------------------

export type MessageTemplate = Pick<
  Row<'message_templates'>,
  | 'id'
  | 'key'
  | 'channel'
  | 'subject'
  | 'body'
  | 'enabled'
  | 'offset_minutes'
  | 'reminder_offsets_minutes'
  | 'updated_at'
>;
export type TemplateKey = Row<'message_templates'>['key'];
export type TemplateChannel = Row<'message_templates'>['channel'];

const TEMPLATE_COLUMNS =
  'id, key, channel, subject, body, enabled, offset_minutes, reminder_offsets_minutes, updated_at';

export function useMessageTemplates() {
  const { shopId } = useShop();
  return useQuery({
    queryKey: settingsKeys.templates(shopId),
    queryFn: async (): Promise<MessageTemplate[]> =>
      unwrapList(
        await supabase
          .from('message_templates')
          .select(TEMPLATE_COLUMNS)
          .eq('shop_id', shopId)
          .order('key')
          .order('channel'),
      ),
  });
}

const defaultTemplateSchema = z.object({
  key: z.string(),
  channel: z.enum(['sms', 'email']),
  subject: z.string().nullable(),
  body: z.string(),
  enabled: z.boolean(),
  offset_minutes: z.number().int().nullable(),
});
export type DefaultTemplate = z.infer<typeof defaultTemplateSchema>;

/** The seeded default wording (to add back a removed channel). */
export function useDefaultTemplates(enabled: boolean) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: settingsKeys.templateDefaults(shopId),
    enabled,
    staleTime: Infinity,
    queryFn: async (): Promise<DefaultTemplate[]> =>
      z.array(defaultTemplateSchema).parse(unwrap(await supabase.rpc('default_message_templates'))),
  });
}

export interface TemplatePatch {
  subject?: string | null;
  body?: string;
  enabled?: boolean;
  offset_minutes?: number | null;
  /** appointment_reminder: 2–3 offsets (null = one reminder at offset_minutes). */
  reminder_offsets_minutes?: number[] | null;
}

/** Plus the inbox's template list and rendered previews (messages/…). */
function invalidateTemplates(queryClient: QueryClient, shopId: string) {
  return invalidateAll(queryClient, [
    settingsKeys.templates(shopId),
    dependentKeys.messageTemplates(shopId),
    dependentKeys.messagePreviews(shopId),
    dependentKeys.documentFollowups(shopId),
  ]);
}

export function useUpdateTemplate() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async ({ id, patch }: { id: string; patch: TemplatePatch }): Promise<void> => {
      unwrap(
        await supabase.from('message_templates').update(patch).eq('id', id).eq('shop_id', shopId),
      );
    },
    // The offset trigger updates sibling channels too, so refetch everything.
    onSuccess: () => invalidateTemplates(queryClient, shopId),
  });
}

export function useResetTemplate() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (id: string): Promise<void> => {
      unwrap(await supabase.rpc('reset_message_template', { p_template_id: id }));
    },
    onSuccess: () => invalidateTemplates(queryClient, shopId),
  });
}

export function useAddTemplateChannel() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (input: {
      key: TemplateKey;
      channel: TemplateChannel;
      subject: string | null;
      body: string;
      offset_minutes: number | null;
    }): Promise<void> => {
      unwrap(
        await supabase
          .from('message_templates')
          .insert({ ...input, shop_id: shopId, enabled: true }),
      );
    },
    onSuccess: () => invalidateTemplates(queryClient, shopId),
  });
}

export function useDeleteTemplate() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (id: string): Promise<void> => {
      unwrap(await supabase.from('message_templates').delete().eq('id', id).eq('shop_id', shopId));
    },
    onSuccess: () => invalidateTemplates(queryClient, shopId),
  });
}

// ---------------------------------------------------------------------------
// Form templates
// ---------------------------------------------------------------------------

export type FormTemplate = Pick<
  Row<'form_templates'>,
  'id' | 'name' | 'body' | 'requires_signature' | 'attach_to' | 'active' | 'updated_at'
>;
export type FormAttachTo = Row<'form_templates'>['attach_to'];

export function useFormTemplates() {
  const { shopId } = useShop();
  return useQuery({
    queryKey: settingsKeys.forms(shopId),
    queryFn: async (): Promise<FormTemplate[]> =>
      unwrapList(
        await supabase
          .from('form_templates')
          .select('id, name, body, requires_signature, attach_to, active, updated_at')
          .eq('shop_id', shopId)
          .order('active', { ascending: false })
          .order('name'),
      ),
  });
}

export interface FormTemplateInput {
  id?: string | undefined;
  name?: string;
  body?: string;
  requires_signature?: boolean;
  attach_to?: FormAttachTo;
  active?: boolean;
}

export function useSaveFormTemplate() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async ({ id, ...values }: FormTemplateInput): Promise<void> => {
      if (id) {
        unwrap(
          await supabase.from('form_templates').update(values).eq('id', id).eq('shop_id', shopId),
        );
      } else {
        if (values.name === undefined || values.body === undefined) {
          throw new AppError('Name and body are required.', { kind: 'validation' });
        }
        unwrap(
          await supabase
            .from('form_templates')
            .insert({ ...values, name: values.name, body: values.body, shop_id: shopId }),
        );
      }
    },
    // settings/* also covers the job form picker (settings/form_templates/active).
    onSuccess: () => queryClient.invalidateQueries({ queryKey: settingsKeys.all(shopId) }),
  });
}

export function useDeleteFormTemplate() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (id: string): Promise<void> => {
      unwrap(await supabase.from('form_templates').delete().eq('id', id).eq('shop_id', shopId));
    },
    // settings/* also covers the job form picker (settings/form_templates/active).
    onSuccess: () => queryClient.invalidateQueries({ queryKey: settingsKeys.all(shopId) }),
  });
}

// ---------------------------------------------------------------------------
// Stripe Connect (edge function `stripe-connect`, owner/admin)
// ---------------------------------------------------------------------------

export const stripeStatusSchema = z.object({
  connected: z.boolean(),
  stripe_account_id: z.string().nullable(),
  charges_enabled: z.boolean(),
  payouts_enabled: z.boolean(),
  details_submitted: z.boolean(),
});
export type StripeStatus = z.infer<typeof stripeStatusSchema>;

/**
 * Account/login links are one-time https URLs on stripe.com
 * (connect.stripe.com). Anything else — javascript:, data:, http:, another
 * host — is refused before `window.location.assign` sees it.
 */
export const stripeLinkSchema = z.object({
  url: z.url({ protocol: /^https$/, hostname: /(^|\.)stripe\.com$/ }),
});

/** Url-safe, 8–64 chars (functions/_shared/schemas.ts `requestNonce`). */
export function requestNonce(): string {
  return crypto.randomUUID().replace(/-/g, '');
}

async function invokeStripeConnect(body: Record<string, string>): Promise<unknown> {
  const result = await supabase.functions.invoke<unknown>('stripe-connect', { body });
  const error: unknown = result.error;
  if (error) throw await edgeFunctionError(error);
  return result.data;
}

/** Re-reads the connected account from Stripe (refresh_status). */
export function useStripeStatus(enabled: boolean) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: settingsKeys.stripe(shopId),
    enabled,
    queryFn: async (): Promise<StripeStatus> =>
      stripeStatusSchema.parse(
        await invokeStripeConnect({ action: 'refresh_status', shop_id: shopId }),
      ),
  });
}

/** create_account_link / login_link → a one-time Stripe URL to redirect to. */
export function useStripeLink() {
  const { shopId } = useShop();
  return useMutation({
    mutationFn: async (action: 'create_account_link' | 'login_link'): Promise<string> => {
      const parsed = stripeLinkSchema.safeParse(
        await invokeStripeConnect({ action, shop_id: shopId, request_nonce: requestNonce() }),
      );
      if (!parsed.success) {
        throw new AppError('Stripe returned an unexpected link. Please try again.', {
          kind: 'server',
          cause: parsed.error,
        });
      }
      return parsed.data.url;
    },
  });
}

// ---------------------------------------------------------------------------
// Delete shop (SPEC §3: owner only — RLS `shops_delete`, capability shop.delete)
// ---------------------------------------------------------------------------

/**
 * Memberships that bill (or may bill) through a Stripe subscription on the
 * connected account: delete_shop cancels each of them in Stripe first, and
 * the page says how many.
 */
export function useBillingMembershipCount(enabled: boolean) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: [...settingsKeys.all(shopId), 'delete-shop', 'billing-memberships'] as const,
    enabled,
    queryFn: async (): Promise<number> => {
      const result = await supabase
        .from('memberships')
        .select('id', { count: 'exact', head: true })
        .eq('shop_id', shopId)
        .neq('status', 'cancelled')
        .not('stripe_subscription_id', 'is', null);
      if (result.error) throw toAppError(result.error);
      return result.count ?? 0;
    },
  });
}

export const deleteShopResultSchema = z.object({
  deleted: z.literal(true),
  memberships_cancelled: z.number().int(),
  sessions_expired: z.number().int(),
});
export type DeleteShopResult = z.infer<typeof deleteShopResultSchema>;

/** Friendly text for delete_shop refusals the owner can act on. */
export function deleteShopErrorMessage(error: unknown): string {
  if (error instanceof EdgeFunctionError) {
    if (error.reason === 'payment_in_progress') {
      return 'A card payment for this shop is still being processed. Wait a few minutes for it to finish, then try again. Nothing was deleted.';
    }
    if (error.reason === 'name_mismatch') {
      return 'The name you typed doesn’t match this shop’s name. Nothing was deleted.';
    }
  }
  return errorMessage(error);
}

/**
 * Deletes the current shop through payments → delete_shop (owner only):
 * the server first cancels every membership's Stripe subscription, settles
 * or expires open card payments and pay links (409 payment_in_progress when
 * one is still processing — nothing is deleted), then deletes the shop (every
 * tenant row cascades; its SMS number is logged for release). `confirmName`
 * must be the shop's name (422 name_mismatch otherwise). Afterwards the
 * shop's cached queries are dropped and the membership list is refetched,
 * which switches to another shop (or to onboarding when none are left).
 */
export function useDeleteShop() {
  const { shopId } = useShop();
  const { refetch } = useShopContext();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (confirmName: string): Promise<DeleteShopResult> =>
      invokeEdge(
        'payments',
        'delete_shop',
        { shop_id: shopId, confirm_name: confirmName },
        deleteShopResultSchema,
      ),
    onSuccess: async () => {
      // Membership list first: the shell moves off the deleted shop, so its
      // pages unmount before the shop's cache entries are dropped.
      await refetch();
      const tenantKey = ['shop', shopId] as const;
      await queryClient.cancelQueries({ queryKey: tenantKey });
      queryClient.removeQueries({ queryKey: tenantKey });
    },
  });
}
