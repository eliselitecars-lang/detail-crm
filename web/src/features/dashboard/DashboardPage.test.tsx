import { screen, waitFor, within } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi, type Mock } from 'vitest';
import { membership, renderRoute, shopValue, signedInAuth } from '@/test/render';
import {
  builders,
  createBuilder,
  resetSupabaseMock,
  setFunctionResult,
  setTableResult,
  supabase,
  type Builder,
  type MockResult,
} from '@/test/supabaseMock';
import DashboardPage from './DashboardPage';
import { scheduleRow, shopSummary, techSummary } from './fixtures.test-data';
import { DECLINE_PAYMENT_IN_PROGRESS, REQUEST_ALREADY_HANDLED } from './api';
import {
  customerFromTitle,
  dashboardSummarySchema,
  formatDuration,
  scheduleCustomerLabel,
  servicesFromTitle,
} from './summary';

vi.mock('@/lib/supabase', () => import('@/test/supabaseMock'));

const rpc = supabase.rpc as unknown as Mock<(name: string, args?: unknown) => Builder>;
let rpcResults: Record<string, MockResult> = {};

beforeEach(() => {
  resetSupabaseMock();
  rpcResults = {};
  rpc.mockImplementation((name: string) => createBuilder(rpcResults[name] ?? { data: null }));
});

const RELEASED = {
  invoice_id: null,
  job_id: 'job-9',
  cancelled: 0,
  succeeded: 0,
  in_progress: 0,
  sessions_expired: 1,
};

function setup(role: 'owner' | 'technician' = 'owner') {
  return renderRoute(<DashboardPage />, {
    path: '/app',
    routePath: '/app',
    auth: signedInAuth(),
    shop: shopValue({ membership: membership({ role }) }),
  });
}

describe('dashboard summary helpers', () => {
  it('validates the RPC shape', () => {
    expect(dashboardSummarySchema.safeParse(shopSummary).success).toBe(true);
    expect(dashboardSummarySchema.safeParse(techSummary).success).toBe(true);
    expect(
      dashboardSummarySchema.safeParse({ ...shopSummary, revenue: { today: 1 } }).success,
    ).toBe(false);
  });

  it('formats durations and extracts services from calendar titles', () => {
    expect(formatDuration(0)).toBe('0m');
    expect(formatDuration(45 * 60)).toBe('45m');
    expect(formatDuration(7 * 3600 + 5 * 60 + 59)).toBe('7h 05m');
    expect(servicesFromTitle('Jane — Full Detail')).toBe('Full Detail');
    expect(servicesFromTitle('Jane')).toBeNull();
    expect(servicesFromTitle(null)).toBeNull();
  });

  it('labels company-only (fleet) customers from the calendar title', () => {
    expect(customerFromTitle('Acme Fleet — Full Detail')).toBe('Acme Fleet');
    expect(customerFromTitle('Acme Fleet')).toBe('Acme Fleet');
    expect(customerFromTitle(null)).toBeNull();
    expect(scheduleCustomerLabel({ customer_name: 'Jane Doe', title: 'Jane Doe — X' })).toBe(
      'Jane Doe',
    );
    expect(scheduleCustomerLabel({ customer_name: null, title: 'Acme Fleet — Wash' })).toBe(
      'Acme Fleet',
    );
    expect(scheduleCustomerLabel({ customer_name: null, title: null })).toBe('Customer');
  });
});

