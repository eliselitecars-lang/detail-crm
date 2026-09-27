import { screen, waitFor, within } from '@testing-library/react';
import { beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import type { MessageTemplate, ShopSettings } from './api';
import { redirectTo } from './externalRedirect';
import { renderSettings } from './testing/renderSettings';
import {
  builders,
  createBuilder,
  invoke,
  resetSupabaseMock,
  setTableResult,
  supabase,
  upload,
} from './testing/supabaseMock';

vi.mock('@/lib/supabase', () => import('./testing/supabaseMock'));
vi.mock('./externalRedirect', () => ({ redirectTo: vi.fn() }));

const SHOP: ShopSettings = {
  id: 'shop-1',
  name: 'Glacier Detailing',
  slug: 'glacier-detailing',
  email: 'hello@glacier.test',
  phone: '+12055550100',
  website: null,
  address_line1: null,
  address_line2: null,
  city: 'Birmingham',
  region: 'AL',
  postal_code: '35203',
  country: 'US',
  timezone: 'America/Chicago',
  currency: 'usd',
  logo_path: null,
  brand_color: null,
  business_type: 'fixed',
  tax_rate_bps: 0,
  techs_can_collect_payments: false,
  review_url: 'https://g.page/r/glacier',
  quote_terms: null,
  invoice_terms: null,
  invoice_due_days: 0,
  sms_from_number: null,
  updated_at: '2026-01-01T00:00:00Z',
};

// Route pages are lazy; transform them once up front so the first test's
// findBy* timeouts measure rendering, not cold module compilation.
beforeAll(async () => {
  await Promise.all([
    import('./SettingsPage'),
    import('./pages/BusinessProfilePage'),
    import('./pages/BookingSettingsPage'),
    import('./pages/BlockedTimesPage'),
    import('./pages/CouponsPage'),
    import('./pages/PaymentsPage'),
    import('./pages/SmsPage'),
    import('./pages/TemplatesPage'),
    import('./pages/VehicleCategoriesPage'),
    import('./pages/DeleteShopPage'),
  ]);
}, 60_000);

beforeEach(() => {
  resetSupabaseMock();
  setTableResult('shops', { data: SHOP });
});

describe('settings navigation & access', () => {
  it('redirects /app/settings to the business profile and lists every section for owners', async () => {
    const { router } = renderSettings('/app/settings');
    expect(
      await screen.findByRole('heading', { name: 'Business profile', level: 2 }, { timeout: 5000 }),
    ).toBeVisible();
    expect(router.state.location.pathname).toBe('/app/settings/business');
    const nav = screen.getByRole('navigation', { name: 'Settings' });
    expect(within(nav).getByRole('link', { name: 'Payments' })).toBeInTheDocument();
    expect(within(nav).getByRole('link', { name: 'SMS' })).toBeInTheDocument();
    expect(await screen.findByLabelText(/Business name/)).toHaveValue('Glacier Detailing');
  });

  it('shows managers read-only settings without Payments or SMS', async () => {
    renderSettings('/app/settings/business', { role: 'manager' });
    expect(await screen.findByText(/Only the owner or an admin can change them/)).toBeVisible();
    const nav = screen.getByRole('navigation', { name: 'Settings' });
    expect(within(nav).queryByRole('link', { name: 'Payments' })).not.toBeInTheDocument();
    expect(within(nav).queryByRole('link', { name: 'SMS' })).not.toBeInTheDocument();
    expect(await screen.findByLabelText(/Business name/)).toBeDisabled();
    expect(screen.queryByRole('button', { name: 'Save changes' })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /Upload logo/ })).not.toBeInTheDocument();
  });

  it('blocks managers from the Stripe page', async () => {
    renderSettings('/app/settings/payments', { role: 'manager' });
    expect(await screen.findByText('You don’t have access to this page')).toBeVisible();
    expect(invoke).not.toHaveBeenCalled();
  });

  it('keeps technicians out of settings entirely', async () => {
    renderSettings('/app/settings/business', { role: 'technician' });
    expect(await screen.findByText('You don’t have access to this page')).toBeVisible();
    expect(screen.queryByRole('navigation', { name: 'Settings' })).not.toBeInTheDocument();
  });
});

