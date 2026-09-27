/**
 * Catalog data (SPEC §4.3, §4.6 checklist templates). Every member reads;
 * managers+ write (RLS: is_shop_manager). Service images live in the public
 * `shop-assets` bucket at <shop_id>/services/<service_id>.<ext>.
 */
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import type { PostgrestError } from '@supabase/supabase-js';
import { unwrap, unwrapRequired } from '@/lib/db';
import { AppError, toAppError } from '@/lib/errors';
import { shopKey } from '@/lib/queryKeys';
import { supabase } from '@/lib/supabase';
import { useShop } from '@/features/shop/shopContext';
import {
  bySortThenName,
  serviceImagePath,
  type CategoryRow,
  type ChecklistItemPayload,
  type ChecklistTemplateRow,
  type PricePlan,
  type PriceRow,
  type ServiceRow,
  type ServiceUsage,
  type VehicleCategoryRow,
} from './model';

export const catalogKeys = {
  all: (shopId: string) => shopKey(shopId, 'catalog'),
  categories: (shopId: string) => [...catalogKeys.all(shopId), 'categories'] as const,
  services: (shopId: string) => [...catalogKeys.all(shopId), 'services'] as const,
  basePrices: (shopId: string) => [...catalogKeys.all(shopId), 'base-prices'] as const,
  service: (shopId: string, id: string) => [...catalogKeys.all(shopId), 'service', id] as const,
  prices: (shopId: string, id: string) => [...catalogKeys.all(shopId), 'prices', id] as const,
  packageItems: (shopId: string, id: string) =>
    [...catalogKeys.all(shopId), 'package-items', id] as const,
  addons: (shopId: string, id: string) => [...catalogKeys.all(shopId), 'addons', id] as const,
  usage: (shopId: string, id: string) => [...catalogKeys.all(shopId), 'usage', id] as const,
  vehicleCategories: (shopId: string) =>
    [...catalogKeys.all(shopId), 'vehicle-categories'] as const,
  checklists: (shopId: string) => [...catalogKeys.all(shopId), 'checklists'] as const,
};

/** unwrap() for list results: null data (never expected) becomes []. */
function listOf<T>(result: { data: T[] | null; error: PostgrestError | null }): T[] {
  return unwrap(result) ?? [];
}

function notUpdated(what: string): AppError {
  return new AppError(`That ${what} could not be updated. Refresh and try again.`, {
    kind: 'not_found',
  });
}

function useInvalidateCatalog() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return () => queryClient.invalidateQueries({ queryKey: catalogKeys.all(shopId) });
}

// ------------------------------------------------------------------ reads

export function useCategories() {
  const { shopId } = useShop();
  return useQuery({
    queryKey: catalogKeys.categories(shopId),
    queryFn: async (): Promise<CategoryRow[]> => {
      const rows = listOf(
        await supabase
          .from('service_categories')
          .select('*')
          .eq('shop_id', shopId)
          .order('sort')
          .order('name'),
      );
      return [...rows].sort(bySortThenName);
    },
  });
}

/** Every service (archived included; screens filter). */
export function useServices() {
  const { shopId } = useShop();
  return useQuery({
    queryKey: catalogKeys.services(shopId),
    queryFn: async (): Promise<ServiceRow[]> => {
      const rows = listOf(
        await supabase
          .from('services')
          .select('*')
          .eq('shop_id', shopId)
          .order('sort')
          .order('name'),
      );
      return [...rows].sort(bySortThenName);
    },
  });
}

/** Base prices (vehicle_category_id null) by service id. */
export function useBasePrices() {
  const { shopId } = useShop();
  return useQuery({
    queryKey: catalogKeys.basePrices(shopId),
    queryFn: async (): Promise<Map<string, number>> => {
      const rows = listOf(
        await supabase
          .from('service_prices')
          .select('service_id, price_cents')
          .eq('shop_id', shopId)
          .is('vehicle_category_id', null),
      );
      return new Map(rows.map((r) => [r.service_id, r.price_cents]));
    },
  });
}

export function useService(serviceId: string) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: catalogKeys.service(shopId, serviceId),
    queryFn: async (): Promise<ServiceRow> =>
      unwrapRequired(
        await supabase
          .from('services')
          .select('*')
          .eq('shop_id', shopId)
          .eq('id', serviceId)
          .maybeSingle(),
        'service',
      ),
  });
}

