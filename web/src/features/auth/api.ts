import { z } from 'zod';
import { toAppError } from '@/lib/errors';
import { supabase } from '@/lib/supabase';
import { SHOP_ROLES } from '@/features/shop/permissions';
import { absoluteUrl } from './redirects';

export async function signInWithPassword(email: string, password: string): Promise<void> {
  const { error } = await supabase.auth.signInWithPassword({ email, password });
  if (error) throw toAppError(error);
}

export interface SignUpResult {
  /** False when email confirmation is required before a session exists. */
  signedIn: boolean;
}

export async function signUp(input: {
  email: string;
  password: string;
  fullName: string;
  next: string;
}): Promise<SignUpResult> {
  const { data, error } = await supabase.auth.signUp({
    email: input.email,
    password: input.password,
    options: {
      data: { full_name: input.fullName },
      emailRedirectTo: absoluteUrl(input.next),
    },
  });
  if (error) throw toAppError(error);
  return { signedIn: data.session !== null };
}

export async function sendPasswordReset(email: string): Promise<void> {
  const { error } = await supabase.auth.resetPasswordForEmail(email, {
    redirectTo: absoluteUrl('/reset-password'),
  });
  if (error) throw toAppError(error);
}

export async function updatePassword(password: string): Promise<void> {
  const { error } = await supabase.auth.updateUser({ password });
  if (error) throw toAppError(error);
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** Invite tokens are uuids; anything else is rejected before hitting the API. */
export function isInviteToken(token: string | undefined): token is string {
  return typeof token === 'string' && UUID_RE.test(token);
}

export const inviteSchema = z.object({
  shop_name: z.string(),
  shop_slug: z.string(),
  role: z.enum(SHOP_ROLES),
  email: z.string(),
  expires_at: z.string(),
  status: z.enum(['pending', 'accepted', 'revoked', 'expired']),
});

export type InvitePreview = z.infer<typeof inviteSchema>;

/** public_get_invite(p_token) — shop name/role/email/status for the landing page. */
export async function getInvite(token: string): Promise<InvitePreview | null> {
  const { data, error } = await supabase.rpc('public_get_invite', { p_token: token });
  if (error) throw toAppError(error);
  const rows = z.array(inviteSchema).parse(Array.isArray(data) ? data : data ? [data] : []);
  return rows[0] ?? null;
}

/**
 * accept_invite(p_token) links the signed-in, email-confirmed user to the
 * invite's shop with the invited role; returns the new membership's shop id.
 */
export async function acceptInvite(token: string): Promise<string> {
  const { data, error } = await supabase.rpc('accept_invite', { p_token: token });
  if (error) throw toAppError(error);
  return z.object({ shop_id: z.string() }).parse(data).shop_id;
}
