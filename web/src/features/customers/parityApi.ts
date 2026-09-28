/**
 * Customer page additions (parity): documents (P-25), custom field data
 * (P-9), referral code and credits (P-29) and merging duplicates (P-20).
 * Every rule is the server's (RLS, triggers, RPCs); this is the data layer.
 */
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { z } from 'zod';
import { unwrap, unwrapRequired, type Row } from '@/lib/db';
import { AppError } from '@/lib/errors';
import { readCustomData, type CustomData, type CustomFieldDef } from '@/lib/customFields';
import { shopKey } from '@/lib/queryKeys';
import { supabase } from '@/lib/supabase';
import { useShop } from '@/features/shop/shopContext';
import { documentContentType, documentDisplayName, safeFileName } from '@/features/jobs/documents';
import { unwrapList } from '@/features/quotes/shared/db';
import { customerKeys } from './api';

const SIGNED_URL_SECONDS = 60 * 60;

export const parityKeys = {
  documents: (shopId: string, customerId: string) =>
    [...customerKeys.all(shopId), 'documents', customerId] as const,
  customFields: (shopId: string) => shopKey(shopId, 'settings', 'custom-fields', 'customer'),
  referralProgram: (shopId: string) => shopKey(shopId, 'settings', 'money-referral-program'),
  referralCode: (shopId: string, customerId: string) =>
    [...customerKeys.all(shopId), 'referral-code', customerId] as const,
  referralCredits: (shopId: string, customerId: string) =>
    [...customerKeys.all(shopId), 'referral-credits', customerId] as const,
  leadRequests: (shopId: string, customerId: string) =>
    [...customerKeys.all(shopId), 'lead-requests', customerId] as const,
  mergePreview: (shopId: string, sourceId: string, targetId: string) =>
    [...customerKeys.all(shopId), 'merge-preview', sourceId, targetId] as const,
};

// ---------------------------------------------------------------------------
// Documents
// ---------------------------------------------------------------------------

export type CustomerDocument = Pick<
  Row<'documents'>,
  | 'id'
  | 'job_id'
  | 'file_name'
  | 'content_type'
  | 'size_bytes'
  | 'customer_visible'
  | 'created_at'
  | 'storage_path'
> & { url: string | null; job_number: number | null };

const documentRowSchema = z.object({
  id: z.string(),
  job_id: z.string().nullable(),
  file_name: z.string(),
  content_type: z.string(),
  size_bytes: z.number(),
  customer_visible: z.boolean(),
  created_at: z.string(),
  storage_path: z.string(),
  job: z.object({ number: z.number() }).nullable().optional(),
});

/** documents bucket object name for a customer file (exactly 4 segments). */
export function customerDocumentPath(
  shopId: string,
  customerId: string,
  id: string,
  fileName: string,
): string {
  return `${shopId}/customers/${customerId}/${id}-${safeFileName(fileName)}`;
}

/**
 * The customer's files: their own folder plus the files of their jobs (a job
 * file's customer is filled by the server). Managers+ (RLS). Short-lived
 * signed URLs to open them.
 */
export function useCustomerDocuments(customerId: string, enabled: boolean) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: parityKeys.documents(shopId, customerId),
    enabled,
    staleTime: 30 * 60_000, // signed URLs last an hour
    queryFn: async (): Promise<CustomerDocument[]> => {
      const { data, error } = await supabase
        .from('documents')
        .select(
          'id, job_id, file_name, content_type, size_bytes, customer_visible, created_at, storage_path, job:jobs(number)',
        )
        .eq('shop_id', shopId)
        .eq('customer_id', customerId)
        .order('created_at', { ascending: false });
      const rows = z.array(documentRowSchema).parse(unwrap({ data, error }) ?? []);
      const urls = new Map<string, string>();
      if (rows.length > 0) {
        const signed = await supabase.storage.from('documents').createSignedUrls(
          rows.map((r) => r.storage_path),
          SIGNED_URL_SECONDS,
        );
        if (!signed.error) {
          for (const item of signed.data) {
            if (item.path && item.signedUrl) urls.set(item.path, item.signedUrl);
          }
        }
      }
      return rows.map(({ job, ...row }) => ({
        ...row,
        job_number: job?.number ?? null,
        url: urls.get(row.storage_path) ?? null,
      }));
    },
  });
}

function useInvalidateDocuments(customerId: string) {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return () =>
    queryClient.invalidateQueries({ queryKey: parityKeys.documents(shopId, customerId) });
}