describe('BusinessProfilePage', () => {
  it('saves the profile and refreshes the shell shop', async () => {
    const { user, refetch } = renderSettings('/app/settings/business');
    const name = await screen.findByLabelText(/Business name/);
    await user.clear(name);
    await user.type(name, 'Glacier Auto Spa');
    await user.type(screen.getByLabelText('Website'), 'glacier.test');
    await user.click(screen.getByRole('button', { name: 'Save changes' }));

    await waitFor(() => expect(refetch).toHaveBeenCalled());
    const update = builders.shops?.find((b) => b.update.mock.calls.length > 0);
    expect(update?.update).toHaveBeenCalledWith(
      expect.objectContaining({
        name: 'Glacier Auto Spa',
        website: 'https://glacier.test',
        phone: '+12055550100',
        timezone: 'America/Chicago',
        brand_color: null,
      }),
    );
    expect(update?.eq).toHaveBeenCalledWith('id', 'shop-1');
    expect(await screen.findByText('Business profile saved')).toBeVisible();
  });

  it('uploads a logo to <shop_id>/logo.<ext> and stores the path', async () => {
    const { user } = renderSettings('/app/settings/business');
    await screen.findByRole('button', { name: 'Upload logo' });
    const input = document.querySelector<HTMLInputElement>('input[type="file"]');
    if (!input) throw new Error('file input missing');
    await user.upload(input, new File(['png'], 'logo.png', { type: 'image/png' }));
    await waitFor(() =>
      expect(upload).toHaveBeenCalledWith('shop-1/logo.png', expect.any(File), {
        upsert: true,
        contentType: 'image/png',
        cacheControl: '60',
      }),
    );
    await waitFor(() =>
      expect(
        builders.shops?.some((b) =>
          b.update.mock.calls.some(
            (c) => JSON.stringify(c[0]) === '{"logo_path":"shop-1/logo.png"}',
          ),
        ),
      ).toBe(true),
    );
  });
});

describe('BookingSettingsPage', () => {
  beforeEach(() => {
    setTableResult('booking_settings', {
      data: {
        shop_id: 'shop-1',
        enabled: false,
        auto_confirm: false,
        lead_time_minutes: 120,
        max_days_ahead: 60,
        slot_interval_minutes: 30,
        buffer_minutes: 0,
        max_concurrent_jobs: 1,
        require_deposit: false,
        deposit_type: 'percent',
        deposit_value: 0,
        service_area_postal_codes: [],
        booking_message: null,
        cancellation_policy: null,
        allow_client_cancel_hours: 24,
        created_at: '2026-01-01T00:00:00Z',
        updated_at: '2026-01-01T00:00:00Z',
      },
    });
  });

  it('shows the public booking link', async () => {
    renderSettings('/app/settings/booking');
    expect(await screen.findByLabelText('Booking link')).toHaveTextContent(
      `${window.location.origin}/book/glacier-detailing`,
    );
    expect(screen.getByText('Booking off')).toBeVisible();
  });

  it('validates and saves a percent deposit as basis points', async () => {
    const { user } = renderSettings('/app/settings/booking');
    await user.click(await screen.findByRole('switch', { name: 'Accept online bookings' }));
    await user.click(screen.getByRole('switch', { name: 'Require a deposit to book' }));
    await user.click(screen.getByRole('button', { name: 'Save changes' }));
    expect(await screen.findByText('Enter a percentage between 0.01 and 100.')).toBeVisible();

    await user.type(screen.getByLabelText(/Deposit percent/), '20');
    await user.type(screen.getByLabelText('Service area postal codes'), '35203, 35209');
    await user.click(screen.getByRole('button', { name: 'Save changes' }));
    await waitFor(() => {
      const update = builders.booking_settings?.find((b) => b.update.mock.calls.length > 0);
      expect(update?.update).toHaveBeenCalledWith(
        expect.objectContaining({
          enabled: true,
          require_deposit: true,
          deposit_type: 'percent',
          deposit_value: 2000,
          lead_time_minutes: 120,
          service_area_postal_codes: ['35203', '35209'],
        }),
      );
    });
  });
});