export function useServicePrices(serviceId: string) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: catalogKeys.prices(shopId, serviceId),
    queryFn: async (): Promise<PriceRow[]> =>
      listOf(
        await supabase
          .from('service_prices')
          .select('*')
          .eq('shop_id', shopId)
          .eq('service_id', serviceId),
      ),
  });
}

export function useVehicleCategories() {
  const { shopId } = useShop();
  return useQuery({
    queryKey: catalogKeys.vehicleCategories(shopId),
    queryFn: async (): Promise<VehicleCategoryRow[]> => {
      const rows = listOf(
        await supabase
          .from('vehicle_categories')
          .select('id, name, sort')
          .eq('shop_id', shopId)
          .order('sort')
          .order('name'),
      );
      return [...rows].sort(bySortThenName);
    },
  });
}

export interface PackageItem {
  id: string;
  service_id: string;
  sort: number;
}

export function usePackageItems(packageId: string, enabled = true) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: catalogKeys.packageItems(shopId, packageId),
    enabled,
    queryFn: async (): Promise<PackageItem[]> =>
      listOf(
        await supabase
          .from('package_items')
          .select('id, service_id, sort')
          .eq('shop_id', shopId)
          .eq('package_id', packageId)
          .order('sort')
          .order('created_at'),
      ),
  });
}

export function useServiceAddons(serviceId: string, enabled = true) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: catalogKeys.addons(shopId, serviceId),
    enabled,
    queryFn: async (): Promise<{ id: string; addon_id: string }[]> =>
      listOf(
        await supabase
          .from('service_addons')
          .select('id, addon_id')
          .eq('shop_id', shopId)
          .eq('service_id', serviceId),
      ),
  });
}

async function countWhere(
  table: 'job_line_items' | 'quote_line_items' | 'invoice_line_items',
  shopId: string,
  serviceId: string,
): Promise<number> {
  const result = await supabase
    .from(table)
    .select('id', { count: 'exact', head: true })
    .eq('shop_id', shopId)
    .eq('service_id', serviceId);
  if (result.error) throw toAppError(result.error);
  return result.count ?? 0;
}

/** How many documents / packages / plans reference a service (delete vs archive). */
export function useServiceUsage(serviceId: string, enabled: boolean) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: catalogKeys.usage(shopId, serviceId),
    enabled,
    staleTime: 0,
    queryFn: async (): Promise<ServiceUsage> => {
      const [jobLines, quoteLines, invoiceLines, packages, plans] = await Promise.all([
        countWhere('job_line_items', shopId, serviceId),
        countWhere('quote_line_items', shopId, serviceId),
        countWhere('invoice_line_items', shopId, serviceId),
        supabase
          .from('package_items')
          .select('id', { count: 'exact', head: true })
          .eq('shop_id', shopId)
          .eq('service_id', serviceId)
          .then((r) => {
            if (r.error) throw toAppError(r.error);
            return r.count ?? 0;
          }),
        supabase
          .from('membership_plans')
          .select('id', { count: 'exact', head: true })
          .eq('shop_id', shopId)
          .contains('included_service_ids', [serviceId])
          .then((r) => {
            if (r.error) throw toAppError(r.error);
            return r.count ?? 0;
          }),
      ]);
      return { jobLines, quoteLines, invoiceLines, packages, plans };
    },
  });
}

export function useChecklistTemplates() {
  const { shopId } = useShop();
  return useQuery({
    queryKey: catalogKeys.checklists(shopId),
    queryFn: async (): Promise<ChecklistTemplateRow[]> =>
      listOf(
        await supabase.from('checklist_templates').select('*').eq('shop_id', shopId).order('name'),
      ),
  });
}

// ------------------------------------------------------------- services

export type ServiceColumns = Omit<
  ServiceRow,
  'id' | 'shop_id' | 'created_at' | 'updated_at' | 'archived_at' | 'image_path'
>;

export function useCreateService() {
  const { shopId } = useShop();
  const invalidate = useInvalidateCatalog();
  return useMutation({
    mutationFn: async (values: ServiceColumns): Promise<string> => {
      const inserted = listOf(
        await supabase
          .from('services')
          .insert({ ...values, shop_id: shopId })
          .select('id'),
      );
      const id = inserted[0]?.id;
      if (!id) throw new AppError('The service could not be created.', { kind: 'unknown' });
      return id;
    },
    onSettled: invalidate,
  });
}