export function useUploadCustomerDocument(customerId: string) {
  const { shopId } = useShop();
  const invalidate = useInvalidateDocuments(customerId);
  return useMutation({
    mutationFn: async (file: File) => {
      const contentType = documentContentType(file);
      if (!contentType) {
        throw new AppError('This type of file can’t be uploaded.', { kind: 'validation' });
      }
      const path = customerDocumentPath(shopId, customerId, crypto.randomUUID(), file.name);
      const upload = await supabase.storage
        .from('documents')
        .upload(path, file, { contentType, upsert: false });
      if (upload.error) {
        throw new AppError(
          upload.error.message.toLowerCase().includes('row-level security')
            ? 'You don’t have permission to add files to this customer.'
            : 'The upload failed. Check your connection and try again.',
          { kind: 'server', cause: upload.error },
        );
      }
      const { error } = await supabase.from('documents').insert({
        shop_id: shopId,
        customer_id: customerId,
        storage_path: path,
        file_name: documentDisplayName(file.name),
        content_type: contentType,
        size_bytes: file.size,
      });
      if (error) {
        try {
          await supabase.storage.from('documents').remove([path]);
        } catch {
          // best effort: an unregistered object is private and purged later
        }
        unwrap({ data: null, error });
      }
    },
    onSettled: invalidate,
  });
}

/** Show / hide a file on the customer's portal (and job report / booking page for job files). */
export function useSetCustomerDocumentVisible(customerId: string) {
  const { shopId } = useShop();
  const invalidate = useInvalidateDocuments(customerId);
  return useMutation({
    mutationFn: async ({ id, visible }: { id: string; visible: boolean }) => {
      const rows = unwrapList(
        await supabase
          .from('documents')
          .update({ customer_visible: visible })
          .eq('shop_id', shopId)
          .eq('id', id)
          .select('id'),
      );
      if (rows.length === 0) {
        throw new AppError('Only managers can share files with the customer.', {
          kind: 'permission',
        });
      }
    },
    onSettled: invalidate,
  });
}

/** Deletes the row; the server queues the stored file for removal. */
export function useDeleteCustomerDocument(customerId: string) {
  const { shopId } = useShop();
  const invalidate = useInvalidateDocuments(customerId);
  return useMutation({
    mutationFn: async (id: string) => {
      const rows = unwrapList(
        await supabase.from('documents').delete().eq('shop_id', shopId).eq('id', id).select('id'),
      );
      if (rows.length === 0) {
        throw new AppError('This file could not be deleted.', { kind: 'permission' });
      }
    },
    onSettled: invalidate,
  });
}

// ---------------------------------------------------------------------------
// Custom fields (customer entity)
// ---------------------------------------------------------------------------

export type CustomFieldRow = Pick<
  Row<'custom_fields'>,
  'id' | 'key' | 'label' | 'type' | 'options' | 'help_text' | 'required' | 'sort' | 'archived_at'
>;

// ---------------------------------------------------------------------------
// Lead form requests (P-9)
// ---------------------------------------------------------------------------

/**
 * What the customer asked for on a lead form (lead_submissions, written only
 * by public_submit_lead). A submission never changes an existing customer, so
 * the message, the answers and the vehicle they described live only here.
 */
export interface LeadRequest {
  id: string;
  created_at: string;
  /** null when the form was deleted. */
  form_name: string | null;
  message: string | null;
  answers: CustomData;
  /** The vehicle as the visitor described it ({year, make, model}). */
  vehicle: { year: number | null; make: string | null; model: string | null } | null;
  /** The customer already existed (their record was left unchanged). */
  matched_existing: boolean;
}

/** Most recent requests shown on the customer page. */
export const LEAD_REQUESTS_LIMIT = 10;

const leadVehicleSchema = z.object({
  year: z.number().int().nullable().optional(),
  make: z.string().nullable().optional(),
  model: z.string().nullable().optional(),
});

const leadRequestRowSchema = z.object({
  id: z.string(),
  created_at: z.string(),
  message: z.string().nullable(),
  answers: z.unknown(),
  vehicle_info: z.unknown(),
  matched_existing: z.boolean(),
  form: z.object({ name: z.string() }).nullable().optional(),
});

/** Year make model, or null when the visitor gave none of them. */
export function leadVehicleText(vehicle: LeadRequest['vehicle']): string | null {
  if (!vehicle) return null;
  const text = [vehicle.year, vehicle.make, vehicle.model]
    .filter((p) => p !== null && p !== undefined && String(p).trim() !== '')
    .join(' ');
  return text || null;
}

/**
 * The customer's lead form submissions, newest first (managers+: RLS on
 * lead_submissions and lead_forms). `total` is the exact count, so the card
 * can say when older requests are not shown.
 */
