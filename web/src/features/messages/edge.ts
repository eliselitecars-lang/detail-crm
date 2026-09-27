/**
 * `messaging` edge function — `send` action (supabase/functions/messaging/
 * send.ts): staff send a free-form or templated SMS/email to a customer.
 * The function checks the caller's role for `shop_id`, queues the row
 * (queue_message / enqueue_template_message / customer-level template —
 * rendering happens server-side) and delivers it immediately. The client
 * never renders templates or chooses the recipient address.
 *
 * Body (strict): { action: 'send', shop_id, customer_id?, job_id?, channel,
 *                  template_key? | body (+ subject for email), request_nonce? }
 * Response: { message_id, channel, status, error }
 * Refusals: 422 `unprocessable` with a human message and `details.reason`
 * (opted_out, no_address, sms_not_configured, template_disabled,
 * job_required + details.variables, missing_link + details.variables,
 * no_marketing_consent, appointment_closed…) — thrown as EdgeFunctionError.
 * `request_nonce` (one per compose, reused on retry) makes a replay return
 * the first message instead of sending again (messages.request_nonce).
 */
import { z } from 'zod';
import { Constants } from '@/lib/database.types';
import { invokeEdge } from '@/features/quotes/shared/edge';
import type { MessageChannel, MessageTemplateKey } from './model';

export type SendContent =
  | { kind: 'text'; subject: string | null; body: string }
  | { kind: 'template'; templateKey: MessageTemplateKey };

export interface SendMessageInput {
  shopId: string;
  customerId: string;
  channel: MessageChannel;
  jobId: string | null;
  content: SendContent;
  /** One per compose, reused on retry (8–64 of A-Z a-z 0-9 _ -). */
  requestNonce?: string;
}

/** The JSON body for `messaging` → `send` (only fields the strict schema accepts). */
export function sendMessageBody(input: SendMessageInput): Record<string, string> {
  const body: Record<string, string> = {
    action: 'send',
    shop_id: input.shopId,
    customer_id: input.customerId,
    channel: input.channel,
  };
  if (input.jobId) body.job_id = input.jobId;
  if (input.content.kind === 'template') {
    body.template_key = input.content.templateKey;
  } else {
    body.body = input.content.body;
    if (input.channel === 'email' && input.content.subject) body.subject = input.content.subject;
  }
  if (input.requestNonce) body.request_nonce = input.requestNonce;
  return body;
}

export const sendResultSchema = z.object({
  message_id: z.string(),
  channel: z.enum(Constants.public.Enums.message_channel),
  /** After the immediate delivery attempt: sent, failed, queued (retry scheduled), sending, cancelled. */
  status: z.enum(Constants.public.Enums.message_status),
  error: z.string().nullable(),
});

export type SendMessageResult = z.infer<typeof sendResultSchema>;

/** Throws EdgeFunctionError (with `reason` / `details`) when the server refuses. */
export async function sendMessage(input: SendMessageInput): Promise<SendMessageResult> {
  const { action, ...params } = sendMessageBody(input);
  return invokeEdge('messaging', action ?? 'send', params, sendResultSchema);
}
