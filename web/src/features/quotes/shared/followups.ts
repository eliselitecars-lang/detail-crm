/**
 * Automatic document follow-ups (P-3): reminders for an unanswered quote,
 * an unpaid deposit and an unpaid / past-due invoice. The schedule, the
 * attempts and what is due next are the server's (document_followup_status,
 * 0085); staff can only pause or resume them per document
 * (set_document_followups_paused). Shop-wide switches live in Settings →
 * Follow-ups.
 */
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { z } from 'zod';
import { unwrap } from '@/lib/db';
import { shopKey } from '@/lib/queryKeys';
import { supabase } from '@/lib/supabase';
import { useShop } from '@/features/shop/shopContext';

export type FollowupKind = 'quote' | 'deposit' | 'invoice';

export const followupStatusSchema = z.object({
  kind: z.enum(['quote', 'deposit', 'invoice']),
  stage: z.enum(['quote', 'deposit', 'invoice', 'invoice_overdue']),
  enabled: z.boolean(),
  paused: z.boolean(),
  attempts_sent: z.number().int(),
  max_attempts: z.number().int(),
  last_sent_at: z.string().nullable(),
  next_at: z.string().nullable(),
});
export type FollowupStatus = z.infer<typeof followupStatusSchema>;

/**
 * Every follow-up status of the shop lives under this key, so a change of the
 * shop's follow-up settings can refresh them all at once.
 */
export const followupKeys = {
  all: (shopId: string) => shopKey(shopId, 'followups'),
  status: (shopId: string, kind: FollowupKind, id: string) =>
    [...followupKeys.all(shopId), kind, id] as const,
};

/** A missing / non-object answer means "nothing to show" (older server, no row). */
function parseStatus(data: unknown): FollowupStatus | null {
  if (data === null || data === undefined) return null;
  return followupStatusSchema.parse(data);
}

export function useFollowupStatus(kind: FollowupKind, id: string, enabled = true) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: followupKeys.status(shopId, kind, id),
    enabled,
    queryFn: async () =>
      parseStatus(
        unwrap(await supabase.rpc('document_followup_status', { p_kind: kind, p_id: id })),
      ),
  });
}

export function useSetFollowupsPaused(kind: FollowupKind, id: string) {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (paused: boolean) =>
      parseStatus(
        unwrap(
          await supabase.rpc('set_document_followups_paused', {
            p_kind: kind,
            p_id: id,
            p_paused: paused,
          }),
        ),
      ),
    onSuccess: (status) => {
      if (status) queryClient.setQueryData(followupKeys.status(shopId, kind, id), status);
    },
    onSettled: () =>
      queryClient.invalidateQueries({ queryKey: followupKeys.status(shopId, kind, id) }),
  });
}

const STAGE_LABELS: Record<FollowupStatus['stage'], string> = {
  quote: 'Quote reminders',
  deposit: 'Deposit reminders',
  invoice: 'Payment reminders',
  invoice_overdue: 'Past-due notices',
};

export function followupStageLabel(stage: FollowupStatus['stage']): string {
  return STAGE_LABELS[stage];
}

/** "1 of 2 sent" / "None sent yet" / "3 of 3 sent". */
export function followupAttemptsText(
  status: Pick<FollowupStatus, 'attempts_sent' | 'max_attempts'>,
) {
  if (status.max_attempts <= 0)
    return status.attempts_sent > 0 ? `${status.attempts_sent} sent` : null;
  if (status.attempts_sent === 0) return 'None sent yet';
  return `${Math.min(status.attempts_sent, status.max_attempts)} of ${status.max_attempts} sent`;
}