const template = (over: Partial<MessageTemplate>): MessageTemplate => ({
  id: 'tpl',
  key: 'appointment_reminder',
  channel: 'sms',
  subject: null,
  body: 'Reminder from {{shop_name}}',
  enabled: true,
  offset_minutes: -1440,
  updated_at: '2026-01-01T00:00:00Z',
  ...over,
});

describe('TemplatesPage', () => {
  it('edits wording and timing with placeholder chips and a live preview', async () => {
    setTableResult('message_templates', {
      data: [
        template({ id: 'sms-1' }),
        template({
          id: 'email-1',
          channel: 'email',
          subject: 'Reminder',
          body: 'See you soon',
        }),
      ],
    });
    const { user } = renderSettings('/app/settings/templates');
    expect(await screen.findByText('1 day before the appointment')).toBeVisible();
    await user.click(screen.getByRole('button', { name: 'Edit Appointment reminder' }));

    const dialog = await screen.findByRole('dialog', { name: 'Appointment reminder' });
    const preview = within(dialog).getByRole('region', { name: 'Preview' });
    expect(preview).toHaveTextContent('Reminder from Glacier Detailing');

    const amount = within(dialog).getByLabelText('Send timing amount');
    await user.clear(amount);
    await user.type(amount, '2');

    const body = within(dialog).getByRole('textbox', { name: /^Message/ });
    await user.click(body);
    await user.keyboard('{End} ');
    await user.click(within(dialog).getByRole('button', { name: 'Customer first name' }));
    expect(body).toHaveValue('Reminder from {{shop_name}} {{customer_first_name}}');
    expect(preview).toHaveTextContent('Reminder from Glacier Detailing [customer first name]');

    await user.click(within(dialog).getByRole('button', { name: 'Save changes' }));
    await waitFor(() => {
      const update = builders.message_templates?.find((b) => b.update.mock.calls.length > 0);
      expect(update?.update).toHaveBeenCalledWith({
        body: 'Reminder from {{shop_name}} {{customer_first_name}}',
        offset_minutes: -2880,
      });
      expect(update?.eq).toHaveBeenCalledWith('id', 'sms-1');
    });
  });

  it('resets a template to the default wording via RPC', async () => {
    setTableResult('message_templates', {
      data: [template({ id: 'sms-1', key: 'on_the_way', offset_minutes: null })],
    });
    const { user } = renderSettings('/app/settings/templates');
    await user.click(await screen.findByRole('button', { name: 'Edit On the way' }));
    const dialog = await screen.findByRole('dialog', { name: 'On the way' });
    await user.click(within(dialog).getByRole('button', { name: 'Reset to default wording' }));
    await user.click(await screen.findByRole('button', { name: 'Reset' }));
    await waitFor(() =>
      expect(supabase.rpc).toHaveBeenCalledWith('reset_message_template', {
        p_template_id: 'sms-1',
      }),
    );
  });
});

