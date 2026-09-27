import { describe, expect, it } from 'vitest';
import {
  assignableRoles,
  canDeactivateMember,
  canEditMember,
  compensationFormSchema,
  formatCompensation,
  isInviteExpired,
  memberDetailsSchema,
  sortMembers,
  targetOf,
  type TeamMember,
} from './model';

const member = (over: Partial<TeamMember>): TeamMember => ({
  member_id: 'm',
  user_id: 'u',
  role: 'technician',
  display_name: 'Tech',
  calendar_color: null,
  active: true,
  phone: null,
  email: null,
  ...over,
});

describe('role rules (from permissions.canChangeMemberRole)', () => {
  it('owner may move anyone else between non-owner roles', () => {
    expect(assignableRoles('owner', { role: 'technician', isSelf: false })).toEqual([
      'admin',
      'manager',
    ]);
    expect(assignableRoles('owner', { role: 'admin', isSelf: false })).toEqual([
      'manager',
      'technician',
    ]);
    expect(assignableRoles('owner', { role: 'owner', isSelf: true })).toEqual([]);
  });

  it('admin cannot touch the owner, themselves, or grant owner', () => {
    expect(assignableRoles('admin', { role: 'owner', isSelf: false })).toEqual([]);
    expect(assignableRoles('admin', { role: 'admin', isSelf: true })).toEqual([]);
    expect(assignableRoles('admin', { role: 'manager', isSelf: false })).toEqual([
      'admin',
      'technician',
    ]);
  });

  it('managers and technicians change nobody', () => {
    expect(assignableRoles('manager', { role: 'technician', isSelf: false })).toEqual([]);
    expect(assignableRoles('technician', { role: 'technician', isSelf: false })).toEqual([]);
  });

  it('edit and deactivate rules', () => {
    expect(canEditMember('admin', { role: 'owner', isSelf: false })).toBe(false);
    expect(canEditMember('admin', { role: 'admin', isSelf: true })).toBe(true);
    expect(canEditMember('manager', { role: 'technician', isSelf: false })).toBe(false);
    expect(canDeactivateMember('owner', { role: 'admin', isSelf: false })).toBe(true);
    expect(canDeactivateMember('admin', { role: 'owner', isSelf: false })).toBe(false);
    expect(canDeactivateMember('owner', { role: 'owner', isSelf: true })).toBe(false);
  });

  it('knows who "self" is', () => {
    expect(targetOf(member({ user_id: 'me' }), 'me')).toEqual({ role: 'technician', isSelf: true });
    expect(targetOf(member({ user_id: 'x' }), 'me').isSelf).toBe(false);
  });
});

describe('sortMembers', () => {
  it('active first, then by rank, then name', () => {
    const sorted = sortMembers([
      member({ member_id: '1', display_name: 'Zed', role: 'technician' }),
      member({ member_id: '2', display_name: 'Amy', role: 'technician', active: false }),
      member({ member_id: '3', display_name: 'Bob', role: 'owner' }),
      member({ member_id: '4', display_name: 'Abe', role: 'technician' }),
    ]);
    expect(sorted.map((m) => m.member_id)).toEqual(['3', '4', '1', '2']);
  });
});

describe('compensation', () => {
  it('formats pay from cents and basis points', () => {
    expect(formatCompensation(undefined, 'usd')).toBe('Not set');
    expect(formatCompensation({ hourly_rate_cents: 2250, commission_bps: 0 }, 'usd')).toBe(
      '$22.50/hr',
    );
    expect(formatCompensation({ hourly_rate_cents: 0, commission_bps: 1050 }, 'usd')).toBe(
      '10.5% commission',
    );
  });

  it('parses the form to integer cents and bps', () => {
    expect(compensationFormSchema.parse({ hourlyRateCents: 2500, commission: '12.5' })).toEqual({
      hourlyRateCents: 2500,
      commission: 1250,
    });
    expect(
      compensationFormSchema.safeParse({ hourlyRateCents: 2500, commission: '120' }).success,
    ).toBe(false);
    expect(
      compensationFormSchema.safeParse({ hourlyRateCents: 12.5, commission: '0' }).success,
    ).toBe(false);
  });

  it('validates member details', () => {
    expect(memberDetailsSchema.safeParse({ displayName: ' ', calendarColor: '' }).success).toBe(
      false,
    );
    expect(memberDetailsSchema.safeParse({ displayName: 'A', calendarColor: 'red' }).success).toBe(
      false,
    );
    expect(
      memberDetailsSchema.safeParse({ displayName: 'A', calendarColor: '#1f6feb' }).success,
    ).toBe(true);
  });

  it('detects expired invites', () => {
    const now = new Date('2026-03-10T00:00:00Z');
    expect(isInviteExpired({ expires_at: '2026-03-09T23:59:59Z' }, now)).toBe(true);
    expect(isInviteExpired({ expires_at: '2026-03-11T00:00:00Z' }, now)).toBe(false);
  });
});
