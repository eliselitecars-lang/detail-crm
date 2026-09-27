/**
 * Where a notification leads. Notifications carry only an optional job_id
 * (0031_comms_notifications.sql), so other kinds open their section.
 */
import type { Row } from '@/lib/db';

export type NotificationKind = Row<'notifications'>['kind'];

export interface NotificationLinkInput {
  kind: NotificationKind;
  job_id: string | null;
}

export interface NotificationLink {
  href: string;
  label: string;
}

export function notificationLink(n: NotificationLinkInput): NotificationLink | null {
  switch (n.kind) {
    case 'inbound_message':
      return { href: '/app/messages', label: 'Open messages' };
    case 'quote_approved':
    case 'quote_declined':
      return n.job_id
        ? { href: `/app/jobs/${n.job_id}`, label: 'Open job' }
        : { href: '/app/quotes', label: 'Open quotes' };
    case 'payment_received':
      return n.job_id
        ? { href: `/app/jobs/${n.job_id}`, label: 'Open job' }
        : { href: '/app/payments', label: 'Open payments' };
    case 'new_booking':
    case 'booking_cancelled':
    case 'form_signed':
    case 'general':
      return n.job_id ? { href: `/app/jobs/${n.job_id}`, label: 'Open job' } : null;
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
