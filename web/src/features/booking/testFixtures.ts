/** Test fixtures for the booking feature (unit/component tests only). */
import { addLocalDays, shopLocalToUtcIso, shopToday } from '@/lib/dates';
import type { BookingCatalog, BookingDocument, ShopProfile } from './api';

export const TZ = 'America/Chicago';
export const SEDAN = '11111111-1111-4111-8111-111111111111';
export const TRUCK = '22222222-2222-4222-8222-222222222222';
export const WASH = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1';
export const COAT = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2';
export const WAX = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1';
export const PET = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2';
export const TOKEN = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';

export function profileFixture(overrides: Partial<ShopProfile> = {}): ShopProfile {
  return {
    name: 'Glacier Detailing',
    slug: 'glacier',
    logo_path: null,
    brand_color: '#1F6FEB',
    phone: '+12055550100',
    website: null,
    city: 'Birmingham',
    region: 'AL',
    country: 'US',
    timezone: TZ,
    currency: 'usd',
    business_type: 'both',
    tax_rate_bps: 0,
    booking: {
      enabled: true,
      auto_confirm: false,
      lead_time_minutes: 60,
      max_days_ahead: 60,
      slot_interval_minutes: 30,
      require_deposit: true,
      deposit_type: 'percent',
      deposit_value: 2000,
      service_area_limited: false,
      booking_message: null,
      cancellation_policy: 'Cancel 24 hours ahead.',
      allow_client_cancel_hours: 24,
    },
    tracking: { meta_pixel_id: null, ga4_measurement_id: null },
    ...overrides,
  };
}

const price = (vehicle_category_id: string, price_cents: number) => ({
  vehicle_category_id,
  price_cents,
  duration_minutes: 90,
});

export function catalogFixture(): BookingCatalog {
  return {
    vehicle_categories: [
      { id: SEDAN, name: 'Sedan' },
      { id: TRUCK, name: 'Truck' },
    ],
    service_categories: [{ id: 'sc-1', name: 'Detailing', bookable_weekdays: null }],
    services: [
      {
        id: WASH,
        category_id: 'sc-1',
        name: 'Full detail',
        description: 'Inside and out',
        kind: 'service',
        image_path: null,
        duration_minutes: 120,
        base_price_cents: 15000,
        prices: [price(SEDAN, 15000), price(TRUCK, 20000)],
        includes: [],
        addon_ids: [WAX, PET],
      },
      {
        id: COAT,
        category_id: 'sc-1',
        name: 'Ceramic coating',
        description: null,
        kind: 'package',
        image_path: null,
        duration_minutes: 480,
        base_price_cents: null,
        prices: [price(SEDAN, 90000)],
        includes: ['Paint correction'],
        addon_ids: [WAX],
      },
    ],
    addons: [
      {
        id: WAX,
        category_id: null,
        name: 'Hand wax',
        description: null,
        kind: 'addon',
        image_path: null,
        duration_minutes: 30,
        base_price_cents: 4000,
        prices: [price(SEDAN, 4000), price(TRUCK, 5000)],
      },
      {
        id: PET,
        category_id: null,
        name: 'Pet hair removal',
        description: null,
        kind: 'addon',
        image_path: null,
        duration_minutes: 30,
        base_price_cents: 3000,
        prices: [price(SEDAN, 3000)],
      },
    ],
  };
}

/** Slots on the shop-local day after today (so they are always in the first week shown). */
export function slotsFixture(): { starts_at: string; ends_at: string }[] {
  const day = addLocalDays(shopToday(TZ), 1);
  return ['09:00', '11:30'].map((time) => {
    const start = shopLocalToUtcIso(day, time, TZ);
    return { starts_at: start, ends_at: new Date(Date.parse(start) + 90 * 60_000).toISOString() };
  });
}

export function bookingDocFixture(overrides: Partial<BookingDocument> = {}): BookingDocument {
  const start = slotsFixture()[0]?.starts_at ?? '2026-10-01T14:00:00.000Z';
  return {
    shop: {
      name: 'Glacier Detailing',
      slug: 'glacier',
      logo_path: null,
      brand_color: null,
      email: 'hello@glacier.test',
      phone: '+12055550100',
      website: null,
      address_line1: '1 Main St',
      address_line2: null,
      city: 'Birmingham',
      region: 'AL',
      postal_code: '35203',
      country: 'US',
      timezone: TZ,
      currency: 'usd',
      review_url: null,
    },
    booking_message: null,
    booking: {
      number: 1042,
      status: 'scheduled',
      scheduled_start: start,
      scheduled_end: new Date(Date.parse(start) + 90 * 60_000).toISOString(),
      location_type: 'shop',
      service_address: null,
      notes: null,
      created_at: '2026-09-01T00:00:00Z',
      confirmed_at: null,
      completed_at: null,
      cancelled_at: null,
      cancel_reason: null,
    },
    vehicle: { year: 2021, make: 'Toyota', model: 'Camry', trim: null, color: 'Blue' },
    line_items: [
      {
        name: 'Full detail',
        description: null,
        vehicle_label: '2021 Toyota Camry',
        quantity: 1,
        unit_price_cents: 15000,
        discount_cents: 0,
        taxable: true,
        total_cents: 15000,
      },
    ],
    totals: {
      subtotal_cents: 15000,
      discount_cents: 0,
      coupon_code: null,
      tax_rate_bps: 0,
      tax_cents: 0,
      total_cents: 15000,
      paid_cents: 0,
      balance_cents: 15000,
    },
    deposit: {
      required_cents: 3000,
      paid_cents: 0,
      due_cents: 3000,
      status: 'due',
      payment_pending: false,
      card_payments_enabled: true,
    },
    cancellation: {
      allowed: true,
      deadline: new Date(Date.parse(start) - 24 * 3_600_000).toISOString(),
      allow_client_cancel_hours: 24,
      policy: 'Cancel 24 hours ahead.',
    },
    forms: [
      {
        title: 'Vehicle waiver',
        requires_signature: true,
        status: 'pending',
        signed_at: null,
        token: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
      },
    ],
    invoice: null,
    ...overrides,
  };
}
