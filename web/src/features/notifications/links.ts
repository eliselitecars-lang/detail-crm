/**
 * Where a notification leads. Notifications carry optional job_id,
 * customer_id, quote_id and invoice_id (0031_comms_notifications.sql); the
 * most specific record wins, else the kind's section. Title and body are the
 * server's; only the destination is decided here.
 */
import type { Row } from '@/lib/db';
import type { ShopRole } from '@/features/shop/permissions';

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
const customerLink = (id: string): NotificationLink => ({
  href: `/app/customers/${id}`,
  label: 'Open customer',
});

/** The notifications list: where a kind the reader can't act on leads. */
const NOTIFICATIONS_LINK: NotificationLink = {
  href: '/app/notifications',
  label: 'Open notifications',
};

/**
 * `role` is the reader's role in the notification's shop: owner-only
 * destinations (the subscription billing page) fall back to the
 * notifications list for everyone else (e.g. a former owner after a
 * transfer).
 */
export function notificationLink(
  n: NotificationLinkInput,
  role?: ShopRole | null,
): NotificationLink | null {
  switch (n.kind) {
    case 'billing_payment_failed':
      return role === 'owner'
        ? { href: '/app/settings/billing', label: 'Open billing' }
        : NOTIFICATIONS_LINK;
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
    case 'inspection_acknowledged':
    case 'job_assigned':
    case 'job_rescheduled':
      if (n.job_id) return jobLink(n.job_id);
      return n.customer_id ? customerLink(n.customer_id) : null;
    case 'new_lead':
      return n.customer_id
        ? customerLink(n.customer_id)
        : { href: '/app/customers', label: 'Open customers' };
    case 'membership_joined':
      return { href: '/app/memberships', label: 'Open memberships' };
    case 'gift_card_purchased':
      return { href: '/app/gift-cards', label: 'Open gift cards' };
    case 'low_stock':
      return { href: '/app/inventory', label: 'Open inventory' };
    case 'task_assigned':
    case 'task_due':
      return { href: '/app/tasks', label: 'Open tasks' };
    case 'sms_number_status':
      return { href: '/app/settings/sms', label: 'Open text messaging' };
    case 'webhook_failing':
      return { href: '/app/settings/webhooks', label: 'Open webhooks' };
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
  gift_card_purchased: 'Gift card sold',
  membership_joined: 'New member',
  low_stock: 'Low stock',
  inspection_acknowledged: 'Inspection signed',
  job_assigned: 'Job assigned',
  job_rescheduled: 'Job rescheduled',
  new_lead: 'New lead',
  task_assigned: 'Task assigned',
  task_due: 'Task due',
  sms_number_status: 'Text messaging',
  webhook_failing: 'Webhook failing',
  billing_payment_failed: 'Subscription payment',
};
