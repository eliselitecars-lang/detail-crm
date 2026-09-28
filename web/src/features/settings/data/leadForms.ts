/**
 * Lead-capture forms (P-9): lead_forms (0081 / 0088). The public page is
 * /lead/<token>; submissions create leads (or match existing customers,
 * which are never modified). Managers read, owners/admins edit. field_ids
 * are the shop's customer fields asked on the form, in order.
 */
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useShop } from '@/features/shop/shopContext';
import { unwrap, type Row } from '@/lib/db';
import { toAppError } from '@/lib/errors';
import { supabase } from '@/lib/supabase';
import { settingsKeys } from '../api';
import { unwrapList } from './shared';

export type LeadForm = Pick<
  Row<'lead_forms'>,
  | 'id'
  | 'token'
  | 'name'
  | 'headline'
  | 'intro'
  | 'default_source'
  | 'field_ids'
  | 'ask_vehicle'
  | 'ask_message'
  | 'success_message'
  | 'notify_staff'
  | 'auto_reply'
  | 'active'
  | 'archived_at'
  | 'created_at'
>;
export type CustomerSource = Row<'lead_forms'>['default_source'];

const COLUMNS =
  'id, token, name, headline, intro, default_source, field_ids, ask_vehicle, ask_message, success_message, notify_staff, auto_reply, active, archived_at, created_at';

export const leadFormKeys = {
  list: (shopId: string) => [...settingsKeys.all(shopId), 'lead-forms'] as const,
  counts: (shopId: string) => [...settingsKeys.all(shopId), 'lead-form-counts'] as const,
};

/** /lead/<token> */
export function leadFormUrl(token: string, origin: string = window.location.origin): string {
  return `${origin}/lead/${encodeURIComponent(token)}`;
}

export function useLeadForms() {
  const { shopId } = useShop();
  return useQuery({
    queryKey: leadFormKeys.list(shopId),
    queryFn: async (): Promise<LeadForm[]> =>
      unwrapList(
        await supabase
          .from('lead_forms')
          .select(COLUMNS)
          .eq('shop_id', shopId)
          .is('archived_at', null)
          .order('created_at', { ascending: false }),
      ),
  });
}

/**
 * Submissions in the last 30 days, per form (managers read lead_submissions):
 * one exact count per form (HEAD request), never a row list, so the numbers
 * are not capped by PostgREST's max_rows.
 */
export function useLeadSubmissionCounts(formIds: readonly string[]) {
  const { shopId } = useShop();
  const ids = [...new Set(formIds)].sort();
  return useQuery({
    queryKey: [...leadFormKeys.counts(shopId), ids] as const,
    enabled: ids.length > 0,
    queryFn: async (): Promise<Map<string, number>> => {
      const since = new Date(Date.now() - 30 * 24 * 3600 * 1000).toISOString();
      const entries = await Promise.all(
        ids.map(async (id) => {
          const { count, error } = await supabase
            .from('lead_submissions')
            .select('id', { count: 'exact', head: true })
            .eq('shop_id', shopId)
            .eq('lead_form_id', id)
            .gte('created_at', since);
          if (error) throw toAppError(error);
          return [id, count ?? 0] as const;
        }),
      );
      return new Map(entries);
    },
  });
}

export interface LeadFormInput {
  id?: string | undefined;
  name: string;
  headline: string | null;
  intro: string | null;
  default_source: CustomerSource;
  field_ids: string[];
  ask_vehicle: boolean;
  ask_message: boolean;
  success_message: string | null;
  notify_staff: boolean;
  auto_reply: boolean;
  active: boolean;
}

export function useSaveLeadForm() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async ({ id, ...values }: LeadFormInput): Promise<void> => {
      if (id) {
        unwrap(await supabase.from('lead_forms').update(values).eq('id', id).eq('shop_id', shopId));
      } else {
        unwrap(await supabase.from('lead_forms').insert({ ...values, shop_id: shopId }));
      }
    },
    onSettled: () => queryClient.invalidateQueries({ queryKey: leadFormKeys.list(shopId) }),
  });
}

/**
 * Archives a form: its link stops working; past submissions (and the leads
 * they created) stay.
 */
export function useArchiveLeadForm() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (id: string): Promise<void> => {
      unwrap(
        await supabase
          .from('lead_forms')
          .update({ archived_at: new Date().toISOString(), active: false })
          .eq('id', id)
          .eq('shop_id', shopId),
      );
    },
    onSettled: () => queryClient.invalidateQueries({ queryKey: leadFormKeys.list(shopId) }),
  });
}
