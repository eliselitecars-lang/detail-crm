/**
 * What each message template is for, which placeholders it can use and how
 * its timing works (migration 0032 header). Labels only — the wording itself
 * lives in the database.
 */
import type { TemplateChannel, TemplateKey } from '../api';
import { UNIT_MINUTES, type DurationUnit } from '../schemas';

export interface TemplateKeyMeta {
  key: TemplateKey;
  label: string;
  description: string;
  /** Channels the database allows for this key. */
  channels: readonly TemplateChannel[];
  /** Time-based automation: how offset_minutes is interpreted. */
  timing?: {
    direction: 'before_start' | 'after_completion';
    /** Allowed magnitude in minutes (CHECK message_templates_offset). */
    maxMinutes: number;
  };
  audience: 'customer' | 'staff';
}

export interface TemplateGroup {
  label: string;
  keys: readonly TemplateKeyMeta[];
}

const BOTH = ['sms', 'email'] as const;

export const TEMPLATE_GROUPS: readonly TemplateGroup[] = [
  {
    label: 'Bookings',
    keys: [
      {
        key: 'booking_request_received',
        label: 'Booking request received',
        description: 'Sent when a customer requests a time online and it needs your approval.',
        channels: BOTH,
        audience: 'customer',
      },
      {
        key: 'booking_confirmed',
        label: 'Booking confirmed',
        description: 'Sent when an appointment is confirmed.',
        channels: BOTH,
        audience: 'customer',
      },
      {
        key: 'appointment_reminder',
        label: 'Appointment reminder',
        description: 'Sent automatically before each scheduled appointment.',
        channels: BOTH,
        audience: 'customer',
        timing: { direction: 'before_start', maxMinutes: 43200 },
      },
    ],
  },
  {
    label: 'Job updates',
    keys: [
      {
        key: 'on_the_way',
        label: 'On the way',
        description: 'Sent when a technician marks the job en route.',
        channels: BOTH,
        audience: 'customer',
      },
      {
        key: 'job_started',
        label: 'Job started',
        description: 'Sent when work on the vehicle begins.',
        channels: BOTH,
        audience: 'customer',
      },
      {
        key: 'job_completed',
        label: 'Job completed',
        description: 'Sent when the job is marked complete.',
        channels: BOTH,
        audience: 'customer',
      },
    ],
  },
  {
    label: 'Quotes & payments',
    keys: [
      {
        key: 'quote_sent',
        label: 'Quote sent',
        description: 'Sent with the link when you send a quote.',
        channels: BOTH,
        audience: 'customer',
      },
      {
        key: 'invoice_sent',
        label: 'Invoice sent',
        description: 'Sent with the payment link when you send an invoice.',
        channels: BOTH,
        audience: 'customer',
      },
      {
        key: 'payment_receipt',
        label: 'Payment receipt',
        description: 'Sent after a payment is received.',
        channels: BOTH,
        audience: 'customer',
      },
    ],
  },
  {
    label: 'Follow-ups',
    keys: [
      {
        key: 'review_request',
        label: 'Review request',
        description: 'Asks for a review after the job is completed (uses your review link).',
        channels: BOTH,
        audience: 'customer',
        timing: { direction: 'after_completion', maxMinutes: 525600 },
      },
      {
        key: 'follow_up',
        label: 'Rebooking follow-up',
        description: 'Invites the customer back some time after their last job.',
        channels: BOTH,
        audience: 'customer',
        timing: { direction: 'after_completion', maxMinutes: 525600 },
      },
      {
        key: 'membership_welcome',
        label: 'Membership welcome',
        description: 'Sent when a customer’s membership starts.',
        channels: BOTH,
        audience: 'customer',
      },
    ],
  },
  {
    label: 'Team',
    keys: [
      {
        key: 'invite',
        label: 'Team invitation',
        description: 'Emailed to people you invite to join your team.',
        channels: ['email'],
        audience: 'staff',
      },
    ],
  },
];

export const TEMPLATE_KEYS: readonly TemplateKeyMeta[] = TEMPLATE_GROUPS.flatMap((g) => g.keys);

export function templateMeta(key: TemplateKey): TemplateKeyMeta {
  const meta = TEMPLATE_KEYS.find((m) => m.key === key);
  if (!meta) throw new Error(`Unknown template key ${key}`);
  return meta;
}

