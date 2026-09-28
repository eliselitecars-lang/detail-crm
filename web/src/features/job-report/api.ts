/**
 * Customer job report /r/<token> (P-8, P-30). public_get_job_report (0072)
 * returns the curated report (VOLATILE: it stamps the first view, so it is
 * called with POST, the supabase-js rpc default) — ids only, never storage
 * paths; the public-media function signs the photo / video / document URLs.
 * public_ack_inspection signs off the pre-service inspection remotely after
 * the drawn signature is uploaded under the report's signature folder.
 */
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { z } from 'zod';
import { Constants } from '@/lib/database.types';
import { unwrap } from '@/lib/db';
import { AppError, toAppError } from '@/lib/errors';
import { publicKey } from '@/lib/queryKeys';
import { supabase } from '@/lib/supabase';
import {
  parseDocument,
  zIntOrNull,
  zJobStatus,
  zText,
} from '@/features/public-docs/shared/schemas';
import { fetchReportMedia, MEDIA_REFRESH_MS, MEDIA_STALE_MS } from './media';

const Enums = Constants.public.Enums;

export const reportKeys = {
  report: (token: string) => publicKey('job-report', token),
  media: (token: string) => publicKey('job-report-media', token),
};

const markSchema = z.object({
  id: z.string(),
  view: z.enum(Enums.vehicle_view),
  x: z.number(),
  y: z.number(),
  damage: z.enum(Enums.damage_kind),
  note: zText,
  has_photo: z.boolean(),
});
export type ReportMark = z.output<typeof markSchema>;

const inspectionSchema = z.object({
  id: z.string(),
  kind: z.enum(Enums.inspection_kind),
  mileage: zIntOrNull,
  fuel_level: zIntOrNull,
  marks: z.array(markSchema),
  signed_at: zText,
  signed_by_name: zText,
  signed_remotely: z
    .boolean()
    .nullish()
    .transform((v) => v ?? false),
  can_acknowledge: z.boolean(),
});
export type ReportInspection = z.output<typeof inspectionSchema>;

const photoSchema = z.object({
  id: z.string(),
  kind: z.enum(Enums.job_photo_kind),
  caption: zText,
  media_type: z
    .string()
    .nullish()
    .transform((v): 'image' | 'video' => (v === 'video' ? 'video' : 'image')),
  duration_seconds: z
    .number()
    .nullish()
    .transform((v) => v ?? null),
  has_poster: z
    .boolean()
    .nullish()
    .transform((v) => v ?? false),
  created_at: z.string(),
});
export type ReportPhoto = z.output<typeof photoSchema>;

export const jobReportSchema = z.object({
  shop: z.object({
    name: z.string(),
    logo_path: zText,
    brand_color: zText,
    phone: zText,
    email: zText,
    review_url: zText,
  }),
  job: z.object({
    number: z.number().int(),
    status: zJobStatus,
    completed_at: zText,
    /** Shop-local date of the visit (completed, else scheduled, else created). */
    local_date: z.string(),
  }),
  vehicle: z
    .object({ year: zIntOrNull, make: zText, model: zText, color: zText })
    .nullish()
    .transform((v) => v ?? null),
  services: z.array(z.string()),
  message: zText,
  published_at: zText,
  photos: z.array(photoSchema),
  inspections: z.array(inspectionSchema),
  documents: z.array(
    z.object({
      id: z.string(),
      file_name: z.string(),
      content_type: zText,
      size_bytes: z
        .number()
        .int()
        .nullish()
        .transform((v) => v ?? null),
    }),
  ),
  /** '<shop>/reports/<token>/' while a pre-service inspection can be signed; else null. */
  signature_upload_prefix: zText,
});
export type JobReport = z.output<typeof jobReportSchema>;

function retryTransient(failureCount: number, error: unknown): boolean {
  const kind = toAppError(error).kind;
  return failureCount < 2 && (kind === 'network' || kind === 'server' || kind === 'unknown');
}

export function useJobReport(token: string) {
  return useQuery({
    queryKey: reportKeys.report(token),
    queryFn: async () =>
      parseDocument(
        jobReportSchema,
        unwrap(await supabase.rpc('public_get_job_report', { p_token: token })),
      ),
    retry: retryTransient,
    // Viewing stamps first_viewed_at once; refetching on focus is pointless.
    refetchOnWindowFocus: false,
    staleTime: 5 * 60_000,
  });
}

/** Signed URLs of the report's media, refreshed before the 10-minute expiry. */
export function useReportMedia(token: string, enabled: boolean) {
  return useQuery({
    queryKey: reportKeys.media(token),
    queryFn: () => fetchReportMedia(token),
    enabled,
    retry: retryTransient,
    staleTime: MEDIA_STALE_MS,
    refetchInterval: MEDIA_REFRESH_MS,
  });
}

/** `<prefix>signature-<uuid>.png`: exactly <shop>/reports/<token>/<file> (4 segments). */
export function reportSignaturePath(prefix: string): string {
  const folder = prefix.endsWith('/') ? prefix : `${prefix}/`;
  return `${folder}signature-${crypto.randomUUID()}.png`;
}

export interface AckInput {
  inspectionId: string;
  signerName: string;
  signature: Blob;
  uploadPrefix: string | null;
}

export function useAcknowledgeInspection(token: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async ({ inspectionId, signerName, signature, uploadPrefix }: AckInput) => {
      if (!uploadPrefix) {
        throw new AppError('This inspection can no longer be signed here.', { kind: 'validation' });
      }
      const path = reportSignaturePath(uploadPrefix);
      const upload = await supabase.storage.from('signatures').upload(path, signature, {
        contentType: 'image/png',
        upsert: false,
        cacheControl: '3600',
      });
      if (upload.error) {
        throw new AppError(
          'Your signature could not be saved. Check your connection and try again.',
          { kind: 'server', cause: upload.error },
        );
      }
      return parseDocument(
        jobReportSchema,
        unwrap(
          await supabase.rpc('public_ack_inspection', {
            p_token: token,
            p_inspection_id: inspectionId,
            p_signer_name: signerName,
            p_signature_path: path,
          }),
        ),
      );
    },
    onSuccess: (report) => queryClient.setQueryData(reportKeys.report(token), report),
    onError: () => void queryClient.invalidateQueries({ queryKey: reportKeys.report(token) }),
  });
}
