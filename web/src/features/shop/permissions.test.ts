import { describe, expect, it } from 'vitest';
import {
  can,
  canChangeMemberRole,
  canDeactivateMember,
  CAPABILITIES,
  invitableRoles,
  permissionContextOf,
  SHOP_ROLES,
  type Capability,
  type ShopRole,
} from './permissions';

const ctx = (role: ShopRole, techsCanCollectPayments = false) => ({
  role,
  techsCanCollectPayments,
});

/** Expected matrix (SPEC §3), one row per capability: [owner, admin, manager, technician]. */
const MATRIX: Record<Capability, [boolean, boolean, boolean, boolean]> = {
  'settings.view': [true, true, true, false],
  'settings.manage': [true, true, false, false],
  'shop.viewBasic': [true, true, true, true],
  'shop.connectStripe': [true, true, false, false],
  'shop.manageSmsNumber': [true, true, false, false],
  'shop.delete': [true, false, false, false],
  'shop.transfer': [true, false, false, false],
  'team.view': [true, true, true, false],
  'team.viewNames': [true, true, true, true],
  'team.manage': [true, true, false, false],
  'compensation.view': [true, true, false, false],
  'compensation.manage': [true, true, false, false],
  'compensation.viewOwn': [true, true, true, true],
  'customers.view': [true, true, true, false],
  'customers.viewAssigned': [true, true, true, true],
  'customers.manage': [true, true, true, false],
  'customers.merge': [true, true, false, false],
  'import.run': [true, true, true, false],
  'catalog.view': [true, true, true, true],
  'catalog.manage': [true, true, true, false],
  'calendar.view': [true, true, true, true],
  'jobs.view': [true, true, true, false],
  'jobs.viewAssigned': [true, true, true, true],
  'jobs.manage': [true, true, true, false],
  'jobs.progress': [true, true, true, true],
  'jobs.moveStatusBackward': [true, true, true, false],
  'jobs.shareReport': [true, true, true, false],
  'blockedTimes.manage': [true, true, true, false],
  'calendarFeed.own': [true, true, true, true],
  'quotes.view': [true, true, true, false],
  'quotes.manage': [true, true, true, false],
  'invoices.view': [true, true, true, false],
  'invoices.manage': [true, true, true, false],
  'invoices.viewAssigned': [true, true, true, false],
  'payments.view': [true, true, true, false],
  'payments.collect': [true, true, true, false],
  'payments.refund': [true, true, false, false],
  'invoices.void': [true, true, false, false],
  'memberships.view': [true, true, true, false],
  'memberships.manage': [true, true, true, false],
  'cards.view': [true, true, true, false],
  'cards.charge': [true, true, true, false],
  'giftCards.view': [true, true, true, false],
  'giftCards.manage': [true, true, true, false],
  'giftCards.adjust': [true, true, false, false],
  'reports.view': [true, true, true, false],
  'reports.viewOwn': [true, true, true, true],
  'messages.inbox': [true, true, true, false],
  'messages.sendJobUpdates': [true, true, true, true],
  'campaigns.manage': [true, true, true, false],
  'webhooks.manage': [true, true, false, false],
  'tasks.own': [true, true, true, true],
  'tasks.manage': [true, true, true, false],
  'inventory.view': [true, true, true, false],
  'inventory.manage': [true, true, true, false],
  'timeclock.own': [true, true, true, true],
  'timeclock.viewAll': [true, true, true, false],
  'timeclock.editAll': [true, true, true, false],
  'notifications.view': [true, true, true, true],
  'billing.view': [true, true, true, false],
  'billing.manage': [true, false, false, false],
};

