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

export const inboxMessageSchema = messageSchema.extend({
  customer: threadCustomerSchema.nullable(),
});
export type InboxMessage = z.infer<typeof inboxMessageSchema>;

export const unreadRowSchema = z.object({
  id: z.string(),
  customer_id: z.string().nullable(),
  from_address: z.string().nullable(),
  created_at: z.string(),
});
export type UnreadRow = z.infer<typeof unreadRowSchema>;

/**
 * Which conversation a thread is. Customers are keyed by id; inbound texts
 * from numbers that match no customer (customer_id null) are grouped by the
 * sender's number until someone adds that customer (the server then attaches
 * them automatically).
 */
export type ThreadRef =
  { kind: 'customer'; customerId: string } | { kind: 'unknown'; from: string };

export function threadKey(ref: ThreadRef): string {
  return ref.kind === 'customer' ? `c:${ref.customerId}` : `u:${ref.from}`;
}

export function refForMessage(m: {
  customer_id: string | null;
  direction: string;
  from_address: string | null;
}): ThreadRef | null {
  if (m.customer_id) return { kind: 'customer', customerId: m.customer_id };
  if (m.direction === 'inbound' && m.from_address) return { kind: 'unknown', from: m.from_address };
  return null;
}

export interface ThreadSummary {
  key: string;
  ref: ThreadRef;
  customer: ThreadCustomer | null;
  last: InboxMessage;
  unread: number;
}

/**
 * Groups messages (newest first) into one thread per customer / unknown
 * sender, newest thread first, with unread counts (inbound, read_at null).
 */
export function buildThreads(
  messages: readonly InboxMessage[],
  unread: readonly Pick<UnreadRow, 'customer_id' | 'from_address'>[],
): ThreadSummary[] {
  const unreadByKey = new Map<string, number>();
  for (const row of unread) {
    const ref = refForMessage({ ...row, direction: 'inbound' });
    if (!ref) continue;
    const key = threadKey(ref);
    unreadByKey.set(key, (unreadByKey.get(key) ?? 0) + 1);
  }

  const threads = new Map<string, ThreadSummary>();
  const sorted = [...messages].sort((a, b) => b.created_at.localeCompare(a.created_at));
  for (const message of sorted) {
    const ref = refForMessage(message);
    if (!ref) continue;
    const key = threadKey(ref);
    const existing = threads.get(key);
    if (existing) {
      if (!existing.customer && message.customer) existing.customer = message.customer;
      continue;
    }
    threads.set(key, {
      key,
      ref,
      customer: message.customer,
      last: message,
      unread: unreadByKey.get(key) ?? 0,
    });
  }
  return [...threads.values()];
}

/**
 * Ids of the newest unread message of every thread that has unread messages
 * but is not among `presentKeys` (the threads built from the newest page of
 * the whole inbox). A campaign launch inserts one outbound row per recipient
 * at once, which can push every older conversation — including ones with
 * unread replies — out of that page; fetching these rows keeps unread
 * conversations in the list whatever the page holds. Newest threads first,
 * at most `max`.
 */
export function unreadThreadsOutside(
  presentKeys: ReadonlySet<string>,
  unread: readonly UnreadRow[],
  max: number,
): string[] {
  const newest = new Map<string, UnreadRow>();
  for (const row of unread) {
    const ref = refForMessage({ ...row, direction: 'inbound' });
    if (!ref) continue;
    const key = threadKey(ref);
    if (presentKeys.has(key)) continue;
    const current = newest.get(key);
    if (!current || row.created_at > current.created_at) newest.set(key, row);
  }
  return [...newest.values()]
    .sort((a, b) => b.created_at.localeCompare(a.created_at))
    .slice(0, max)
    .map((row) => row.id);
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
export function messagePreview(m: Pick<Message, 'body' | 'subject' | 'channel'>): string {
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

/** Template keys whose wording refers to a job ({{job_date}}, {{services}}, links…). */
export const JOB_TEMPLATE_KEYS: ReadonlySet<MessageTemplateKey> = new Set<MessageTemplateKey>([
  'booking_request_received',
  'booking_confirmed',
  'appointment_reminder',
  'on_the_way',
  'job_started',
  'job_completed',
  'quote_sent',
  'invoice_sent',
  'payment_receipt',
  'review_request',
  'follow_up',
]);
