/** Test fixtures for dashboard specs (shapes of dashboard_summary / calendar_events). */
export const shopSummary = {
  shop_id: 'shop-1',
  timezone: 'America/Chicago',
  as_of: '2026-09-27T15:00:00Z',
  scope: 'shop',
  today: '2026-09-27',
  week_start: '2026-09-21',
  month_start: '2026-09-01',
  jobs_today: {
    total: 3,
    by_status: {
      requested: 0,
      scheduled: 2,
      confirmed: 1,
      en_route: 0,
      in_progress: 0,
      completed: 0,
      cancelled: 1,
      no_show: 0,
    },
  },
  next_job: {
    id: 'job-1',
    number: 1042,
    status: 'confirmed',
    scheduled_start: '2026-09-27T16:00:00Z',
    scheduled_end: '2026-09-27T18:00:00Z',
    location_type: 'mobile',
    customer_id: 'c-1',
    customer_name: 'Jane Doe',
    vehicle_id: 'v-1',
    vehicle_label: '2021 Toyota Camry',
    assigned_member_ids: ['member-1'],
  },
  jobs_this_week: 12,
  pending_booking_requests: 1,
  quotes_awaiting_response: 4,
  open_invoices: { count: 5, balance_cents: 123456 },
  overdue_invoices: { count: 2, balance_cents: 45000 },
  revenue: {
    today: { net_cents: 25000, tips_cents: 2000, payments_count: 2 },
    week: { net_cents: 150000, tips_cents: 9000, payments_count: 9 },
    month: { net_cents: 610000, tips_cents: 30000, payments_count: 31 },
  },
  unread_inbound_messages: 3,
  clocked_in: {
    count: 1,
    members: [
      {
        member_id: 'member-2',
        display_name: 'Theo Tech',
        since: '2026-09-27T13:05:00Z',
        job_id: null,
      },
    ],
  },
};

export const techSummary = {
  ...shopSummary,
  scope: 'own',
  pending_booking_requests: null,
  quotes_awaiting_response: null,
  open_invoices: null,
  overdue_invoices: null,
  revenue: null,
  unread_inbound_messages: null,
  next_job: null,
  clocked_in: { count: 0, members: [] },
};

export function scheduleRow(overrides: Record<string, unknown> = {}) {
  return {
    event_type: 'job',
    id: 'job-1',
    job_number: 1042,
    status: 'confirmed',
    starts_at: '2026-09-27T16:00:00Z',
    ends_at: '2026-09-27T18:00:00Z',
    is_busy_block: false,
    customer_id: 'c-1',
    customer_name: 'Jane Doe',
    vehicle_id: 'v-1',
    vehicle_label: '2021 Toyota Camry',
    location_type: 'mobile',
    service_address: '1 Main St, Birmingham',
    resource_id: null,
    assigned_member_ids: ['member-1'],
    member_id: null,
    title: 'Jane Doe — Full Detail, Ceramic Coating',
    ...overrides,
  };
}
