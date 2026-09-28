import { describe, expect, it } from 'vitest';
import { notificationLink, type NotificationLinkInput } from './links';

const n = (
  kind: NotificationLinkInput['kind'],
  ids: Partial<Omit<NotificationLinkInput, 'kind'>> = {},
): NotificationLinkInput => ({
  kind,
  job_id: null,
  customer_id: null,
  quote_id: null,
  invoice_id: null,
  ...ids,
});

describe('notificationLink', () => {
  it('opens the customer’s conversation for inbound messages', () => {
    expect(notificationLink(n('inbound_message', { customer_id: 'c1' }))).toEqual({
      href: '/app/messages?customer=c1',
      label: 'Open conversation',
    });
    expect(notificationLink(n('inbound_message'))?.href).toBe('/app/messages');
  });

  it('prefers the quote, then the job, for quote responses', () => {
    expect(notificationLink(n('quote_approved', { quote_id: 'q1', job_id: 'j1' }))).toEqual({
      href: '/app/quotes/q1',
      label: 'Open quote',
    });
    expect(notificationLink(n('quote_declined', { job_id: 'j1' }))?.href).toBe('/app/jobs/j1');
    expect(notificationLink(n('quote_approved'))?.href).toBe('/app/quotes');
  });

  it('prefers the invoice, then the job, for payments', () => {
    expect(
      notificationLink(
        n('payment_received', { invoice_id: 'i1', job_id: 'j1', customer_id: 'c1' }),
      ),
    ).toEqual({ href: '/app/invoices/i1', label: 'Open invoice' });
    expect(notificationLink(n('payment_received', { job_id: 'j1' }))?.href).toBe('/app/jobs/j1');
    expect(notificationLink(n('payment_received', { customer_id: 'c1' }))?.href).toBe(
      '/app/payments',
    );
  });

  it('opens the job, else the customer, for bookings, forms and general updates', () => {
    expect(notificationLink(n('new_booking', { job_id: 'j1', customer_id: 'c1' }))).toEqual({
      href: '/app/jobs/j1',
      label: 'Open job',
    });
    expect(notificationLink(n('booking_cancelled', { customer_id: 'c1' }))).toEqual({
      href: '/app/customers/c1',
      label: 'Open customer',
    });
    expect(notificationLink(n('form_signed', { job_id: 'j2' }))?.href).toBe('/app/jobs/j2');
    expect(notificationLink(n('general'))).toBeNull();
  });

  it('sends owners to Billing for a subscription payment problem, others to the list', () => {
    expect(notificationLink(n('billing_payment_failed'), 'owner')).toEqual({
      href: '/app/settings/billing',
      label: 'Open billing',
    });
    for (const role of ['admin', 'manager', 'technician'] as const) {
      expect(notificationLink(n('billing_payment_failed'), role)?.href).toBe('/app/notifications');
    }
    expect(notificationLink(n('billing_payment_failed'))?.href).toBe('/app/notifications');
  });
});