describe('DashboardPage (manager+)', () => {
  it('shows money tiles, schedule, next job and who is clocked in', async () => {
    rpcResults.dashboard_summary = { data: shopSummary };
    rpcResults.calendar_events = {
      data: [scheduleRow(), scheduleRow({ id: 'busy', is_busy_block: true, customer_name: null })],
    };
    rpcResults.report_team = { data: [{ member_id: 'member-1', worked_seconds: 3 * 3600 }] };
    setTableResult('jobs', { data: [] });
    setTableResult('time_entries', { data: [] });
    setup();

    expect(await screen.findByText('$250.00')).toBeInTheDocument();
    expect(screen.getByText('2 payments · $20.00 tips (not in revenue)')).toBeInTheDocument();
    expect(screen.getByText('$1,500.00')).toBeInTheDocument();
    expect(screen.getByText('$6,100.00')).toBeInTheDocument();
    expect(screen.getByText('$1,234.56')).toBeInTheDocument();
    expect(screen.getByText('$450.00')).toBeInTheDocument();
    expect(screen.getByText('3 unread messages')).toBeInTheDocument();
    expect(screen.getByRole('link', { name: /Quotes out/ })).toHaveAttribute(
      'href',
      '/app/quotes?status=sent',
    );

    const schedule = screen.getByRole('region', { name: 'Today’s schedule' });
    const job = await within(schedule).findByRole('link', { name: /Jane Doe/ });
    expect(job).toHaveAttribute('href', '/app/jobs/job-1');
    expect(
      within(schedule).getByText('2021 Toyota Camry · Full Detail, Ceramic Coating'),
    ).toBeInTheDocument();
    expect(within(schedule).getByText('11:00 AM – 1:00 PM')).toBeInTheDocument();

    expect(screen.getByRole('region', { name: 'On the clock' })).toHaveTextContent('Theo Tech');
    expect(await screen.findByText('3h 00m')).toBeInTheDocument();
    expect(rpc).toHaveBeenCalledWith('calendar_events', {
      p_shop_id: 'shop-1',
      p_from: '2026-09-27T05:00:00.000Z',
      p_to: '2026-09-28T05:00:00.000Z',
    });
    expect(rpc).toHaveBeenCalledWith('report_team', {
      p_shop_id: 'shop-1',
      p_from: '2026-09-21',
      p_to: '2026-09-27',
    });
  });

  it('approves and declines booking requests', async () => {
    rpcResults.dashboard_summary = { data: shopSummary };
    setFunctionResult('payments', { data: RELEASED });
    rpcResults.calendar_events = { data: [] };
    setTableResult('time_entries', { data: [] });
    setTableResult('customers', {
      data: [{ id: 'c-9', first_name: 'Sam', last_name: 'Lee', company: null }],
    });
    setTableResult('jobs', {
      data: [
        {
          id: 'job-9',
          number: 1050,
          scheduled_start: '2026-09-29T14:00:00Z',
          scheduled_end: '2026-09-29T16:00:00Z',
          location_type: 'shop',
          created_at: '2026-09-26T10:00:00Z',
          customer_id: 'c-9',
        },
      ],
    });
    const { user } = setup();
    const requests = await screen.findByRole('region', { name: 'Booking requests' });
    await within(requests).findByText(/Sam Lee/);

    await user.click(
      within(requests).getByRole('button', { name: 'Approve booking from Sam Lee' }),
    );
    await waitFor(() =>
      expect(builders.jobs?.some((b) => b.update.mock.calls.length > 0)).toBe(true),
    );
    const approve = builders.jobs?.find((b) => b.update.mock.calls.length > 0);
    expect(approve?.update).toHaveBeenCalledWith({ status: 'scheduled' });
    expect(approve?.eq).toHaveBeenCalledWith('status', 'requested');

    await user.click(
      within(requests).getByRole('button', { name: 'Decline booking from Sam Lee' }),
    );
    const dialog = await screen.findByRole('alertdialog', { name: 'Decline this booking?' });
    const confirm = within(dialog).getByRole('button', { name: 'Decline booking' });
    expect(confirm).toBeDisabled();
    await user.type(within(dialog).getByLabelText(/Reason/), 'Fully booked that day');
    await user.click(confirm);
    await waitFor(() =>
      expect(
        builders.jobs?.some((b) =>
          b.update.mock.calls.some(([p]) => (p as { status?: string }).status === 'cancelled'),
        ),
      ).toBe(true),
    );
    const decline = builders.jobs?.find((b) =>
      b.update.mock.calls.some(([p]) => (p as { status?: string }).status === 'cancelled'),
    );
    expect(decline?.update).toHaveBeenCalledWith({
      status: 'cancelled',
      cancel_reason: 'Fully booked that day',
    });
    // The open deposit Checkout / sheet is released before the job is cancelled.
    expect(supabase.functions.invoke).toHaveBeenCalledWith('payments', {
      body: { action: 'cancel_open_payments', shop_id: 'shop-1', job_id: 'job-9' },
    });
    expect(supabase.functions.invoke.mock.invocationCallOrder[0]).toBeLessThan(
      decline!.update.mock.invocationCallOrder[0]!,
    );
    expect(await screen.findByText('Booking declined')).toBeInTheDocument();
  });

  it('keeps a request when its deposit payment is still processing', async () => {
    rpcResults.dashboard_summary = { data: shopSummary };
    rpcResults.calendar_events = { data: [] };
    setFunctionResult('payments', { data: { ...RELEASED, in_progress: 1 } });
    setTableResult('time_entries', { data: [] });
    setTableResult('customers', {
      data: [{ id: 'c-9', first_name: 'Sam', last_name: 'Lee', company: null }],
    });
    setTableResult('jobs', {
      data: [
        {
          id: 'job-9',
          number: 1050,
          scheduled_start: '2026-09-29T14:00:00Z',
          scheduled_end: '2026-09-29T16:00:00Z',
          location_type: 'shop',
          created_at: '2026-09-26T10:00:00Z',
          customer_id: 'c-9',
        },
      ],
    });
    const { user } = setup();
    const requests = await screen.findByRole('region', { name: 'Booking requests' });
    await within(requests).findByText(/Sam Lee/);
    await user.click(
      within(requests).getByRole('button', { name: 'Decline booking from Sam Lee' }),
    );
    const dialog = await screen.findByRole('alertdialog', { name: 'Decline this booking?' });
    await user.type(within(dialog).getByLabelText(/Reason/), 'Fully booked');
    await user.click(within(dialog).getByRole('button', { name: 'Decline booking' }));
    expect(await within(dialog).findByText(DECLINE_PAYMENT_IN_PROGRESS)).toBeInTheDocument();
    expect(
      builders.jobs?.some((b) =>
        b.update.mock.calls.some(([p]) => (p as { status?: string }).status === 'cancelled'),
      ),
    ).toBe(false);
  });

  it('says so when a deposit had already been paid for a declined request', async () => {
    rpcResults.dashboard_summary = { data: shopSummary };
    rpcResults.calendar_events = { data: [] };
    setFunctionResult('payments', { data: { ...RELEASED, succeeded: 1 } });
    setTableResult('time_entries', { data: [] });
    setTableResult('customers', {
      data: [{ id: 'c-9', first_name: 'Sam', last_name: 'Lee', company: null }],
    });
    setTableResult('jobs', {
      data: [
        {
          id: 'job-9',
          number: 1050,
          scheduled_start: '2026-09-29T14:00:00Z',
          scheduled_end: '2026-09-29T16:00:00Z',
          location_type: 'shop',
          created_at: '2026-09-26T10:00:00Z',
          customer_id: 'c-9',
        },
      ],
    });
    const { user } = setup();
    const requests = await screen.findByRole('region', { name: 'Booking requests' });
    await within(requests).findByText(/Sam Lee/);
    await user.click(
      within(requests).getByRole('button', { name: 'Decline booking from Sam Lee' }),
    );
    const dialog = await screen.findByRole('alertdialog', { name: 'Decline this booking?' });
    await user.type(within(dialog).getByLabelText(/Reason/), 'Fully booked');
    await user.click(within(dialog).getByRole('button', { name: 'Decline booking' }));
    expect(await screen.findByText(/A card payment had already gone through/)).toBeInTheDocument();
  });

  it('shows fleet jobs on today’s schedule by company name', async () => {
    rpcResults.dashboard_summary = { data: shopSummary };
    rpcResults.calendar_events = {
      data: [scheduleRow({ customer_name: null, title: 'Acme Fleet — Exterior Wash' })],
    };
    setTableResult('jobs', { data: [] });
    setTableResult('time_entries', { data: [] });
    setup();
    const schedule = await screen.findByRole('region', { name: 'Today’s schedule' });
    const job = await within(schedule).findByRole('link', { name: /Acme Fleet/ });
    expect(job).toHaveAttribute('href', '/app/jobs/job-1');
    expect(within(schedule).queryByText(/^Customer/)).not.toBeInTheDocument();
  });

  it('says so when a request was already handled elsewhere (no false success)', async () => {
    rpcResults.dashboard_summary = { data: shopSummary };
    rpcResults.calendar_events = { data: [] };
    setTableResult('time_entries', { data: [] });
    setTableResult('customers', {
      data: [{ id: 'c-9', first_name: 'Sam', last_name: 'Lee', company: null }],
    });
    const request = {
      id: 'job-9',
      number: 1050,
      scheduled_start: '2026-09-29T14:00:00Z',
      scheduled_end: '2026-09-29T16:00:00Z',
      location_type: 'shop',
      created_at: '2026-09-26T10:00:00Z',
      customer_id: 'c-9',
    };
    setTableResult('jobs', { data: [request] });
    const { user } = setup();
    const requests = await screen.findByRole('region', { name: 'Booking requests' });
    await within(requests).findByText(/Sam Lee/);

    // Someone else approved it: the guarded update matches zero rows.
    setTableResult('jobs', { data: [] });
    await user.click(
      within(requests).getByRole('button', { name: 'Approve booking from Sam Lee' }),
    );
    expect(await screen.findByText(REQUEST_ALREADY_HANDLED)).toBeInTheDocument();
    expect(screen.queryByText('Booking approved')).not.toBeInTheDocument();
    const approve = builders.jobs?.find((b) => b.update.mock.calls.length > 0);
    expect(approve?.select).toHaveBeenCalledWith('id');
    expect(await within(requests).findByText('No requests waiting')).toBeInTheDocument();
  });

  it('closes the decline dialog with a notice when the request was already handled', async () => {
    rpcResults.dashboard_summary = { data: shopSummary };
    setFunctionResult('payments', { data: RELEASED });
    rpcResults.calendar_events = { data: [] };
    setTableResult('time_entries', { data: [] });
    setTableResult('customers', {
      data: [{ id: 'c-9', first_name: 'Sam', last_name: 'Lee', company: null }],
    });
    setTableResult('jobs', {
      data: [
        {
          id: 'job-9',
          number: 1050,
          scheduled_start: '2026-09-29T14:00:00Z',
          scheduled_end: '2026-09-29T16:00:00Z',
          location_type: 'shop',
          created_at: '2026-09-26T10:00:00Z',
          customer_id: 'c-9',
        },
      ],
    });
    const { user } = setup();
    const requests = await screen.findByRole('region', { name: 'Booking requests' });
    await within(requests).findByText(/Sam Lee/);
    await user.click(
      within(requests).getByRole('button', { name: 'Decline booking from Sam Lee' }),
    );
    const dialog = await screen.findByRole('alertdialog', { name: 'Decline this booking?' });
    await user.type(within(dialog).getByLabelText(/Reason/), 'Fully booked');
    setTableResult('jobs', { data: [] });
    await user.click(within(dialog).getByRole('button', { name: 'Decline booking' }));
    expect(await screen.findByText(REQUEST_ALREADY_HANDLED)).toBeInTheDocument();
    await waitFor(() =>
      expect(screen.queryByRole('alertdialog', { name: 'Decline this booking?' })).toBeNull(),
    );
    expect(screen.queryByText('Booking declined')).not.toBeInTheDocument();
  });

  it('shows an error with retry when the summary fails', async () => {
    rpcResults.dashboard_summary = {
      data: null,
      error: { code: '42501', message: 'not a member of this shop' },
    };
    setup();
    expect(await screen.findByText('Not a member of this shop.')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Try again' })).toBeInTheDocument();
    expect(screen.getByRole('heading', { name: 'Dashboard', level: 1 })).toBeInTheDocument();
  });
});

describe('DashboardPage (technician)', () => {
  it('shows my jobs, no money, and clocks in', async () => {
    rpcResults.dashboard_summary = { data: techSummary };
    rpcResults.calendar_events = {
      data: [
        scheduleRow(),
        scheduleRow({
          id: 'job-2',
          customer_name: 'Other Person',
          assigned_member_ids: ['member-7'],
        }),
      ],
    };
    rpcResults.report_team = { data: [{ member_id: 'member-1', worked_seconds: 5400 }] };
    rpcResults.clock_in = { data: { id: 't-1' } };
    setTableResult('time_entries', { data: [] });
    const { user } = setup('technician');

    const mine = await screen.findByRole('region', { name: 'My jobs today' });
    expect(await within(mine).findByText(/Jane Doe/)).toBeInTheDocument();
    expect(within(mine).queryByText(/Other Person/)).not.toBeInTheDocument();
    expect(screen.queryByText(/Revenue today/)).not.toBeInTheDocument();
    expect(screen.queryByRole('region', { name: 'Booking requests' })).not.toBeInTheDocument();
    expect(screen.getByText('No upcoming jobs')).toBeInTheDocument();
    expect(await screen.findByText('1h 30m')).toBeInTheDocument();

    await user.click(screen.getByRole('button', { name: 'Clock in' }));
    await waitFor(() =>
      expect(rpc).toHaveBeenCalledWith('clock_in', { p_shop_id: 'shop-1', p_source: 'web' }),
    );
  });
});