export const CHANNEL_LABELS: Record<TemplateChannel, string> = {
  sms: 'Text (SMS)',
  email: 'Email',
};
export const BODY_LIMITS: Record<TemplateChannel, number> = { sms: 1600, email: 20000 };

export interface PlaceholderMeta {
  name: string;
  label: string;
}

/** Documented placeholders (0032). Order = order of the chips. */
export const CUSTOMER_PLACEHOLDERS: readonly PlaceholderMeta[] = [
  { name: 'customer_first_name', label: 'Customer first name' },
  { name: 'customer_name', label: 'Customer full name' },
  { name: 'shop_name', label: 'Shop name' },
  { name: 'shop_phone', label: 'Shop phone' },
  { name: 'job_date', label: 'Appointment date' },
  { name: 'job_time', label: 'Appointment time' },
  { name: 'job_number', label: 'Job number' },
  { name: 'vehicle', label: 'Vehicle' },
  { name: 'services', label: 'Services' },
  { name: 'booking_link', label: 'Manage-booking link' },
  { name: 'booking_page_link', label: 'Booking page link' },
  { name: 'quote_link', label: 'Quote link' },
  { name: 'invoice_link', label: 'Invoice link' },
  { name: 'review_link', label: 'Review link' },
  { name: 'amount', label: 'Amount' },
  { name: 'balance', label: 'Balance due' },
];

export const INVITE_PLACEHOLDERS: readonly PlaceholderMeta[] = [
  { name: 'shop_name', label: 'Shop name' },
  { name: 'invite_link', label: 'Invitation link' },
];

export function placeholdersFor(key: TemplateKey): readonly PlaceholderMeta[] {
  return key === 'invite' ? INVITE_PLACEHOLDERS : CUSTOMER_PLACEHOLDERS;
}

/**
 * Preview values: real shop details where the shop has them; everything that
 * depends on a customer or job is shown as a labelled [placeholder] so no
 * made-up customer data or amounts appear.
 */
export function previewVars(shop: {
  name: string;
  phone: string | null;
  reviewUrl: string | null;
  bookingPageUrl: string;
}): Record<string, string> {
  const vars: Record<string, string> = {};
  for (const p of [...CUSTOMER_PLACEHOLDERS, ...INVITE_PLACEHOLDERS]) {
    vars[p.name] = `[${p.label.toLowerCase()}]`;
  }
  vars.shop_name = shop.name;
  if (shop.phone) vars.shop_phone = shop.phone;
  if (shop.reviewUrl) vars.review_link = shop.reviewUrl;
  vars.booking_page_link = shop.bookingPageUrl;
  return vars;
}

// ---------------------------------------------------------------------------
// Offsets
// ---------------------------------------------------------------------------

/** Human timing text, e.g. "1 day before the appointment", "2 hours after completion". */
export function describeOffset(meta: TemplateKeyMeta, offsetMinutes: number | null): string | null {
  if (!meta.timing || offsetMinutes === null) return null;
  const abs = Math.abs(offsetMinutes);
  const suffix =
    meta.timing.direction === 'before_start' ? 'before the appointment' : 'after completion';
  if (abs === 0) {
    return meta.timing.direction === 'before_start'
      ? 'At the appointment time'
      : 'Right after completion';
  }
  let amount: number;
  let unit: string;
  if (abs % 1440 === 0) {
    amount = abs / 1440;
    unit = 'day';
  } else if (abs % 60 === 0) {
    amount = abs / 60;
    unit = 'hour';
  } else {
    amount = abs;
    unit = 'minute';
  }
  return `${amount} ${unit}${amount === 1 ? '' : 's'} ${suffix}`;
}

/** Editor value/unit → stored offset (negative before the start). Null if invalid. */
export function offsetFromInput(
  meta: TemplateKeyMeta,
  value: string,
  unit: DurationUnit,
): number | null {
  if (!meta.timing) return null;
  const text = value.trim();
  if (!/^\d+$/.test(text)) return null;
  const minutes = Number(text) * UNIT_MINUTES[unit];
  if (minutes > meta.timing.maxMinutes) return null;
  return meta.timing.direction === 'before_start' ? (minutes === 0 ? 0 : -minutes) : minutes;
}
