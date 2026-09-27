/**
 * Job detail panels: money summary + invoice, checklist, photos,
 * inspections, forms, time clock and messages. Storage object names follow
 * the storage.objects policies (first folder = shop id, second = job id for
 * job-photos). Money values are read from job_payment_summary only.
 */
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { z } from 'zod';
import { unwrap, unwrapRequired, type Row } from '@/lib/db';
import { AppError, edgeFunctionError } from '@/lib/errors';
import { shopKey } from '@/lib/queryKeys';
import { supabase } from '@/lib/supabase';
import { useShop } from '@/features/shop/shopContext';
import { jobKeys } from './api';
import { unwrapList } from './db';
import {
  jobPhotoPath,
  photoExtension,
  signaturePath,
  type DamageKind,
  type InspectionKind,
  type JobPhotoKind,
  type VehicleView,
} from './model';

const SIGNED_URL_SECONDS = 60 * 60;

function newId(): string {
  return crypto.randomUUID();
}

async function signedUrls(bucket: string, paths: string[]): Promise<Map<string, string>> {
  const unique = Array.from(new Set(paths));
  const map = new Map<string, string>();
  if (unique.length === 0) return map;
  const { data, error } = await supabase.storage
    .from(bucket)
    .createSignedUrls(unique, SIGNED_URL_SECONDS);
  if (error) return map; // images degrade to placeholders; rows still render
  for (const item of data) {
    if (item.path && item.signedUrl) map.set(item.path, item.signedUrl);
  }
  return map;
}

async function removeObject(bucket: string, path: string) {
  try {
    await supabase.storage.from(bucket).remove([path]);
  } catch {
    // best effort: an orphaned object is harmless and private
  }
}

async function uploadObject(bucket: string, path: string, body: Blob, contentType: string) {
  const { error } = await supabase.storage
    .from(bucket)
    .upload(path, body, { contentType, upsert: false });
  if (error) {
    throw new AppError(
      error.message.toLowerCase().includes('row-level security')
        ? 'You don’t have permission to upload files to this job.'
        : 'The upload failed. Check your connection and try again.',
      { kind: 'server', cause: error },
    );
  }
}

function useInvalidateJob(jobId: string) {
  const queryClient = useQueryClient();
  const { shopId } = useShop();
  return () => queryClient.invalidateQueries({ queryKey: jobKeys.detail(shopId, jobId) });
}

// ---------------------------------------------------------------------------
// Money panel
// ---------------------------------------------------------------------------

const summarySchema = z.object({
  job_id: z.string(),
  invoice_id: z.string().nullable(),
  invoice_number: z.number().nullable(),
  invoice_status: z.enum(['draft', 'open', 'partially_paid', 'paid', 'void']).nullable(),
  total_cents: z.number().nullable(),
  deposit_required_cents: z.number().nullable(),
  deposit_paid_cents: z.number().nullable(),
  deposit_due_cents: z.number().nullable(),
  paid_cents: z.number().nullable(),
  tip_cents: z.number().nullable(),
  refunded_cents: z.number().nullable(),
  pending_cents: z.number().nullable(),
  balance_cents: z.number().nullable(),
});

export type PaymentSummary = z.infer<typeof summarySchema>;

export function usePaymentSummary(jobId: string, enabled: boolean) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: jobKeys.part(shopId, jobId, 'payments'),
    enabled,
    queryFn: async (): Promise<PaymentSummary | null> => {
      const rows = z
        .array(summarySchema)
        .parse(unwrap(await supabase.rpc('job_payment_summary', { p_job_id: jobId })) ?? []);
      return rows[0] ?? null;
    },
  });
}

export function useCreateInvoice(jobId: string) {
  const queryClient = useQueryClient();
  const { shopId } = useShop();
  return useMutation({
    mutationFn: async (): Promise<string> => {
      const invoice = unwrapRequired(
        await supabase.rpc('create_invoice_from_job', { p_job_id: jobId }),
        'invoice',
      );
      return invoice.id;
    },
    onSettled: async () => {
      await Promise.all([
        queryClient.invalidateQueries({ queryKey: jobKeys.all(shopId) }),
        queryClient.invalidateQueries({ queryKey: shopKey(shopId, 'invoices') }),
        queryClient.invalidateQueries({ queryKey: shopKey(shopId, 'payments') }),
      ]);
    },
  });
}

