import type { Capability } from '@/features/shop/permissions';

/**
 * Settings sub-pages (SPEC §6 "settings"). `view` gates visibility in the
 * sub-nav and the route; editing is decided per page (see useSettingsAccess).
 */
export interface SettingsSection {
  path: string;
  label: string;
  description: string;
  view: Capability;
}

export const SETTINGS_SECTIONS = [
  {
    path: 'business',
    label: 'Business profile',
    description: 'Name, contact details, address, time zone, logo and brand colour.',
    view: 'settings.view',
  },
  {
    path: 'booking',
    label: 'Online booking',
    description: 'Your public booking page, availability rules and deposits.',
    view: 'settings.view',
  },
  {
    path: 'hours',
    label: 'Business hours',
    description: 'When customers can book and when your team works.',
    view: 'settings.view',
  },
  {
    path: 'blocked-times',
    label: 'Blocked times',
    description: 'Holidays, closures and time off for the whole shop or one person.',
    view: 'settings.view',
  },
  {
    path: 'resources',
    label: 'Bays & vans',
    description: 'Bays, vans and other resources jobs can be scheduled on.',
    view: 'settings.view',
  },
  {
    path: 'taxes',
    label: 'Taxes & documents',
    description: 'Sales tax, quote and invoice terms, payment collection.',
    view: 'settings.view',
  },
  {
    path: 'vehicle-categories',
    label: 'Vehicle categories',
    description: 'Size classes used to price services.',
    view: 'settings.view',
  },
  {
    path: 'coupons',
    label: 'Coupons',
    description: 'Discount codes for online booking and staff-created jobs.',
    view: 'settings.view',
  },
  {
    path: 'templates',
    label: 'Messages & automations',
    description: 'Wording and timing of the texts and emails customers receive.',
    view: 'settings.view',
  },
  {
    path: 'forms',
    label: 'Forms',
    description: 'Waivers and agreements customers read and sign.',
    view: 'settings.view',
  },
  {
    path: 'payments',
    label: 'Payments',
    description: 'Connect Stripe to take card payments and deposits.',
    view: 'shop.connectStripe',
  },
  {
    path: 'sms',
    label: 'SMS',
    description: 'The phone number your texts are sent from.',
    view: 'shop.manageSmsNumber',
  },
] as const satisfies readonly SettingsSection[];

export type SettingsSectionPath = (typeof SETTINGS_SECTIONS)[number]['path'];

export function sectionByPath(path: SettingsSectionPath): SettingsSection {
  const section = SETTINGS_SECTIONS.find((s) => s.path === path);
  if (!section) throw new Error(`Unknown settings section ${path}`);
  return section;
}
