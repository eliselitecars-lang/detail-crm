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
  /** appointment_reminder: up to 3 reminders (reminder_offsets_minutes). */
  multipleReminders?: boolean;
  /**
   * The template rows are only the shop-wide on/off switch per channel; the
   * wording lives elsewhere (service_followup: per service in the catalog).
   */
  switchOnly?: boolean;
  /** Where the timing is set when it isn't in the template (document follow-ups). */
  timingNote?: string;
}

export interface TemplateGroup {
  label: string;
  keys: readonly TemplateKeyMeta[];
}

const BOTH = ['sms', 'email'] as const;
const FOLLOWUP_TIMING = 'Timing is set in Settings → Follow-ups.';

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
        multipleReminders: true,
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
    label: 'Payment & quote follow-ups',
    keys: [
      {
        key: 'quote_reminder',
        label: 'Quote reminder',
        description: 'Reminds the customer about a quote they haven’t answered yet.',
        channels: BOTH,
        audience: 'customer',
        timingNote: FOLLOWUP_TIMING,
      },
      {
        key: 'deposit_reminder',
        label: 'Deposit reminder',
        description: 'Reminds the customer to pay the deposit for an upcoming appointment.',
        channels: BOTH,
        audience: 'customer',
        timingNote: FOLLOWUP_TIMING,
      },
      {
        key: 'invoice_reminder',
        label: 'Invoice reminder',
        description: 'Reminds the customer about an unpaid invoice before it’s due.',
        channels: BOTH,
        audience: 'customer',
        timingNote: FOLLOWUP_TIMING,
      },
      {
        key: 'invoice_overdue',
        label: 'Past-due notice',
        description: 'Tells the customer an invoice is past its due date.',
        channels: BOTH,
        audience: 'customer',
        timingNote: FOLLOWUP_TIMING,
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
        key: 'service_followup',
        label: 'Maintenance follow-ups',
        description:
          'Per-service reminders some time after a job, e.g. a coating top-up. Write them on each service in the Catalog; these switches turn each channel on or off for every service.',
        channels: BOTH,
        audience: 'customer',
        switchOnly: true,
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
    label: 'Leads, reports & rewards',
    keys: [
      {
        key: 'lead_received',
        label: 'Lead received',
        description:
          'Auto-reply to someone who fills in one of your lead forms (when the form has auto-reply on). It’s emailed, and texted only to a customer already on file whose number you verified — never to a number typed into the form. It greets everyone as “there”: the name from a form is never put in the message.',
        channels: BOTH,
        audience: 'customer',
      },
      {
        key: 'job_report',
        label: 'Job report',
        description: 'Sends the link to a job report (photos and inspection) when you share it.',
        channels: BOTH,
        audience: 'customer',
      },
      {
        key: 'gift_card_delivery',
        label: 'Gift card delivery',
        description:
          'Emails a gift card and its code to the recipient. Sent by email only, so the code never appears in a text.',
        channels: ['email'],
        audience: 'customer',
      },
      {
        key: 'referral_reward',
        label: 'Referral reward',
        description:
          'Thanks a customer whose referral completed a first visit, with their store credit code.',
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

const BASE_PLACEHOLDERS: readonly PlaceholderMeta[] = [
  { name: 'customer_first_name', label: 'Customer first name' },
  { name: 'customer_name', label: 'Customer full name' },
  { name: 'shop_name', label: 'Shop name' },
  { name: 'shop_phone', label: 'Shop phone' },
];

const APPOINTMENT_PLACEHOLDERS: readonly PlaceholderMeta[] = [
  { name: 'job_date', label: 'Appointment date' },
  { name: 'job_time', label: 'Appointment time' },
  { name: 'job_number', label: 'Job number' },
  { name: 'vehicle', label: 'Vehicle' },
  { name: 'services', label: 'Services' },
];

/** Documented placeholders (0032 + rebook_link from 0083). Order = order of the chips. */
export const CUSTOMER_PLACEHOLDERS: readonly PlaceholderMeta[] = [
  ...BASE_PLACEHOLDERS,
  ...APPOINTMENT_PLACEHOLDERS,
  { name: 'booking_link', label: 'Manage-booking link' },
  { name: 'booking_page_link', label: 'Booking page link' },
  { name: 'rebook_link', label: 'Rebooking link' },
  { name: 'quote_link', label: 'Quote link' },
  { name: 'invoice_link', label: 'Invoice link' },
  { name: 'review_link', label: 'Review link' },
  { name: 'amount', label: 'Amount' },
  { name: 'balance', label: 'Balance due' },
];

const QUOTE_PLACEHOLDERS: readonly PlaceholderMeta[] = [
  ...BASE_PLACEHOLDERS,
  { name: 'quote_number', label: 'Quote number' },
  { name: 'quote_total', label: 'Quote total' },
  { name: 'valid_until', label: 'Valid until' },
  { name: 'quote_link', label: 'Quote link' },
];

const DEPOSIT_PLACEHOLDERS: readonly PlaceholderMeta[] = [
  ...BASE_PLACEHOLDERS,
  ...APPOINTMENT_PLACEHOLDERS,
  { name: 'deposit_due', label: 'Deposit due' },
  { name: 'deposit_link', label: 'Deposit payment link' },
  { name: 'booking_link', label: 'Manage-booking link' },
];

const INVOICE_PLACEHOLDERS: readonly PlaceholderMeta[] = [
  ...BASE_PLACEHOLDERS,
  { name: 'invoice_number', label: 'Invoice number' },
  { name: 'amount', label: 'Invoice total' },
  { name: 'balance', label: 'Balance due' },
  { name: 'due_date', label: 'Due date' },
  { name: 'invoice_link', label: 'Invoice link' },
];

const OVERDUE_PLACEHOLDERS: readonly PlaceholderMeta[] = [
  ...INVOICE_PLACEHOLDERS,
  { name: 'days_overdue', label: 'Days past due' },
];

const REPORT_PLACEHOLDERS: readonly PlaceholderMeta[] = [
  ...BASE_PLACEHOLDERS,
  ...APPOINTMENT_PLACEHOLDERS,
  { name: 'report_link', label: 'Job report link' },
];

/**
 * Placeholders of per-service maintenance follow-ups (service_followups
 * wording, written in the catalog): the job's details plus {{rebook_link}},
 * which preselects the service and the vehicle size on the booking page.
 */
export const SERVICE_FOLLOWUP_PLACEHOLDERS: readonly PlaceholderMeta[] = [
  ...BASE_PLACEHOLDERS,
  ...APPOINTMENT_PLACEHOLDERS,
  { name: 'rebook_link', label: 'Rebooking link' },
  { name: 'review_link', label: 'Review link' },
];

const GIFT_CARD_PLACEHOLDERS: readonly PlaceholderMeta[] = [
  { name: 'customer_first_name', label: 'Recipient first name' },
  { name: 'recipient_name', label: 'Recipient name' },
  { name: 'sender_name', label: 'Sender name' },
  { name: 'gift_card_amount', label: 'Gift card amount' },
  { name: 'gift_card_code', label: 'Gift card code' },
  { name: 'gift_message', label: 'Gift message' },
  { name: 'shop_name', label: 'Shop name' },
  { name: 'shop_phone', label: 'Shop phone' },
];

const REFERRAL_PLACEHOLDERS: readonly PlaceholderMeta[] = [
  ...BASE_PLACEHOLDERS,
  { name: 'referee_first_name', label: 'Referred friend’s first name' },
  { name: 'credit_amount', label: 'Credit amount' },
  { name: 'gift_card_code', label: 'Credit code' },
];

export const INVITE_PLACEHOLDERS: readonly PlaceholderMeta[] = [
  { name: 'shop_name', label: 'Shop name' },
  // invites/index.ts buildInviteEmail supplies shop_phone too.
  { name: 'shop_phone', label: 'Shop phone' },
  { name: 'invite_link', label: 'Invitation link' },
];

const KEY_PLACEHOLDERS: Partial<Record<TemplateKey, readonly PlaceholderMeta[]>> = {
  invite: INVITE_PLACEHOLDERS,
  quote_reminder: QUOTE_PLACEHOLDERS,
  deposit_reminder: DEPOSIT_PLACEHOLDERS,
  invoice_reminder: INVOICE_PLACEHOLDERS,
  invoice_overdue: OVERDUE_PLACEHOLDERS,
  service_followup: SERVICE_FOLLOWUP_PLACEHOLDERS,
  lead_received: BASE_PLACEHOLDERS,
  job_report: REPORT_PLACEHOLDERS,
  gift_card_delivery: GIFT_CARD_PLACEHOLDERS,
  referral_reward: REFERRAL_PLACEHOLDERS,
};

export function placeholdersFor(key: TemplateKey): readonly PlaceholderMeta[] {
  return KEY_PLACEHOLDERS[key] ?? CUSTOMER_PLACEHOLDERS;
}

const ALL_PLACEHOLDERS: readonly PlaceholderMeta[] = [
  ...CUSTOMER_PLACEHOLDERS,
  ...Object.values(KEY_PLACEHOLDERS).flat(),
];

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
  for (const p of ALL_PLACEHOLDERS) {
    vars[p.name] ??= `[${p.label.toLowerCase()}]`;
  }
  vars.shop_name = shop.name;
  if (shop.phone) vars.shop_phone = shop.phone;
  if (shop.reviewUrl) vars.review_link = shop.reviewUrl;
  vars.booking_page_link = shop.bookingPageUrl;
  vars.rebook_link = shop.bookingPageUrl;
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

/** "2 days and 2 hours before the appointment" for several reminders. */
export function describeReminders(offsets: readonly number[]): string | null {
  if (offsets.length === 0) return null;
  const parts = [...offsets]
    .sort((a, b) => a - b)
    .map((o) => {
      const abs = Math.abs(o);
      if (abs === 0) return 'at the start';
      const [amount, unit] =
        abs % 1440 === 0
          ? [abs / 1440, 'day']
          : abs % 60 === 0
            ? [abs / 60, 'hour']
            : [abs, 'minute'];
      return `${amount} ${unit}${amount === 1 ? '' : 's'}`;
    });
  const list =
    parts.length === 1
      ? parts[0]
      : `${parts.slice(0, -1).join(', ')} and ${parts[parts.length - 1] ?? ''}`;
  return `${list} before the appointment`;
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