// ---------------------------------------------------------------------------
// Checklist
// ---------------------------------------------------------------------------

export type ChecklistItem = Pick<
  Row<'job_checklist_items'>,
  'id' | 'label' | 'sort' | 'done_at' | 'done_by' | 'template_id'
>;

export function useChecklist(jobId: string) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: jobKeys.part(shopId, jobId, 'checklist'),
    queryFn: async (): Promise<ChecklistItem[]> =>
      unwrapList(
        await supabase
          .from('job_checklist_items')
          .select('id, label, sort, done_at, done_by, template_id')
          .eq('shop_id', shopId)
          .eq('job_id', jobId)
          .order('sort')
          .order('created_at'),
      ),
  });
}

/** Ticking is local and reversible → optimistic (README → Mutations). */
export function useToggleChecklistItem(jobId: string) {
  const queryClient = useQueryClient();
  const { shopId } = useShop();
  const key = jobKeys.part(shopId, jobId, 'checklist');
  return useMutation({
    mutationFn: async ({ id, done }: { id: string; done: boolean }) => {
      const rows = unwrapList(
        await supabase
          .from('job_checklist_items')
          .update({ done_at: done ? new Date().toISOString() : null })
          .eq('shop_id', shopId)
          .eq('id', id)
          .select('id'),
      );
      if (rows.length === 0) {
        throw new AppError('You can’t update this checklist.', { kind: 'permission' });
      }
    },
    onMutate: async ({ id, done }) => {
      await queryClient.cancelQueries({ queryKey: key });
      const previous = queryClient.getQueryData<ChecklistItem[]>(key);
      queryClient.setQueryData<ChecklistItem[]>(key, (items) =>
        items?.map((item) =>
          item.id === id ? { ...item, done_at: done ? new Date().toISOString() : null } : item,
        ),
      );
      return { previous };
    },
    onError: (_error, _vars, context) => {
      if (context?.previous) queryClient.setQueryData(key, context.previous);
    },
    onSettled: () => queryClient.invalidateQueries({ queryKey: key }),
  });
}

export function useAddChecklistItem(jobId: string) {
  const { shopId } = useShop();
  const invalidate = useInvalidateJob(jobId);
  return useMutation({
    mutationFn: async ({ label, sort }: { label: string; sort: number }) => {
      unwrap(
        await supabase
          .from('job_checklist_items')
          .insert({ shop_id: shopId, job_id: jobId, label: label.trim(), sort }),
      );
    },
    onSettled: invalidate,
  });
}

export function useDeleteChecklistItem(jobId: string) {
  const { shopId } = useShop();
  const invalidate = useInvalidateJob(jobId);
  return useMutation({
    mutationFn: async (id: string) => {
      unwrap(await supabase.from('job_checklist_items').delete().eq('shop_id', shopId).eq('id', id));
    },
    onSettled: invalidate,
  });
}

export function useChecklistTemplates(enabled: boolean) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: shopKey(shopId, 'catalog', 'checklist_templates'),
    enabled,
    queryFn: async (): Promise<Pick<Row<'checklist_templates'>, 'id' | 'name'>[]> =>
      unwrapList(
        await supabase
          .from('checklist_templates')
          .select('id, name')
          .eq('shop_id', shopId)
          .order('name'),
      ),
  });
}

export function useApplyChecklistTemplate(jobId: string) {
  const invalidate = useInvalidateJob(jobId);
  return useMutation({
    mutationFn: async (templateId: string): Promise<number> => {
      const rows = unwrap(
        await supabase.rpc('apply_checklist_template', {
          p_job_id: jobId,
          p_template_id: templateId,
        }),
      );
      return rows?.length ?? 0;
    },
    onSettled: invalidate,
  });
}

// ---------------------------------------------------------------------------
// Photos
// ---------------------------------------------------------------------------

export type JobPhoto = Pick<
  Row<'job_photos'>,
  'id' | 'storage_path' | 'kind' | 'caption' | 'uploaded_by' | 'created_at'
> & { url: string | null };

