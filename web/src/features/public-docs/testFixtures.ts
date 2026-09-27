/** Test fixtures for the public document pages (tests only). */
import type { FormDocument, InvoiceDocument, QuoteDocument } from './api';
import type { PublicShop } from './shared/schemas';

export const DOC_TOKEN = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';
export const OPT_A = 'ffffffff-ffff-4fff-8fff-fffffffffff1';
export const OPT_B = 'ffffffff-ffff-4fff-8fff-fffffffffff2';

export function shopFixture(overrides: Partial<PublicShop> = {}): PublicShop {
  return {
    name: 'Glacier Detailing',
    slug: 'glacier',
    logo_path: null,
    brand_color: '#1F6FEB',
    email: 'hello@glacier.test',
    phone: '+12055550100',
    website: null,
    address_line1: '1 Main St',
    address_line2: null,
    city: 'Birmingham',
    region: 'AL',
    postal_code: '35203',
    country: 'US',
    timezone: 'America/Chicago',
    currency: 'usd',
    review_url: null,
    ...overrides,
  };
}

const line = (name: string, cents: number) => ({
  name,
  description: null,
  vehicle_label: '2021 Toyota Camry',
  quantity: 1,
  unit_price_cents: cents,
  discount_cents: 0,
  taxable: true,
  total_cents: cents,
});

export function quoteFixture(overrides: Partial<QuoteDocument['quote']> = {}): QuoteDocument {
  return {
    shop: shopFixture(),
    quote: {
      number: 301,
      status: 'viewed',
      valid_until: '2099-12-31',
      expires_at: null,
      notes: 'Thanks for the opportunity.',
      terms: null,
      subtotal_cents: 50000,
      discount_cents: 0,
      tax_rate_bps: 800,
      tax_cents: 4000,
      total_cents: 54000,
      sent_at: '2026-09-20T15:00:00Z',
      viewed_at: '2026-09-21T15:00:00Z',
      approved_at: null,
      approved_by_name: null,
      declined_at: null,
      declined_reason: null,
      expired_at: null,
      can_respond: true,
      ...overrides,
    },
    customer: { first_name: 'Ana', last_name: 'Diaz', company: null },
    vehicle: { year: 2021, make: 'Toyota', model: 'Camry', trim: null, color: null },
    line_items: [
      { ...line('Paint correction', 50000), id: 'l-1', optional: false, selected: true },
      { ...line('Wheel coating', 15000), id: OPT_A, optional: true, selected: false },
      { ...line('Glass coating', 8000), id: OPT_B, optional: true, selected: true },
    ],
  };
}

export function invoiceFixture(
  overrides: Partial<InvoiceDocument['invoice']> = {},
): InvoiceDocument {
  return {
    shop: shopFixture(),
    invoice: {
      number: 2001,
      status: 'partially_paid',
      issued_at: '2026-09-20T15:00:00Z',
      due_at: '2099-10-20T15:00:00Z',
      paid_at: null,
      voided_at: null,
      notes: null,
      terms: 'Due on receipt.',
      subtotal_cents: 30000,
      discount_cents: 0,
      tax_rate_bps: 0,
      tax_cents: 0,
      total_cents: 30000,
      amount_paid_cents: 10000,
      balance_cents: 20000,
      tip_cents: 0,
      payable: true,
      card_payments_enabled: true,
      ...overrides,
    },
    customer: { first_name: 'Ana', last_name: 'Diaz', company: null },
    job: { number: 1042, scheduled_start: '2026-09-19T15:00:00Z', scheduled_end: null },
    vehicle: { year: 2021, make: 'Toyota', model: 'Camry', trim: null, color: null },
    line_items: [line('Full detail', 30000)],
    payments: [
      {
        kind: 'deposit',
        method: 'card',
        status: 'succeeded',
        amount_cents: 10000,
        tip_cents: 0,
        refunded_cents: 0,
        card_brand: 'visa',
        card_last4: '4242',
        paid_at: '2026-09-18T15:00:00Z',
      },
    ],
  };
}

export function formFixture(overrides: Partial<FormDocument['form']> = {}): FormDocument {
  return {
    shop: {
      name: 'Glacier Detailing',
      slug: 'glacier',
      logo_path: null,
      brand_color: null,
      timezone: 'America/Chicago',
    },
    form: {
      title: 'Vehicle waiver',
      body: '# Waiver\n\nI agree to **the terms**.\n\n- Remove valuables',
      requires_signature: true,
      status: 'pending',
      signer_name: null,
      signed_at: null,
      ...overrides,
    },
    job: {
      number: 1042,
      scheduled_start: '2026-10-01T14:00:00Z',
      scheduled_end: null,
      vehicle: '2021 Toyota Camry',
    },
    customer: null,
    signature_upload_prefix: `shop-1/forms/${DOC_TOKEN}/`,
  };
}
