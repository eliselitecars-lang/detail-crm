/**
 * Queries shared by the money features: customer/vehicle pickers, the
 * service catalog, catalog pricing (price_services RPC), shop document
 * defaults and customer messaging (template render + messaging.send).
 */
import { keepPreviousData, useMutation, useQuery } from '@tanstack/react-query';
import { z } from 'zod';
import { unwrap, unwrapRequired, type Row } from '@/lib/db';
import { formatCents } from '@/lib/money';
import { formatPhone } from '@/lib/phone';
import { shopKey } from '@/lib/queryKeys';
import { supabase } from '@/lib/supabase';
import { useShop } from '@/features/shop/shopContext';
import { unwrapList } from './db';
import { invokeEdge } from './edge';
import { customerName, escapeLike } from './format';

// ---------------------------------------------------------------------------
// Customers & vehicles
// ---------------------------------------------------------------------------

export const CUSTOMER_COLUMNS =
  'id, first_name, last_name, company, email, phone, archived_at, sms_opted_out_at, email_opted_out_at';

export type PickerCustomer = Pick<
  Row<'customers'>,
  | 'id'
  | 'first_name'
  | 'last_name'
  | 'company'
  | 'email'
  | 'phone'
  | 'archived_at'
  | 'sms_opted_out_at'
  | 'email_opted_out_at'
>;

export const VEHICLE_COLUMNS =
  'id, customer_id, year, make, model, trim, color, license_plate, category_id, archived_at';

export type PickerVehicle = Pick<
  Row<'vehicles'>,
  | 'id'
  | 'customer_id'
  | 'year'
  | 'make'
  | 'model'
  | 'trim'
  | 'color'
  | 'license_plate'
  | 'category_id'
  | 'archived_at'
>;

export const pickerKeys = {
  customerSearch: (shopId: string, query: string) =>
    shopKey(shopId, 'customers', 'money-picker', query),
  customer: (shopId: string, id: string) => shopKey(shopId, 'customers', 'money-customer', id),
  vehicles: (shopId: string, customerId: string) =>
    shopKey(shopId, 'vehicles', 'money-customer', customerId),
  categories: (shopId: string) => shopKey(shopId, 'catalog', 'money-vehicle-categories'),
  services: (shopId: string) => shopKey(shopId, 'catalog', 'money-services'),
  pricing: (shopId: string, args: unknown) => shopKey(shopId, 'catalog', 'money-pricing', args),
  docDefaults: (shopId: string) => shopKey(shopId, 'shop', 'money-doc-defaults'),
  template: (shopId: string, key: string, channel: string) =>
    shopKey(shopId, 'settings', 'money-template', key, channel),
};

/** Customer search for pickers (name / company / email / phone). */
export function useCustomerSearch(query: string, enabled = true) {
  const { shopId } = useShop();
  const term = query.trim().toLowerCase();
  return useQuery({
    queryKey: pickerKeys.customerSearch(shopId, term),
    enabled,
    placeholderData: keepPreviousData,
    queryFn: async (): Promise<PickerCustomer[]> => {
      let request = supabase
        .from('customers')
        .select(CUSTOMER_COLUMNS)
        .eq('shop_id', shopId)
        .is('archived_at', null);
      if (term) request = request.ilike('search_text', `%${escapeLike(term)}%`);
      return unwrapList(
        await request
          .order('last_name', { ascending: true, nullsFirst: false })
          .order('first_name', { ascending: true, nullsFirst: false })
          .limit(20),
      );
    },
  });
}

export function useCustomer(customerId: string | null | undefined) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: pickerKeys.customer(shopId, customerId ?? ''),
    enabled: Boolean(customerId),
    queryFn: async (): Promise<PickerCustomer> =>
      unwrapRequired(
        await supabase
          .from('customers')
          .select(CUSTOMER_COLUMNS)
          .eq('shop_id', shopId)
          .eq('id', customerId ?? '')
          .maybeSingle(),
        'customer',
      ),
  });
}

