/**
 * Team (SPEC §3/§4.1): directory via shop_team (managers+ get contact
 * details), role/active changes on shop_members (owner/admin; the
 * shop_members_client_guard trigger enforces the matrix), pay rates in
 * member_compensation (owner/admin), invites (invites edge function +
 * revoke_invite), and owner-only transfer_ownership.
 */
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { z } from 'zod';
import { useToast } from '@/components/ui';
import { unwrap } from '@/lib/db';
import { AppError } from '@/lib/errors';
import { shopKey } from '@/lib/queryKeys';
import { supabase } from '@/lib/supabase';
import { useCan } from '@/features/shop/useCan';
import { useShop, useShopContext } from '@/features/shop/shopContext';
import type { ShopRole } from '@/features/shop/permissions';
import { resendInvite, sendInvite, type SendInviteInput } from './edge';
import { announceInvite } from './inviteNotice';
import { teamMemberSchema, type Compensation, type PendingInvite } from './model';

export const teamKeys = {
  all: (shopId: string) => shopKey(shopId, 'team'),
  members: (shopId: string) => [...teamKeys.all(shopId), 'members'] as const,
  compensation: (shopId: string) => [...teamKeys.all(shopId), 'compensation'] as const,
  invites: (shopId: string) => [...teamKeys.all(shopId), 'invites'] as const,
};

export function useTeam() {
  const { shopId } = useShop();
  return useQuery({
    queryKey: teamKeys.members(shopId),
    queryFn: async () =>
      z
        .array(teamMemberSchema)
        .parse(unwrap(await supabase.rpc('shop_team', { p_shop_id: shopId })) ?? []),
  });
}

export function useCompensation() {
  const { shopId } = useShop();
  const allowed = useCan('compensation.view');
  return useQuery({
    queryKey: teamKeys.compensation(shopId),
    enabled: allowed,
    queryFn: async (): Promise<Map<string, Compensation>> => {
      const result = await supabase
        .from('member_compensation')
        .select('member_id, hourly_rate_cents, commission_bps')
        .eq('shop_id', shopId);
      return new Map((unwrap(result) ?? []).map((row) => [row.member_id, row]));
    },
  });
}

export function usePendingInvites() {
  const { shopId } = useShop();
  const allowed = useCan('team.manage');
  return useQuery({
    queryKey: teamKeys.invites(shopId),
    enabled: allowed,
    queryFn: async (): Promise<PendingInvite[]> => {
      const result = await supabase
        .from('shop_invites')
        .select('id, email, role, token, expires_at, created_at')
        .eq('shop_id', shopId)
        .is('accepted_at', null)
        .is('revoked_at', null)
        .order('created_at', { ascending: false });
      return unwrap(result) ?? [];
    },
  });
}

export interface MemberPatch {
  role?: ShopRole;
  active?: boolean;
  display_name?: string;
  calendar_color?: string | null;
}

export function useUpdateMember() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async ({ memberId, patch }: { memberId: string; patch: MemberPatch }) => {
      const result = await supabase
        .from('shop_members')
        .update(patch)
        .eq('shop_id', shopId)
        .eq('id', memberId)
        .select('id');
      const rows = unwrap(result) ?? [];
      if (rows.length === 0)
        throw new AppError('That team member could not be updated.', { kind: 'not_found' });
    },
    onSettled: () => queryClient.invalidateQueries({ queryKey: teamKeys.all(shopId) }),
  });
}

export function useSaveCompensation() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  const toast = useToast();
  return useMutation({
    mutationFn: async (values: Compensation) => {
      unwrap(
        await supabase
          .from('member_compensation')
          .upsert({ ...values, shop_id: shopId }, { onConflict: 'member_id' }),
      );
    },
    onSuccess: () => toast.success('Pay saved'),
    onSettled: () => queryClient.invalidateQueries({ queryKey: teamKeys.compensation(shopId) }),
  });
}

export function useSendInvite() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (input: Omit<SendInviteInput, 'shopId'>) => sendInvite({ ...input, shopId }),
    onSettled: () => queryClient.invalidateQueries({ queryKey: teamKeys.invites(shopId) }),
  });
}

export function useResendInvite() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  const toast = useToast();
  return useMutation({
    mutationFn: (inviteId: string) => resendInvite(inviteId),
    onSuccess: (result) => announceInvite(toast, result, true),
    onError: (error) => toast.error(error),
    onSettled: () => queryClient.invalidateQueries({ queryKey: teamKeys.invites(shopId) }),
  });
}

export function useRevokeInvite() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (inviteId: string) => {
      unwrap(await supabase.rpc('revoke_invite', { p_invite_id: inviteId }));
    },
    onSettled: () => queryClient.invalidateQueries({ queryKey: teamKeys.invites(shopId) }),
  });
}

/** Owner only. The caller becomes an admin, so the shop context is reloaded. */
export function useTransferOwnership() {
  const { shopId } = useShop();
  const { refetch } = useShopContext();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (memberId: string) => {
      unwrap(
        await supabase.rpc('transfer_ownership', { p_shop_id: shopId, p_member_id: memberId }),
      );
    },
    onSuccess: async () => {
      await refetch();
    },
    onSettled: () => queryClient.invalidateQueries({ queryKey: teamKeys.all(shopId) }),
  });
}