describe('PaymentsPage (Stripe Connect)', () => {
  it('connects a new account by redirecting to the onboarding link', async () => {
    invoke.mockImplementation((_name, { body }) =>
      Promise.resolve(
        body.action === 'refresh_status'
          ? {
              data: {
                connected: false,
                stripe_account_id: null,
                charges_enabled: false,
                payouts_enabled: false,
                details_submitted: false,
              },
              error: null,
            }
          : { data: { url: 'https://connect.stripe.com/setup/abc' }, error: null },
      ),
    );
    const { user } = renderSettings('/app/settings/payments');
    expect(await screen.findByText('Not connected')).toBeVisible();
    await user.click(screen.getByRole('button', { name: 'Connect Stripe' }));
    await waitFor(() =>
      expect(vi.mocked(redirectTo)).toHaveBeenCalledWith('https://connect.stripe.com/setup/abc'),
    );
    expect(invoke).toHaveBeenCalledWith('stripe-connect', {
      body: expect.objectContaining({
        action: 'create_account_link',
        shop_id: 'shop-1',
        request_nonce: expect.stringMatching(/^[A-Za-z0-9_-]{8,64}$/),
      }),
    });
  });

  it('refreshes the status when Stripe sends the owner back', async () => {
    invoke.mockResolvedValue({
      data: {
        connected: true,
        stripe_account_id: 'acct_123',
        charges_enabled: true,
        payouts_enabled: true,
        details_submitted: true,
      },
      error: null,
    });
    const { router } = renderSettings('/app/settings/payments?stripe=return');
    expect(await screen.findByText('Connected and ready to take payments')).toBeVisible();
    expect(
      await screen.findByText('Stripe is connected. You can take card payments and deposits.'),
    ).toBeVisible();
    expect(screen.getByText('Charges: on')).toBeVisible();
    expect(screen.getByRole('button', { name: 'Open Stripe dashboard' })).toBeVisible();
    expect(invoke).toHaveBeenCalledWith('stripe-connect', {
      body: { action: 'refresh_status', shop_id: 'shop-1' },
    });
    await waitFor(() => expect(router.state.location.search).toBe(''));
  });

  it('refuses to redirect to a link that is not an https stripe.com URL', async () => {
    invoke.mockImplementation((_name, { body }) =>
      Promise.resolve(
        body.action === 'refresh_status'
          ? {
              data: {
                connected: false,
                stripe_account_id: null,
                charges_enabled: false,
                payouts_enabled: false,
                details_submitted: false,
              },
              error: null,
            }
          : { data: { url: 'javascript:alert(document.cookie)' }, error: null },
      ),
    );
    const { user } = renderSettings('/app/settings/payments');
    expect(await screen.findByText('Not connected')).toBeVisible();
    await user.click(screen.getByRole('button', { name: 'Connect Stripe' }));
    expect(
      await screen.findByText('Stripe returned an unexpected link. Please try again.'),
    ).toBeVisible();
    expect(vi.mocked(redirectTo)).not.toHaveBeenCalled();
  });

  it('shows the edge function error with a retry', async () => {
    invoke.mockResolvedValue({ data: null, error: new TypeError('Failed to fetch') });
    renderSettings('/app/settings/payments');
    expect(await screen.findByText('Couldn’t load your Stripe status')).toBeVisible();
    expect(screen.getByRole('button', { name: 'Try again' })).toBeVisible();
  });
});

describe('VehicleCategoriesPage', () => {
  it('warns how many prices and vehicles a delete affects', async () => {
    setTableResult('vehicle_categories', {
      data: [
        { id: 'c1', name: 'Car', sort: 1 },
        { id: 'c2', name: 'SUV', sort: 2 },
      ],
    });
    setTableResult('service_prices', { data: null, count: 4 });
    setTableResult('vehicles', { data: null, count: 1 });
    const { user } = renderSettings('/app/settings/vehicle-categories');
    await user.click(await screen.findByRole('button', { name: 'Delete SUV' }));
    expect(
      await screen.findByText('4 service prices for this size will be deleted.'),
    ).toBeVisible();
    expect(screen.getByText('1 vehicle will no longer have a size category.')).toBeVisible();
    await user.click(screen.getByRole('button', { name: 'Delete anyway' }));
    await waitFor(() => {
      const del = builders.vehicle_categories?.find((b) => b.delete.mock.calls.length > 0);
      expect(del?.eq).toHaveBeenCalledWith('id', 'c2');
    });
  });

  it('reorders categories by rewriting sort positions', async () => {
    setTableResult('vehicle_categories', {
      data: [
        { id: 'c1', name: 'Car', sort: 1 },
        { id: 'c2', name: 'SUV', sort: 2 },
      ],
    });
    const { user } = renderSettings('/app/settings/vehicle-categories');
    await user.click(await screen.findByRole('button', { name: 'Move SUV up' }));
    await waitFor(() => {
      const updates = (builders.vehicle_categories ?? []).flatMap((b) => b.update.mock.calls);
      expect(updates).toEqual([[{ sort: 1 }], [{ sort: 2 }]]);
    });
  });
});

