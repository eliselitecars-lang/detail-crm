import { screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { renderRoute, shopValue } from '@/test/render';
import {
  builders,
  createBuilder,
  resetSupabaseMock,
  setTableResult,
  supabase,
} from '@/test/supabaseMock';
import NewJobPage from './NewJobPage';
import { TEAM } from './testFixtures';

vi.mock('@/lib/supabase', () => import('@/test/supabaseMock'));

const CUSTOMER = {
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
};

const PRICING = {
  vehicle_category_id: 'cat-1',
  tax_rate_bps: 875,
  duration_minutes: 150,
  priced: true,
  lines: [
    {
      service_id: 'svc-1',
      name: 'Full detail',
      kind: 'service',
      taxable: true,
      duration_minutes: 150,
      catalog_price_cents: 24000,
      unit_price_cents: 24000,
      membership_included: false,
      note: null,
    },
  ],
  memberships: [],
  suggested_discount_kind: 'none',
  suggested_discount_value: 0,
  totals: { subtotal_cents: 24000, discount_cents: 0, tax_cents: 2100, total_cents: 26100 },
};

function setup(path: string, resources: unknown[] = []) {
  const rpc: Record<string, unknown> = { shop_team: TEAM, price_services: PRICING };
  supabase.rpc.mockImplementation((...args: unknown[]) =>
    createBuilder({ data: rpc[String(args[0])] ?? null }),
  );
  setTableResult('customers', { data: [CUSTOMER] });
  setTableResult('vehicles', {
    data: [
      {
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
    ],
  });
  setTableResult('vehicle_categories', { data: [{ id: 'cat-1', name: 'Car', sort: 1 }] });
  setTableResult('services', {
    data: [
      {
        id: 'svc-1',
        name: 'Full detail',
        kind: 'service',
        duration_minutes: 150,
        category_id: null,
        description: null,
        sort: 1,
      },
    ],
  });
  setTableResult('service_categories', { data: [] });
  setTableResult('resources', { data: resources });
  setTableResult('jobs', { data: { id: 'job-new' } });
  return renderRoute(<NewJobPage />, {
    path,
    routePath: '/app/jobs/new',
    shop: shopValue(),
    routes: [{ path: '/app/jobs/:jobId', element: <p>Job page</p> }],
  });
}

beforeEach(() => resetSupabaseMock());

describe('NewJobPage', () => {
  it('prefills the calendar slot in shop time, prices services on the server and creates the job', async () => {
    const { user, router } = setup(
      '/app/jobs/new?start=2026-09-28T14:00:00.000Z&end=2026-09-28T16:00:00.000Z',
    );
    // 14:00Z = 09:00 in America/Chicago
    expect(screen.getByLabelText(/Start time/)).toHaveValue('09:00');
    expect(screen.getByLabelText(/End time/)).toHaveValue('11:00');

    await user.type(screen.getByRole('combobox', { name: /Customer/ }), 'Jane');
    await user.click(await screen.findByRole('option', { name: /Jane Doe/ }));
    await user.click(await screen.findByRole('radio', { name: /2021 Honda Civic/ }));
    await user.click(await screen.findByRole('checkbox', { name: /Full detail/ }));

    await waitFor(() =>
      expect(supabase.rpc).toHaveBeenCalledWith('price_services', {
        p_shop: 'shop-1',
        p_customer_id: 'cust-1',
        p_vehicle_category_id: 'cat-1',
        p_service_ids: ['svc-1'],
        p_vehicle_id: 'veh-1',
      }),
    );
    expect(await screen.findByText('$261.00')).toBeInTheDocument();

    await user.click(screen.getByRole('checkbox', { name: 'Theo Tech' }));
    await user.click(screen.getByRole('button', { name: 'Create job' }));
    await waitFor(() => expect(router.state.location.pathname).toBe('/app/jobs/job-new'));

    const job = builders.jobs?.[0]?.insert.mock.calls[0]?.[0] as Record<string, unknown>;
    expect(job).toMatchObject({
      customer_id: 'cust-1',
      vehicle_id: 'veh-1',
      status: 'scheduled',
      scheduled_start: '2026-09-28T14:00:00.000Z',
      // the calendar selection's end wins over the summed service time
      scheduled_end: '2026-09-28T16:00:00.000Z',
      location_type: 'shop',
    });
    expect(job).not.toHaveProperty('total_cents');
    expect(builders.job_line_items?.[0]?.insert).toHaveBeenCalledWith([
      expect.objectContaining({
        job_id: 'job-new',
        service_id: 'svc-1',
        unit_price_cents: 24000,
        duration_minutes: 150,
      }),
    ]);
    expect(builders.job_assignments?.[0]?.upsert).toHaveBeenCalledWith(
      [{ shop_id: 'shop-1', job_id: 'job-new', member_id: 'member-2' }],
      expect.anything(),
    );
  });

  it('sizes the appointment from service durations when no end was chosen', async () => {
    const { user } = setup('/app/jobs/new?start=2026-09-28T14:00:00.000Z');
    await user.type(screen.getByRole('combobox', { name: /Customer/ }), 'Jane');
    await user.click(await screen.findByRole('option', { name: /Jane Doe/ }));
    await user.click(await screen.findByRole('radio', { name: /2021 Honda Civic/ }));
    await user.click(await screen.findByRole('checkbox', { name: /Full detail/ }));
    await waitFor(() => expect(screen.getByLabelText(/End time/)).toHaveValue('11:30'));
  });

  it('creates a customer inline; Enter saves the customer, not the job', async () => {
    const { user } = setup('/app/jobs/new');
    setTableResult('customers', {
      data: { ...CUSTOMER, id: 'cust-new', first_name: 'Sam', last_name: 'Lee' },
    });
    await user.click(screen.getByRole('button', { name: 'New customer' }));
    await user.type(screen.getByLabelText('First name'), 'Sam');
    await user.type(screen.getByLabelText('Last name'), 'Lee{Enter}');
    await waitFor(() =>
      expect(builders.customers?.some((b) => b.insert.mock.calls.length > 0)).toBe(true),
    );
    const insert = builders.customers?.find((b) => b.insert.mock.calls.length > 0)?.insert;
    expect(insert).toHaveBeenCalledWith(
      expect.objectContaining({
        first_name: 'Sam',
        last_name: 'Lee',
        shop_id: 'shop-1',
        source: 'staff',
      }),
    );
    expect(builders.jobs).toBeUndefined();
    expect(await screen.findByText('Sam Lee')).toBeInTheDocument();
  });

  it('requires a customer before creating', async () => {
    const { user } = setup('/app/jobs/new');
    await user.click(screen.getByRole('button', { name: 'Create job' }));
    expect(await screen.findByText('Choose a customer.')).toBeInTheDocument();
    expect(builders.jobs).toBeUndefined();
  });

  it('keeps the created job and retries only the lines after a partial failure', async () => {
    const { user, router } = setup('/app/jobs/new?start=2026-09-28T14:00:00.000Z');
    setTableResult('job_line_items', { error: { message: 'line rejected', code: '23514' } });
    await user.type(screen.getByRole('combobox', { name: /Customer/ }), 'Jane');
    await user.click(await screen.findByRole('option', { name: /Jane Doe/ }));
    await user.click(await screen.findByRole('radio', { name: /2021 Honda Civic/ }));
    await user.click(await screen.findByRole('checkbox', { name: /Full detail/ }));
    await screen.findByText('$261.00');
    await user.click(screen.getByRole('button', { name: 'Create job' }));
    expect(await screen.findByText(/job was created, but its services/)).toBeInTheDocument();
    expect(screen.getByRole('link', { name: /open the job/i })).toHaveAttribute(
      'href',
      '/app/jobs/job-new',
    );
    // The job row exists: its fields (customer, vehicle, schedule, notes…) are
    // locked so a retry can't silently drop edits or mismatch the vehicle.
    expect(screen.getByText(/this form is locked/)).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /Change/ })).toBeDisabled();
    expect(screen.getByRole('radio', { name: /2021 Honda Civic/ })).toBeDisabled();
    expect(screen.getByRole('checkbox', { name: /Full detail/ })).toBeDisabled();
    expect(screen.getByLabelText('Notes for the customer')).toBeDisabled();
    expect(screen.getByRole('checkbox', { name: 'Theo Tech' })).toBeDisabled();
    expect(screen.getByRole('button', { name: 'Retry saving' })).toBeEnabled();

    setTableResult('job_line_items', { data: null });
    await user.click(screen.getByRole('button', { name: 'Retry saving' }));
    await waitFor(() => expect(router.state.location.pathname).toBe('/app/jobs/job-new'));
    expect(builders.jobs?.filter((b) => b.insert.mock.calls.length > 0)).toHaveLength(1);
    // the retry replays exactly the lines the job was created with
    const lineInserts = (builders.job_line_items ?? []).flatMap((b) => b.insert.mock.calls);
    expect(lineInserts).toHaveLength(2);
    expect(lineInserts[1]?.[0]).toEqual(lineInserts[0]?.[0]);
  });

  it('prefills the bay / van picked in the calendar resource view', async () => {
    const view = setup(
      '/app/jobs/new?start=2026-09-28T14:00:00.000Z&end=2026-09-28T16:00:00.000Z&resourceId=res-2',
      [
        { id: 'res-1', name: 'Bay 1', kind: 'bay', active: true, archived_at: null },
        { id: 'res-2', name: 'Van 2', kind: 'van', active: true, archived_at: null },
      ],
    );
    const { user, router } = view;
    await waitFor(() => expect(screen.getByLabelText('Bay / van')).toHaveValue('res-2'));
    await user.type(screen.getByRole('combobox', { name: /Customer/ }), 'Jane');
    await user.click(await screen.findByRole('option', { name: /Jane Doe/ }));
    await user.click(await screen.findByRole('radio', { name: /2021 Honda Civic/ }));
    await user.click(screen.getByRole('button', { name: 'Create job' }));
    await waitFor(() => expect(router.state.location.pathname).toBe('/app/jobs/job-new'));
    const insert = builders.jobs?.find((b) => b.insert.mock.calls.length > 0)?.insert;
    expect(insert?.mock.calls[0]?.[0]).toMatchObject({ resource_id: 'res-2' });
  });
});
