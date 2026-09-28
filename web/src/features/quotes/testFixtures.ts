/**
 * Row factories for the money features' tests (quotes, invoices, payments,
 * memberships). Test-only: never imported by app code.
 */
import type { Row } from '@/lib/db';

export const SHOP_ID = 'shop-1';
export const CUSTOMER_ID = '30000000-0000-4000-8000-000000000001';

export function customerRow(overrides: Partial<Row<'customers'>> = {}) {
  return {
    id: CUSTOMER_ID,
    first_name: 'Jane',
    last_name: 'Doe',
    company: null,
    email: 'jane@example.com',
    phone: '+12055550123',
    archived_at: null,
    sms_opted_out_at: null,
    email_opted_out_at: null,
    ...overrides,
  };
}

export function quoteRow(overrides: Partial<Row<'quotes'>> = {}): Row<'quotes'> {
  return {
    id: 'quote-1',
    shop_id: SHOP_ID,
    number: 1001,
    customer_id: CUSTOMER_ID,
    vehicle_id: null,
    status: 'draft',
    valid_until: null,
    notes: null,
    terms: null,
    internal_notes: null,
    discount_kind: 'none',
    discount_value: 0,
    tax_rate_bps: 800,
    subtotal_cents: 25000,
    discount_cents: 0,
    tax_cents: 2000,
    total_cents: 27000,
    public_token: '40000000-0000-4000-8000-000000000001',
    sent_at: null,
    viewed_at: null,
    approved_at: null,
    approved_by_name: null,
    declined_at: null,
    declined_reason: null,
    expired_at: null,
    converted_at: null,
    converted_job_id: null,
    followups_paused: false,
    selected_option_id: null,
    self_schedule: false,
    self_scheduled_at: null,
    quote_schedule_needs: null,
    quote_self_schedule_reason: null,
    created_by: null,
    created_at: '2026-09-20T15:00:00Z',
    updated_at: '2026-09-20T15:00:00Z',
    ...overrides,
  };
}

export function quoteLineRow(
  overrides: Partial<Row<'quote_line_items'>> = {},
): Row<'quote_line_items'> {
  return {
    id: 'qli-1',
    shop_id: SHOP_ID,
    quote_id: 'quote-1',
    service_id: null,
    vehicle_id: null,
    name: 'Full detail',
    description: null,
    quantity: 1,
    unit_price_cents: 25000,
    discount_cents: 0,
    taxable: true,
    duration_minutes: 180,
    optional: false,
    selected: true,
    discount_eligible: true,
    fee_id: null,
    membership_id: null,
    option_id: null,
    sort: 1,
    total_cents: 25000,
    created_at: '2026-09-20T15:00:00Z',
    updated_at: '2026-09-20T15:00:00Z',
    ...overrides,
  };
}

export function invoiceRow(overrides: Partial<Row<'invoices'>> = {}): Row<'invoices'> {
  return {
    id: 'inv-1',
    shop_id: SHOP_ID,
    number: 2001,
    job_id: null,
    customer_id: CUSTOMER_ID,
    status: 'open',
    issued_at: '2026-09-20T15:00:00Z',
    due_at: '2026-10-20T15:00:00Z',
    sent_at: '2026-09-20T15:00:00Z',
    paid_at: null,
    voided_at: null,
    void_reason: null,
    notes: null,
    terms: null,
    internal_notes: null,
    discount_kind: 'none',
    discount_value: 0,
    tax_rate_bps: 0,
    subtotal_cents: 30000,
    discount_cents: 0,
    tax_cents: 0,
    total_cents: 30000,
    amount_paid_cents: 10000,
    balance_cents: 20000,
    tip_cents: 0,
    followups_paused: false,
    public_token: '50000000-0000-4000-8000-000000000001',
    created_by: null,
    created_at: '2026-09-20T15:00:00Z',
    updated_at: '2026-09-20T15:00:00Z',
    ...overrides,
  };
}

export function invoiceLineRow(
  overrides: Partial<Row<'invoice_line_items'>> = {},
): Row<'invoice_line_items'> {
  return {
    id: 'ili-1',
    shop_id: SHOP_ID,
    invoice_id: 'inv-1',
    service_id: null,
    vehicle_id: null,
    name: 'Ceramic coating',
    description: null,
    quantity: 1,
    unit_price_cents: 30000,
    discount_cents: 0,
    taxable: true,
    discount_eligible: true,
    fee_id: null,
    job_id: null,
    membership_id: null,
    sort: 1,
    total_cents: 30000,
    created_at: '2026-09-20T15:00:00Z',
    updated_at: '2026-09-20T15:00:00Z',
    ...overrides,
  };
}

export function paymentRow(overrides: Partial<Row<'payments'>> = {}): Row<'payments'> {
  return {
    id: 'pay-1',
    shop_id: SHOP_ID,
    invoice_id: 'inv-1',
    job_id: null,
    customer_id: CUSTOMER_ID,
    membership_id: null,
    kind: 'payment',
    method: 'card',
    status: 'succeeded',
    amount_cents: 10000,
    tip_cents: 1500,
    refunded_cents: 0,
    disputed_cents: 0,
    stripe_payment_intent_id: 'pi_123',
    stripe_charge_id: 'ch_123',
    stripe_checkout_session_id: null,
    card_brand: 'visa',
    card_last4: '4242',
    stripe_method_type: null,
    note: null,
    recorded_by: null,
    paid_at: '2026-09-21T15:00:00Z',
    created_at: '2026-09-21T15:00:00Z',
    updated_at: '2026-09-21T15:00:00Z',
    ...overrides,
  };
}

export function planRow(overrides: Partial<Row<'membership_plans'>> = {}): Row<'membership_plans'> {
  return {
    id: 'plan-1',
    shop_id: SHOP_ID,
    name: 'Maintenance Club',
    description: null,
    price_cents: 4900,
    interval: 'month',
    interval_count: 1,
    included_service_ids: [],
    discount_bps: 1000,
    included_uses_per_period: null,
    online_joinable: false,
    terms: null,
    active: true,
    sort: 0,
    stripe_product_id: null,
    stripe_price_id: null,
    archived_at: null,
    created_at: '2026-09-01T15:00:00Z',
    updated_at: '2026-09-01T15:00:00Z',
    ...overrides,
  };
}
