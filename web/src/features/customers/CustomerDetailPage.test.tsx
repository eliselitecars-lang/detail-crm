import { screen, waitFor, within } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { membership, renderRoute, shopValue, signedInAuth } from '@/test/render';
import {
  builders,
  createBuilder,
  edgeHttpError,
  mockRpc,
  pgError,
  resetSupabaseMock,
  setTableResult,
  supabase,
} from '@/test/supabaseMock';
import CustomerDetailPage from './CustomerDetailPage';

vi.mock('@/lib/supabase', () => import('@/test/supabaseMock'));

const invoke = supabase.functions.invoke;

beforeEach(() => {
  resetSupabaseMock();
  setTableResult('vehicles', { data: [] });
  setTableResult('vehicle_categories', { data: [{ id: 'cat-1', name: 'Small SUV', sort: 1 }] });
});
afterEach(() => vi.unstubAllGlobals());

const customer = {
  id: 'c-1',
  shop_id: 'shop-1',
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
  country: 'US',
  lat: null,
  lng: null,
  notes: 'Gate code 1234',
  tags: ['VIP'],
  lifecycle: 'customer',
  source: 'referral',
  sms_opt_in: true,
  email_opt_in: false,
  portal_user_id: 'user-9',
  stripe_customer_id: null,
  archived_at: null,
  created_at: '2026-01-05T15:00:00Z',
  updated_at: '2026-01-05T15:00:00Z',
  search_text: 'jane doe',
  sms_opted_out_at: null,
  email_opted_out_at: null,
};

function setup(role: 'owner' | 'manager' | 'technician' = 'owner', path = '/app/customers/c-1') {
  setTableResult('customers', { data: customer });
  return renderRoute(<CustomerDetailPage />, {
    path,
    routePath: '/app/customers/:customerId',
    auth: signedInAuth(),
    shop: shopValue({ membership: membership({ role }) }),
  });
}

