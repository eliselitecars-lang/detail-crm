/**
 * `invites` edge function (supabase/functions/invites): admin+ create an
 * invite (invite_member as the caller, then the /invite/<token> link is
 * emailed) or re-send a pending one (an expired invite is re-issued with a
 * new token). A failed email does not undo the invite: the response says
 * `email_sent: false` and carries `invite_url` to share another way.
 */
import { z } from 'zod';
import { edgeFunctionError } from '@/lib/errors';
import { supabase } from '@/lib/supabase';
import type { ShopRole } from '@/features/shop/permissions';

export interface SendInviteInput {
  shopId: string;
  email: string;
  role: Exclude<ShopRole, 'owner'>;
}

export function sendInviteBody(input: SendInviteInput) {
  return { action: 'send_invite', shop_id: input.shopId, email: input.email, role: input.role };
}

export function resendInviteBody(inviteId: string) {
  return { action: 'resend_invite', invite_id: inviteId };
}

export const inviteResultSchema = z.object({
  invite: z.object({ id: z.string(), email: z.string(), expires_at: z.string() }).loose(),
  invite_url: z.string(),
  email_sent: z.boolean(),
  reissued: z.boolean().optional(),
});
export type InviteResult = z.infer<typeof inviteResultSchema>;

async function invoke(body: Record<string, string>): Promise<InviteResult> {
  const result = await supabase.functions.invoke('invites', { body });
  if (result.error) throw await edgeFunctionError(result.error);
  const data: unknown = result.data;
  return inviteResultSchema.parse(data);
}

export function sendInvite(input: SendInviteInput): Promise<InviteResult> {
  return invoke(sendInviteBody(input));
}

export function resendInvite(inviteId: string): Promise<InviteResult> {
  return invoke(resendInviteBody(inviteId));
}

/**
 * `billing` sync_customer, right after a successful ownership transfer (the
 * former owner is an admin by then): the shop's platform billing customer —
 * receipts, renewal notices and failed-payment emails — is readdressed to
 * the new owner. Best effort: the transfer has already happened, and the
 * daily sync_customers run readdresses the customer if this call fails.
 * True when the customer was updated.
 */
export async function syncBillingCustomer(shopId: string): Promise<boolean> {
  try {
    const result = await supabase.functions.invoke('billing', {
      body: { action: 'sync_customer', shop_id: shopId },
    });
    if (result.error) return false;
    const parsed = z.object({ synced: z.boolean() }).safeParse(result.data);
    return parsed.success && parsed.data.synced;
  } catch {
    return false;
  }
}