describe('capability matrix (SPEC §3)', () => {
  it('covers every capability', () => {
    expect(Object.keys(MATRIX).sort()).toEqual(Object.keys(CAPABILITIES).sort());
  });

  for (const [capability, expected] of Object.entries(MATRIX) as [Capability, boolean[]][]) {
    it(capability, () => {
      expect(SHOP_ROLES.map((role) => can(ctx(role), capability))).toEqual(expected);
    });
  }

  it('lets technicians collect payments / see assigned invoices only when the shop allows it', () => {
    expect(can(ctx('technician', false), 'payments.collect')).toBe(false);
    expect(can(ctx('technician', true), 'payments.collect')).toBe(true);
    expect(can(ctx('technician', true), 'invoices.viewAssigned')).toBe(true);
    // …but never the full lists, refunds or saved cards
    expect(can(ctx('technician', true), 'payments.view')).toBe(false);
    expect(can(ctx('technician', true), 'payments.refund')).toBe(false);
    expect(can(ctx('technician', true), 'cards.charge')).toBe(false);
  });

  it('lets technicians share job reports only when the shop allows it', () => {
    expect(can(ctx('technician'), 'jobs.shareReport')).toBe(false);
    expect(can({ ...ctx('technician'), techsCanShareReports: true }, 'jobs.shareReport')).toBe(
      true,
    );
    expect(can({ ...ctx('manager'), techsCanShareReports: false }, 'jobs.shareReport')).toBe(true);
    // the report flag never widens payment access
    expect(can({ ...ctx('technician'), techsCanShareReports: true }, 'payments.collect')).toBe(
      false,
    );
  });

  it('builds the context from a membership', () => {
    expect(
      permissionContextOf({
        role: 'technician',
        shop: { techs_can_collect_payments: true, techs_can_share_reports: true },
      }),
    ).toEqual({ role: 'technician', techsCanCollectPayments: true, techsCanShareReports: true });
    expect(
      permissionContextOf({ role: 'manager', shop: { techs_can_collect_payments: false } }),
    ).toEqual({ role: 'manager', techsCanCollectPayments: false, techsCanShareReports: false });
  });

  it('denies everything without a context', () => {
    expect(can(null, 'calendar.view')).toBe(false);
    expect(can(undefined, 'shop.viewBasic')).toBe(false);
  });
});

describe('team management rules', () => {
  it('owner can change others but not grant owner or change self', () => {
    expect(canChangeMemberRole('owner', { role: 'admin', isSelf: false }, 'manager')).toBe(true);
    expect(canChangeMemberRole('owner', { role: 'technician', isSelf: false }, 'admin')).toBe(true);
    expect(canChangeMemberRole('owner', { role: 'manager', isSelf: false }, 'owner')).toBe(false);
    expect(canChangeMemberRole('owner', { role: 'owner', isSelf: true }, 'admin')).toBe(false);
  });

  it('admin cannot touch the owner, themselves, or grant owner', () => {
    expect(canChangeMemberRole('admin', { role: 'owner', isSelf: false }, 'admin')).toBe(false);
    expect(canChangeMemberRole('admin', { role: 'manager', isSelf: false }, 'owner')).toBe(false);
    expect(canChangeMemberRole('admin', { role: 'admin', isSelf: true }, 'manager')).toBe(false);
    expect(canChangeMemberRole('admin', { role: 'technician', isSelf: false }, 'manager')).toBe(
      true,
    );
    expect(canChangeMemberRole('admin', { role: 'admin', isSelf: false }, 'manager')).toBe(true);
  });

  it('managers and technicians change nobody; same role is a no-op', () => {
    expect(canChangeMemberRole('manager', { role: 'technician', isSelf: false }, 'manager')).toBe(
      false,
    );
    expect(
      canChangeMemberRole('technician', { role: 'technician', isSelf: false }, 'manager'),
    ).toBe(false);
    expect(canChangeMemberRole('owner', { role: 'manager', isSelf: false }, 'manager')).toBe(false);
  });

  it('invites and deactivation', () => {
    expect(invitableRoles('owner')).toEqual(['admin', 'manager', 'technician']);
    expect(invitableRoles('admin')).toEqual(['admin', 'manager', 'technician']);
    expect(invitableRoles('manager')).toEqual([]);
    expect(canDeactivateMember('owner', { role: 'admin', isSelf: false })).toBe(true);
    expect(canDeactivateMember('admin', { role: 'owner', isSelf: false })).toBe(false);
    expect(canDeactivateMember('admin', { role: 'admin', isSelf: true })).toBe(false);
    expect(canDeactivateMember('manager', { role: 'technician', isSelf: false })).toBe(false);
  });
});
