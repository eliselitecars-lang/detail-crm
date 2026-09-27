/**
 * Queries shared by the money features: customer/vehicle pickers, the
 * service catalog, catalog pricing (price_services RPC), shop document
 * defaults and customer messaging (server-rendered document messages +
 * messaging.send).
 */
import { keepPreviousData, useMutation, useQuery } from '@tanstack/react-query';
import { z } from 'zod';
import { unwrap, unwrapRequired, type Row } from '@/lib/db';
import { AppError } from '@/lib/errors';
import { shopKey } from '@/lib/queryKeys';
import { supabase } from '@/lib/supabase';
import { useShop } from '@/features/shop/shopContext';
import { unwrapList } from './db';
import { invokeEdge } from './edge';
import { escapeLike } from './format';

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
  documentPreview: (shopId: string, kind: string, id: string, channel: string) =>
    shopKey(shopId, 'settings', 'money-document-preview', kind, id, channel),
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
        await request.order('sort_name', { ascending: true }).order('id').limit(20),
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
  /** null when the shop has no vehicle sizes: base prices apply (argument omitted). */
  vehicleCategoryId: string | null;
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
          ...(args.vehicleCategoryId ? { p_vehicle_category_id: args.vehicleCategoryId } : {}),
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
// Messaging (quote_sent / invoice_sent — rendered by the server)
// ---------------------------------------------------------------------------

export type DocTemplateKey = 'quote_sent' | 'invoice_sent';
export type MessageChannel = 'sms' | 'email';
export type DocumentKind = 'quote' | 'invoice';

export interface DocumentRef {
  kind: DocumentKind;
  id: string;
}

const documentArgs = (doc: DocumentRef) =>
  doc.kind === 'quote' ? { p_quote_id: doc.id } : { p_invoice_id: doc.id };

export const documentPreviewSchema = z.object({
  enabled: z.boolean(),
  to_address: z.string().nullable(),
  subject: z.string().nullable(),
  body: z.string(),
});
export type DocumentPreview = z.infer<typeof documentPreviewSchema>;

/**
 * The shop's quote_sent / invoice_sent message for this document exactly as
 * the server will send it (preview_document_message, 0090): rendered from the
 * document, its customer and job, with the client link always filled in and
 * lines whose values are empty dropped. `enabled: false` = the template is
 * turned off for this channel. Manager+ only.
 */
export function useDocumentPreview(doc: DocumentRef, channel: MessageChannel, enabled = true) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: pickerKeys.documentPreview(shopId, doc.kind, doc.id, channel),
    enabled,
    queryFn: async (): Promise<DocumentPreview> => {
      const rows = unwrap(
        await supabase.rpc('preview_document_message', {
          ...documentArgs(doc),
          p_channel: channel,
        }),
      );
      const row = z.array(documentPreviewSchema).parse(rows ?? [])[0];
      if (!row)
        throw new AppError('That message template could not be found.', { kind: 'not_found' });
      return row;
    },
  });
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
  /** One per compose, reused on retry (messages.request_nonce): a replay never sends twice. */
  requestNonce?: string;
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
          ...(input.requestNonce ? { request_nonce: input.requestNonce } : {}),
        },
        sendResponseSchema,
      ),
  });
}

export interface SendDocumentInput {
  doc: DocumentRef;
  channel: MessageChannel;
  /** One per compose, reused on retry: a replay returns the first message. */
  requestNonce: string;
}

/**
 * messaging.send with quote_id / invoice_id: the server renders the shop's
 * quote_sent / invoice_sent template for the document (enqueue_document_message)
 * and delivers it. Refusals are 422 with details.reason (template_disabled,
 * missing_link, opted_out, no_address, sms_not_configured…).
 */
export function useSendDocumentMessage() {
  const { shopId } = useShop();
  return useMutation({
    mutationFn: ({ doc, channel, requestNonce }: SendDocumentInput) =>
      invokeEdge(
        'messaging',
        'send',
        {
          shop_id: shopId,
          channel,
          template_key: doc.kind === 'quote' ? 'quote_sent' : 'invoice_sent',
          ...(doc.kind === 'quote' ? { quote_id: doc.id } : { invoice_id: doc.id }),
          request_nonce: requestNonce,
        },
        sendResponseSchema,
      ),
  });
}