export function useCustomerVehicles(customerId: string | null | undefined) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: pickerKeys.vehicles(shopId, customerId ?? ''),
    enabled: Boolean(customerId),
    queryFn: async (): Promise<PickerVehicle[]> =>
      unwrapList(
        await supabase
          .from('vehicles')
          .select(VEHICLE_COLUMNS)
          .eq('shop_id', shopId)
          .eq('customer_id', customerId ?? '')
          .is('archived_at', null)
          .order('created_at', { ascending: true }),
      ),
  });
}

// ---------------------------------------------------------------------------
// Catalog
// ---------------------------------------------------------------------------

export type CatalogCategory = Pick<Row<'vehicle_categories'>, 'id' | 'name' | 'sort'>;
export type CatalogService = Pick<
  Row<'services'>,
  'id' | 'name' | 'kind' | 'description' | 'taxable' | 'duration_minutes' | 'sort'
>;

export function useVehicleCategories() {
  const { shopId } = useShop();
  return useQuery({
    queryKey: pickerKeys.categories(shopId),
    staleTime: 5 * 60_000,
    queryFn: async (): Promise<CatalogCategory[]> =>
      unwrapList(
        await supabase
          .from('vehicle_categories')
          .select('id, name, sort')
          .eq('shop_id', shopId)
          .order('sort', { ascending: true })
          .order('name', { ascending: true }),
      ),
  });
}

/** Active, non-archived services (all kinds) for line-item and plan pickers. */
export function useCatalogServices() {
  const { shopId } = useShop();
  return useQuery({
    queryKey: pickerKeys.services(shopId),
    staleTime: 60_000,
    queryFn: async (): Promise<CatalogService[]> =>
      unwrapList(
        await supabase
          .from('services')
          .select('id, name, kind, description, taxable, duration_minutes, sort')
          .eq('shop_id', shopId)
          .eq('active', true)
          .is('archived_at', null)
          .order('sort', { ascending: true })
          .order('name', { ascending: true }),
      ),
  });
}

export const pricedLineSchema = z.object({
  service_id: z.string(),
  name: z.string(),
  kind: z.string(),
  taxable: z.boolean(),
  duration_minutes: z.number().nullable(),
  catalog_price_cents: z.number().int().nullable(),
  unit_price_cents: z.number().int().nullable(),
  membership_included: z.boolean(),
  note: z.string().nullable(),
});

export const priceServicesSchema = z.object({
  vehicle_category_id: z.string().nullable(),
  tax_rate_bps: z.number().int().nullable(),
  duration_minutes: z.number().nullable(),
  priced: z.boolean().nullable(),
  lines: z.array(pricedLineSchema).nullable(),
  memberships: z
    .array(
      z.object({
        membership_id: z.string(),
        plan_id: z.string(),
        plan_name: z.string(),
        discount_bps: z.number().int(),
        vehicle_id: z.string().nullable(),
      }),
    )
    .nullable(),
  suggested_discount_kind: z.enum(['none', 'percent']),
  suggested_discount_value: z.number().int(),
});

export type PricedLine = z.infer<typeof pricedLineSchema>;
export type PriceServicesResult = z.infer<typeof priceServicesSchema>;

export interface PriceServicesArgs {
  customerId: string;
  vehicleCategoryId: string;
  vehicleId: string | null;
  serviceIds: string[];
}

/**
 * Catalog prices for the chosen services (price_services RPC: category
 * price, membership inclusions). Only unit prices are used from the result;
 * document totals are always recomputed by the server from saved lines.
 */
export function usePriceServices(args: PriceServicesArgs | null) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: pickerKeys.pricing(shopId, args),
    enabled: args !== null && args.serviceIds.length > 0,
    placeholderData: keepPreviousData,
    queryFn: async (): Promise<PriceServicesResult> => {
      if (!args) throw new Error('pricing arguments missing');
      const data = unwrap(
        await supabase.rpc('price_services', {
          p_shop: shopId,
          p_customer_id: args.customerId,
          p_vehicle_category_id: args.vehicleCategoryId,
          p_service_ids: args.serviceIds,
          ...(args.vehicleId ? { p_vehicle_id: args.vehicleId } : {}),
        }),
      );
      return priceServicesSchema.parse(data);
    },
  });
}

// ---------------------------------------------------------------------------
// Shop document defaults (terms) — not part of the shell's ShopSummary.
// ---------------------------------------------------------------------------