describe('CustomerDetailPage', () => {
  it('shows the header, quick actions and overview', async () => {
    setup();
    expect(await screen.findByRole('heading', { name: 'Jane Doe', level: 1 })).toBeInTheDocument();
    const actions = screen.getByRole('navigation', { name: 'Quick actions' });
    expect(within(actions).getByRole('link', { name: 'Call' })).toHaveAttribute(
      'href',
      'tel:+12055550123',
    );
    expect(within(actions).getByRole('link', { name: 'Text' })).toHaveAttribute(
      'href',
      'sms:+12055550123',
    );
    expect(within(actions).getByRole('link', { name: 'New job' })).toHaveAttribute(
      'href',
      '/app/jobs/new?customerId=c-1',
    );
    expect(within(actions).getByRole('link', { name: 'New quote' })).toHaveAttribute(
      'href',
      '/app/quotes/new?customerId=c-1',
    );
    expect(within(actions).getByRole('link', { name: 'Messages' })).toHaveAttribute(
      'href',
      '/app/messages?customer=c-1',
    );
    expect(screen.getByText('Account linked')).toBeInTheDocument();
    expect(screen.getByText('Gate code 1234')).toBeInTheDocument();
    expect(screen.getByText('1 Main St, Birmingham, AL 35203')).toBeInTheDocument();
    expect(screen.getByRole('tab', { name: 'Saved cards' })).toBeInTheDocument();
  });

  it('shows the server-computed totals for managers', async () => {
    const calls = mockRpc({
      customer_summary: {
        data: [
          {
            customer_id: 'c-1',
            lifetime_paid_cents: 125_000,
            tips_cents: 5_000,
            refunded_cents: 2_500,
            open_balance_cents: 30_000,
            overdue_balance_cents: 10_000,
            completed_jobs: 4,
            upcoming_jobs: 1,
            first_visit_at: '2026-01-10T15:00:00Z',
            last_visit_at: '2026-03-02T15:00:00Z',
            next_job_at: '2026-04-20T14:00:00Z',
            open_quotes: 2,
            active_memberships: 1,
          },
        ],
      },
    });
    setup('manager');
    const card = (await screen.findByRole('heading', { name: 'At a glance' })).closest('section');
    if (!card) throw new Error('summary card missing');
    const totals = within(card);
    expect(await totals.findByText('$1,250.00')).toBeInTheDocument();
    expect(totals.getByText('incl. $50.00 tips · $25.00 refunded')).toBeInTheDocument();
    const balance = totals.getByText('$300.00');
    expect(balance).toHaveClass('text-danger-ink');
    expect(totals.getByText('$100.00 overdue')).toBeInTheDocument();
    expect(totals.getByText('4')).toBeInTheDocument();
    expect(totals.getByText('Next job')).toBeInTheDocument();
    expect(totals.getByText('Apr 20, 2026')).toBeInTheDocument();
    expect(totals.getByText('Last visit Mar 2, 2026')).toBeInTheDocument();
    expect(totals.getByText('2 open quotes · 1 membership')).toBeInTheDocument();
    expect(calls).toContainEqual({ fn: 'customer_summary', args: { p_customer_id: 'c-1' } });
  });

  it('offers a retry when the totals fail to load', async () => {
    mockRpc({ customer_summary: pgError('XX000', 'boom') });
    const { user } = setup();
    const card = (await screen.findByRole('heading', { name: 'At a glance' })).closest('section');
    if (!card) throw new Error('summary card missing');
    await within(card).findByRole('button', { name: /try again/i });
    mockRpc({ customer_summary: { data: [] } });
    await user.click(within(card).getByRole('button', { name: /try again/i }));
    expect(await within(card).findByText('That customer could not be found.')).toBeInTheDocument();
  });

  it('shows not found for a missing customer', async () => {
    renderRoute(<CustomerDetailPage />, {
      path: '/app/customers/nope',
      routePath: '/app/customers/:customerId',
      auth: signedInAuth(),
      shop: shopValue(),
    });
    expect(await screen.findByText('Customer not found')).toBeInTheDocument();
  });

  it('is read-only for technicians (no money tabs, no edit)', async () => {
    setup('technician');
    await screen.findByRole('heading', { name: 'Jane Doe', level: 1 });
    expect(screen.queryByRole('button', { name: 'Edit' })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Archive' })).not.toBeInTheDocument();
    expect(screen.queryByRole('link', { name: 'New job' })).not.toBeInTheDocument();
    expect(screen.queryByRole('link', { name: 'Messages' })).not.toBeInTheDocument();
    const tabs = screen.getAllByRole('tab').map((t) => t.textContent);
    expect(tabs).toEqual(['Overview', 'Vehicles', 'Jobs']);
    // customer_summary is manager+ (the RPC refuses technicians): not requested.
    expect(screen.queryByRole('heading', { name: 'At a glance' })).not.toBeInTheDocument();
    expect(supabase.rpc).not.toHaveBeenCalledWith('customer_summary', expect.anything());
  });

  it('archives after confirmation', async () => {
    const { user } = setup();
    await screen.findByRole('heading', { name: 'Jane Doe', level: 1 });
    await user.click(screen.getByRole('button', { name: 'Archive' }));
    const dialog = await screen.findByRole('dialog', { name: 'Archive Jane Doe?' });
    await user.click(within(dialog).getByRole('button', { name: 'Archive customer' }));
    await waitFor(() =>
      expect(
        builders.customers?.some((b) =>
          b.update.mock.calls.some(
            ([payload]) => typeof (payload as { archived_at?: unknown }).archived_at === 'string',
          ),
        ),
      ).toBe(true),
    );
  });

  it('adds a vehicle using VIN decode', async () => {
    const fetchMock = vi.fn(() =>
      Promise.resolve(
        new Response(
          JSON.stringify({
            Results: [{ ModelYear: '2003', Make: 'HONDA', Model: 'Accord', Trim: 'EX' }],
          }),
        ),
      ),
    );
    vi.stubGlobal('fetch', fetchMock);
    const { user } = setup('owner', '/app/customers/c-1?tab=vehicles');
    expect(await screen.findByText('No vehicles yet')).toBeInTheDocument();
    await user.click(screen.getAllByRole('button', { name: 'Add vehicle' })[0]!);
    const dialog = await screen.findByRole('dialog', { name: 'Add vehicle' });

    const vin = within(dialog).getByLabelText('VIN');
    await user.type(vin, '1HGCM82633A00435');
    await user.click(within(dialog).getByRole('button', { name: 'Decode VIN' }));
    expect(await within(dialog).findByText('A VIN has exactly 17 characters.')).toBeInTheDocument();
    expect(fetchMock).not.toHaveBeenCalled();

    await user.type(vin, '2');
    await user.click(within(dialog).getByRole('button', { name: 'Decode VIN' }));
    expect(await within(dialog).findByText(/Filled in 2003 Honda Accord EX/)).toBeInTheDocument();
    expect(within(dialog).getByLabelText('Make')).toHaveValue('Honda');
    expect(within(dialog).getByLabelText('Year')).toHaveValue('2003');

    await user.selectOptions(within(dialog).getByLabelText(/Size category/), 'cat-1');
    const insertBuilder = createBuilder({ data: { id: 'v-1' } });
    supabase.from.mockImplementationOnce(() => insertBuilder);
    await user.click(within(dialog).getByRole('button', { name: 'Add vehicle' }));
    await waitFor(() =>
      expect(insertBuilder.insert).toHaveBeenCalledWith(
        expect.objectContaining({
          shop_id: 'shop-1',
          customer_id: 'c-1',
          vin: '1HGCM82633A004352',
          year: 2003,
          make: 'Honda',
          model: 'Accord',
          trim: 'EX',
          category_id: 'cat-1',
        }),
      ),
    );
  });

  it('reports VIN decode failures when offline', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(() => Promise.reject(new TypeError('Failed to fetch'))),
    );
    const { user } = setup('owner', '/app/customers/c-1?tab=vehicles');
    await screen.findByText('No vehicles yet');
    await user.click(screen.getAllByRole('button', { name: 'Add vehicle' })[0]!);
    const dialog = await screen.findByRole('dialog', { name: 'Add vehicle' });
    await user.type(within(dialog).getByLabelText('VIN'), '1HGCM82633A004352');
    await user.click(within(dialog).getByRole('button', { name: 'Decode VIN' }));
    expect(await within(dialog).findByText(/Couldn’t reach the VIN service/)).toBeInTheDocument();
  });

  it('removes a saved card after confirmation (manager+)', async () => {
    setTableResult('customer_payment_methods', {
      data: [
        {
          id: 'cpm-1',
          stripe_payment_method_id: 'pm_1Visa',
          brand: 'visa',
          last4: '4242',
          exp_month: 4,
          exp_year: 2030,
          is_default: true,
          created_at: '2026-01-01T00:00:00Z',
        },
      ],
    });
    invoke.mockResolvedValueOnce({ data: { removed: true }, error: null });
    const { user } = setup('manager', '/app/customers/c-1?tab=cards');
    await user.click(await screen.findByRole('button', { name: 'Remove Visa ending in 4242' }));
    const confirm = await screen.findByRole('alertdialog', { name: 'Remove saved card?' });
    const before = (builders.customer_payment_methods ?? []).length;
    await user.click(within(confirm).getByRole('button', { name: 'Remove card' }));
    expect(await screen.findByText('Visa ending in 4242 removed')).toBeInTheDocument();
    expect(invoke).toHaveBeenCalledWith('payments', {
      body: {
        action: 'remove_saved_card',
        shop_id: 'shop-1',
        customer_id: 'c-1',
        payment_method_id: 'pm_1Visa',
      },
    });
    await waitFor(() =>
      expect((builders.customer_payment_methods ?? []).length).toBeGreaterThan(before),
    );
  });

  it('keeps the confirmation open with the server message when removal fails', async () => {
    setTableResult('customer_payment_methods', {
      data: [
        {
          id: 'cpm-1',
          stripe_payment_method_id: 'pm_1Visa',
          brand: 'visa',
          last4: '4242',
          exp_month: 4,
          exp_year: 2030,
          is_default: false,
          created_at: '2026-01-01T00:00:00Z',
        },
      ],
    });
    invoke.mockResolvedValueOnce({
      data: null,
      error: edgeHttpError(403, {
        error: 'Your role does not allow this action.',
        code: 'forbidden',
      }),
    });
    const { user } = setup('manager', '/app/customers/c-1?tab=cards');
    await user.click(await screen.findByRole('button', { name: 'Remove Visa ending in 4242' }));
    const confirm = await screen.findByRole('alertdialog', { name: 'Remove saved card?' });
    await user.click(within(confirm).getByRole('button', { name: 'Remove card' }));
    expect(await screen.findByText('Your role does not allow this action.')).toBeInTheDocument();
    expect(confirm).toBeInTheDocument();
  });

  it('texts a card-setup link through payments + messaging', async () => {
    setTableResult('customer_payment_methods', {
      data: [
        {
          id: 'pm-1',
          brand: 'visa',
          last4: '4242',
          exp_month: 4,
          exp_year: 2030,
          is_default: true,
          created_at: '2026-01-01T00:00:00Z',
        },
      ],
    });
    invoke
      .mockResolvedValueOnce({
        data: { url: 'https://checkout.stripe.com/c/pay/cs_1' },
        error: null,
      })
      .mockResolvedValueOnce({
        data: { message_id: 'm-1', channel: 'sms', status: 'sent', error: null },
        error: null,
      });
    const { user } = setup('manager', '/app/customers/c-1?tab=cards');
    expect(await screen.findByText('Visa ending in 4242')).toBeInTheDocument();
    expect(screen.getByText('Expires 04/30')).toBeInTheDocument();

    await user.click(screen.getByRole('button', { name: 'Text card-setup link' }));
    const dialog = await screen.findByRole('dialog', { name: 'Text a card-setup link' });
    await user.click(within(dialog).getByRole('button', { name: 'Send text' }));
    await waitFor(() => expect(dialog).not.toBeInTheDocument());

    expect(invoke).toHaveBeenNthCalledWith(1, 'payments', {
      body: {
        action: 'setup_card_link',
        shop_id: 'shop-1',
        customer_id: 'c-1',
        request_nonce: expect.any(String),
      },
    });
    expect(invoke).toHaveBeenNthCalledWith(2, 'messaging', {
      body: {
        action: 'send',
        shop_id: 'shop-1',
        customer_id: 'c-1',
        channel: 'sms',
        body: 'Hi Jane, Glacier Detailing here. Add a card on file securely using this link: https://checkout.stripe.com/c/pay/cs_1',
      },
    });
  });

  it('keeps the link available when the text fails', async () => {
    setTableResult('customer_payment_methods', { data: [] });
    invoke
      .mockResolvedValueOnce({
        data: { url: 'https://checkout.stripe.com/c/pay/cs_2' },
        error: null,
      })
      .mockResolvedValueOnce({
        data: {
          message_id: 'm-2',
          channel: 'sms',
          status: 'failed',
          error: 'Carrier rejected the message.',
        },
        error: null,
      });
    const { user } = setup('owner', '/app/customers/c-1?tab=cards');
    expect(await screen.findByText('No saved cards')).toBeInTheDocument();
    await user.click(screen.getByRole('button', { name: 'Text card-setup link' }));
    const dialog = await screen.findByRole('dialog', { name: 'Text a card-setup link' });
    await user.click(within(dialog).getByRole('button', { name: 'Send text' }));
    expect(await within(dialog).findByText('Carrier rejected the message.')).toBeInTheDocument();
    expect(within(dialog).getByLabelText('Card-setup link')).toHaveValue(
      'https://checkout.stripe.com/c/pay/cs_2',
    );
    expect(within(dialog).getByRole('button', { name: 'Try sending again' })).toBeInTheDocument();
  });
});
