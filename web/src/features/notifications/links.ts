/**
 * Where a notification leads. Notifications carry optional job_id,
 * customer_id, quote_id and invoice_id (0031_comms_notifications.sql); the
 * most specific record wins, else the kind's section.
 */
import type { Row } from '@/lib/db';

export type NotificationKind = Row<'notifications'>['kind'];

export type NotificationLinkInput = Pick<
  Row<'notifications'>,
  'kind' | 'job_id' | 'customer_id' | 'quote_id' | 'invoice_id'
>;

export interface NotificationLink {
  href: string;
  label: string;
}

const jobLink = (id: string): NotificationLink => ({ href: `/app/jobs/${id}`, label: 'Open job' });

export function notificationLink(n: NotificationLinkInput): NotificationLink | null {
  switch (n.kind) {
    case 'inbound_message':
      return n.customer_id
        ? {
            href: `/app/messages?customer=${encodeURIComponent(n.customer_id)}`,
            label: 'Open conversation',
          }
        : { href: '/app/messages', label: 'Open messages' };
    case 'quote_approved':
    case 'quote_declined':
      if (n.quote_id) return { href: `/app/quotes/${n.quote_id}`, label: 'Open quote' };
      return n.job_id ? jobLink(n.job_id) : { href: '/app/quotes', label: 'Open quotes' };
    case 'payment_received':
      if (n.invoice_id) return { href: `/app/invoices/${n.invoice_id}`, label: 'Open invoice' };
      return n.job_id ? jobLink(n.job_id) : { href: '/app/payments', label: 'Open payments' };
    case 'new_booking':
    case 'booking_cancelled':
    case 'form_signed':
    case 'general':
      if (n.job_id) return jobLink(n.job_id);
      return n.customer_id
        ? { href: `/app/customers/${n.customer_id}`, label: 'Open customer' }
        : null;
    default:
      return null;
  }
}

export const KIND_LABELS: Record<NotificationKind, string> = {
  new_booking: 'New booking',
  booking_cancelled: 'Booking cancelled',
  quote_approved: 'Quote approved',
  quote_declined: 'Quote declined',
  payment_received: 'Payment',
  inbound_message: 'Message',
  form_signed: 'Form signed',
  general: 'Update',
};
