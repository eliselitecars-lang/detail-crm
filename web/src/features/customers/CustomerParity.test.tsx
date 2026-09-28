import { screen, waitFor, within } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { membership, renderRoute, shopValue } from '@/test/render';
import {
  builders,
  createBuilder,
  mockRpc,
  resetSupabaseMock,
  setTableResult,
  supabase,
} from '@/test/supabaseMock';
import CustomerDetailPage from './CustomerDetailPage';

vi.mock('@/lib/supabase', () => import('@/test/supabaseMock'));

const customer = {
  id: 'c-1',
  shop_id: 'shop-1',
  first_name: 'Jane',
  last_name: 'Doe',
  company: null,
  email: 'jane@example.com',
  phone: '+12055550123',
  address_line1: null,
  address_line2: null,
  city: null,
  region: null,
  postal_code: null,
  country: 'US',
  lat: null,
  lng: null,
  notes: null,
  tags: [],
  lifecycle: 'customer',
  source: 'staff',
  sms_opt_in: false,
  email_opt_in: false,
  portal_user_id: null,
  stripe_customer_id: null,
  archived_at: null,
  merged_into_id: null,
  custom_data: {},
  referral_code: null,
  created_at: '2026-01-05T15:00:00Z',
  updated_at: '2026-01-05T15:00:00Z',
  search_text: 'jane doe',
  sms_opted_out_at: null,
  email_opted_out_at: null,
};

const duplicate = { ...customer, id: 'c-2', first_name: 'Janet', email: 'janet@example.com' };

/**
 * `customers` answers a single row to .maybeSingle() (the detail query) and
 * the list to everything else (pickers).
 */
function customersTable(row: Record<string, unknown>, list: unknown[]) {
  const original = supabase.from.getMockImplementation();
  supabase.from.mockImplementation((table: string) => {
    if (table !== 'customers') return original!(table);
    const builder = createBuilder({ data: list });
    builder.maybeSingle.mockImplementation(() => createBuilder({ data: row }));
    (builders.customers ??= []).push(builder);
    return builder;
  });
}

function setup(row: Record<string, unknown> = customer, path = '/app/customers/c-1') {
  customersTable(row, [customer, duplicate]);
  return renderRoute(<CustomerDetailPage />, {
    path,
    routePath: '/app/customers/:customerId',
    routes: [
      { path: '/app/invoices/:invoiceId', element: <p>Invoice page</p> },
      { path: '/app/customers/c-2', element: <p>Target customer page</p> },
    ],
    shop: shopValue({ membership: membership({ role: 'owner' }) }),
  });
}

beforeEach(() => {
  resetSupabaseMock();
  setTableResult('vehicles', { data: [] });
  setTableResult('vehicle_categories', { data: [] });
});

