import {
  BarChart3,
  CalendarDays,
  ClipboardList,
  Clock,
  CreditCard,
  FileText,
  Gift,
  LayoutDashboard,
  ListTodo,
  Megaphone,
  MessagesSquare,
  Package,
  PackageSearch,
  Receipt,
  Repeat,
  Settings,
  Users,
  UsersRound,
  type LucideIcon,
} from 'lucide-react';
import { can, type Capability, type PermissionContext } from '@/features/shop/permissions';

export interface NavItem {
  label: string;
  /** Absolute path under /app. */
  to: string;
  icon: LucideIcon;
  /** Shown when the current role has ANY of these capabilities. */
  anyOf: readonly Capability[];
  /** Exact-match active state (for the /app index). */
  end?: boolean;
}

export interface NavGroup {
  label: string;
  items: readonly NavItem[];
}

/**
 * Staff navigation (SPEC §6). Visibility follows the §3 matrix via
 * permissions.ts — technicians see only what they can use.
 */
export const NAV_GROUPS: readonly NavGroup[] = [
  {
    label: 'Overview',
    items: [
      {
        label: 'Dashboard',
        to: '/app',
        icon: LayoutDashboard,
        anyOf: ['jobs.viewAssigned'],
        end: true,
      },
      { label: 'Calendar', to: '/app/calendar', icon: CalendarDays, anyOf: ['calendar.view'] },
    ],
  },
  {
    label: 'Work',
    items: [
      { label: 'Jobs', to: '/app/jobs', icon: ClipboardList, anyOf: ['jobs.viewAssigned'] },
      { label: 'Customers', to: '/app/customers', icon: Users, anyOf: ['customers.view'] },
      { label: 'Tasks', to: '/app/tasks', icon: ListTodo, anyOf: ['tasks.own'] },
    ],
  },
  {
    label: 'Money',
    items: [
      { label: 'Quotes', to: '/app/quotes', icon: FileText, anyOf: ['quotes.view'] },
      { label: 'Invoices', to: '/app/invoices', icon: Receipt, anyOf: ['invoices.view'] },
      { label: 'Payments', to: '/app/payments', icon: CreditCard, anyOf: ['payments.view'] },
      { label: 'Memberships', to: '/app/memberships', icon: Repeat, anyOf: ['memberships.view'] },
      { label: 'Gift cards', to: '/app/gift-cards', icon: Gift, anyOf: ['giftCards.view'] },
    ],
  },
  {
    label: 'Engage',
    items: [
      { label: 'Messages', to: '/app/messages', icon: MessagesSquare, anyOf: ['messages.inbox'] },
      { label: 'Campaigns', to: '/app/campaigns', icon: Megaphone, anyOf: ['campaigns.manage'] },
    ],
  },
  {
    label: 'Insights',
    items: [
      {
        label: 'Reports',
        to: '/app/reports',
        icon: BarChart3,
        anyOf: ['reports.view', 'reports.viewOwn'],
      },
      {
        label: 'Inventory',
        to: '/app/inventory',
        icon: PackageSearch,
        anyOf: ['inventory.view'],
      },
    ],
  },
  {
    label: 'Team',
    items: [
      { label: 'Team', to: '/app/team', icon: UsersRound, anyOf: ['team.view'] },
      { label: 'Timesheets', to: '/app/timesheets', icon: Clock, anyOf: ['timeclock.own'] },
    ],
  },
  {
    label: 'Setup',
    items: [
      { label: 'Catalog', to: '/app/catalog', icon: Package, anyOf: ['catalog.view'] },
      {
        label: 'Settings',
        to: '/app/settings',
        icon: Settings,
        // technicians: their personal calendar feed
        anyOf: ['settings.view', 'calendarFeed.own'],
      },
    ],
  },
];

/** Groups filtered to what `ctx` may see (empty groups removed). */
export function visibleNav(ctx: PermissionContext | null): NavGroup[] {
  return NAV_GROUPS.map((group) => ({
    ...group,
    items: group.items.filter((item) => item.anyOf.some((capability) => can(ctx, capability))),
  })).filter((group) => group.items.length > 0);
}