export function useUpdateService(serviceId: string) {
  const { shopId } = useShop();
  const invalidate = useInvalidateCatalog();
  return useMutation({
    mutationFn: async (
      patch: Partial<ServiceColumns> & { archived_at?: string | null; image_path?: string | null },
    ) => {
      const rows = listOf(
        await supabase
          .from('services')
          .update(patch)
          .eq('shop_id', shopId)
          .eq('id', serviceId)
          .select('id'),
      );
      if (rows.length === 0) throw notUpdated('service');
    },
    onSettled: invalidate,
  });
}

export function useDeleteService() {
  const { shopId } = useShop();
  const invalidate = useInvalidateCatalog();
  return useMutation({
    mutationFn: async (service: Pick<ServiceRow, 'id' | 'image_path'>) => {
      const rows = listOf(
        await supabase
          .from('services')
          .delete()
          .eq('shop_id', shopId)
          .eq('id', service.id)
          .select('id'),
      );
      if (rows.length === 0) throw notUpdated('service');
      if (service.image_path) {
        // Best effort: a leftover public image is harmless.
        await supabase.storage.from('shop-assets').remove([service.image_path]);
      }
    },
    onSettled: invalidate,
  });
}

// ------------------------------------------------------------- categories

export function useSaveCategory() {
  const { shopId } = useShop();
  const invalidate = useInvalidateCatalog();
  return useMutation({
    mutationFn: async ({ id, name, sort }: { id?: string; name: string; sort?: number }) => {
      if (id) {
        const rows = listOf(
          await supabase
            .from('service_categories')
            .update({ name })
            .eq('shop_id', shopId)
            .eq('id', id)
            .select('id'),
        );
        if (rows.length === 0) throw notUpdated('category');
      } else {
        unwrap(
          await supabase
            .from('service_categories')
            .insert({ shop_id: shopId, name, sort: sort ?? 0 })
            .select('id'),
        );
      }
    },
    onSettled: invalidate,
  });
}

export function useDeleteCategory() {
  const { shopId } = useShop();
  const invalidate = useInvalidateCatalog();
  return useMutation({
    mutationFn: async (id: string) => {
      const rows = listOf(
        await supabase
          .from('service_categories')
          .delete()
          .eq('shop_id', shopId)
          .eq('id', id)
          .select('id'),
      );
      if (rows.length === 0) throw notUpdated('category');
    },
    onSettled: invalidate,
  });
}

type SortableTable = 'service_categories' | 'services' | 'package_items';

/** Writes new `sort` values (one update per changed row). */
export function useReorder(table: SortableTable) {
  const { shopId } = useShop();
  const invalidate = useInvalidateCatalog();
  return useMutation({
    mutationFn: async (changes: { id: string; sort: number }[]) => {
      for (const change of changes) {
        unwrap(
          await supabase
            .from(table)
            .update({ sort: change.sort })
            .eq('shop_id', shopId)
            .eq('id', change.id),
        );
      }
    },
    onSettled: invalidate,
  });
}

// ------------------------------------------------------------- prices

export function useSavePrices(serviceId: string) {
  const { shopId } = useShop();
  const invalidate = useInvalidateCatalog();
  return useMutation({
    mutationFn: async (plan: PricePlan) => {
      if (plan.deletes.length > 0) {
        unwrap(
          await supabase
            .from('service_prices')
            .delete()
            .eq('shop_id', shopId)
            .eq('service_id', serviceId)
            .in('id', plan.deletes),
        );
      }
      for (const update of plan.updates) {
        const rows = listOf(
          await supabase
            .from('service_prices')
            .update({ price_cents: update.price_cents, duration_minutes: update.duration_minutes })
            .eq('shop_id', shopId)
            .eq('id', update.id)
            .select('id'),
        );
        if (rows.length === 0) throw notUpdated('price');
      }
      if (plan.inserts.length > 0) {
        unwrap(
          await supabase
            .from('service_prices')
            .insert(
              plan.inserts.map((row) => ({ ...row, shop_id: shopId, service_id: serviceId })),
            ),
        );
      }
    },
    onSettled: invalidate,
  });
}

// ------------------------------------------------------ packages / add-ons

