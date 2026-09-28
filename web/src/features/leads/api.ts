/**
 * Lead-capture forms (P-9): public /lead/<token>. public_get_lead_form reads
 * the form (0088; unknown / inactive / archived: PT404) and
 * public_submit_lead creates or matches the contact server-side (limits:
 * PT429; a filled-in honeypot is answered as a success and writes nothing).
 * The page never sees who else is in the shop's records.
 */
import { useMutation, useQuery } from '@tanstack/react-query';
import { z } from 'zod';
import { unwrap } from '@/lib/db';
import { toAppError } from '@/lib/errors';
import { publicKey } from '@/lib/queryKeys';
import { supabase } from '@/lib/supabase';
import { parseDocument, zText } from '@/features/public-docs/shared/schemas';
import type { LeadPayload } from './model';

export const leadKeys = {
  form: (token: string) => publicKey('lead-form', token),
};

const fieldSchema = z.object({
  key: z.string(),
  label: z.string(),
  type: z.enum(['text', 'textarea', 'number', 'select', 'multiselect', 'checkbox', 'date']),
  options: z
    .array(z.string())
    .nullish()
    .transform((v) => v ?? []),
  help_text: zText,
  required: z.boolean(),
});
export type LeadField = z.output<typeof fieldSchema>;

export const leadFormSchema = z.object({
  shop: z.object({ name: z.string(), logo_path: zText, brand_color: zText }),
  form: z.object({
    name: z.string(),
    headline: zText,
    intro: zText,
    ask_vehicle: z.boolean(),
    ask_message: z.boolean(),
    success_message: zText,
  }),
  fields: z.array(fieldSchema),
});
export type LeadForm = z.output<typeof leadFormSchema>;

function retryTransient(failureCount: number, error: unknown): boolean {
  const kind = toAppError(error).kind;
  return failureCount < 2 && (kind === 'network' || kind === 'server' || kind === 'unknown');
}

export function useLeadForm(token: string) {
  return useQuery({
    queryKey: leadKeys.form(token),
    queryFn: async () =>
      parseDocument(
        leadFormSchema,
        unwrap(await supabase.rpc('public_get_lead_form', { p_token: token })),
      ),
    retry: retryTransient,
    staleTime: 5 * 60_000,
  });
}

const submitResultSchema = z.object({ ok: z.boolean(), message: z.string() });

export function useSubmitLead(token: string) {
  return useMutation({
    mutationFn: async (payload: LeadPayload) =>
      parseDocument(
        submitResultSchema,
        unwrap(
          await supabase.rpc('public_submit_lead', {
            p_token: token,
            p_payload: payload,
          }),
        ),
      ),
  });
}