export function usePhotos(jobId: string) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: jobKeys.part(shopId, jobId, 'photos'),
    // signed URLs expire after an hour; refresh well before that
    staleTime: 30 * 60_000,
    queryFn: async (): Promise<JobPhoto[]> => {
      const rows = unwrapList(
        await supabase
          .from('job_photos')
          .select('id, storage_path, kind, caption, uploaded_by, created_at')
          .eq('shop_id', shopId)
          .eq('job_id', jobId)
          .order('created_at'),
      );
      const urls = await signedUrls(
        'job-photos',
        rows.map((r) => r.storage_path),
      );
      return rows.map((r) => ({ ...r, url: urls.get(r.storage_path) ?? null }));
    },
  });
}

export function useUploadPhoto(jobId: string) {
  const { shopId } = useShop();
  const invalidate = useInvalidateJob(jobId);
  return useMutation({
    mutationFn: async ({
      file,
      kind,
      caption,
    }: {
      file: File;
      kind: JobPhotoKind;
      caption: string | null;
    }) => {
      const ext = photoExtension(file);
      if (!ext) throw new AppError('Choose a JPEG, PNG, WebP or HEIC image.', { kind: 'validation' });
      const path = jobPhotoPath(shopId, jobId, ext, newId());
      await uploadObject('job-photos', path, file, file.type || `image/${ext}`);
      const { error } = await supabase
        .from('job_photos')
        .insert({ shop_id: shopId, job_id: jobId, storage_path: path, kind, caption });
      if (error) {
        await removeObject('job-photos', path);
        unwrap({ data: null, error });
      }
    },
    onSettled: invalidate,
  });
}

export function useDeletePhoto(jobId: string) {
  const { shopId } = useShop();
  const invalidate = useInvalidateJob(jobId);
  return useMutation({
    mutationFn: async (photo: Pick<JobPhoto, 'id' | 'storage_path'>) => {
      const rows = unwrapList(
        await supabase
          .from('job_photos')
          .delete()
          .eq('shop_id', shopId)
          .eq('id', photo.id)
          .select('id'),
      );
      if (rows.length === 0) {
        throw new AppError('You can only delete photos you uploaded.', { kind: 'permission' });
      }
      await removeObject('job-photos', photo.storage_path);
    },
    onSettled: invalidate,
  });
}

// ---------------------------------------------------------------------------
// Inspections
// ---------------------------------------------------------------------------

const markSchema = z.object({
  id: z.string(),
  view: z.enum(['front', 'rear', 'left', 'right', 'top', 'interior']),
  x: z.number(),
  y: z.number(),
  damage: z.enum(['scratch', 'dent', 'chip', 'crack', 'stain', 'swirl', 'other']),
  note: z.string().nullable(),
  photo_path: z.string().nullable(),
  created_at: z.string(),
});

const inspectionSchema = z.object({
  id: z.string(),
  job_id: z.string(),
  vehicle_id: z.string().nullable(),
  kind: z.enum(['pre', 'post']),
  mileage: z.number().nullable(),
  fuel_level: z.number().nullable(),
  notes: z.string().nullable(),
  customer_signature_path: z.string().nullable(),
  signed_by_name: z.string().nullable(),
  signed_at: z.string().nullable(),
  created_at: z.string(),
  marks: z.array(markSchema),
});

export type InspectionMark = z.infer<typeof markSchema> & { photoUrl: string | null };
export type Inspection = Omit<z.infer<typeof inspectionSchema>, 'marks'> & {
  marks: InspectionMark[];
  signatureUrl: string | null;
};

export function useInspections(jobId: string) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: jobKeys.part(shopId, jobId, 'inspections'),
    staleTime: 30 * 60_000,
    queryFn: async (): Promise<Inspection[]> => {
      const data = unwrap(
        await supabase
          .from('inspections')
          .select(
            'id, job_id, vehicle_id, kind, mileage, fuel_level, notes, customer_signature_path, signed_by_name, signed_at, created_at, marks:inspection_marks(id, view, x, y, damage, note, photo_path, created_at)',
          )
          .eq('shop_id', shopId)
          .eq('job_id', jobId)
          .order('kind', { ascending: false })
          .order('created_at'),
      );
      const rows = z.array(inspectionSchema).parse(data ?? []);
      const [photoUrls, signatureUrls] = await Promise.all([
        signedUrls(
          'job-photos',
          rows.flatMap((r) => r.marks.map((m) => m.photo_path).filter((p): p is string => !!p)),
        ),
        signedUrls(
          'signatures',
          rows.map((r) => r.customer_signature_path).filter((p): p is string => !!p),
        ),
      ]);
      return rows.map((r) => ({
        ...r,
        signatureUrl: r.customer_signature_path
          ? (signatureUrls.get(r.customer_signature_path) ?? null)
          : null,
        marks: r.marks
          .map((m) => ({
            ...m,
            photoUrl: m.photo_path ? (photoUrls.get(m.photo_path) ?? null) : null,
          }))
          .sort((a, b) => a.created_at.localeCompare(b.created_at)),
      }));
    },
  });
}