export function useAddPackageItem(packageId: string) {
  const { shopId } = useShop();
  const invalidate = useInvalidateCatalog();
  return useMutation({
    mutationFn: async ({ serviceId, sort }: { serviceId: string; sort: number }) => {
      unwrap(
        await supabase
          .from('package_items')
          .insert({ shop_id: shopId, package_id: packageId, service_id: serviceId, sort }),
      );
    },
    onSettled: invalidate,
  });
}

export function useRemovePackageItem() {
  const { shopId } = useShop();
  const invalidate = useInvalidateCatalog();
  return useMutation({
    mutationFn: async (id: string) => {
      unwrap(await supabase.from('package_items').delete().eq('shop_id', shopId).eq('id', id));
    },
    onSettled: invalidate,
  });
}

export function useToggleAddon(serviceId: string) {
  const { shopId } = useShop();
  const invalidate = useInvalidateCatalog();
  return useMutation({
    mutationFn: async ({ addonId, offered }: { addonId: string; offered: boolean }) => {
      if (offered) {
        unwrap(
          await supabase
            .from('service_addons')
            .insert({ shop_id: shopId, service_id: serviceId, addon_id: addonId }),
        );
      } else {
        unwrap(
          await supabase
            .from('service_addons')
            .delete()
            .eq('shop_id', shopId)
            .eq('service_id', serviceId)
            .eq('addon_id', addonId),
        );
      }
    },
    onSettled: invalidate,
  });
}

// ------------------------------------------------------------- images

/** Uploads (overwrites) a service image, then points services.image_path at it. */
export function useUploadServiceImage(service: Pick<ServiceRow, 'id' | 'image_path'>) {
  const { shopId } = useShop();
  const invalidate = useInvalidateCatalog();
  return useMutation({
    mutationFn: async (file: File) => {
      const path = serviceImagePath(shopId, service.id, file.type);
      const bucket = supabase.storage.from('shop-assets');
      const upload = await bucket.upload(path, file, {
        upsert: true,
        contentType: file.type,
        cacheControl: '3600',
      });
      if (upload.error) throw toAppError(upload.error);
      const rows = listOf(
        await supabase
          .from('services')
          .update({ image_path: path })
          .eq('shop_id', shopId)
          .eq('id', service.id)
          .select('id'),
      );
      if (rows.length === 0) throw notUpdated('service');
      if (service.image_path && service.image_path !== path) {
        await bucket.remove([service.image_path]);
      }
    },
    onSettled: invalidate,
  });
}

export function useRemoveServiceImage(service: Pick<ServiceRow, 'id' | 'image_path'>) {
  const { shopId } = useShop();
  const invalidate = useInvalidateCatalog();
  return useMutation({
    mutationFn: async () => {
      const rows = listOf(
        await supabase
          .from('services')
          .update({ image_path: null })
          .eq('shop_id', shopId)
          .eq('id', service.id)
          .select('id'),
      );
      if (rows.length === 0) throw notUpdated('service');
      if (service.image_path)
        await supabase.storage.from('shop-assets').remove([service.image_path]);
    },
    onSettled: invalidate,
  });
}

// ------------------------------------------------------------- checklists

export interface ChecklistTemplateInput {
  id?: string;
  name: string;
  serviceId: string | null;
  items: ChecklistItemPayload[];
}

export function useSaveChecklistTemplate() {
  const { shopId } = useShop();
  const invalidate = useInvalidateCatalog();
  return useMutation({
    mutationFn: async ({ id, name, serviceId, items }: ChecklistTemplateInput) => {
      const values = { name, service_id: serviceId, items };
      if (id) {
        const rows = listOf(
          await supabase
            .from('checklist_templates')
            .update(values)
            .eq('shop_id', shopId)
            .eq('id', id)
            .select('id'),
        );
        if (rows.length === 0) throw notUpdated('checklist');
      } else {
        unwrap(await supabase.from('checklist_templates').insert({ ...values, shop_id: shopId }));
      }
    },
    onSettled: invalidate,
  });
}

export function useDeleteChecklistTemplate() {
  const { shopId } = useShop();
  const invalidate = useInvalidateCatalog();
  return useMutation({
    mutationFn: async (id: string) => {
      const rows = listOf(
        await supabase
          .from('checklist_templates')
          .delete()
          .eq('shop_id', shopId)
          .eq('id', id)
          .select('id'),
      );
      if (rows.length === 0) throw notUpdated('checklist');
    },
    onSettled: invalidate,
  });
}