describe('CouponsPage', () => {
  it('creates a coupon with shop-local dates', async () => {
    setTableResult('coupons', { data: [] });
    const { user } = renderSettings('/app/settings/coupons');
    expect(await screen.findByText('No coupons yet')).toBeVisible();
    await user.click(screen.getAllByRole('button', { name: 'Add coupon' })[0]!);
    const dialog = await screen.findByRole('dialog', { name: 'New coupon' });
    await user.type(within(dialog).getByLabelText(/Code/), 'spring15');
    await user.type(within(dialog).getByRole('textbox', { name: /Percent off/ }), '15');
    await user.type(within(dialog).getByLabelText('Last day'), '2026-03-31');
    await user.type(within(dialog).getByLabelText('Maximum uses'), '50');
    await user.click(within(dialog).getByRole('button', { name: 'Create coupon' }));
    await waitFor(() => {
      const insert = builders.coupons?.find((b) => b.insert.mock.calls.length > 0);
      expect(insert?.insert).toHaveBeenCalledWith({
        code: 'SPRING15',
        description: null,
        kind: 'percent',
        value: 1500,
        starts_at: null,
        ends_at: '2026-04-01T05:00:00.000Z',
        max_redemptions: 50,
        online_only: false,
        active: true,
        shop_id: 'shop-1',
      });
    });
  });

  it('shows a friendly error when the code already exists', async () => {
    setTableResult('coupons', { data: [] });
    const { user } = renderSettings('/app/settings/coupons');
    await user.click((await screen.findAllByRole('button', { name: 'Add coupon' }))[0]!);
    const dialog = await screen.findByRole('dialog', { name: 'New coupon' });
    await user.type(within(dialog).getByLabelText(/Code/), 'DUP');
    await user.type(within(dialog).getByRole('textbox', { name: /Percent off/ }), '10');
    supabase.from.mockReturnValueOnce(
      createBuilder({
        data: null,
        error: { code: '23505', message: 'duplicate key value violates unique constraint' },
      }),
    );
    await user.click(within(dialog).getByRole('button', { name: 'Create coupon' }));
    expect(
      await within(dialog).findByText('You already have a coupon with this code.'),
    ).toBeVisible();
  });
});

describe('BlockedTimesPage', () => {
  it('lets managers block time for the whole shop', async () => {
    setTableResult('blocked_times', { data: [] });
    setTableResult('shop_members', {
      data: [{ id: 'member-1', display_name: 'Olivia Owner', active: true, role: 'owner' }],
    });
    const { user } = renderSettings('/app/settings/blocked-times', { role: 'manager' });
    expect(await screen.findByText('No upcoming blocked times')).toBeVisible();
    await user.click(screen.getAllByRole('button', { name: 'Block time' })[0]!);
    const dialog = await screen.findByRole('dialog', { name: 'Block time' });
    const first = within(dialog).getByLabelText(/First day/);
    await user.clear(first);
    await user.type(first, '2026-12-24');
    const last = within(dialog).getByLabelText(/Last day/);
    await user.clear(last);
    await user.type(last, '2026-12-25');
    await user.type(within(dialog).getByLabelText('Reason'), 'Holiday');
    await user.click(within(dialog).getByRole('button', { name: 'Block time' }));
    await waitFor(() => {
      const insert = builders.blocked_times?.find((b) => b.insert.mock.calls.length > 0);
      expect(insert?.insert).toHaveBeenCalledWith({
        member_id: null,
        starts_at: '2026-12-24T06:00:00.000Z',
        ends_at: '2026-12-26T06:00:00.000Z',
        reason: 'Holiday',
        shop_id: 'shop-1',
      });
    });
  });
});