export function useCreateInspection(jobId: string) {
  const { shopId } = useShop();
  const invalidate = useInvalidateJob(jobId);
  return useMutation({
    mutationFn: async ({ kind, vehicleId }: { kind: InspectionKind; vehicleId: string | null }) => {
      unwrap(
        await supabase
          .from('inspections')
          .insert({ shop_id: shopId, job_id: jobId, kind, vehicle_id: vehicleId }),
      );
    },
    onSettled: invalidate,
  });
}

export function useUpdateInspection(jobId: string) {
  const { shopId } = useShop();
  const invalidate = useInvalidateJob(jobId);
  return useMutation({
    mutationFn: async ({
      id,
      patch,
    }: {
      id: string;
      patch: { mileage?: number | null; fuel_level?: number | null; notes?: string | null };
    }) => {
      unwrap(await supabase.from('inspections').update(patch).eq('shop_id', shopId).eq('id', id));
    },
    onSettled: invalidate,
  });
}

export function useDeleteInspection(jobId: string) {
  const { shopId } = useShop();
  const invalidate = useInvalidateJob(jobId);
  return useMutation({
    mutationFn: async (id: string) => {
      unwrap(await supabase.from('inspections').delete().eq('shop_id', shopId).eq('id', id));
    },
    onSettled: invalidate,
  });
}

export interface NewMark {
  inspectionId: string;
  view: VehicleView;
  x: number;
  y: number;
  damage: DamageKind;
  note: string | null;
  photo: File | null;
}

export function useAddMark(jobId: string) {
  const { shopId } = useShop();
  const invalidate = useInvalidateJob(jobId);
  return useMutation({
    mutationFn: async (mark: NewMark) => {
      let photoPath: string | null = null;
      if (mark.photo) {
        const ext = photoExtension(mark.photo);
        if (!ext) throw new AppError('Choose a JPEG, PNG, WebP or HEIC image.', { kind: 'validation' });
        photoPath = jobPhotoPath(shopId, jobId, ext, newId());
        await uploadObject('job-photos', photoPath, mark.photo, mark.photo.type || `image/${ext}`);
      }
      const { error } = await supabase.from('inspection_marks').insert({
        shop_id: shopId,
        inspection_id: mark.inspectionId,
        view: mark.view,
        x: mark.x,
        y: mark.y,
        damage: mark.damage,
        note: mark.note,
        photo_path: photoPath,
      });
      if (error) {
        if (photoPath) await removeObject('job-photos', photoPath);
        unwrap({ data: null, error });
      }
    },
    onSettled: invalidate,
  });
}

export function useDeleteMark(jobId: string) {
  const { shopId } = useShop();
  const invalidate = useInvalidateJob(jobId);
  return useMutation({
    mutationFn: async (mark: Pick<InspectionMark, 'id' | 'photo_path'>) => {
      unwrap(await supabase.from('inspection_marks').delete().eq('shop_id', shopId).eq('id', mark.id));
      if (mark.photo_path) await removeObject('job-photos', mark.photo_path);
    },
    onSettled: invalidate,
  });
}

