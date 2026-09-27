/**
 * THE capability matrix (SPEC §3) — the only place the web app decides what a
 * role may see or do. The database enforces the same rules with RLS/RPC; this
 * file only drives UI (hiding nav, disabling buttons, route guards). Never
 * rely on it for security.
 *
 * Use `useCan('invoices.manage')` in components or `can(ctx, cap)` in pure
 * code. When SPEC §3 changes, change it here (and permissions.test.ts).
 */

export const SHOP_ROLES = ['owner', 'admin', 'manager', 'technician'] as const;
export type ShopRole = (typeof SHOP_ROLES)[number];

export function isShopRole(value: unknown): value is ShopRole {
  return typeof value === 'string' && (SHOP_ROLES as readonly string[]).includes(value);
}

export const ROLE_LABELS: Record<ShopRole, string> = {
  owner: 'Owner',
  admin: 'Admin',
  manager: 'Manager',
  technician: 'Technician',
};

/** Higher = more privileged. */
export const ROLE_RANK: Record<ShopRole, number> = {
  owner: 4,
  admin: 3,
  manager: 2,
  technician: 1,
};

export interface PermissionContext {
  role: ShopRole;
  /** shops.techs_can_collect_payments */
  techsCanCollectPayments: boolean;
}

type Rule = readonly ShopRole[] | ((ctx: PermissionContext) => boolean);

const ALL: readonly ShopRole[] = SHOP_ROLES;
const OWNER_ADMIN: readonly ShopRole[] = ['owner', 'admin'];
const MANAGERS: readonly ShopRole[] = ['owner', 'admin', 'manager'];
const techWhenAllowed = (ctx: PermissionContext) =>
  ctx.role !== 'technician' || ctx.techsCanCollectPayments;

/**
 * Capability → who has it. Keys are `<area>.<action>`; "Assigned"/"Own"
 * variants mean the server narrows rows to the caller's assigned jobs / own
 * rows (RLS), so the UI may show the screen.
 */
export const CAPABILITIES = {
  // Shop settings, branding, taxes, booking settings, templates
  'settings.view': MANAGERS, // manager: read-only
  'settings.manage': OWNER_ADMIN,
  'shop.viewBasic': ALL, // technicians: read basic shop info
  // Stripe Connect, SMS number, delete/transfer shop
  'shop.connectStripe': OWNER_ADMIN,
  'shop.manageSmsNumber': OWNER_ADMIN,
  'shop.delete': ['owner'],
  'shop.transfer': ['owner'],

  // Team
  'team.view': MANAGERS, // technicians only get names/colors via calendar/job data
  'team.viewNames': ALL,
  'team.manage': OWNER_ADMIN, // invite, change roles, deactivate (see canChangeMemberRole)
  'compensation.view': OWNER_ADMIN,
  'compensation.manage': OWNER_ADMIN,
  'compensation.viewOwn': ALL,

  // Customers & vehicles
  'customers.view': MANAGERS, // full list
  'customers.viewAssigned': ALL, // technicians: only customers on their assigned jobs
  'customers.manage': MANAGERS,

  // Catalog
  'catalog.view': ALL,
  'catalog.manage': MANAGERS,

  // Jobs / calendar
  'calendar.view': ALL, // technicians: others' jobs arrive as anonymized busy blocks
  'jobs.view': MANAGERS, // all jobs
  'jobs.viewAssigned': ALL,
  'jobs.manage': MANAGERS, // create, edit, reschedule, assign, line items
  'jobs.progress': ALL, // forward status, checklist, photos, inspections, forms (assigned for techs)
  'jobs.moveStatusBackward': MANAGERS,
  'blockedTimes.manage': MANAGERS,

  // Quotes, invoices, payments, memberships
  'quotes.view': MANAGERS,
  'quotes.manage': MANAGERS,
  'invoices.view': MANAGERS,
  'invoices.manage': MANAGERS,
  'invoices.viewAssigned': techWhenAllowed,
  'payments.view': MANAGERS,
  'payments.collect': techWhenAllowed, // techs: on assigned jobs only, when the shop allows it
  'payments.refund': OWNER_ADMIN,
  'invoices.void': OWNER_ADMIN,
  'memberships.view': MANAGERS,
  'memberships.manage': MANAGERS,
  'cards.view': MANAGERS,
  'cards.charge': MANAGERS,

  // Reports
  'reports.view': MANAGERS,
  'reports.viewOwn': ALL,

  // Communication
  'messages.inbox': MANAGERS,
  'messages.sendJobUpdates': ALL, // templated "on my way" / "job complete" on assigned jobs
  'campaigns.manage': MANAGERS,

  // Time clock
  'timeclock.own': ALL,
  'timeclock.viewAll': MANAGERS,
  'timeclock.editAll': MANAGERS,

  // Notifications
  'notifications.view': ALL,
} as const satisfies Record<string, Rule>;

export type Capability = keyof typeof CAPABILITIES;

export function can(ctx: PermissionContext | null | undefined, capability: Capability): boolean {
  if (!ctx) return false;
  const rule: Rule = CAPABILITIES[capability];
  return typeof rule === 'function' ? rule(ctx) : rule.includes(ctx.role);
}

export function canAll(
  ctx: PermissionContext | null | undefined,
  capabilities: readonly Capability[],
): boolean {
  return capabilities.every((c) => can(ctx, c));
}

export function canAny(
  ctx: PermissionContext | null | undefined,
  capabilities: readonly Capability[],
): boolean {
  return capabilities.some((c) => can(ctx, c));
}

/**
 * Team role changes (SPEC §3): the owner may change anyone but themselves
 * (ownership moves only via the owner-only transfer flow); an admin may
 * change any non-owner member except themselves, and may never grant owner.
 * Managers and technicians change nobody. The server enforces the same.
 */
export function canChangeMemberRole(
  actor: ShopRole,
  target: { role: ShopRole; isSelf: boolean },
  nextRole: ShopRole,
): boolean {
  if (target.role === nextRole) return false;
  if (actor === 'owner') return !target.isSelf && nextRole !== 'owner';
  if (actor === 'admin') {
    if (target.isSelf || target.role === 'owner') return false;
    return nextRole !== 'owner';
  }
  return false;
}

/** Roles an actor may invite someone as. */
export function invitableRoles(actor: ShopRole): ShopRole[] {
  if (actor === 'owner' || actor === 'admin') return ['admin', 'manager', 'technician'];
  return [];
}

/** Whether `actor` may deactivate/reactivate `target`. */
export function canDeactivateMember(
  actor: ShopRole,
  target: { role: ShopRole; isSelf: boolean },
): boolean {
  if (target.isSelf) return false;
  if (actor === 'owner' || actor === 'admin') return target.role !== 'owner';
  return false;
}