export type DocDefaults = Pick<
  Row<'shops'>,
  'quote_terms' | 'invoice_terms' | 'invoice_due_days' | 'tax_rate_bps' | 'name' | 'phone'
>;

export function useDocDefaults() {
  const { shopId } = useShop();
  return useQuery({
    queryKey: pickerKeys.docDefaults(shopId),
    staleTime: 5 * 60_000,
    queryFn: async (): Promise<DocDefaults> =>
      unwrapRequired(
        await supabase
          .from('shops')
          .select('quote_terms, invoice_terms, invoice_due_days, tax_rate_bps, name, phone')
          .eq('id', shopId)
          .maybeSingle(),
        'shop',
      ),
  });
}

// ---------------------------------------------------------------------------
// Messaging (quote_sent / invoice_sent)
// ---------------------------------------------------------------------------

export type DocTemplateKey = 'quote_sent' | 'invoice_sent';
export type MessageChannel = 'sms' | 'email';

export type DocTemplate = Pick<Row<'message_templates'>, 'subject' | 'body' | 'enabled'>;

export function useDocTemplate(key: DocTemplateKey, channel: MessageChannel, enabled = true) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: pickerKeys.template(shopId, key, channel),
    enabled,
    queryFn: async (): Promise<DocTemplate | null> =>
      unwrap(
        await supabase
          .from('message_templates')
          .select('subject, body, enabled')
          .eq('shop_id', shopId)
          .eq('key', key)
          .eq('channel', channel)
          .maybeSingle(),
      ),
  });
}

/** Values the document templates use ({{placeholders}}, see migration 0032). */
export interface DocTemplateContext {
  customer: { first_name: string | null; last_name: string | null; company: string | null };
  shopName: string;
  shopPhone: string | null;
  link: string;
  currency: string;
  /** Server totals (invoice total / balance); omitted for quotes. */
  amountCents?: number;
  balanceCents?: number;
}

/** Template variables, formatted like the server's comms vars. */
export function docTemplateVars(
  key: DocTemplateKey,
  ctx: DocTemplateContext,
): Record<string, string> {
  const first =
    ctx.customer.first_name?.trim() ||
    ctx.customer.company?.trim() ||
    ctx.customer.last_name?.trim() ||
    'there';
  const vars: Record<string, string> = {
    customer_first_name: first,
    customer_name: customerName(ctx.customer),
    shop_name: ctx.shopName,
    shop_phone: ctx.shopPhone ? formatPhone(ctx.shopPhone) : '',
  };
  vars[key === 'quote_sent' ? 'quote_link' : 'invoice_link'] = ctx.link;
  if (ctx.amountCents !== undefined) {
    vars.amount = formatCents(ctx.amountCents, { currency: ctx.currency });
  }
  if (ctx.balanceCents !== undefined) {
    vars.balance = formatCents(Math.max(ctx.balanceCents, 0), { currency: ctx.currency });
  }
  return vars;
}

/** Renders a template body with the SQL renderer (render_template RPC). */
export async function renderTemplate(body: string, vars: Record<string, string>): Promise<string> {
  const data = unwrap(await supabase.rpc('render_template', { p_body: body, p_vars: vars }));
  return typeof data === 'string' ? data : '';
}

export const sendResponseSchema = z.object({
  message_id: z.string(),
  channel: z.enum(['sms', 'email']),
  status: z.string(),
  error: z.string().nullable().optional(),
});

export type SendMessageResponse = z.infer<typeof sendResponseSchema>;

export interface SendMessageInput {
  customerId: string;
  channel: MessageChannel;
  body: string;
  subject?: string;
  jobId?: string | null;
}

/** messaging.send (free-form, manager+). The server queues + delivers immediately. */
export function useSendCustomerMessage() {
  const { shopId } = useShop();
  return useMutation({
    mutationFn: (input: SendMessageInput) =>
      invokeEdge(
        'messaging',
        'send',
        {
          shop_id: shopId,
          customer_id: input.customerId,
          channel: input.channel,
          body: input.body,
          ...(input.channel === 'email' && input.subject ? { subject: input.subject } : {}),
          ...(input.jobId ? { job_id: input.jobId } : {}),
        },
        sendResponseSchema,
      ),
  });
}
