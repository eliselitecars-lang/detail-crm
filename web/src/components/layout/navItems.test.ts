import { describe, expect, it } from 'vitest';
import { visibleNav } from './navItems';

const labels = (
  role: 'owner' | 'admin' | 'manager' | 'technician',
  techsCanCollectPayments = false,
) => visibleNav({ role, techsCanCollectPayments }).flatMap((g) => g.items.map((i) => i.label));

describe('visibleNav', () => {
  const everything = [
    'Dashboard',
    'Calendar',
    'Jobs',
    'Customers',
    'Tasks',
    'Quotes',
    'Invoices',
    'Payments',
    'Memberships',
    'Gift cards',
    'Messages',
    'Campaigns',
    'Reports',
    'Inventory',
    'Team',
    'Timesheets',
    'Catalog',
    'Settings',
  ];

  it('shows every section to owners, admins and managers', () => {
    expect(labels('owner')).toEqual(everything);
    expect(labels('admin')).toEqual(everything);
    expect(labels('manager')).toEqual(everything);
  });

  it('limits technicians to their own work', () => {
    expect(labels('technician')).toEqual([
      'Dashboard',
      'Calendar',
      'Jobs',
      'Tasks',
      'Reports',
      'Timesheets',
      'Catalog',
      'Settings',
    ]);
    expect(labels('technician', true)).toEqual(labels('technician'));
  });

  it('drops empty groups and shows nothing without a role', () => {
    expect(
      visibleNav({ role: 'technician', techsCanCollectPayments: false }).map((g) => g.label),
    ).not.toContain('Money');
    expect(visibleNav(null)).toEqual([]);
  });
});