/** Customer signs the inspection: upload the PNG, then save path + name (server stamps signed_at). */
export function useSignInspection(jobId: string) {
  const { shopId } = useShop();
  const invalidate = useInvalidateJob(jobId);
  return useMutation({
    mutationFn: async ({
      inspectionId,
      signerName,
      signature,
    }: {
      inspectionId: string;
      signerName: string;
      signature: Blob;
    }) => {
      const path = signaturePath(shopId, 'inspections', inspectionId, newId());
      await uploadObject('signatures', path, signature, 'image/png');
      const rows = unwrapList(
        await supabase
          .from('inspections')
          .update({ customer_signature_path: path, signed_by_name: signerName.trim() })
          .eq('shop_id', shopId)
          .eq('id', inspectionId)
          .select('id'),
      );
      if (rows.length === 0) {
        throw new AppError('This inspection could not be signed.', { kind: 'permission' });
      }
    },
    onSettled: invalidate,
  });
}

/** Manager+: remove the signature so the inspection can be edited again. */
export function useClearInspectionSignature(jobId: string) {
  const { shopId } = useShop();
  const invalidate = useInvalidateJob(jobId);
  return useMutation({
    mutationFn: async (inspectionId: string) => {
      unwrap(
        await supabase
          .from('inspections')
          .update({ customer_signature_path: null, signed_by_name: null, signed_at: null })
          .eq('shop_id', shopId)
          .eq('id', inspectionId),
      );
    },
    onSettled: invalidate,
  });
}

// ---------------------------------------------------------------------------
// Forms
// ---------------------------------------------------------------------------

export type FormSubmission = Pick<
  Row<'form_submissions'>,
  | 'id'
  | 'title'
  | 'body_snapshot'
  | 'requires_signature'
  | 'public_token'
  | 'signer_name'
  | 'signed_at'
  | 'created_at'
  | 'form_template_id'
>;

export function useForms(jobId: string) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: jobKeys.part(shopId, jobId, 'forms'),
    queryFn: async (): Promise<FormSubmission[]> =>
      unwrapList(
        await supabase
          .from('form_submissions')
          .select(
            'id, title, body_snapshot, requires_signature, public_token, signer_name, signed_at, created_at, form_template_id',
          )
          .eq('shop_id', shopId)
          .eq('job_id', jobId)
          .order('created_at'),
      ),
  });
}

export type FormTemplate = Pick<Row<'form_templates'>, 'id' | 'name' | 'body' | 'requires_signature'>;

export function useFormTemplates(enabled: boolean) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: shopKey(shopId, 'settings', 'form_templates', 'active'),
    enabled,
    queryFn: async (): Promise<FormTemplate[]> =>
      unwrapList(
        await supabase
          .from('form_templates')
          .select('id, name, body, requires_signature')
          .eq('shop_id', shopId)
          .eq('active', true)
          .order('name'),
      ),
  });
}

export function useAttachForm(jobId: string) {
  const { shopId } = useShop();
  const invalidate = useInvalidateJob(jobId);
  return useMutation({
    mutationFn: async (template: FormTemplate) => {
      // form_submissions_before_insert fills title/body/customer from the
      // template and job; the values sent here are overwritten.
      unwrap(
        await supabase.from('form_submissions').insert({
          shop_id: shopId,
          job_id: jobId,
          form_template_id: template.id,
          title: template.name,
          body_snapshot: template.body,
        }),
      );
    },
    onSettled: invalidate,
  });
}

export function useDeleteForm(jobId: string) {
  const { shopId } = useShop();
  const invalidate = useInvalidateJob(jobId);
  return useMutation({
    mutationFn: async (id: string) => {
      unwrap(await supabase.from('form_submissions').delete().eq('shop_id', shopId).eq('id', id));
    },
    onSettled: invalidate,
  });
}

export function useSignForm(jobId: string) {
  const { shopId } = useShop();
  const invalidate = useInvalidateJob(jobId);
  return useMutation({
    mutationFn: async ({
      submissionId,
      signerName,
      signature,
    }: {
      submissionId: string;
      signerName: string;
      signature: Blob | null;
    }) => {
      let path: string | null = null;
      if (signature) {
        path = signaturePath(shopId, 'form-submissions', submissionId, newId());
        await uploadObject('signatures', path, signature, 'image/png');
      }
      unwrap(
        await supabase.rpc('sign_form_submission', {
          p_submission_id: submissionId,
          p_signer_name: signerName.trim(),
          ...(path ? { p_signature_path: path } : {}),
        }),
      );
    },
    onSettled: invalidate,
  });
}

// ---------------------------------------------------------------------------
// Time clock
// ---------------------------------------------------------------------------

