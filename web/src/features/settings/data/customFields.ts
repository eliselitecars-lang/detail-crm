/**
 * Custom fields (P-9): custom_fields (0081 / 0088). Every member reads them
 * (jobs and customers show their answers); owners/admins edit. Values live in
 * customers.custom_data / jobs.custom_data and are validated by the server.
 *
 * Other features: `useCustomFields('customer' | 'job')` for the definitions
 * (archived ones included, so saved answers keep their labels) and
 * `@/components/customFields` + `@/lib/customFields` to show / edit values.
 */
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useShop } from '@/features/shop/shopContext';
import type { CustomFieldDef, CustomFieldEntity } from '@/lib/customFields';
import { unwrap, type Row } from '@/lib/db';
import { AppError, toAppError } from '@/lib/errors';
import { supabase } from '@/lib/supabase';
import { settingsKeys } from '../api';
import { unwrapList } from './shared';

export type CustomField = Pick<
  Row<'custom_fields'>,
  | 'id'
  | 'entity'
  | 'key'
  | 'label'
  | 'type'
  | 'options'
  | 'help_text'
  | 'required'
  | 'show_in_booking'
  | 'show_in_lead_form'
  | 'location_scope'
  | 'sort'
  | 'archived_at'
>;

const COLUMNS =
  'id, entity, key, label, type, options, help_text, required, show_in_booking, show_in_lead_form, location_scope, sort, archived_at';

export const customFieldKeys = {
  all: (shopId: string) => [...settingsKeys.all(shopId), 'custom-fields'] as const,
  entity: (shopId: string, entity: CustomFieldEntity) =>
    [...customFieldKeys.all(shopId), entity] as const,
};

/** A custom_fields row as the shared inputs expect it. */
export function toFieldDef(field: CustomField): CustomFieldDef {
  return {
    key: field.key,
    label: field.label,
    type: field.type,
    options: field.options,
    help_text: field.help_text,
    required: field.required,
    archived_at: field.archived_at,
  };
}

/** The shop's fields of one entity, in order (archived ones last). */
export function useCustomFields(entity: CustomFieldEntity) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: customFieldKeys.entity(shopId, entity),
    staleTime: 60_000,
    queryFn: async (): Promise<CustomField[]> =>
      unwrapList(
        await supabase
          .from('custom_fields')
          .select(COLUMNS)
          .eq('shop_id', shopId)
          .eq('entity', entity)
          .order('archived_at', { ascending: true, nullsFirst: true })
          .order('sort')
          .order('label'),
      ),
  });
}

export interface CustomFieldInput {
  id?: string | undefined;
  entity: CustomFieldEntity;
  key: string;
  label: string;
  type: CustomField['type'];
  options: string[];
  help_text: string | null;
  required: boolean;
  show_in_booking: boolean;
  show_in_lead_form: boolean;
  location_scope: CustomField['location_scope'];
  sort?: number;
}

/** Friendlier text for the refusals a field edit can meet. */
export function customFieldError(error: unknown): AppError {
  const appError = toAppError(error);
  if (appError.code === '23505') {
    return new AppError('Another field already uses this key.', {
      kind: 'validation',
      cause: error,
    });
  }
  return appError;
}

export function useSaveCustomField() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async ({ id, ...values }: CustomFieldInput): Promise<void> => {
      try {
        if (id) {
          unwrap(
            await supabase.from('custom_fields').update(values).eq('id', id).eq('shop_id', shopId),
          );
        } else {
          unwrap(await supabase.from('custom_fields').insert({ ...values, shop_id: shopId }));
        }
      } catch (error) {
        throw customFieldError(error);
      }
    },
    onSettled: () => queryClient.invalidateQueries({ queryKey: customFieldKeys.all(shopId) }),
  });
}

export function useArchiveCustomField() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async ({ id, archived }: { id: string; archived: boolean }): Promise<void> => {
      unwrap(
        await supabase
          .from('custom_fields')
          .update({ archived_at: archived ? new Date().toISOString() : null })
          .eq('id', id)
          .eq('shop_id', shopId),
      );
    },
    onSettled: () => queryClient.invalidateQueries({ queryKey: customFieldKeys.all(shopId) }),
  });
}

export function useDeleteCustomField() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (id: string): Promise<void> => {
      unwrap(await supabase.from('custom_fields').delete().eq('id', id).eq('shop_id', shopId));
    },
    onSettled: () => queryClient.invalidateQueries({ queryKey: customFieldKeys.all(shopId) }),
  });
}

/** Writes sort = position (1-based) for every field whose position changed. */
export function useReorderCustomFields() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (ordered: readonly CustomField[]): Promise<void> => {
      const changes = ordered
        .map((f, index) => ({ id: f.id, sort: index + 1, before: f.sort }))
        .filter((c) => c.sort !== c.before);
      for (const change of changes) {
        unwrap(
          await supabase
            .from('custom_fields')
            .update({ sort: change.sort })
            .eq('id', change.id)
            .eq('shop_id', shopId),
        );
      }
    },
    onSettled: () => queryClient.invalidateQueries({ queryKey: customFieldKeys.all(shopId) }),
  });
}
