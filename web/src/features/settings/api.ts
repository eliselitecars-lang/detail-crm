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
import { unwrap, unwrapRequired, type InsertRow, type Row, type UpdateRow } from '@/lib/db';
import { AppError, edgeFunctionError, toAppError } from '@/lib/errors';
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
  resources: (shopId: string) => [...settingsKeys.all(shopId), 'resources'] as const,
  categories: (shopId: string) => [...settingsKeys.all(shopId), 'vehicle-categories'] as const,
  categoryUsage: (shopId: string, categoryId: string) =>
    [...settingsKeys.all(shopId), 'vehicle-category-usage', categoryId] as const,
  coupons: (shopId: string) => [...settingsKeys.all(shopId), 'coupons'] as const,
  templates: (shopId: string) => [...settingsKeys.all(shopId), 'templates'] as const,
  templateDefaults: (shopId: string) => [...settingsKeys.all(shopId), 'template-defaults'] as const,
  forms: (shopId: string) => [...settingsKeys.all(shopId), 'forms'] as const,
  stripe: (shopId: string) => [...settingsKeys.all(shopId), 'stripe'] as const,
};

// ---------------------------------------------------------------------------
// Shop profile / taxes / SMS number (the `shops` row)
// ---------------------------------------------------------------------------

const SHOP_COLUMNS =
  'id, name, slug, email, phone, website, address_line1, address_line2, city, region, postal_code, country, timezone, currency, logo_path, brand_color, business_type, tax_rate_bps, techs_can_collect_payments, review_url, quote_terms, invoice_terms, invoice_due_days, sms_from_number, updated_at';

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

/**
 * Replaces the weekly hours. The exclusion constraint forbids overlapping
 * rows, so old rows go first; if the insert fails the previous week is put
 * back so the shop is never left without hours by a failed save.
 */
export function useSaveBusinessHours() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async ({
      rows,
      previous,
    }: {
      rows: readonly BusinessHoursRow[];
      previous: readonly BusinessHoursRow[];
    }): Promise<void> => {
      unwrap(await supabase.from('business_hours').delete().eq('shop_id', shopId));
      if (rows.length === 0) return;
      const inserted = await supabase
        .from('business_hours')
        .insert(rows.map((row) => ({ ...row, shop_id: shopId })));
      if (inserted.error) {
        if (previous.length > 0) {
          await supabase
            .from('business_hours')
            .insert(previous.map((row) => ({ ...row, shop_id: shopId })));
        }
        throw toAppError(inserted.error);
      }
    },
    onSettled: () =>
      Promise.all([
        queryClient.invalidateQueries({ queryKey: settingsKeys.hours(shopId) }),
        queryClient.invalidateQueries({ queryKey: shopKey(shopId, 'calendar') }),
      ]),
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
  'id' | 'member_id' | 'starts_at' | 'ends_at' | 'reason'
>;

export function useBlockedTimes(showPast: boolean) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: settingsKeys.blocked(shopId, showPast),
    queryFn: async (): Promise<BlockedTime[]> => {
      let query = supabase
        .from('blocked_times')
        .select('id, member_id, starts_at, ends_at, reason')
        .eq('shop_id', shopId);
      query = showPast
        ? query.order('starts_at', { ascending: false })
        : query.gte('ends_at', new Date().toISOString()).order('starts_at');
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
}

export function useSaveBlockedTime() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async ({ id, ...values }: BlockedTimeInput): Promise<void> => {
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

function invalidateBlocked(queryClient: ReturnType<typeof useQueryClient>, shopId: string) {
  return Promise.all([
    queryClient.invalidateQueries({ queryKey: [...settingsKeys.all(shopId), 'blocked'] }),
    queryClient.invalidateQueries({ queryKey: shopKey(shopId, 'calendar') }),
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

function invalidateResources(queryClient: ReturnType<typeof useQueryClient>, shopId: string) {
  return Promise.all([
    queryClient.invalidateQueries({ queryKey: settingsKeys.resources(shopId) }),
    queryClient.invalidateQueries({ queryKey: shopKey(shopId, 'calendar') }),
    queryClient.invalidateQueries({ queryKey: shopKey(shopId, 'resources') }),
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

function invalidateCategories(queryClient: ReturnType<typeof useQueryClient>, shopId: string) {
  return Promise.all([
    queryClient.invalidateQueries({ queryKey: settingsKeys.categories(shopId) }),
    queryClient.invalidateQueries({ queryKey: shopKey(shopId, 'catalog') }),
    queryClient.invalidateQueries({ queryKey: shopKey(shopId, 'vehicles') }),
    queryClient.invalidateQueries({ queryKey: shopKey(shopId, 'customers') }),
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
            'id, code, description, kind, value, starts_at, ends_at, max_redemptions, redemptions, online_only, active',
          )
          .eq('shop_id', shopId)
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
    onSuccess: () => queryClient.invalidateQueries({ queryKey: settingsKeys.coupons(shopId) }),
  });
}

export function useDeleteCoupon() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (id: string): Promise<void> => {
      unwrap(await supabase.from('coupons').delete().eq('id', id).eq('shop_id', shopId));
    },
    onSuccess: () => queryClient.invalidateQueries({ queryKey: settingsKeys.coupons(shopId) }),
  });
}

// ---------------------------------------------------------------------------
// Message templates & automations
// ---------------------------------------------------------------------------

export type MessageTemplate = Pick<
  Row<'message_templates'>,
  'id' | 'key' | 'channel' | 'subject' | 'body' | 'enabled' | 'offset_minutes' | 'updated_at'
>;
export type TemplateKey = Row<'message_templates'>['key'];
export type TemplateChannel = Row<'message_templates'>['channel'];

const TEMPLATE_COLUMNS = 'id, key, channel, subject, body, enabled, offset_minutes, updated_at';

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
}

function invalidateTemplates(queryClient: ReturnType<typeof useQueryClient>, shopId: string) {
  return queryClient.invalidateQueries({ queryKey: settingsKeys.templates(shopId) });
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
    onSuccess: () => queryClient.invalidateQueries({ queryKey: settingsKeys.forms(shopId) }),
  });
}

export function useDeleteFormTemplate() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (id: string): Promise<void> => {
      unwrap(await supabase.from('form_templates').delete().eq('id', id).eq('shop_id', shopId));
    },
    onSuccess: () => queryClient.invalidateQueries({ queryKey: settingsKeys.forms(shopId) }),
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

const linkSchema = z.object({ url: z.url() });

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
    mutationFn: async (action: 'create_account_link' | 'login_link'): Promise<string> =>
      linkSchema.parse(
        await invokeStripeConnect({ action, shop_id: shopId, request_nonce: requestNonce() }),
      ).url,
  });
}