export function useCustomerLeadRequests(customerId: string, enabled: boolean) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: parityKeys.leadRequests(shopId, customerId),
    enabled,
    queryFn: async (): Promise<{ requests: LeadRequest[]; total: number }> => {
      const { data, error, count } = await supabase
        .from('lead_submissions')
        .select(
          'id, created_at, message, answers, vehicle_info, matched_existing, form:lead_forms(name)',
          {
            count: 'exact',
          },
        )
        .eq('shop_id', shopId)
        .eq('customer_id', customerId)
        .order('created_at', { ascending: false })
        .limit(LEAD_REQUESTS_LIMIT);
      const rows = z.array(leadRequestRowSchema).parse(unwrap({ data, error }) ?? []);
      const requests = rows.map((row): LeadRequest => {
        const vehicle = leadVehicleSchema.safeParse(row.vehicle_info);
        return {
          id: row.id,
          created_at: row.created_at,
          form_name: row.form?.name ?? null,
          message: row.message,
          answers: readCustomData(row.answers),
          vehicle: vehicle.success
            ? {
                year: vehicle.data.year ?? null,
                make: vehicle.data.make ?? null,
                model: vehicle.data.model ?? null,
              }
            : null,
          matched_existing: row.matched_existing,
        };
      });
      return { requests, total: count ?? requests.length };
    },
  });
}

/** The shop's customer fields in order (archived ones kept: saved answers keep their label). */
export function useCustomerFields() {
  const { shopId } = useShop();
  return useQuery({
    queryKey: parityKeys.customFields(shopId),
    staleTime: 60_000,
    queryFn: async (): Promise<CustomFieldDef[]> => {
      const rows = unwrapList<CustomFieldRow>(
        await supabase
          .from('custom_fields')
          .select('id, key, label, type, options, help_text, required, sort, archived_at')
          .eq('shop_id', shopId)
          .eq('entity', 'customer')
          .order('sort', { ascending: true })
          .order('label', { ascending: true }),
      );
      return rows.map((r) => ({
        key: r.key,
        label: r.label,
        type: r.type,
        options: r.options,
        help_text: r.help_text,
        required: r.required,
        archived_at: r.archived_at,
      }));
    },
  });
}

/** Saves customers.custom_data (validated by the server; "<label> must be …" errors). */
export function useUpdateCustomerCustomData(customerId: string) {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (data: CustomData) =>
      readCustomData(
        unwrapRequired<{ custom_data: unknown }>(
          await supabase
            .from('customers')
            .update({ custom_data: data })
            .eq('shop_id', shopId)
            .eq('id', customerId)
            .select('custom_data')
            .maybeSingle(),
          'customer',
        ).custom_data,
      ),
    onSettled: () => queryClient.invalidateQueries({ queryKey: customerKeys.all(shopId) }),
  });
}

// ---------------------------------------------------------------------------
// Referral program
// ---------------------------------------------------------------------------

export type ReferralProgram = Pick<
  Row<'referral_settings'>,
  'enabled' | 'referee_discount_kind' | 'referee_discount_value' | 'referrer_reward_cents'
>;

export function useReferralProgram(enabled: boolean) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: parityKeys.referralProgram(shopId),
    enabled,
    staleTime: 60_000,
    queryFn: async (): Promise<ReferralProgram | null> =>
      unwrap(
        await supabase
          .from('referral_settings')
          .select('enabled, referee_discount_kind, referee_discount_value, referrer_reward_cents')
          .eq('shop_id', shopId)
          .maybeSingle(),
      ),
  });
}

export const referralCodeSchema = z.object({ code: z.string(), share_url: z.string().nullable() });
export type ReferralCode = z.infer<typeof referralCodeSchema>;

/**
 * The customer's referral code and share link, created on first call
 * (get_or_create_referral_code; 55000 while the program is off).
 */
export function useReferralCode(customerId: string, enabled: boolean) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: parityKeys.referralCode(shopId, customerId),
    enabled,
    staleTime: Infinity,
    retry: false,
    queryFn: async (): Promise<ReferralCode> =>
      referralCodeSchema.parse(
        unwrap(await supabase.rpc('get_or_create_referral_code', { p_customer_id: customerId })),
      ),
  });
}

/** The booking link that carries the code (the server's share_url, else this origin). */
export function referralShareUrl(code: ReferralCode, slug: string, origin?: string): string {
  if (code.share_url) return code.share_url;
  const base = (origin ?? window.location.origin).replace(/\/+$/, '');
  return `${base}/book/${encodeURIComponent(slug)}?coupon=${encodeURIComponent(code.code)}`;
}

