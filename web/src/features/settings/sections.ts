import type { Capability } from '@/features/shop/permissions';

/**
 * Settings sub-pages (SPEC §6 "settings"). `view` gates visibility in the
 * sub-nav and the route; editing is decided per page (see useSettingsAccess).
 * `group` heads the sub-nav on wide screens.
 */
export interface SettingsSection {
  path: string;
  label: string;
  description: string;
  view: Capability;
  group: SettingsGroup;
}

export const SETTINGS_GROUPS = [
  'Business',
  'Booking',
  'Money',
  'Messages',
  'Data & integrations',
  'Account',
] as const;
export type SettingsGroup = (typeof SETTINGS_GROUPS)[number];

export const SETTINGS_SECTIONS = [
  {
    path: 'business',
    label: 'Business profile',
    description: 'Name, contact details, address, time zone, logo and brand colour.',
    view: 'settings.view',
    group: 'Business',
  },
  {
    path: 'hours',
    label: 'Business hours',
    description: 'When customers can book and when your team works.',
    view: 'settings.view',
    group: 'Business',
  },
  {
    path: 'blocked-times',
    label: 'Closures & time off',
    description:
      'Holidays, closures, time off and other calendar events for the whole shop or one person.',
    view: 'settings.view',
    group: 'Business',
  },
  {
    path: 'resources',
    label: 'Bays & vans',
    description: 'Bays, vans and other resources jobs can be scheduled on.',
    view: 'settings.view',
    group: 'Business',
  },
  {
    path: 'vehicle-categories',
    label: 'Vehicle categories',
    description: 'Size classes used to price services.',
    view: 'settings.view',
    group: 'Business',
  },
  {
    path: 'taxes',
    label: 'Taxes & documents',
    description: 'Sales tax, quote and invoice terms, what technicians may do.',
    view: 'settings.view',
    group: 'Business',
  },
  {
    path: 'booking',
    label: 'Online booking',
    description: 'Your public booking page, availability rules, deposits and tracking.',
    view: 'settings.view',
    group: 'Booking',
  },
  {
    path: 'booking-links',
    label: 'Private booking links',
    description:
      'Links that offer chosen services only, including ones hidden from your booking page.',
    view: 'settings.view',
    group: 'Booking',
  },
  {
    path: 'custom-fields',
    label: 'Custom fields',
    description:
      'Extra details you keep for customers and jobs, and the questions asked when booking.',
    view: 'settings.view',
    group: 'Booking',
  },
  {
    path: 'lead-forms',
    label: 'Lead forms',
    description: 'Contact forms for your website that add new leads to your customer list.',
    view: 'settings.view',
    group: 'Booking',
  },
  {
    path: 'payments',
    label: 'Payments',
    description: 'Connect Stripe to take card payments and deposits.',
    view: 'shop.connectStripe',
    group: 'Money',
  },
  {
    path: 'fees',
    label: 'Fees',
    description: 'Preset fees such as travel, added by hand or automatically by location.',
    view: 'settings.view',
    group: 'Money',
  },
  {
    path: 'coupons',
    label: 'Coupons',
    description: 'Discount codes for online booking and staff-created jobs.',
    view: 'settings.view',
    group: 'Money',
  },
  {
    path: 'gift-cards',
    label: 'Gift cards',
    description: 'Sell gift cards online and set their expiry and terms.',
    view: 'settings.view',
    group: 'Money',
  },
  {
    path: 'referrals',
    label: 'Referrals',
    description: 'Reward customers who send you new customers.',
    view: 'settings.view',
    group: 'Money',
  },
  {
    path: 'templates',
    label: 'Messages & automations',
    description: 'Wording and timing of the texts and emails customers receive.',
    view: 'settings.view',
    group: 'Messages',
  },
  {
    path: 'followups',
    label: 'Follow-ups',
    description: 'Automatic reminders for unanswered quotes, unpaid deposits and unpaid invoices.',
    view: 'settings.view',
    group: 'Messages',
  },
  {
    path: 'sms',
    label: 'SMS',
    description: 'The phone number your texts are sent from.',
    view: 'shop.manageSmsNumber',
    group: 'Messages',
  },
  {
    path: 'forms',
    label: 'Forms',
    description: 'Waivers and agreements customers read and sign.',
    view: 'settings.view',
    group: 'Messages',
  },
  {
    path: 'import-export',
    label: 'Import & export',
    description:
      'Bring customers, vehicles and services in from a spreadsheet, or download your data.',
    view: 'import.run',
    group: 'Data & integrations',
  },
  {
    path: 'webhooks',
    label: 'Webhooks',
    description: 'Send bookings, payments and other events to Zapier or your own systems.',
    view: 'webhooks.manage',
    group: 'Data & integrations',
  },
  {
    path: 'calendar-feed',
    label: 'Calendar feed',
    description: 'See your jobs in Google Calendar, Apple Calendar or Outlook.',
    view: 'calendarFeed.own',
    group: 'Data & integrations',
  },
  {
    path: 'delete-shop',
    label: 'Delete shop',
    description: 'Permanently delete this shop and everything in it.',
    view: 'shop.delete',
    group: 'Account',
  },
] as const satisfies readonly SettingsSection[];

export type SettingsSectionPath = (typeof SETTINGS_SECTIONS)[number]['path'];

export function sectionByPath(path: SettingsSectionPath): SettingsSection {
  const section = SETTINGS_SECTIONS.find((s) => s.path === path);
  if (!section) throw new Error(`Unknown settings section ${path}`);
  return section;
}