describe('CustomerDetailPage — parity', () => {
  it('merges a duplicate into the customer to keep, after the preview', async () => {
    const summary = (c: typeof customer) => ({
      id: c.id,
      name: `${c.first_name} ${c.last_name}`,
      email: c.email,
      phone: c.phone,
      lifecycle: 'customer',
      created_at: c.created_at,
      archived_at: null,
      merged_into_id: null,
      portal_linked: false,
      has_stripe_customer: false,
    });
    const calls = mockRpc({
      merge_customers_preview: {
        data: {
          source: summary(customer),
          target: summary(duplicate),
          counts: { jobs: 2, vehicles: 1 },
          conflicts: [
            {
              code: 'default_card',
              blocking: false,
              message: 'The kept customer keeps their default card.',
            },
          ],
          can_merge: true,
        },
      },
      merge_customers: { data: { target_id: 'c-2', moved: { jobs: 2, vehicles: 1 } } },
    });
    const { user } = setup();
    await user.click(await screen.findByRole('button', { name: 'Merge into…' }));
    const dialog = await screen.findByRole('dialog', { name: /Merge Jane Doe/ });
    await user.click(within(dialog).getByRole('combobox', { name: /Keep this customer/ }));
    const options = await within(dialog).findAllByRole('option');
    // the customer being merged is never offered as its own target
    expect(options.map((o) => o.textContent)).not.toContain(expect.stringMatching(/^Jane Doe/));
    await user.click(within(dialog).getByRole('option', { name: /Janet Doe/ }));
    expect(await within(dialog).findByText(/1 vehicle, 2 jobs/)).toBeInTheDocument();
    expect(
      within(dialog).getByText('The kept customer keeps their default card.'),
    ).toBeInTheDocument();
    const merge = within(dialog).getByRole('button', { name: 'Merge customers' });
    expect(merge).toBeDisabled();
    await user.type(within(dialog).getByLabelText(/Type “Janet Doe” to confirm/), 'janet doe');
    await user.click(merge);
    await waitFor(() =>
      expect(calls.find((c) => c.fn === 'merge_customers')?.args).toEqual({
        p_source_id: 'c-1',
        p_target_id: 'c-2',
      }),
    );
    expect(await screen.findByText('Target customer page')).toBeInTheDocument();
  });

  it('shows a merged duplicate as merged, with no actions', async () => {
    setup({ ...customer, archived_at: '2026-09-01T00:00:00Z', merged_into_id: 'c-2' });
    expect(await screen.findByText(/This customer was merged into/)).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Edit' })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Merge into…' })).not.toBeInTheDocument();
  });

  it('bills several unbilled jobs on one invoice', async () => {
    const calls = mockRpc({
      unbilled_jobs: {
        data: [
          {
            job_id: 'job-1',
            number: 1042,
            status: 'completed',
            scheduled_start: '2026-09-10T15:00:00Z',
            completed_at: '2026-09-10T18:00:00Z',
            vehicle_label: '2021 Toyota Camry',
            total_cents: 20000,
            paid_cents: 0,
          },
          {
            job_id: 'job-2',
            number: 1043,
            status: 'completed',
            scheduled_start: '2026-09-11T15:00:00Z',
            completed_at: '2026-09-11T18:00:00Z',
            vehicle_label: '2019 Ford F-150',
            total_cents: 30000,
            paid_cents: 5000,
          },
        ],
      },
      create_invoice_from_jobs: { data: { id: 'inv-9', number: 2050 } },
    });
    const { user } = setup();
    const list = await screen.findByRole('list', { name: 'Unbilled jobs' });
    const create = screen.getByRole('button', { name: 'Create invoice' });
    expect(create).toBeDisabled();
    await user.click(within(list).getByRole('checkbox', { name: /Job #1042/ }));
    await user.click(within(list).getByRole('checkbox', { name: /Job #1043/ }));
    await user.click(create);
    await waitFor(() =>
      expect(calls.find((c) => c.fn === 'create_invoice_from_jobs')?.args).toEqual({
        p_customer_id: 'c-1',
        p_job_ids: ['job-1', 'job-2'],
      }),
    );
    expect(await screen.findByText('Invoice page')).toBeInTheDocument();
  });

  it('edits the shop’s custom fields for the customer', async () => {
    setTableResult('custom_fields', {
      data: [
        {
          id: 'f-1',
          key: 'fleet_number',
          label: 'Fleet number',
          type: 'text',
          options: [],
          help_text: null,
          required: false,
          sort: 1,
          archived_at: null,
        },
      ],
    });
    const { user } = setup();
    await screen.findByText('Fleet number');
    const card = screen.getByRole('heading', { name: 'More details' }).closest('section');
    if (!card) throw new Error('card missing');
    await user.click(within(card).getByRole('button', { name: 'Edit' }));
    await user.type(within(card).getByLabelText('Fleet number'), 'F-17');
    await user.click(within(card).getByRole('button', { name: 'Save details' }));
    await waitFor(() =>
      expect(
        builders.customers?.some((b) =>
          b.update.mock.calls.some(
            ([patch]) =>
              JSON.stringify((patch as { custom_data?: unknown }).custom_data) ===
              JSON.stringify({ fleet_number: 'F-17' }),
          ),
        ),
      ).toBe(true),
    );
  });

  it('shows the referral code and link while the program is on', async () => {
    setTableResult('referral_settings', {
      data: {
        enabled: true,
        referee_discount_kind: 'fixed',
        referee_discount_value: 2000,
        referrer_reward_cents: 2500,
      },
    });
    setTableResult('referral_credits', { data: [] });
    const calls = mockRpc({
      get_or_create_referral_code: { data: { code: 'AB12CD34', share_url: null } },
    });
    setup();
    expect(await screen.findByText('AB12CD34')).toBeInTheDocument();
    expect(screen.getByText(/\/book\/glacier-detailing\?coupon=AB12CD34/)).toBeInTheDocument();
    expect(calls.find((c) => c.fn === 'get_or_create_referral_code')?.args).toEqual({
      p_customer_id: 'c-1',
    });
  });

  it('shows an error with retry when the referral program fails to load', async () => {
    setTableResult('referral_settings', {
      data: null,
      error: { message: 'boom', code: 'XX000' },
    });
    setTableResult('referral_credits', { data: [] });
    const { user } = setup();
    expect(await screen.findByText('Couldn’t load referrals')).toBeInTheDocument();
    setTableResult('referral_settings', {
      data: {
        enabled: true,
        referee_discount_kind: 'fixed',
        referee_discount_value: 2000,
        referrer_reward_cents: 2500,
      },
    });
    mockRpc({ get_or_create_referral_code: { data: { code: 'AB12CD34', share_url: null } } });
    const card = screen.getByText('Couldn’t load referrals').closest('section') ?? document.body;
    await user.click(within(card).getByRole('button', { name: /try again/i }));
    expect(await screen.findByText('AB12CD34')).toBeInTheDocument();
  });

  it('does not show $0 earned when the referral credits fail to load', async () => {
    setTableResult('referral_settings', {
      data: {
        enabled: true,
        referee_discount_kind: 'fixed',
        referee_discount_value: 2000,
        referrer_reward_cents: 2500,
      },
    });
    setTableResult('referral_credits', { data: null, error: { message: 'boom', code: 'XX000' } });
    mockRpc({ get_or_create_referral_code: { data: { code: 'AB12CD34', share_url: null } } });
    setup();
    expect(await screen.findByText('Couldn’t load referrals')).toBeInTheDocument();
    expect(screen.queryByText(/Credit earned/)).not.toBeInTheDocument();
  });

  it('uploads a file to the customer’s folder and registers it', async () => {
    setTableResult('documents', { data: [] });
    const { user } = setup(customer, '/app/customers/c-1?tab=documents');
    const button = await screen.findByRole('button', { name: 'Add files' });
    const input = button.parentElement?.querySelector('input[type="file"]');
    if (!(input instanceof HTMLInputElement)) throw new Error('file input missing');
    await user.upload(
      input,
      new File(['%PDF'], 'Fleet agreement.pdf', { type: 'application/pdf' }),
    );
    const upload = supabase.storage.from('documents').upload;
    await waitFor(() => expect(upload).toHaveBeenCalled());
    const [path] = upload.mock.calls[0] ?? [];
    expect(path).toMatch(/^shop-1\/customers\/c-1\/[0-9a-f-]{36}-Fleet-agreement\.pdf$/);
    await waitFor(() =>
      expect(builders.documents?.some((b) => b.insert.mock.calls.length > 0)).toBe(true),
    );
    expect(
      builders.documents?.find((b) => b.insert.mock.calls.length > 0)?.insert,
    ).toHaveBeenCalledWith(
      expect.objectContaining({
        shop_id: 'shop-1',
        customer_id: 'c-1',
        file_name: 'Fleet agreement.pdf',
        content_type: 'application/pdf',
      }),
    );
  });
});
