/**
 * Job documents (P-25, 0075): files in the documents bucket registered by a
 * documents row. Managers see and manage every file; technicians the files
 * of jobs they work (they add files and delete their own; only managers make
 * a file visible to the customer — the server forces it off otherwise).
 * Deleting a row queues its object for the storage purge (server).
 */
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { unwrap, type Row } from '@/lib/db';
import { AppError } from '@/lib/errors';
import { supabase } from '@/lib/supabase';
import { useShop } from '@/features/shop/shopContext';
import { jobKeys } from './api';
import { unwrapList } from './db';
import { documentContentType, documentDisplayName, jobDocumentPath } from './documents';

const SIGNED_URL_SECONDS = 60 * 60;

export type JobDocument = Pick<
  Row<'documents'>,
  | 'id'
  | 'file_name'
  | 'content_type'
  | 'size_bytes'
  | 'customer_visible'
  | 'uploaded_by'
  | 'created_at'
  | 'storage_path'
> & { url: string | null };

export function useJobDocuments(jobId: string) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: jobKeys.part(shopId, jobId, 'documents'),
    staleTime: 30 * 60_000, // signed URLs last an hour
    queryFn: async (): Promise<JobDocument[]> => {
      const rows = unwrapList(
        await supabase
          .from('documents')
          .select(
            'id, file_name, content_type, size_bytes, customer_visible, uploaded_by, created_at, storage_path',
          )
          .eq('shop_id', shopId)
          .eq('job_id', jobId)
          .order('created_at', { ascending: false }),
      );
      const urls = new Map<string, string>();
      if (rows.length > 0) {
        const { data, error } = await supabase.storage.from('documents').createSignedUrls(
          rows.map((r) => r.storage_path),
          SIGNED_URL_SECONDS,
        );
        if (!error) {
          for (const item of data) {
            if (item.path && item.signedUrl) urls.set(item.path, item.signedUrl);
          }
        }
      }
      return rows.map((r) => ({ ...r, url: urls.get(r.storage_path) ?? null }));
    },
  });
}

function useInvalidateDocuments(jobId: string) {
  const queryClient = useQueryClient();
  const { shopId } = useShop();
  return () =>
    queryClient.invalidateQueries({ queryKey: jobKeys.part(shopId, jobId, 'documents') });
}

export function useUploadJobDocument(jobId: string) {
  const { shopId } = useShop();
  const invalidate = useInvalidateDocuments(jobId);
  return useMutation({
    mutationFn: async (file: File) => {
      const contentType = documentContentType(file);
      if (!contentType) {
        throw new AppError('This type of file can’t be uploaded.', { kind: 'validation' });
      }
      const path = jobDocumentPath(shopId, jobId, crypto.randomUUID(), file.name);
      const upload = await supabase.storage
        .from('documents')
        .upload(path, file, { contentType, upsert: false });
      if (upload.error) {
        throw new AppError(
          upload.error.message.toLowerCase().includes('row-level security')
            ? 'You don’t have permission to add files to this job.'
            : 'The upload failed. Check your connection and try again.',
          { kind: 'server', cause: upload.error },
        );
      }
      const { error } = await supabase.from('documents').insert({
        shop_id: shopId,
        job_id: jobId,
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

/** Managers+: show / hide a file on the customer's job report, booking page and portal. */
export function useSetDocumentVisible(jobId: string) {
  const { shopId } = useShop();
  const invalidate = useInvalidateDocuments(jobId);
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

export function useDeleteJobDocument(jobId: string) {
  const { shopId } = useShop();
  const invalidate = useInvalidateDocuments(jobId);
  return useMutation({
    mutationFn: async (id: string) => {
      const rows = unwrapList(
        await supabase.from('documents').delete().eq('shop_id', shopId).eq('id', id).select('id'),
      );
      if (rows.length === 0) {
        throw new AppError('You can only delete files you uploaded.', { kind: 'permission' });
      }
    },
    onSettled: invalidate,
  });
}
