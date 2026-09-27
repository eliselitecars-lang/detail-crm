/**
 * Shared fixtures for jobs/calendar tests (names only; amounts are whatever
 * the "server" returned in the test — nothing here is computed).
 */
import type { JobDetail, JobListRow } from './api';
import type { StatusTransition } from './model';

export function jobDetailRow(overrides: Partial<JobDetail> = {}): JobDetail {
  return {
    id: 'job-1',
    shop_id: 'shop-1',
    number: 1001,
    customer_id: 'cust-1',
    vehicle_id: 'veh-1',
    status: 'scheduled',
    scheduled_start: '2026-09-28T14:00:00Z',
    scheduled_end: '2026-09-28T16:00:00Z',
    location_type: 'mobile',
    service_address_line1: '1 Main St',
    service_address_line2: null,
    service_city: 'Birmingham',
    service_region: 'AL',
    service_postal_code: '35203',
    resource_id: null,
    notes: 'Gate code 1234',
    internal_notes: null,
    source: 'staff',
    quote_id: null,
    coupon_id: null,
    discount_kind: 'none',
    discount_value: 0,
    subtotal_cents: 25000,
    discount_cents: 0,
    tax_rate_bps: 875,
    tax_cents: 2188,
    total_cents: 27188,
    deposit_required_cents: 5000,
    created_at: '2026-09-20T15:00:00Z',
    updated_at: '2026-09-20T15:00:00Z',
    confirmed_at: null,
    en_route_at: null,
    started_at: null,
    completed_at: null,
    cancelled_at: null,
    cancel_reason: null,
    reminder_sent_at: null,
    review_requested_at: null,
    customer: {
      id: 'cust-1',
      first_name: 'Jane',
      last_name: 'Doe',
      company: null,
      email: 'jane@example.com',
      phone: '+12055550123',
      address_line1: '1 Main St',
      address_line2: null,
      city: 'Birmingham',
      region: 'AL',
      postal_code: '35203',
      sms_opted_out_at: null,
      email_opted_out_at: null,
    },
    vehicle: {
      id: 'veh-1',
      year: 2021,
      make: 'Honda',
      model: 'Civic',
      trim: null,
      color: 'Blue',
      vin: null,
      license_plate: 'ABC123',
      category_id: 'cat-1',
    },
    ...overrides,
  };
}

export function jobListRow(overrides: Partial<JobListRow> = {}): JobListRow {
  return {
    id: 'job-1',
    number: 1001,
    status: 'scheduled',
    scheduled_start: '2026-09-28T14:00:00Z',
    scheduled_end: '2026-09-28T16:00:00Z',
    total_cents: 27188,
    location_type: 'shop',
    customer: { id: 'cust-1', first_name: 'Jane', last_name: 'Doe', company: null },
    vehicle: { id: 'veh-1', year: 2021, make: 'Honda', model: 'Civic' },
    line_items: [
      { name: 'Wax', sort: 2 },
      { name: 'Full detail', sort: 1 },
    ],
    assignments: [{ member_id: 'member-2' }],
    ...overrides,
  };
}

const edge = (
  from: StatusTransition['from_status'],
  to: StatusTransition['to_status'],
  direction: 'forward' | 'backward',
  technician_allowed = false,
): StatusTransition => ({ from_status: from, to_status: to, direction, technician_allowed });

export const TRANSITIONS: StatusTransition[] = [
  edge('requested', 'scheduled', 'forward'),
  edge('scheduled', 'confirmed', 'forward'),
  edge('scheduled', 'en_route', 'forward', true),
  edge('scheduled', 'in_progress', 'forward', true),
  edge('scheduled', 'cancelled', 'forward'),
  edge('scheduled', 'no_show', 'forward'),
  edge('scheduled', 'requested', 'backward'),
  edge('confirmed', 'en_route', 'forward', true),
  edge('en_route', 'in_progress', 'forward', true),
  edge('in_progress', 'completed', 'forward', true),
  edge('cancelled', 'scheduled', 'backward'),
];

export const TEAM = [
  {
    member_id: 'member-1',
    user_id: 'user-1',
    role: 'owner',
    display_name: 'Olivia Owner',
    calendar_color: null,
    active: true,
    phone: null,
    email: null,
  },
  {
    member_id: 'member-2',
    user_id: 'user-2',
    role: 'technician',
    display_name: 'Theo Tech',
    calendar_color: null,
    active: true,
    phone: null,
    email: null,
  },
];