export type TimeEntry = Pick<
  Row<'time_entries'>,
  'id' | 'member_id' | 'job_id' | 'kind' | 'clock_in' | 'clock_out' | 'source'
>;

export function useJobTime(jobId: string) {
  const { shopId, memberId } = useShop();
  return useQuery({
    queryKey: [...jobKeys.part(shopId, jobId, 'time'), memberId] as const,
    queryFn: async (): Promise<{ entries: TimeEntry[]; myOpenJobEntry: TimeEntry | null }> => {
      const [entries, mine] = await Promise.all([
        supabase
          .from('time_entries')
          .select('id, member_id, job_id, kind, clock_in, clock_out, source')
          .eq('shop_id', shopId)
          .eq('job_id', jobId)
          .order('clock_in', { ascending: false })
          .limit(50),
        supabase
          .from('time_entries')
          .select('id, member_id, job_id, kind, clock_in, clock_out, source')
          .eq('shop_id', shopId)
          .eq('member_id', memberId)
          .eq('kind', 'job')
          .is('clock_out', null)
          .limit(1),
      ]);
      return { entries: unwrapList(entries), myOpenJobEntry: unwrapList(mine)[0] ?? null };
    },
  });
}

export function useJobClock(jobId: string) {
  const queryClient = useQueryClient();
  const { shopId } = useShop();
  return useMutation({
    mutationFn: async (action: 'in' | 'out') => {
      if (action === 'in') {
        unwrap(
          await supabase.rpc('clock_in', {
            p_shop_id: shopId,
            p_job_id: jobId,
            p_kind: 'job',
            p_source: 'web',
          }),
        );
      } else {
        unwrap(await supabase.rpc('clock_out', { p_shop_id: shopId, p_kind: 'job' }));
      }
    },
    onSettled: async () => {
      await Promise.all([
        queryClient.invalidateQueries({ queryKey: jobKeys.detail(shopId, jobId) }),
        queryClient.invalidateQueries({ queryKey: shopKey(shopId, 'time_entries') }),
      ]);
    },
  });
}

// ---------------------------------------------------------------------------
// Messages
// ---------------------------------------------------------------------------

export type JobMessage = Pick<
  Row<'messages'>,
  | 'id'
  | 'direction'
  | 'channel'
  | 'body'
  | 'subject'
  | 'status'
  | 'template_key'
  | 'created_at'
  | 'error'
>;

export function useJobMessages(jobId: string, enabled: boolean) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: jobKeys.part(shopId, jobId, 'messages'),
    enabled,
    queryFn: async (): Promise<JobMessage[]> =>
      unwrapList(
        await supabase
          .from('messages')
          .select('id, direction, channel, body, subject, status, template_key, created_at, error')
          .eq('shop_id', shopId)
          .eq('job_id', jobId)
          .order('created_at', { ascending: false })
          .limit(20),
      ),
  });
}

export type JobTemplateKey = 'on_the_way' | 'job_completed';

const sendResponseSchema = z.object({
  message_id: z.string(),
  channel: z.enum(['sms', 'email']),
  status: z.string(),
  error: z.string().nullable(),
});

export type SendResult = z.infer<typeof sendResponseSchema>;

/** messaging edge function `send` with a template (technicians: assigned jobs only). */
export function useSendJobTemplate(jobId: string) {
  const queryClient = useQueryClient();
  const { shopId } = useShop();
  return useMutation({
    mutationFn: async ({
      templateKey,
      channel,
    }: {
      templateKey: JobTemplateKey;
      channel: 'sms' | 'email';
    }): Promise<SendResult> => {
      const result: { data: unknown; error: unknown } = await supabase.functions.invoke<unknown>(
        'messaging',
        {
          body: { action: 'send', shop_id: shopId, job_id: jobId, channel, template_key: templateKey },
        },
      );
      if (result.error) throw await edgeFunctionError(result.error);
      return sendResponseSchema.parse(result.data);
    },
    onSettled: async () => {
      await Promise.all([
        queryClient.invalidateQueries({ queryKey: jobKeys.part(shopId, jobId, 'messages') }),
        queryClient.invalidateQueries({ queryKey: shopKey(shopId, 'messages') }),
      ]);
    },
  });
}
