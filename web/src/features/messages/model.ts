/**
 * Messages inbox — pure types and helpers (no Supabase, no React), so the
 * grouping/unread/opt-out rules are unit-testable.
 */
import { z } from 'zod';
import { Constants } from '@/lib/database.types';

export const MESSAGE_CHANNELS = Constants.public.Enums.message_channel;
export type MessageChannel = (typeof MESSAGE_CHANNELS)[number];
export type MessageStatus = (typeof Constants.public.Enums.message_status)[number];
export type MessageTemplateKey = (typeof Constants.public.Enums.message_template_key)[number];

export const threadCustomerSchema = z.object({
  id: z.string(),
  first_name: z.string().nullable(),
  last_name: z.string().nullable(),
  company: z.string().nullable(),
  phone: z.string().nullable(),
  email: z.string().nullable(),
  sms_opt_in: z.boolean(),
  email_opt_in: z.boolean(),
  sms_opted_out_at: z.string().nullable(),
  email_opted_out_at: z.string().nullable(),
  archived_at: z.string().nullable(),
});
export type ThreadCustomer = z.infer<typeof threadCustomerSchema>;

/** Columns selected for ThreadCustomer (keep in sync with the schema above). */
export const THREAD_CUSTOMER_COLUMNS =
  'id, first_name, last_name, company, phone, email, sms_opt_in, email_opt_in, sms_opted_out_at, email_opted_out_at, archived_at';

export const messageSchema = z.object({
  id: z.string(),
  customer_id: z.string().nullable(),
  job_id: z.string().nullable(),
  campaign_id: z.string().nullable(),
  direction: z.enum(Constants.public.Enums.message_direction),
  channel: z.enum(Constants.public.Enums.message_channel),
  to_address: z.string(),
  from_address: z.string().nullable(),
  subject: z.string().nullable(),
  body: z.string(),
  status: z.enum(Constants.public.Enums.message_status),
  error: z.string().nullable(),
  template_key: z.enum(Constants.public.Enums.message_template_key).nullable(),
  read_at: z.string().nullable(),
  send_after: z.string(),
  sent_at: z.string().nullable(),
  delivered_at: z.string().nullable(),
  created_at: z.string(),
});
export type Message = z.infer<typeof messageSchema>;

/** Columns selected for Message (keep in sync with the schema above). */
export const MESSAGE_COLUMNS =
  'id, customer_id, job_id, campaign_id, direction, channel, to_address, from_address, subject, body, status, error, template_key, read_at, send_after, sent_at, delivered_at, created_at';

/**
 * Which conversation a thread is. Customers are keyed by id; messages with no
 * customer (a text from a number that matches no customer) are grouped by the
 * counterpart address until someone adds that customer (the server then
 * attaches them automatically).
 */
export type ThreadRef =
  { kind: 'customer'; customerId: string } | { kind: 'unknown'; from: string };

export function threadKey(ref: ThreadRef): string {
  return ref.kind === 'customer' ? `c:${ref.customerId}` : `u:${ref.from}`;
}

/** One inbox_threads row (0090): the newest message per conversation + unread count. */
export const inboxThreadRowSchema = z.object({
  /** 'c:<customer id>' or 'a:<address>' (email lower-cased, SMS as E.164). */
  thread_key: z.string(),
  customer_id: z.string().nullable(),
  /** Counterpart address of the thread's newest message (inbound: sender; outbound: recipient). */
  from_address: z.string().nullable(),
  customer_first_name: z.string().nullable(),
  customer_last_name: z.string().nullable(),
  customer_company: z.string().nullable(),
  last_message_id: z.string(),
  last_direction: z.enum(Constants.public.Enums.message_direction),
  last_channel: z.enum(Constants.public.Enums.message_channel),
  last_status: z.enum(Constants.public.Enums.message_status),
  /** The first 280 characters of the newest message. */
  last_body: z.string(),
  last_created_at: z.string(),
  unread_count: z.number().int(),
});
export type InboxThreadRow = z.infer<typeof inboxThreadRowSchema>;

export interface ThreadSummary {
  key: string;
  ref: ThreadRef;
  customer: Pick<ThreadCustomer, 'first_name' | 'last_name' | 'company'> | null;
  last: {
    id: string;
    direction: Message['direction'];
    channel: MessageChannel;
    status: MessageStatus;
    body: string;
    created_at: string;
  };
  unread: number;
}

/** Maps an inbox_threads row to the thread list model (null for a row with no address). */
export function threadFromRow(row: InboxThreadRow): ThreadSummary | null {
  let ref: ThreadRef;
  if (row.customer_id) {
    ref = { kind: 'customer', customerId: row.customer_id };
  } else {
    const from =
      row.from_address ?? (row.thread_key.startsWith('a:') ? row.thread_key.slice(2) : '');
    if (!from) return null;
    ref = { kind: 'unknown', from };
  }
  return {
    key: threadKey(ref),
    ref,
    customer: row.customer_id
      ? {
          first_name: row.customer_first_name,
          last_name: row.customer_last_name,
          company: row.customer_company,
        }
      : null,
    last: {
      id: row.last_message_id,
      direction: row.last_direction,
      channel: row.last_channel,
      status: row.last_status,
      body: row.last_body,
      created_at: row.last_created_at,
    },
    unread: row.unread_count,
  };
}

