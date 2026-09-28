import { screen, waitFor, within } from '@testing-library/react';
import { beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import type { ShopSettings } from './api';
import { renderSettings } from './testing/renderSettings';
import {
  builders,
  edgeHttpError,
  mockRpc,
  pgError,
  resetSupabaseMock,
  setTableResult,
  supabase,
} from '@/test/supabaseMock';

vi.mock('@/lib/supabase', () => import('@/test/supabaseMock'));

const SHOP: ShopSettings = {
  id: 'shop-1',
  name: 'Glacier Detailing',
  slug: 'glacier-detailing',
  email: 'hello@glacier.test',
  phone: '+12055550100',
  website: 'https://glacier.test',
  address_line1: '1 Main St',
  address_line2: null,
  city: 'Birmingham',
  region: 'AL',
  postal_code: '35203',
  country: 'US',
  timezone: 'America/Chicago',
  currency: 'usd',
  logo_path: null,
  brand_color: null,
  business_type: 'both',
  tax_rate_bps: 0,
  techs_can_collect_payments: false,
  techs_can_share_reports: false,
  review_url: null,
  quote_terms: null,
  invoice_terms: null,
  invoice_due_days: 0,
  sms_from_number: null,
  updated_at: '2026-01-01T00:00:00Z',
};

beforeAll(async () => {
  await Promise.all([
    import('./SettingsPage'),
    import('./pages/FollowupsPage'),
    import('./pages/CustomFieldsPage'),
    import('./pages/BookingLinksPage'),
    import('./pages/FeesPage'),
    import('./pages/WebhooksPage'),
    import('./pages/CalendarFeedPage'),
    import('./pages/ImportExportPage'),
    import('./pages/GiftCardSettingsPage'),
    import('./pages/ReferralSettingsPage'),
    import('./pages/SmsPage'),
    import('./pages/LeadFormsPage'),
  ]);
}, 60_000);

beforeEach(() => {
  resetSupabaseMock();
  setTableResult('shops', { data: SHOP });
});

function updateCall(table: string) {
  return builders[table]?.find((b) => b.update.mock.calls.length > 0)?.update.mock.calls[0]?.[0];
}
function insertCall(table: string) {
  return builders[table]?.find((b) => b.insert.mock.calls.length > 0)?.insert.mock.calls[0]?.[0];
}

describe('settings navigation (parity sections)', () => {
  it('groups the new sections and hides admin-only ones from managers', async () => {
    setTableResult('followup_settings', { data: null, error: null });
    renderSettings('/app/settings/fees', { role: 'manager' });
    const nav = await screen.findByRole('navigation', { name: 'Settings' });
    for (const label of [
      'Private booking links',
      'Custom fields',
      'Lead forms',
      'Fees',
      'Gift cards',
      'Referrals',
      'Follow-ups',
      'Import & export',
      'Calendar feed',
    ]) {
      expect(within(nav).getByRole('link', { name: label })).toBeInTheDocument();
    }
    expect(within(nav).queryByRole('link', { name: 'Webhooks' })).not.toBeInTheDocument();
  });

  it('blocks managers from webhooks', async () => {
    renderSettings('/app/settings/webhooks', { role: 'manager' });
    expect(await screen.findByText('You don’t have access to this page')).toBeVisible();
  });
});

describe('FollowupsPage', () => {
  it('saves the schedule and turns the message on when every channel is off', async () => {
    setTableResult('followup_settings', {
      data: {
        shop_id: 'shop-1',
        quote_enabled: false,
        quote_first_after_hours: 48,
        quote_repeat_every_hours: 72,
        quote_max_attempts: 2,
        deposit_enabled: false,
        deposit_first_after_hours: 24,
        deposit_repeat_every_hours: 48,
        deposit_max_attempts: 2,
        invoice_enabled: false,
        invoice_first_after_hours: 72,
        invoice_repeat_every_hours: 168,
        invoice_max_attempts: 2,
        overdue_enabled: false,
        overdue_first_after_days: 1,
        overdue_repeat_every_days: 7,
        overdue_max_attempts: 3,
        created_at: '2026-01-01T00:00:00Z',
        updated_at: '2026-01-01T00:00:00Z',
      },
    });
    setTableResult('message_templates', {
      data: [
        {
          id: 'qr-sms',
          key: 'quote_reminder',
          channel: 'sms',
          subject: null,
          body: 'x',
          enabled: false,
          offset_minutes: null,
          reminder_offsets_minutes: null,
          updated_at: '2026-01-01T00:00:00Z',
        },
      ],
    });
    const { user, queryClient } = renderSettings('/app/settings/followups');
    const invalidate = vi.spyOn(queryClient, 'invalidateQueries');
    const section = await screen.findByRole('region', { name: 'Quotes waiting for an answer' });
    await user.click(within(section).getByRole('switch', { name: 'Send automatically' }));
    expect(within(section).getByText(/text and email are both off/)).toBeVisible();
    const first = within(section).getByLabelText(/First reminder after the quote is sent/);
    expect(first.tagName).toBe('INPUT');
    const firstUnit = within(section).getByRole('combobox', {
      name: 'Unit for the first reminder',
    });
    const repeatUnit = within(section).getByRole('combobox', { name: 'Unit for the repeat' });
    // Each unit picker is its own control: no id, description or error state shared with
    // the number input of the same field.
    for (const unit of [firstUnit, repeatUnit]) {
      expect(unit).not.toHaveAttribute('id');
      expect(unit).not.toHaveAttribute('aria-describedby');
    }
    const ids = [...section.querySelectorAll('[id]')].map((el) => el.id);
    expect(new Set(ids).size).toBe(ids.length);
    await user.clear(first);
    await user.type(first, 'x');
    await user.click(screen.getByRole('button', { name: 'Save changes' }));
    await waitFor(() => expect(first).toHaveAttribute('aria-invalid', 'true'));
    expect(firstUnit).not.toHaveAttribute('aria-invalid');
    await user.clear(first);
    await user.type(first, '3');
    await user.selectOptions(firstUnit, 'days');
    await user.click(screen.getByRole('button', { name: 'Save changes' }));
    await waitFor(() =>
      expect(updateCall('followup_settings')).toMatchObject({
        quote_enabled: true,
        quote_first_after_hours: 72,
        quote_repeat_every_hours: 72,
        quote_max_attempts: 2,
      }),
    );
    await waitFor(() => expect(updateCall('message_templates')).toEqual({ enabled: true }));
    // Open quote and invoice pages re-read their follow-up schedule.
    await waitFor(() =>
      expect(invalidate).toHaveBeenCalledWith({ queryKey: ['shop', 'shop-1', 'followups'] }),
    );
  });
});

describe('CustomFieldsPage', () => {
  it('adds a job booking question with a key suggested from the label', async () => {
    setTableResult('custom_fields', { data: [] });
    const { user } = renderSettings('/app/settings/custom-fields');
    await user.click(await screen.findByRole('tab', { name: 'Job fields & booking questions' }));
    await user.click((await screen.findAllByRole('button', { name: 'Add field' }))[0]!);
    const dialog = await screen.findByRole('dialog', { name: 'New job field' });
    await user.type(within(dialog).getByLabelText(/^Label/), 'Gate code');
    expect(within(dialog).getByLabelText(/^Key/)).toHaveValue('gate_code');
    await user.click(within(dialog).getByRole('switch', { name: 'Ask when booking' }));
    await user.selectOptions(within(dialog).getByLabelText('Ask on'), 'mobile');
    await user.click(within(dialog).getByRole('button', { name: 'Add field' }));
    await waitFor(() =>
      expect(insertCall('custom_fields')).toMatchObject({
        entity: 'job',
        key: 'gate_code',
        label: 'Gate code',
        type: 'text',
        options: [],
        show_in_booking: true,
        show_in_lead_form: false,
        location_scope: 'mobile',
        shop_id: 'shop-1',
      }),
    );
  });

  it('requires options for a choice field', async () => {
    setTableResult('custom_fields', { data: [] });
    const { user } = renderSettings('/app/settings/custom-fields');
    await user.click((await screen.findAllByRole('button', { name: 'Add field' }))[0]!);
    const dialog = await screen.findByRole('dialog', { name: 'New customer field' });
    await user.type(within(dialog).getByLabelText(/^Label/), 'Preferred contact');
    await user.selectOptions(within(dialog).getByLabelText(/^Type/), 'select');
    await user.click(within(dialog).getByRole('button', { name: 'Add field' }));
    expect(await within(dialog).findByText('Add at least one option.')).toBeVisible();
    expect(insertCall('custom_fields')).toBeUndefined();
  });
});

describe('FeesPage', () => {
  it('adds an automatic mobile fee in cents', async () => {
    setTableResult('shop_fees', { data: [] });
    const { user } = renderSettings('/app/settings/fees');
    await user.click((await screen.findAllByRole('button', { name: 'Add fee' }))[0]!);
    const dialog = await screen.findByRole('dialog', { name: 'New fee' });
    await user.type(within(dialog).getByLabelText(/^Name/), 'Travel fee');
    await user.type(within(dialog).getByLabelText(/^Amount/), '25');
    await user.selectOptions(within(dialog).getByLabelText('When to add it'), 'mobile');
    await user.click(within(dialog).getByRole('button', { name: 'Add fee' }));
    await waitFor(() =>
      expect(insertCall('shop_fees')).toEqual({
        name: 'Travel fee',
        amount_cents: 2500,
        taxable: false,
        auto_apply: 'mobile',
        active: true,
        sort: 1,
        shop_id: 'shop-1',
      }),
    );
  });
});

describe('BookingLinksPage', () => {
  it('creates a link with hand-picked services and shows its URL', async () => {
    setTableResult('booking_links', { data: [] });
    setTableResult('services', {
      data: [
        {
          id: 'svc-1',
          name: 'Ceramic coating',
          kind: 'service',
          active: true,
          online_bookable: false,
          category_id: null,
        },
        {
          id: 'svc-2',
          name: 'Air freshener',
          kind: 'product',
          active: true,
          online_bookable: false,
          category_id: null,
        },
      ],
    });
    const { user } = renderSettings('/app/settings/booking-links');
    await user.click((await screen.findAllByRole('button', { name: 'New link' }))[0]!);
    const dialog = await screen.findByRole('dialog', { name: 'New private booking link' });
    expect(within(dialog).queryByLabelText('Air freshener')).not.toBeInTheDocument();
    expect(within(dialog).getByText('Hidden online')).toBeVisible();
    await user.type(within(dialog).getByLabelText(/^Name/), 'Fleet washes');
    await user.click(within(dialog).getByRole('button', { name: 'Create link' }));
    expect(await within(dialog).findByText('Choose at least one service.')).toBeVisible();
    await user.click(within(dialog).getByLabelText('Ceramic coating'));
    await user.click(within(dialog).getByRole('button', { name: 'Create link' }));
    await waitFor(() =>
      expect(insertCall('booking_links')).toEqual({
        name: 'Fleet washes',
        service_ids: ['svc-1'],
        note: null,
        active: true,
        expires_at: null,
        shop_id: 'shop-1',
      }),
    );
  });

  it('lists links with their private URL', async () => {
    setTableResult('booking_links', {
      data: [
        {
          id: 'l1',
          token: '11111111-1111-4111-8111-111111111111',
          name: 'VIP',
          service_ids: ['svc-1'],
          note: null,
          active: true,
          expires_at: null,
          created_at: '2026-01-01T00:00:00Z',
        },
      ],
    });
    setTableResult('services', { data: [] });
    renderSettings('/app/settings/booking-links', { role: 'manager' });
    expect(await screen.findByLabelText('Link for VIP')).toHaveTextContent(
      `${window.location.origin}/book/glacier-detailing?link=11111111-1111-4111-8111-111111111111`,
    );
    expect(screen.queryByRole('button', { name: 'Edit VIP' })).not.toBeInTheDocument();
  });
});

describe('WebhooksPage', () => {
  it('creates an endpoint and shows the signing secret once', async () => {
    setTableResult('webhook_endpoints', { data: [] });
    setTableResult('webhook_deliveries', { data: [] });
    const calls = mockRpc({
      create_webhook_endpoint: { data: { id: 'w1', secret: `whsec_${'a'.repeat(64)}` } },
    });
    const { user } = renderSettings('/app/settings/webhooks');
    await user.click((await screen.findAllByRole('button', { name: 'Add endpoint' }))[0]!);
    const dialog = await screen.findByRole('dialog', { name: 'New webhook endpoint' });
    await user.type(within(dialog).getByLabelText(/^URL/), 'https://127.0.0.1/hook');
    await user.click(within(dialog).getByRole('button', { name: 'Add endpoint' }));
    expect(await within(dialog).findByText('Use a host name, not an IP address.')).toBeVisible();
    const url = within(dialog).getByLabelText(/^URL/);
    await user.clear(url);
    await user.type(url, 'https://hooks.zapier.test/catch/1');
    await user.click(within(dialog).getByLabelText('Form signed'));
    await user.click(within(dialog).getByRole('button', { name: 'Add endpoint' }));
    const secret = await screen.findByRole('dialog', { name: 'Endpoint added' });
    expect(within(secret).getByLabelText('Signing secret')).toHaveTextContent(
      `whsec_${'a'.repeat(64)}`,
    );
    expect(calls.find((c) => c.fn === 'create_webhook_endpoint')?.args).toEqual({
      p_shop_id: 'shop-1',
      p_url: 'https://hooks.zapier.test/catch/1',
      p_events: [
        'booking_created',
        'booking_confirmed',
        'on_the_way',
        'job_completed',
        'payment_succeeded',
        'membership_activated',
      ],
    });
  });
});

describe('CalendarFeedPage', () => {
  it('creates a personal feed with https and webcal links', async () => {
    setTableResult('calendar_feed_tokens', { data: null });
    const calls = mockRpc({
      create_calendar_feed: {
        data: {
          token: '22222222-2222-4222-8222-222222222222',
          path: '/functions/v1/calendar-feed?token=22222222-2222-4222-8222-222222222222',
        },
      },
    });
    const { user } = renderSettings('/app/settings/calendar-feed', { role: 'manager' });
    await user.click(await screen.findByRole('switch', { name: /Include every job/ }));
    await user.click(screen.getByRole('button', { name: 'Create my calendar link' }));
    await waitFor(() =>
      expect(calls.find((c) => c.fn === 'create_calendar_feed')?.args).toEqual({
        p_shop_id: 'shop-1',
        p_include_all: true,
      }),
    );
  });

  it('shows the live link', async () => {
    setTableResult('calendar_feed_tokens', {
      data: {
        id: 'f1',
        token: '33333333-3333-4333-8333-333333333333',
        include_all: false,
        created_at: '2026-01-01T00:00:00Z',
        last_accessed_at: null,
      },
    });
    renderSettings('/app/settings/calendar-feed', { role: 'technician' });
    expect(await screen.findByLabelText('Calendar link')).toHaveTextContent(
      'https://unit-test.supabase.co/functions/v1/calendar-feed?token=33333333-3333-4333-8333-333333333333',
    );
    expect(screen.getByRole('link', { name: /Open in calendar app/ })).toHaveAttribute(
      'href',
      'webcal://unit-test.supabase.co/functions/v1/calendar-feed?token=33333333-3333-4333-8333-333333333333',
    );
  });
});

describe('ImportExportPage', () => {
  it('waits for the vehicle sizes before matching a services file, then maps per-size prices', async () => {
    setTableResult('import_batches', { data: [] });
    setTableResult('custom_fields', { data: [] });
    setTableResult('vehicle_categories', { error: { code: '57014', message: 'timeout' } });
    const { user } = renderSettings('/app/settings/import-export', { role: 'manager' });
    await screen.findByText('Import from a spreadsheet');
    // A customers file does not need the sizes.
    const csv = 'Service,Price,Price SUV\nFull detail,150,190\n';
    const input = document.querySelector<HTMLInputElement>('input[type="file"]');
    await user.upload(input!, new File([csv], 'services.csv', { type: 'text/csv' }));
    expect(await screen.findByText('services.csv')).toBeVisible();

    await user.click(screen.getByRole('radio', { name: /Services & prices/ }));
    // Sizes failed: said so, nothing can be matched or checked yet.
    expect(await screen.findByText('Couldn’t load your vehicle sizes')).toBeVisible();
    expect(screen.queryByLabelText('Field for the column Price SUV')).toBeNull();
    expect(screen.getByRole('button', { name: 'Check the file' })).toBeDisabled();

    setTableResult('vehicle_categories', {
      data: [
        { id: 'cat-1', name: 'Sedan', sort: 1 },
        { id: 'cat-2', name: 'SUV', sort: 2 },
      ],
    });
    await user.click(screen.getByRole('button', { name: 'Try again' }));
    // The mapping is suggested again against the sizes that arrived.
    expect(await screen.findByLabelText('Field for the column Price SUV')).toHaveValue('price.SUV');
    expect(screen.getByLabelText('Field for the column Price')).toHaveValue('price.base');
    expect(screen.getByLabelText('Field for the column Service')).toHaveValue('name');
    expect(screen.getByRole('button', { name: 'Check the file' })).toBeEnabled();
  });

  it('imports the custom-field columns of a customer export', async () => {
    setTableResult('import_batches', { data: [] });
    setTableResult('vehicle_categories', { data: [] });
    setTableResult('custom_fields', {
      data: [
        {
          id: 'f-1',
          entity: 'customer',
          key: 'referred_by',
          label: 'Referred by',
          type: 'text',
          options: [],
          help_text: null,
          required: false,
          show_in_booking: false,
          show_in_lead_form: false,
          location_scope: null,
          sort: 1,
          archived_at: null,
        },
        {
          id: 'f-2',
          entity: 'customer',
          key: 'fleet_size',
          label: 'Fleet size',
          type: 'number',
          options: [],
          help_text: null,
          required: false,
          show_in_booking: false,
          show_in_lead_form: false,
          location_scope: null,
          sort: 2,
          archived_at: null,
        },
        {
          id: 'f-3',
          entity: 'customer',
          key: 'old',
          label: 'Old field',
          type: 'text',
          options: [],
          help_text: null,
          required: false,
          show_in_booking: false,
          show_in_lead_form: false,
          location_scope: null,
          sort: 3,
          archived_at: '2026-01-01T00:00:00Z',
        },
      ],
    });
    const calls = mockRpc({
      import_customers: () => ({
        data: {
          batch_id: null,
          dry_run: true,
          counts: { created: 1, updated: 0, skipped: 0, errors: 0 },
          rows: [
            { row: 1, action: 'create', customer_id: null, vehicle_action: 'none', message: null },
          ],
        },
      }),
    });
    const { user } = renderSettings('/app/settings/import-export', { role: 'manager' });
    await screen.findByText('Import from a spreadsheet');
    const csv = 'First name,Email,Referred by,Fleet size,Old field\nAnn,ann@x.test,Bob,3,x\n';
    const input = document.querySelector<HTMLInputElement>('input[type="file"]');
    await user.upload(input!, new File([csv], 'customers.csv', { type: 'text/csv' }));
    expect(await screen.findByLabelText('Field for the column Referred by')).toHaveValue(
      'custom.referred_by',
    );
    expect(screen.getByLabelText('Field for the column Fleet size')).toHaveValue(
      'custom.fleet_size',
    );
    // archived fields are not offered
    expect(screen.getByLabelText('Field for the column Old field')).toHaveValue('');
    await user.click(screen.getByRole('button', { name: 'Check the file' }));
    expect(await screen.findByText('Check results (nothing saved yet)')).toBeVisible();
    expect(calls.find((c) => c.fn === 'import_customers')?.args).toMatchObject({
      p_rows: [
        {
          first_name: 'Ann',
          email: 'ann@x.test',
          custom_data: { referred_by: 'Bob', fleet_size: 3 },
        },
      ],
    });
  });

  it('maps columns, checks the file (dry run) and then imports', async () => {
    setTableResult('import_batches', { data: [] });
    setTableResult('vehicle_categories', { data: [] });
    setTableResult('custom_fields', { data: [] });
    const calls = mockRpc({
      import_customers: (args) => ({
        data: {
          batch_id: args.p_dry_run ? null : 'batch-1',
          dry_run: args.p_dry_run,
          counts: { created: 1, updated: 0, skipped: 0, errors: 1 },
          rows: [
            {
              row: 1,
              action: 'create',
              customer_id: null,
              vehicle_action: 'create',
              message: null,
            },
            {
              row: 2,
              action: 'error',
              customer_id: null,
              vehicle_action: 'none',
              message: 'email is not valid',
            },
          ],
        },
      }),
    });
    const { user } = renderSettings('/app/settings/import-export', { role: 'manager' });
    await screen.findByText('Import from a spreadsheet');
    const csv =
      'Name,E-mail,Make,Model,Notes\nJane Doe,jane@x.test,Honda,Civic,\nBob,not-an-email,,,\n';
    const input = document.querySelector<HTMLInputElement>('input[type="file"]');
    await user.upload(input!, new File([csv], 'clients.csv', { type: 'text/csv' }));
    expect(await screen.findByText('clients.csv')).toBeVisible();
    expect(screen.getByLabelText('Field for the column E-mail')).toHaveValue('email');
    expect(screen.getByLabelText('Field for the column Name')).toHaveValue('full_name');
    expect(screen.getByLabelText('Field for the column Make')).toHaveValue('vehicle.make');

    await user.click(screen.getByRole('button', { name: 'Check the file' }));
    expect(await screen.findByText('Check results (nothing saved yet)')).toBeVisible();
    const imports = calls.filter((c) => c.fn === 'import_customers');
    expect(imports[0]?.args).toMatchObject({
      p_shop_id: 'shop-1',
      p_dry_run: true,
      p_file_name: 'clients.csv',
      p_rows: [
        {
          first_name: 'Jane',
          last_name: 'Doe',
          email: 'jane@x.test',
          vehicle: { make: 'Honda', model: 'Civic' },
        },
        { first_name: 'Bob', email: 'not-an-email' },
      ],
    });
    expect(screen.getAllByText('email is not valid')[0]).toBeVisible();

    await user.click(screen.getByRole('button', { name: 'Import 1 row' }));
    expect(await screen.findByText('Import results')).toBeVisible();
    expect(calls.filter((c) => c.fn === 'import_customers')[1]?.args).toMatchObject({
      p_dry_run: false,
    });
  });
  it('resumes an import that stopped part-way instead of sending the saved rows again', async () => {
    setTableResult('vehicle_categories', { data: [] });
    setTableResult('custom_fields', { data: [] });
    // What the batch row says after the first chunk (500 rows) was saved.
    setTableResult('import_batches', {
      data: [
        {
          id: 'batch-1',
          kind: 'customers',
          status: 'committed',
          file_name: 'big.csv',
          row_count: 500,
          created_count: 500,
          updated_count: 0,
          skipped_count: 0,
          error_count: 0,
          created_at: '2026-01-01T00:00:00Z',
        },
      ],
    });
    let failNext = true;
    const created = (rows: unknown[]) => ({
      counts: { created: rows.length, updated: 0, skipped: 0, errors: 0 },
      rows: rows.map((_, i) => ({ row: i + 1, action: 'create', vehicle_action: 'none' })),
    });
    const calls = mockRpc({
      import_customers: (args) => {
        const rows = args.p_rows as unknown[];
        if (args.p_dry_run) return { data: { batch_id: null, dry_run: true, ...created(rows) } };
        if (args.p_batch_id && failNext) {
          failNext = false;
          return pgError('57014', 'canceling statement due to statement timeout');
        }
        return { data: { batch_id: 'batch-1', dry_run: false, ...created(rows) } };
      },
    });
    const { user } = renderSettings('/app/settings/import-export', { role: 'manager' });
    await screen.findByText('Import from a spreadsheet');
    const lines = Array.from({ length: 600 }, (_, i) => `Customer ${i + 1}`);
    const input = document.querySelector<HTMLInputElement>('input[type="file"]');
    await user.upload(
      input!,
      new File([`Name\n${lines.join('\n')}\n`], 'big.csv', { type: 'text/csv' }),
    );
    await user.click(await screen.findByRole('button', { name: 'Check the file' }));
    await user.click(await screen.findByRole('button', { name: 'Import 600 rows' }));

    const alert = await screen.findByRole('alert');
    expect(alert).toHaveTextContent('The import stopped after 500 of 600 rows.');
    expect(alert).toHaveTextContent('customers without an email or phone would be added twice');
    // The full-file import is no longer offered.
    expect(screen.queryByRole('button', { name: 'Import 600 rows' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'Check again' })).toBeNull();

    await user.click(within(alert).getByRole('button', { name: 'Import the remaining 100 rows' }));
    expect(await screen.findByText('Import results')).toBeVisible();
    const commits = calls.filter((c) => c.args.p_dry_run === false);
    expect(commits).toHaveLength(3);
    expect(commits[2]?.args).toMatchObject({ p_batch_id: 'batch-1' });
    const resumed = commits[2]?.args.p_rows as { first_name: string }[];
    expect(resumed).toHaveLength(100);
    expect(resumed[0]).toEqual({ first_name: 'Customer', last_name: '501' });
    expect(screen.getByText('600 new')).toBeVisible();
    // One nonce per committed chunk; the resumed chunk (timed out, maybe
    // applied) is sent again with ITS nonce. Dry runs carry none.
    const nonces = commits.map((c) => c.args.p_request_nonce);
    expect(nonces[0]).toMatch(/^[A-Za-z0-9_-]{8,64}$/);
    expect(nonces[1]).not.toBe(nonces[0]);
    expect(nonces[2]).toBe(nonces[1]);
    expect(calls.filter((c) => c.args.p_dry_run === true)[0]?.args).not.toHaveProperty(
      'p_request_nonce',
    );
  });

  it('retries a chunk whose reply was lost with the same nonce and counts the replay once', async () => {
    setTableResult('import_batches', { data: [] });
    setTableResult('vehicle_categories', { data: [] });
    setTableResult('custom_fields', { data: [] });
    let commits = 0;
    const result = (dryRun: boolean, replayed?: boolean) => ({
      data: {
        batch_id: dryRun ? null : 'batch-1',
        dry_run: dryRun,
        counts: { created: 1, updated: 0, skipped: 0, errors: 0 },
        rows: [{ row: 1, action: 'create', vehicle_action: 'none' }],
        ...(replayed ? { replayed: true } : {}),
      },
    });
    const calls = mockRpc({
      import_customers: (args) => {
        if (args.p_dry_run) return result(true);
        commits += 1;
        // the first commit is applied, but its reply never arrives
        return commits === 1
          ? { data: null, error: new TypeError('Failed to fetch') }
          : result(false, true);
      },
    });
    const { user } = renderSettings('/app/settings/import-export', { role: 'manager' });
    await screen.findByText('Import from a spreadsheet');
    const input = document.querySelector<HTMLInputElement>('input[type="file"]');
    await user.upload(input!, new File(['Name\nJane Doe\n'], 'one.csv', { type: 'text/csv' }));
    await user.click(await screen.findByRole('button', { name: 'Check the file' }));
    await user.click(await screen.findByRole('button', { name: 'Import 1 row' }));
    expect(await screen.findByText(/Can’t reach the server|Can't reach the server/)).toBeVisible();
    await user.click(screen.getByRole('button', { name: 'Import 1 row' }));
    expect(await screen.findByText('Import results')).toBeVisible();
    expect(
      screen.getByText(/1 row was already saved by an earlier attempt whose reply was lost/),
    ).toBeVisible();
    const sent = calls.filter((c) => c.args.p_dry_run === false);
    expect(sent).toHaveLength(2);
    expect(sent[1]?.args.p_request_nonce).toBe(sent[0]?.args.p_request_nonce);
    expect(screen.getByText('1 new')).toBeVisible();
  });
});

describe('GiftCardSettingsPage', () => {
  it('validates offers and saves cents', async () => {
    setTableResult('gift_card_settings', {
      data: {
        shop_id: 'shop-1',
        online_enabled: false,
        offers: [],
        allow_custom_amount: false,
        min_custom_cents: 1000,
        max_custom_cents: 50000,
        expires_months: null,
        terms: null,
        updated_at: '2026-01-01T00:00:00Z',
      },
    });
    const { user } = renderSettings('/app/settings/gift-cards');
    await user.click(await screen.findByRole('switch', { name: 'Sell gift cards online' }));
    await user.click(screen.getByRole('button', { name: 'Save changes' }));
    expect(
      await screen.findByText('Add at least one card or allow custom amounts to sell online.'),
    ).toBeVisible();
    await user.click(screen.getByRole('button', { name: 'Add a card' }));
    await user.type(screen.getByLabelText('Card 1 value'), '100');
    await user.type(screen.getByLabelText('Card 1 price'), '120');
    await user.click(screen.getByRole('button', { name: 'Save changes' }));
    expect(await screen.findByText('The price can’t be more than the card value.')).toBeVisible();
    const price = screen.getByLabelText('Card 1 price');
    await user.clear(price);
    await user.type(price, '90');
    await user.click(screen.getByRole('button', { name: 'Save changes' }));
    await waitFor(() =>
      expect(updateCall('gift_card_settings')).toMatchObject({
        online_enabled: true,
        offers: [{ value_cents: 10000, price_cents: 9000 }],
        expires_months: null,
      }),
    );
  });
});

describe('ReferralSettingsPage', () => {
  it('needs a discount to turn the programme on', async () => {
    setTableResult('referral_settings', {
      data: {
        shop_id: 'shop-1',
        enabled: false,
        referee_discount_kind: 'fixed',
        referee_discount_value: 0,
        referrer_reward_cents: 0,
        terms: null,
        updated_at: '2026-01-01T00:00:00Z',
      },
    });
    const { user } = renderSettings('/app/settings/referrals');
    await user.click(await screen.findByRole('switch', { name: 'Referral programme on' }));
    await user.click(screen.getByRole('button', { name: 'Save changes' }));
    expect(await screen.findByText('Enter an amount greater than $0.')).toBeVisible();
    await user.type(screen.getByLabelText('Discount amount'), '20');
    await user.type(screen.getByLabelText(/Reward for the referrer/), '15');
    await user.click(screen.getByRole('button', { name: 'Save changes' }));
    await waitFor(() =>
      expect(updateCall('referral_settings')).toEqual({
        enabled: true,
        referee_discount_kind: 'fixed',
        referee_discount_value: 2000,
        referrer_reward_cents: 1500,
        terms: null,
      }),
    );
  });
});

describe('SmsPage (self-serve numbers)', () => {
  it('keeps the manual number when provisioning is off', async () => {
    supabase.functions.invoke.mockResolvedValue({
      data: { enabled: false, isv_enabled: false },
      error: null,
    });
    renderSettings('/app/settings/sms');
    expect(await screen.findByText(/Buying a number yourself isn’t available yet/)).toBeVisible();
    expect(screen.getByLabelText('SMS from number')).toBeVisible();
  });

  it('searches and buys a toll-free number when provisioning is on', async () => {
    supabase.functions.invoke.mockImplementation(((
      _name: string,
      options: { body: { action: string } },
    ) => {
      if (options.body.action === 'status') {
        return Promise.resolve({ data: { enabled: true, isv_enabled: false }, error: null });
      }
      if (options.body.action === 'search_numbers') {
        return Promise.resolve({
          data: { numbers: [{ phone_e164: '+18885550123', locality: null, region: 'US' }] },
          error: null,
        });
      }
      return Promise.resolve({ data: { number: '+18885550123' }, error: null });
    }) as never);
    mockRpc({
      sms_provisioning_status: {
        data: {
          number: null,
          kind: null,
          verification_status: null,
          rejection_reason: null,
          provisioned: false,
        },
      },
    });
    const { user } = renderSettings('/app/settings/sms');
    expect(await screen.findByText('Get a texting number')).toBeVisible();
    expect(screen.getByRole('radio', { name: /Local number/ })).toBeDisabled();
    await user.click(screen.getByRole('button', { name: 'Search numbers' }));
    await user.click(await screen.findByRole('radio', { name: /\(888\) 555-0123/ }));
    await user.click(screen.getByRole('button', { name: /Buy/ }));
    await waitFor(() => {
      const buy = supabase.functions.invoke.mock.calls.find(
        (c) => (c[1] as { body: { action: string } }).body.action === 'purchase_number',
      );
      expect((buy?.[1] as { body: Record<string, unknown> }).body).toMatchObject({
        action: 'purchase_number',
        shop_id: 'shop-1',
        phone_e164: '+18885550123',
      });
    });
  });
});

describe('SmsPage when the provisioning check fails', () => {
  const rejected = {
    sms_provisioning_status: {
      data: {
        number: '+18885550123',
        kind: 'tollfree',
        verification_status: 'rejected',
        rejection_reason: 'Business website does not match',
        provisioned: true,
      },
    },
  };

  it('shows an error with a retry instead of "not available", then the bought number', async () => {
    let fail = true;
    supabase.functions.invoke.mockImplementation(((
      _name: string,
      options: { body: { action: string } },
    ) =>
      Promise.resolve(
        options.body.action === 'status' && fail
          ? { data: null, error: edgeHttpError(503, { error: 'Service unavailable' }) }
          : { data: { enabled: true, isv_enabled: false }, error: null },
      )) as never);
    mockRpc(rejected);
    const { user } = renderSettings('/app/settings/sms');
    expect(
      await screen.findByText('Couldn’t check your text messaging setup', undefined, {
        timeout: 3000,
      }),
    ).toBeVisible();
    expect(screen.queryByText(/Buying a number yourself isn’t available yet/)).toBeNull();
    expect(screen.queryByLabelText('SMS from number')).toBeNull();
    fail = false;
    await user.click(screen.getByRole('button', { name: 'Try again' }));
    expect(await screen.findByText(/Business website does not match/)).toBeVisible();
  });

  it('still reads a function that is not deployed (404) as "not available"', async () => {
    supabase.functions.invoke.mockResolvedValue({
      data: null,
      error: edgeHttpError(404, { error: 'Function not found' }),
    });
    mockRpc(rejected);
    renderSettings('/app/settings/sms');
    expect(await screen.findByText(/Buying a number yourself isn’t available yet/)).toBeVisible();
  });

  it('reads provisioning_disabled as "not available"', async () => {
    supabase.functions.invoke.mockResolvedValue({
      data: null,
      error: edgeHttpError(422, {
        error: 'Self-serve numbers are not available.',
        code: 'unprocessable',
        details: { reason: 'provisioning_disabled' },
      }),
    });
    mockRpc(rejected);
    renderSettings('/app/settings/sms');
    expect(await screen.findByText(/Buying a number yourself isn’t available yet/)).toBeVisible();
  });
});

describe('SmsPage verification', () => {
  it('sends the toll-free verification in the function’s shape', async () => {
    supabase.functions.invoke.mockImplementation(((
      _name: string,
      options: { body: { action: string } },
    ) =>
      Promise.resolve(
        options.body.action === 'status'
          ? { data: { enabled: true, isv_enabled: false }, error: null }
          : { data: { ok: true }, error: null },
      )) as never);
    mockRpc({
      sms_provisioning_status: {
        data: {
          number: '+18885550123',
          kind: 'tollfree',
          verification_status: 'not_started',
          rejection_reason: null,
          provisioned: true,
        },
      },
    });
    const { user } = renderSettings('/app/settings/sms');
    await user.click(await screen.findByRole('button', { name: 'Verify the number' }));
    const dialog = await screen.findByRole('dialog', { name: 'Toll-free verification' });
    await user.type(within(dialog).getByLabelText(/Contact first name/), 'Olivia');
    await user.type(within(dialog).getByLabelText(/Contact last name/), 'Owner');
    await user.type(
      within(dialog).getByLabelText(/Describe your texts/),
      'Appointment confirmations and reminders for our customers.',
    );
    await user.type(
      within(dialog).getByLabelText(/Sample message/),
      'Your detail is confirmed for Tuesday 9 AM. Reply STOP to opt out.',
    );
    await user.click(within(dialog).getByRole('button', { name: 'Send for review' }));
    await waitFor(() => {
      const call = supabase.functions.invoke.mock.calls.find(
        (c) =>
          (c[1] as { body: { action: string } }).body.action === 'submit_tollfree_verification',
      );
      expect((call?.[1] as { body: Record<string, unknown> }).body).toEqual({
        action: 'submit_tollfree_verification',
        shop_id: 'shop-1',
        business: {
          legal_name: 'Glacier Detailing',
          website: 'https://glacier.test',
          address_line1: '1 Main St',
          city: 'Birmingham',
          region: 'AL',
          postal_code: '35203',
          country: 'US',
          contact_first_name: 'Olivia',
          contact_last_name: 'Owner',
          contact_email: 'hello@glacier.test',
          contact_phone: '+12055550100',
          use_case_categories: ['ACCOUNT_NOTIFICATIONS', 'CUSTOMER_CARE'],
          use_case_summary: 'Appointment confirmations and reminders for our customers.',
          production_message_sample:
            'Your detail is confirmed for Tuesday 9 AM. Reply STOP to opt out.',
          opt_in_type: 'WEB_FORM',
          opt_in_image_urls: [`${window.location.origin}/book/glacier-detailing`],
          estimated_monthly_volume: '1,000',
        },
      });
    });
  });
});

describe('LeadFormsPage', () => {
  it("counts each form's submissions with an exact count, not a capped row list", async () => {
    const form = (id: string, name: string) => ({
      id,
      token: `tok-${id}`,
      name,
      headline: null,
      intro: null,
      default_source: 'other',
      field_ids: [],
      ask_vehicle: true,
      ask_message: true,
      success_message: null,
      notify_staff: true,
      auto_reply: false,
      active: true,
      archived_at: null,
      created_at: '2026-01-01T00:00:00Z',
    });
    setTableResult('lead_forms', { data: [form('f1', 'Website'), form('f2', 'Flyer')] });
    setTableResult('lead_submissions', { data: null, count: 1500 });
    setTableResult('custom_fields', { data: [] });
    renderSettings('/app/settings/lead-forms');
    expect(await screen.findAllByText(/1,500 submissions in the last 30 days/)).toHaveLength(2);
    const queries = builders.lead_submissions ?? [];
    expect(queries).toHaveLength(2);
    for (const q of queries) {
      expect(q.select).toHaveBeenCalledWith('id', { count: 'exact', head: true });
      expect(q.limit).not.toHaveBeenCalled();
    }
    expect(queries.flatMap((q) => q.eq.mock.calls)).toEqual(
      expect.arrayContaining([
        ['lead_form_id', 'f1'],
        ['lead_form_id', 'f2'],
      ]),
    );
  });

  it('creates a form asking lead-form customer fields', async () => {
    setTableResult('lead_forms', { data: [] });
    setTableResult('lead_submissions', { data: [] });
    setTableResult('custom_fields', {
      data: [
        {
          id: 'cf1',
          entity: 'customer',
          key: 'budget',
          label: 'Budget',
          type: 'text',
          options: [],
          help_text: null,
          required: false,
          show_in_booking: false,
          show_in_lead_form: true,
          location_scope: null,
          sort: 1,
          archived_at: null,
        },
      ],
    });
    const { user } = renderSettings('/app/settings/lead-forms');
    await user.click((await screen.findAllByRole('button', { name: 'New form' }))[0]!);
    const dialog = await screen.findByRole('dialog', { name: 'New lead form' });
    await user.type(within(dialog).getByLabelText(/^Name/), 'Website contact');
    await user.click(within(dialog).getByLabelText('Budget'));
    await user.click(within(dialog).getByRole('button', { name: 'Create form' }));
    await waitFor(() =>
      expect(insertCall('lead_forms')).toMatchObject({
        name: 'Website contact',
        default_source: 'other',
        field_ids: ['cf1'],
        ask_vehicle: true,
        ask_message: true,
        notify_staff: true,
        auto_reply: false,
        active: true,
        shop_id: 'shop-1',
      }),
    );
  });
});
