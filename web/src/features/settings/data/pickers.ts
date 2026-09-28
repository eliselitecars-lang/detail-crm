/** Pickers used by settings forms: catalog services and customers. */
import { keepPreviousData, useQuery } from '@tanstack/react-query';
import { useShop } from '@/features/shop/shopContext';
import { unwrapRequired, type Row } from '@/lib/db';
import { supabase } from '@/lib/supabase';
import { settingsKeys } from '../api';
import { unwrapList } from './shared';

export type ServiceOption = Pick<
  Row<'services'>,
  'id' | 'name' | 'kind' | 'active' | 'online_bookable' | 'category_id'
>;

export type CustomerOption = Pick<
  Row<'customers'>,
  'id' | 'first_name' | 'last_name' | 'company' | 'email' | 'phone'
>;

export const pickerKeys = {
  services: (shopId: string) => [...settingsKeys.all(shopId), 'service-options'] as const,
  customers: (shopId: string, term: string) =>
    [...settingsKeys.all(shopId), 'customer-options', term] as const,
  customer: (shopId: string, id: string) =>
    [...settingsKeys.all(shopId), 'customer-option', id] as const,
};

/** Non-archived catalog services (inactive ones included, flagged), by name. */
export function useServiceOptions() {
  const { shopId } = useShop();
  return useQuery({
    queryKey: pickerKeys.services(shopId),
    staleTime: 60_000,
    queryFn: async (): Promise<ServiceOption[]> =>
      unwrapList(
        await supabase
          .from('services')
          .select('id, name, kind, active, online_bookable, category_id')
          .eq('shop_id', shopId)
          .is('archived_at', null)
          .order('name'),
      ),
  });
}

/** % and _ are wildcards in LIKE: match them literally. */
export function escapeLike(text: string): string {
  return text.replace(/[\\%_]/g, (c) => `\\${c}`);
}

const CUSTOMER_COLUMNS = 'id, first_name, last_name, company, email, phone';

export function useCustomerOptions(query: string, enabled = true) {
  const { shopId } = useShop();
  const term = query.trim().toLowerCase();
  return useQuery({
    queryKey: pickerKeys.customers(shopId, term),
    enabled,
    placeholderData: keepPreviousData,
    queryFn: async (): Promise<CustomerOption[]> => {
      let request = supabase
        .from('customers')
        .select(CUSTOMER_COLUMNS)
        .eq('shop_id', shopId)
        .is('archived_at', null);
      if (term) request = request.ilike('search_text', `%${escapeLike(term)}%`);
      return unwrapList(await request.order('sort_name').order('id').limit(20));
    },
  });
}

export function useCustomerOption(id: string | null) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: pickerKeys.customer(shopId, id ?? ''),
    enabled: id !== null,
    queryFn: async (): Promise<CustomerOption> =>
      unwrapRequired(
        await supabase
          .from('customers')
          .select(CUSTOMER_COLUMNS)
          .eq('shop_id', shopId)
          .eq('id', id ?? '')
          .maybeSingle(),
        'customer',
      ),
  });
}

export function customerLabel(c: CustomerOption): string {
  const name = [c.first_name, c.last_name]
    .map((p) => p?.trim() ?? '')
    .filter(Boolean)
    .join(' ');
  const main = name || c.company?.trim() || 'Unnamed customer';
  const contact = c.email ?? c.phone;
  return contact ? `${main} (${contact})` : main;
}