export const referralCreditSchema = z.object({
  id: z.string(),
  status: z.enum(['issued', 'skipped']),
  amount_cents: z.number().int(),
  created_at: z.string(),
  referee: z
    .object({
      id: z.string(),
      first_name: z.string().nullable(),
      last_name: z.string().nullable(),
      company: z.string().nullable(),
    })
    .nullable(),
});
export type ReferralCredit = z.infer<typeof referralCreditSchema>;

/** Rewards earned by this customer as a referrer (referral_credits, managers+). */
export function useReferralCredits(customerId: string, enabled: boolean) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: parityKeys.referralCredits(shopId, customerId),
    enabled,
    queryFn: async (): Promise<ReferralCredit[]> => {
      const { data, error } = await supabase
        .from('referral_credits')
        .select(
          'id, status, amount_cents, created_at, referee:customers!referral_credits_referee_fk(id, first_name, last_name, company)',
        )
        .eq('shop_id', shopId)
        .eq('referrer_customer_id', customerId)
        .order('created_at', { ascending: false })
        .limit(50);
      return z.array(referralCreditSchema).parse(unwrap({ data, error }) ?? []);
    },
  });
}

// ---------------------------------------------------------------------------
// Merge duplicates (owner / admin)
// ---------------------------------------------------------------------------

const summarySchema = z.object({
  id: z.string(),
  name: z.string().nullable(),
  email: z.string().nullable(),
  phone: z.string().nullable(),
  lifecycle: z.string(),
  created_at: z.string(),
  archived_at: z.string().nullable(),
  merged_into_id: z.string().nullable(),
  portal_linked: z.boolean(),
  has_stripe_customer: z.boolean(),
});

export const mergePreviewSchema = z.object({
  source: summarySchema,
  target: summarySchema,
  counts: z.record(z.string(), z.number()),
  conflicts: z.array(z.object({ code: z.string(), blocking: z.boolean(), message: z.string() })),
  can_merge: z.boolean(),
});
export type MergePreview = z.infer<typeof mergePreviewSchema>;

/** What merging source into target would move, and why it can't (blocking conflicts). */
export function useMergePreview(sourceId: string, targetId: string | null) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: parityKeys.mergePreview(shopId, sourceId, targetId ?? ''),
    enabled: targetId !== null,
    staleTime: 0,
    queryFn: async (): Promise<MergePreview> =>
      mergePreviewSchema.parse(
        unwrap(
          await supabase.rpc('merge_customers_preview', {
            p_source_id: sourceId,
            p_target_id: targetId ?? '',
          }),
        ),
      ),
  });
}

export const mergeResultSchema = z.object({
  target_id: z.string(),
  moved: z.record(z.string(), z.number()),
});

/** merge_customers: moves everything to the target and marks the source merged. */
export function useMergeCustomers() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async ({ sourceId, targetId }: { sourceId: string; targetId: string }) =>
      mergeResultSchema.parse(
        unwrap(
          await supabase.rpc('merge_customers', { p_source_id: sourceId, p_target_id: targetId }),
        ),
      ),
    // Nearly every domain has customer-owned rows: refresh the whole shop.
    onSettled: () => queryClient.invalidateQueries({ queryKey: ['shop', shopId] }),
  });
}

/** merge_customers_preview's counts: [key, singular, plural], in display order. */
export const MERGE_COUNT_LABELS: readonly (readonly [string, string, string])[] = [
  ['vehicles', 'vehicle', 'vehicles'],
  ['jobs', 'job', 'jobs'],
  ['series', 'recurring series', 'recurring series'],
  ['events', 'calendar event', 'calendar events'],
  ['quotes', 'quote', 'quotes'],
  ['invoices', 'invoice', 'invoices'],
  ['payments', 'payment', 'payments'],
  ['memberships', 'membership', 'memberships'],
  ['saved_cards', 'saved card', 'saved cards'],
  ['messages', 'message', 'messages'],
  ['forms', 'form', 'forms'],
  ['documents', 'document', 'documents'],
  ['gift_cards', 'gift card', 'gift cards'],
  ['coupons', 'coupon', 'coupons'],
];

/** "3 jobs, 2 invoices, 1 vehicle" of the non-zero counts. */
export function mergeCountsText(counts: Readonly<Record<string, number>>): string {
  const parts = MERGE_COUNT_LABELS.filter(([key]) => (counts[key] ?? 0) > 0).map(
    ([key, one, many]) => {
      const n = counts[key] ?? 0;
      return `${n} ${n === 1 ? one : many}`;
    },
  );
  return parts.length > 0 ? parts.join(', ') : 'No records to move';
}
