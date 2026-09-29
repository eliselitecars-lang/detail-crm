import { screen, waitFor, within } from '@testing-library/react';
import { beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import type { MessageTemplate, ShopSettings } from './api';
import { redirectTo } from './externalRedirect';
import { renderSettings } from './testing/renderSettings';
import {
  builders,
  createBuilder,
  edgeHttpError,
  resetSupabaseMock,
  setTableResult,
  supabase,
} from '@/test/supabaseMock';

vi.mock('@/lib/supabase', () => import('@/test/supabaseMock'));

const invoke = supabase.functions.invoke;
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
  techs_can_share_reports: false,
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

  it('shows technicians only their calendar feed', async () => {
    renderSettings('/app/settings/business', { role: 'technician' });
    expect(await screen.findByText('You don’t have access to this page')).toBeVisible();
    const nav = screen.getByRole('navigation', { name: 'Settings' });
    expect(
      within(nav)
        .getAllByRole('link')
        .map((l) => l.textContent),
    ).toEqual(['Calendar feed']);
  });

  it('sends technicians from /app/settings to their calendar feed', async () => {
    setTableResult('calendar_feed_tokens', { data: null });
    const { router } = renderSettings('/app/settings', { role: 'technician' });
    expect(
      await screen.findByRole('heading', { name: 'Calendar feed', level: 2 }, { timeout: 5000 }),
    ).toBeVisible();
    expect(router.state.location.pathname).toBe('/app/settings/calendar-feed');
    expect(await screen.findByText('No calendar feed yet')).toBeVisible();
    // only managers may subscribe to every job
    expect(screen.queryByRole('switch', { name: /Include every job/ })).not.toBeInTheDocument();
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
      expect(supabase.storage.from('shop-assets').upload).toHaveBeenCalledWith(
        'shop-1/logo.png',
        expect.any(File),
        {
          upsert: true,
          contentType: 'image/png',
          cacheControl: '60',
        },
      ),
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

describe('BusinessProfilePage: removing the logo', () => {
  it('asks first; Cancel keeps it, confirming clears logo_path and deletes the file', async () => {
    setTableResult('shops', { data: { ...SHOP, logo_path: 'shop-1/logo.png' } });
    const { user } = renderSettings('/app/settings/business');
    const bucket = supabase.storage.from('shop-assets');
    await user.click(await screen.findByRole('button', { name: 'Remove' }));

    const dialog = await screen.findByRole('alertdialog', { name: 'Remove your logo?' });
    expect(dialog).toHaveTextContent(/booking page, quotes, invoices and customer emails/);
    expect(dialog).toHaveTextContent(/can’t be undone/);
    const logoCleared = () =>
      builders.shops?.some((b) =>
        b.update.mock.calls.some((c) => JSON.stringify(c[0]) === '{"logo_path":null}'),
      ) ?? false;
    await user.click(within(dialog).getByRole('button', { name: 'Cancel' }));
    await waitFor(() =>
      expect(
        screen.queryByRole('alertdialog', { name: 'Remove your logo?' }),
      ).not.toBeInTheDocument(),
    );
    expect(logoCleared()).toBe(false);
    expect(bucket.remove).not.toHaveBeenCalled();

    await user.click(screen.getByRole('button', { name: 'Remove' }));
    await user.click(
      within(await screen.findByRole('alertdialog', { name: 'Remove your logo?' })).getByRole(
        'button',
        { name: 'Remove logo' },
      ),
    );
    await waitFor(() => expect(logoCleared()).toBe(true));
    await waitFor(() => expect(bucket.remove).toHaveBeenCalledWith(['shop-1/logo.png']));
    expect(await screen.findByText('Logo removed')).toBeVisible();
  });
});

describe('BusinessProfilePage: mailing address for marketing email (0119)', () => {
  it('says marketing email stops while the street address or city is blank', async () => {
    const { user } = renderSettings('/app/settings/business');
    const line1 = await screen.findByLabelText('Address line 1');
    expect(
      screen.getByText(/Without a street address and city, marketing email isn’t sent/),
    ).toBeVisible();
    expect(
      screen.getByText(/Marketing emails \(campaigns, rebooking and maintenance/),
    ).toBeVisible();

    await user.type(line1, '1 Main St');
    await waitFor(() =>
      expect(
        screen.queryByText(/Without a street address and city, marketing email isn’t sent/),
      ).not.toBeInTheDocument(),
    );
    // Clearing the city warns again before anything is saved.
    await user.clear(screen.getByLabelText('City'));
    expect(
      await screen.findByText(/Without a street address and city, marketing email isn’t sent/),
    ).toBeVisible();
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
        max_concurrent_shop: null,
        max_concurrent_mobile: null,
        count_member_availability: false,
        allow_multi_day: false,
        multi_day_max_days: 2,
        quote_self_schedule: false,
        meta_pixel_id: null,
        ga4_measurement_id: null,
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

  it('tells shops what their tracking tags see and to keep Meta’s advanced matching off', async () => {
    renderSettings('/app/settings/booking');
    const tracking = await screen.findByRole('region', { name: 'Tracking' });
    expect(tracking).toHaveTextContent(/never give them names, emails, phone numbers or booking/);
    expect(tracking).toHaveTextContent(/keep “Automatic advanced matching” off/);
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
  reminder_offsets_minutes: null,
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

    const amount = within(dialog).getByLabelText('Reminder 1 amount');
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
        reminder_offsets_minutes: null,
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

describe('TemplatesPage: Team invitation (always sent; needs {{invite_link}})', () => {
  const invite = (over: Partial<MessageTemplate> = {}) =>
    template({
      id: 'inv-email',
      key: 'invite',
      channel: 'email',
      subject: 'Join {{shop_name}}',
      body: 'Accept here: {{invite_link}}',
      offset_minutes: null,
      ...over,
    });

  it('labels the switch as the wording, not sending, and says what turning it off does', async () => {
    setTableResult('message_templates', { data: [invite()] });
    const { user } = renderSettings('/app/settings/templates');
    const toggle = await screen.findByRole('switch', {
      name: 'Team invitation: use your wording',
    });
    expect(
      screen.queryByRole('switch', { name: /Team invitation: Email/ }),
    ).not.toBeInTheDocument();
    expect(screen.getByText(/Invitations are always sent/)).toBeVisible();
    await user.click(toggle);
    await waitFor(() => {
      const update = builders.message_templates?.find((b) => b.update.mock.calls.length > 0);
      expect(update?.update).toHaveBeenCalledWith({ enabled: false });
    });
    expect(await screen.findByText('Team invitation: the default wording is used')).toBeVisible();
  });

  it('says the default wording is sent while the wording is off or has no invitation link', async () => {
    setTableResult('message_templates', { data: [invite({ enabled: false })] });
    const first = renderSettings('/app/settings/templates');
    expect(
      await screen.findByText(
        'Your wording is off, so invitations are sent with the default wording.',
      ),
    ).toBeVisible();
    first.unmount();

    setTableResult('message_templates', { data: [invite({ body: 'Welcome aboard!' })] });
    renderSettings('/app/settings/templates');
    expect(
      await screen.findByText(
        /Include the invitation link \(\{\{invite_link\}\}\)\. Without it, invitations are sent with the default wording\. Edit the wording/,
      ),
    ).toBeVisible();
  });

  it('says a shop on its free trial sends the default wording (0124 invite_email_permit)', async () => {
    supabase.rpc.mockImplementation(((fn: string) =>
      createBuilder(
        fn === 'shop_entitlement'
          ? {
              data: {
                billing_enabled: true,
                state: 'trialing',
                reason: 'trial',
                plan_name: null,
                trial_ends_at: '2099-01-01T00:00:00Z',
                current_period_end: null,
                cancel_at_period_end: false,
                max_members: null,
                members_used: 1,
                can_write: true,
                is_owner: true,
              },
            }
          : { data: null },
      )) as never);
    setTableResult('message_templates', { data: [invite()] });
    const { user } = renderSettings('/app/settings/templates');
    expect(
      await screen.findByText(
        'During your free trial, invitations are sent with the default wording.',
      ),
    ).toBeVisible();
    await user.click(screen.getByRole('button', { name: 'Edit Team invitation' }));
    const dialog = await screen.findByRole('dialog', { name: 'Team invitation' });
    expect(
      within(dialog).getByText(
        'Not what’s sent yet: during your free trial, invitations use the default wording.',
      ),
    ).toBeVisible();
  });

  it('refuses to save wording without {{invite_link}} and explains why', async () => {
    setTableResult('message_templates', { data: [invite()] });
    const { user } = renderSettings('/app/settings/templates');
    await user.click(await screen.findByRole('button', { name: 'Edit Team invitation' }));
    const dialog = await screen.findByRole('dialog', { name: 'Team invitation' });
    expect(within(dialog).getByRole('switch', { name: /Use this wording/ })).toBeChecked();
    const body = within(dialog).getByRole('textbox', { name: /^Message/ });
    await user.clear(body);
    await user.type(body, 'Welcome aboard!');
    // Said as it is typed, before any save attempt.
    expect(within(dialog).getByText(/^Include the invitation link/)).toHaveAttribute(
      'role',
      'note',
    );
    expect(within(dialog).getByText(/Not what’s sent/)).toBeVisible();

    await user.click(within(dialog).getByRole('button', { name: 'Save changes' }));
    expect(
      await within(dialog).findByText(
        'Include the invitation link ({{invite_link}}). Without it, invitations are sent with the default wording.',
      ),
    ).toBeVisible();
    expect(builders.message_templates?.some((b) => b.update.mock.calls.length > 0) ?? false).toBe(
      false,
    );

    await user.click(within(dialog).getByRole('button', { name: 'Invitation link' }));
    await user.click(within(dialog).getByRole('button', { name: 'Save changes' }));
    await waitFor(() => {
      const update = builders.message_templates?.find((b) => b.update.mock.calls.length > 0);
      expect(update?.update).toHaveBeenCalledWith({
        body: expect.stringContaining('{{invite_link}}') as unknown,
      });
    });
  });
});

describe('TemplatesPage: marketing email without a mailing address (0119)', () => {
  const marketing = () => [
    template({ id: 'fu-sms', key: 'follow_up', offset_minutes: 43200 }),
    template({ id: 'fu-email', key: 'follow_up', channel: 'email', offset_minutes: 43200 }),
    template({ id: 'sf-email', key: 'service_followup', channel: 'email', offset_minutes: null }),
  ];

  it('says switched-on follow-up emails aren’t sent and links to the Business profile', async () => {
    setTableResult('message_templates', { data: marketing() });
    renderSettings('/app/settings/templates');
    const notice = await screen.findByRole('status', {
      name: 'Marketing email needs your mailing address',
    });
    expect(notice).toHaveTextContent(
      'Rebooking and maintenance follow-up emails are on but aren’t being sent.',
    );
    expect(within(notice).getByRole('link', { name: 'Add the mailing address' })).toHaveAttribute(
      'href',
      '/app/settings/business',
    );
    expect(
      screen.getAllByText(/Emails aren’t sent until the shop’s mailing address is on file/),
    ).toHaveLength(2);
  });

  it('shows nothing once the address is on file, or while those emails are off', async () => {
    setTableResult('shops', { data: { ...SHOP, address_line1: '1 Main St' } });
    setTableResult('message_templates', { data: marketing() });
    const first = renderSettings('/app/settings/templates');
    expect(
      await screen.findByRole('switch', { name: /^Rebooking follow-up: email/i }),
    ).toBeVisible();
    expect(screen.queryByText(/aren’t being sent/)).not.toBeInTheDocument();
    expect(screen.queryByText(/mailing address is on file/)).not.toBeInTheDocument();
    first.unmount();

    setTableResult('shops', { data: SHOP });
    setTableResult('message_templates', {
      data: marketing().map((t) => (t.channel === 'email' ? { ...t, enabled: false } : t)),
    });
    renderSettings('/app/settings/templates');
    expect(
      await screen.findByRole('switch', { name: /^Rebooking follow-up: email/i }),
    ).toBeVisible();
    expect(screen.queryByText(/aren’t being sent/)).not.toBeInTheDocument();
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
        service_ids: null,
        min_subtotal_cents: null,
        once_per_customer: false,
        customer_id: null,
        new_customers_only: false,
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
        kind: 'closed',
        member_id: null,
        title: null,
        starts_at: '2026-12-24T06:00:00.000Z',
        ends_at: '2026-12-26T06:00:00.000Z',
        reason: 'Holiday',
        affects_capacity: true,
        recurrence: null,
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

  it('says how many memberships will be cancelled in Stripe (deletion stays possible)', async () => {
    setTableResult('memberships', { data: null, count: 2 });
    renderSettings('/app/settings/delete-shop');
    expect(
      await screen.findByText(/2 active memberships will be cancelled in Stripe/),
    ).toBeVisible();
    expect(screen.getByRole('button', { name: /Delete shop/ })).toBeEnabled();
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

    invoke.mockResolvedValueOnce({
      data: { deleted: true, memberships_cancelled: 0, sessions_expired: 0 },
      error: null,
    });
    await user.type(input, ' Detailing');
    expect(confirm).toBeEnabled();
    await user.click(confirm);

    await waitFor(() => expect(router.state.location.pathname).toBe('/app'));
    expect(invoke).toHaveBeenCalledWith('payments', {
      body: { action: 'delete_shop', shop_id: 'shop-1', confirm_name: 'Glacier Detailing' },
    });
    expect(builders.shops?.some((b) => b.delete.mock.calls.length > 0) ?? false).toBe(false);
    expect(refetch).toHaveBeenCalled();
  });

  it('keeps the dialog open with the error when the delete is refused', async () => {
    setTableResult('memberships', { data: null, count: 0 });
    const { user, router } = renderSettings('/app/settings/delete-shop');
    await user.click(await screen.findByRole('button', { name: /Delete shop/ }));
    const dialog = await screen.findByRole('alertdialog');
    invoke.mockResolvedValueOnce({
      data: null,
      error: edgeHttpError(409, {
        error: 'A payment for this is already being processed. Refresh in a moment.',
        code: 'conflict',
        details: { reason: 'payment_in_progress' },
      }),
    });
    await user.type(within(dialog).getByLabelText(/Type the shop name/), 'Glacier Detailing');
    await user.keyboard('{Enter}');
    expect(
      await within(dialog).findByText(/still being processed.*Nothing was deleted\./),
    ).toBeVisible();
    expect(router.state.location.pathname).toBe('/app/settings/delete-shop');
  });

  it('says the subscription is cancelled too while billing is on, and why nothing was deleted', async () => {
    setTableResult('memberships', { data: null, count: 0 });
    supabase.rpc.mockImplementation(((fn: string) =>
      createBuilder(
        fn === 'shop_entitlement'
          ? {
              data: {
                billing_enabled: true,
                state: 'active',
                reason: 'subscribed',
                plan_name: 'Plan A',
                trial_ends_at: null,
                current_period_end: '2099-01-01T00:00:00Z',
                cancel_at_period_end: false,
                max_members: null,
                members_used: 1,
                can_write: true,
                is_owner: true,
              },
            }
          : { data: null },
      )) as never);
    const { user } = renderSettings('/app/settings/delete-shop');
    expect(
      await screen.findByText(/subscription is cancelled right away, so it isn’t charged again/),
    ).toBeVisible();
    await user.click(screen.getByRole('button', { name: /Delete shop/ }));
    const dialog = await screen.findByRole('alertdialog', {
      description: /and its subscription is cancelled/,
    });
    invoke.mockResolvedValueOnce({
      data: null,
      error: edgeHttpError(502, {
        error: "The shop's subscription could not be cancelled, so the shop was not deleted.",
        code: 'upstream_error',
        details: { reason: 'platform_subscription_cancel_failed' },
      }),
    });
    await user.type(within(dialog).getByLabelText(/Type the shop name/), 'Glacier Detailing');
    await user.keyboard('{Enter}');
    expect(
      await within(dialog).findByText(
        'We could not cancel the shop’s subscription, so nothing was deleted. Try again.',
      ),
    ).toBeVisible();
  });

  it('says the subscription is cancelled when one is live though billing is switched off', async () => {
    setTableResult('memberships', { data: null, count: 0 });
    setTableResult('shop_billing', {
      data: [
        {
          plan_id: 'plan-a',
          status: 'active',
          trial_ends_at: null,
          current_period_end: '2099-01-01T00:00:00Z',
          cancel_at_period_end: false,
        },
      ],
    });
    supabase.rpc.mockImplementation(((fn: string) =>
      createBuilder(
        fn === 'shop_entitlement'
          ? {
              data: {
                billing_enabled: false,
                state: 'active',
                reason: 'billing_off',
                plan_name: null,
                trial_ends_at: null,
                current_period_end: null,
                cancel_at_period_end: false,
                max_members: null,
                members_used: null,
                can_write: true,
                is_owner: true,
              },
            }
          : { data: null },
      )) as never);
    const { user } = renderSettings('/app/settings/delete-shop');
    expect(
      await screen.findByText(/subscription is cancelled right away, so it isn’t charged again/),
    ).toBeVisible();
    await user.click(screen.getByRole('button', { name: /Delete shop/ }));
    expect(
      await screen.findByRole('alertdialog', { description: /and its subscription is cancelled/ }),
    ).toBeVisible();
  });

  it('promises no subscription cancel when the shop has none that can bill', async () => {
    setTableResult('memberships', { data: null, count: 0 });
    setTableResult('shop_billing', {
      data: [
        {
          plan_id: null,
          status: 'canceled',
          trial_ends_at: null,
          current_period_end: '2020-01-01T00:00:00Z',
          cancel_at_period_end: false,
        },
      ],
    });
    renderSettings('/app/settings/delete-shop');
    expect(await screen.findByRole('button', { name: /Delete shop/ })).toBeVisible();
    await waitFor(() => expect(builders.shop_billing?.length ?? 0).toBeGreaterThan(0));
    expect(screen.queryByText(/subscription is cancelled/)).not.toBeInTheDocument();
  });

  it('shows a retryable error when the membership check fails', async () => {
    setTableResult('memberships', { data: null, error: { message: 'boom', code: '500' } });
    renderSettings('/app/settings/delete-shop');
    expect(await screen.findByText('Couldn’t load shop details')).toBeVisible();
    expect(screen.getByRole('button', { name: 'Try again' })).toBeVisible();
  });
});
