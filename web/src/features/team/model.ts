/**
 * Team — pure rules and shapes (unit-tested). Role/deactivation rules come
 * from permissions.ts (the web copy of SPEC §3); the server enforces them too.
 */
import { z } from 'zod';
import { formatBps, formatCents } from '@/lib/money';
import { zCents, zPercentBps } from '@/lib/validation';
import {
  canChangeMemberRole,
  canDeactivateMember,
  ROLE_RANK,
  SHOP_ROLES,
  type ShopRole,
} from '@/features/shop/permissions';

export const teamMemberSchema = z.object({
  member_id: z.string(),
  user_id: z.string(),
  role: z.enum(SHOP_ROLES),
  display_name: z.string(),
  calendar_color: z.string().nullable(),
  active: z.boolean(),
  phone: z.string().nullable(),
  email: z.string().nullable(),
});
export type TeamMember = z.infer<typeof teamMemberSchema>;

export interface MemberTarget {
  role: ShopRole;
  isSelf: boolean;
}

export function targetOf(member: TeamMember, currentUserId: string | undefined): MemberTarget {
  return { role: member.role, isSelf: member.user_id === currentUserId };
}

/** Roles `actor` may move `target` to (empty = cannot change this member's role). */
export function assignableRoles(actor: ShopRole, target: MemberTarget): ShopRole[] {
  return SHOP_ROLES.filter((role) => canChangeMemberRole(actor, target, role));
}

export function canEditMember(actor: ShopRole, target: MemberTarget): boolean {
  if (actor !== 'owner' && actor !== 'admin') return false;
  if (target.isSelf) return true; // own name/colour
  return target.role !== 'owner';
}

export { canDeactivateMember };

/** Active first, then by role (owner → technician), then name. */
export function sortMembers(members: readonly TeamMember[]): TeamMember[] {
  return [...members].sort(
    (a, b) =>
      Number(b.active) - Number(a.active) ||
      ROLE_RANK[b.role] - ROLE_RANK[a.role] ||
      a.display_name.localeCompare(b.display_name),
  );
}

export const ROLE_DESCRIPTIONS: Record<ShopRole, string> = {
  owner: 'Everything, including deleting or transferring the shop.',
  admin: 'Everything except deleting or transferring the shop.',
  manager: 'Schedule, customers, money and messages. No settings or pay rates.',
  technician: 'Assigned jobs, their own time clock and hours.',
};

export interface Compensation {
  member_id: string;
  hourly_rate_cents: number;
  commission_bps: number;
  /** Commission on jobs they sold (jobs.sold_by_member_id), P-12. */
  sales_commission_bps: number;
}

export function formatCompensation(
  comp:
    | (Pick<Compensation, 'hourly_rate_cents' | 'commission_bps'> &
        Partial<Pick<Compensation, 'sales_commission_bps'>>)
    | undefined,
  currency: string,
): string {
  const sales = comp?.sales_commission_bps ?? 0;
  if (!comp || (comp.hourly_rate_cents === 0 && comp.commission_bps === 0 && sales === 0))
    return 'Not set';
  const parts: string[] = [];
  if (comp.hourly_rate_cents > 0)
    parts.push(`${formatCents(comp.hourly_rate_cents, { currency })}/hr`);
  if (comp.commission_bps > 0) parts.push(`${formatBps(comp.commission_bps)} commission`);
  if (sales > 0) parts.push(`${formatBps(sales)} on sales`);
  return parts.join(' · ');
}

export const compensationFormSchema = z.object({
  hourlyRateCents: zCents.max(100_000_00, 'That rate looks too high.'),
  commission: zPercentBps(100),
  salesCommission: zPercentBps(100),
});
export type CompensationFormInput = z.input<typeof compensationFormSchema>;
export type CompensationFormOutput = z.output<typeof compensationFormSchema>;

const HEX = /^#[0-9a-fA-F]{6}$/;
export const memberDetailsSchema = z.object({
  displayName: z
    .string()
    .trim()
    .min(1, 'Name is required.')
    .max(100, 'Keep the name under 100 characters.'),
  calendarColor: z
    .string()
    .trim()
    .refine((v) => v === '' || HEX.test(v), 'Use a colour like #1F6FEB.'),
});
export type MemberDetailsInput = z.input<typeof memberDetailsSchema>;

export interface PendingInvite {
  id: string;
  email: string;
  role: ShopRole;
  token: string;
  expires_at: string;
  created_at: string;
}

export function isInviteExpired(invite: Pick<PendingInvite, 'expires_at'>, now: Date): boolean {
  return new Date(invite.expires_at).getTime() <= now.getTime();
}