/** Threads from inbox pages (newest first), each conversation once. */
export function threadsFromPages(pages: readonly (readonly InboxThreadRow[])[]): ThreadSummary[] {
  const seen = new Map<string, ThreadSummary>();
  for (const row of pages.flat()) {
    const thread = threadFromRow(row);
    if (thread && !seen.has(thread.key)) seen.set(thread.key, thread);
  }
  return [...seen.values()];
}

export function customerName(
  c: Pick<ThreadCustomer, 'first_name' | 'last_name' | 'company'> | null | undefined,
): string {
  if (!c) return 'Unknown customer';
  const full = [c.first_name, c.last_name]
    .map((p) => p?.trim())
    .filter(Boolean)
    .join(' ');
  return full || c.company?.trim() || 'Unnamed customer';
}

/** One-line preview of a message for the thread list. */
export function messagePreview(
  m: Pick<Message, 'body' | 'channel'> & { subject?: string | null },
): string {
  const text = m.body.replace(/\s+/g, ' ').trim();
  if (text) return text;
  if (m.channel === 'email' && m.subject) return m.subject;
  return '(no text)';
}

export interface ChannelAvailability {
  available: boolean;
  /** Why the channel cannot be used (shown next to the channel choice). */
  reason: string | null;
}

/**
 * Whether staff can message a customer on a channel. Mirrors queue_message's
 * checks (address present, not opted out); the server has the final say and
 * also checks the shop's SMS number. Opt-IN is a marketing (campaign) rule,
 * not a requirement for one-to-one messages.
 */
export function channelAvailability(
  customer: Pick<
    ThreadCustomer,
    'phone' | 'email' | 'sms_opted_out_at' | 'email_opted_out_at' | 'archived_at'
  >,
  channel: MessageChannel,
): ChannelAvailability {
  if (channel === 'sms') {
    if (!customer.phone) return { available: false, reason: 'No mobile number on file.' };
    if (customer.sms_opted_out_at)
      return { available: false, reason: 'Opted out of texts (replied STOP).' };
    return { available: true, reason: null };
  }
  if (!customer.email) return { available: false, reason: 'No email address on file.' };
  if (customer.email_opted_out_at) return { available: false, reason: 'Unsubscribed from email.' };
  return { available: true, reason: null };
}

export const SMS_MAX_LENGTH = 1600;
export const EMAIL_MAX_LENGTH = 50000;

/** Standard SMS segment estimate (GSM-7 160 / 153, otherwise UCS-2 70 / 67). */
export function smsSegments(text: string): number {
  if (text.length === 0) return 0;
  // eslint-disable-next-line no-control-regex
  const gsm = /^[\u0000-\u007F£¥èéùìòÇØøÅåΔΦΓΛΩΠΨΣΘΞÆæßÉ¤¡ÄÖÑÜ§¿äöñüà€]*$/.test(text);
  const single = gsm ? 160 : 70;
  const multi = gsm ? 153 : 67;
  return text.length <= single ? 1 : Math.ceil(text.length / multi);
}

/** Human labels for message_template_key. */
export const TEMPLATE_LABELS: Record<MessageTemplateKey, string> = {
  booking_request_received: 'Booking request received',
  booking_confirmed: 'Booking confirmed',
  appointment_reminder: 'Appointment reminder',
  on_the_way: 'On the way',
  job_started: 'Job started',
  job_completed: 'Job completed',
  quote_sent: 'Quote sent',
  invoice_sent: 'Invoice sent',
  payment_receipt: 'Payment receipt',
  review_request: 'Review request',
  follow_up: 'Follow-up',
  membership_welcome: 'Membership welcome',
  invite: 'Team invite',
};

/**
 * Templates staff may send from the inbox: every key except `invite` (staff
 * invites are emailed by the invites function). Mirrors SENDABLE_TEMPLATE_KEYS
 * in supabase/functions/messaging/send.ts.
 */
export const SENDABLE_TEMPLATE_KEYS: readonly MessageTemplateKey[] =
  Constants.public.Enums.message_template_key.filter((key) => key !== 'invite');

/**
 * Templates that may be sent without a job (send.ts CUSTOMER_TEMPLATE_KEYS),
 * as long as the shop's wording uses only customer-level placeholders; the
 * server answers `job_required` otherwise.
 */
export const CUSTOMER_TEMPLATE_KEYS: ReadonlySet<MessageTemplateKey> = new Set<MessageTemplateKey>([
  'review_request',
  'follow_up',
  'membership_welcome',
]);

/**
 * Templates about one job (dates, vehicle, services, booking / quote / invoice
 * links, amounts): the server refuses them without a job (`job_required`).
 */
export const JOB_TEMPLATE_KEYS: ReadonlySet<MessageTemplateKey> = new Set<MessageTemplateKey>(
  SENDABLE_TEMPLATE_KEYS.filter((key) => !CUSTOMER_TEMPLATE_KEYS.has(key)),
);

/** "{{job_date}}, {{vehicle}}" for refusal messages listing template variables. */
export function formatTemplateVariables(variables: readonly string[]): string {
  return variables.map((name) => `{{${name}}}`).join(', ');
}