describe('SmsPage', () => {
  it('maps a number already used by another shop to a field error', async () => {
    const { user } = renderSettings('/app/settings/sms');
    const input = await screen.findByLabelText('SMS from number');
    await user.type(input, '(205) 555-0199');
    supabase.from.mockReturnValueOnce(
      createBuilder({
        data: null,
        error: {
          code: '23505',
          message: 'duplicate key value violates unique constraint "shops_sms_from_number_key"',
        },
      }),
    );
    await user.click(screen.getByRole('button', { name: 'Save changes' }));
    expect(await screen.findByText('Another shop already uses this number.')).toBeVisible();
  });
});

describe('DeleteShopPage', () => {
  it('is listed and reachable only for the owner', async () => {
    renderSettings('/app/settings/delete-shop', { role: 'admin' });
    expect(await screen.findByText('You don’t have access to this page')).toBeVisible();
    const nav = screen.getByRole('navigation', { name: 'Settings' });
    expect(within(nav).queryByRole('link', { name: 'Delete shop' })).not.toBeInTheDocument();
    expect(builders.memberships).toBeUndefined();
  });

  it('blocks deletion while memberships still bill through Stripe', async () => {
    setTableResult('memberships', { data: null, count: 2 });
    renderSettings('/app/settings/delete-shop');
    expect(await screen.findByText(/2 memberships still bill customers/)).toBeVisible();
    expect(screen.getByRole('link', { name: 'Memberships page' })).toHaveAttribute(
      'href',
      '/app/memberships',
    );
    expect(screen.getByRole('button', { name: /Delete shop/ })).toBeDisabled();
    const query = builders.memberships?.[0];
    expect(query?.neq).toHaveBeenCalledWith('status', 'cancelled');
    expect(query?.not).toHaveBeenCalledWith('stripe_subscription_id', 'is', null);
  });

  it('deletes the shop after the owner types its name, then leaves settings', async () => {
    setTableResult('memberships', { data: null, count: 0 });
    const { user, router, refetch } = renderSettings('/app/settings/delete-shop');
    const nav = await screen.findByRole('navigation', { name: 'Settings' });
    expect(within(nav).getByRole('link', { name: 'Delete shop' })).toBeInTheDocument();
    await user.click(await screen.findByRole('button', { name: /Delete shop/ }));

    const dialog = await screen.findByRole('alertdialog', { name: 'Delete Glacier Detailing?' });
    const confirm = within(dialog).getByRole('button', { name: 'Delete shop permanently' });
    expect(confirm).toBeDisabled();
    const input = within(dialog).getByLabelText(/Type the shop name/);
    expect(input).toHaveFocus();
    await user.type(input, 'Glacier');
    expect(confirm).toBeDisabled();

    setTableResult('shops', { data: [{ id: 'shop-1' }] });
    await user.type(input, ' Detailing');
    expect(confirm).toBeEnabled();
    await user.click(confirm);

    await waitFor(() => expect(router.state.location.pathname).toBe('/app'));
    const del = builders.shops?.find((b) => b.delete.mock.calls.length > 0);
    expect(del?.eq).toHaveBeenCalledWith('id', 'shop-1');
    expect(refetch).toHaveBeenCalled();
  });

  it('keeps the dialog open with the error when the delete is refused', async () => {
    setTableResult('memberships', { data: null, count: 0 });
    const { user, router } = renderSettings('/app/settings/delete-shop');
    await user.click(await screen.findByRole('button', { name: /Delete shop/ }));
    const dialog = await screen.findByRole('alertdialog');
    setTableResult('shops', { data: [] });
    await user.type(within(dialog).getByLabelText(/Type the shop name/), 'Glacier Detailing');
    await user.keyboard('{Enter}');
    expect(
      await within(dialog).findByText('Only the shop owner can delete this shop.'),
    ).toBeVisible();
    expect(router.state.location.pathname).toBe('/app/settings/delete-shop');
  });

  it('shows a retryable error when the membership check fails', async () => {
    setTableResult('memberships', { data: null, error: { message: 'boom', code: '500' } });
    renderSettings('/app/settings/delete-shop');
    expect(await screen.findByText('Couldn’t load shop details')).toBeVisible();
    expect(screen.getByRole('button', { name: 'Try again' })).toBeVisible();
  });
});
