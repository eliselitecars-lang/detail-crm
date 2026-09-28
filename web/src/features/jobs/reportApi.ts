/**
 * Customer-facing job report (P-8, 0072). The report link (/r/<token>) is
 * its own credential: readable by managers, and by technicians on the job
 * when the shop lets them share reports. publish_job_report creates or
 * updates the job's one live report (same token) and can text / email the
 * link; revoke_job_report (managers+) kills the link.
 */
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { z } from 'zod';
import { unwrap, type Row } from '@/lib/db';
import { supabase } from '@/lib/supabase';
import { useShop } from '@/features/shop/shopContext';
import { jobKeys } from './api';
import type { JobPhotoKind } from './model';

export type JobReport = Pick<
  Row<'job_reports'>,
  | 'id'
  | 'token'
  | 'include_inspections'
  | 'photo_kinds'
  | 'message'
  | 'published_at'
  | 'first_viewed_at'
>;

/** The public page of a report token. */
export function reportLink(origin: string, token: string): string {
  return `${origin.replace(/\/$/, '')}/r/${token}`;
}

export function useJobReport(jobId: string, enabled: boolean) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: jobKeys.part(shopId, jobId, 'report'),
    enabled,
    queryFn: async (): Promise<JobReport | null> =>
      unwrap(
        await supabase
          .from('job_reports')
          .select(
            'id, token, include_inspections, photo_kinds, message, published_at, first_viewed_at',
          )
          .eq('shop_id', shopId)
          .eq('job_id', jobId)
          .is('revoked_at', null)
          .maybeSingle(),
      ),
  });
}

const publishResultSchema = z.object({
  report_id: z.string(),
  token: z.string(),
  url: z.string().nullable(),
  queued: z.boolean(),
});

export type PublishResult = z.infer<typeof publishResultSchema>;

export interface PublishInput {
  includeInspections: boolean;
  photoKinds: JobPhotoKind[];
  message: string;
  /** null = don't send (copy the link); 'both' = text and email. */
  send: 'sms' | 'email' | 'both' | null;
}

export function usePublishJobReport(jobId: string) {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (input: PublishInput): Promise<PublishResult> => {
      const message = input.message.trim();
      return publishResultSchema.parse(
        unwrap(
          await supabase.rpc('publish_job_report', {
            p_job_id: jobId,
            p_include_inspections: input.includeInspections,
            p_photo_kinds: input.photoKinds,
            ...(message ? { p_message: message } : {}),
            p_send: input.send !== null,
            ...(input.send === 'sms' || input.send === 'email' ? { p_channel: input.send } : {}),
          }),
        ),
      );
    },
    onSettled: () =>
      Promise.all([
        queryClient.invalidateQueries({ queryKey: jobKeys.part(shopId, jobId, 'report') }),
        queryClient.invalidateQueries({ queryKey: jobKeys.part(shopId, jobId, 'messages') }),
      ]),
  });
}

export function useRevokeJobReport(jobId: string) {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (reportId: string) => {
      unwrap(await supabase.rpc('revoke_job_report', { p_report_id: reportId }));
    },
    onSettled: () =>
      queryClient.invalidateQueries({ queryKey: jobKeys.part(shopId, jobId, 'report') }),
  });
}
