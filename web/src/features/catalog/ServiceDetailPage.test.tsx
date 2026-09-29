import { screen, waitFor, within } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { membership, renderRoute, shopValue } from '@/test/render';
import {
  builders,
  createBuilder,
  resetSupabaseMock,
  supabase,
  type MockResult,
} from '@/test/supabaseMock';
import ServiceDetailPage from './ServiceDetailPage';

vi.mock('@/lib/supabase', () => import('@/test/supabaseMock'));

const base = {
  shop_id: 'shop-1',
  category_id: null,
  description: 'Hand wash and wax',
  duration_minutes: 120,
  taxable: true,
  online_bookable: false,
  active: true,
  sort: 0,
  image_path: null,
  archived_at: null,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

let results: Record<string, MockResult> = {};

/** Like the shared mock, but `.maybeSingle()` resolves to the first row. */
function mockTables(next: Record<string, MockResult>) {
  results = next;
  supabase.from.mockImplementation((table: string) => {
    const result = results[table] ?? { data: [] };
    const builder = createBuilder(result);
    builder.maybeSingle.mockImplementation(() =>
      createBuilder({ data: Array.isArray(result.data) ? (result.data[0] ?? null) : null }),
    );
    (builders[table] ??= []).push(builder);
    return builder;
  });
}

function renderAs(role: 'owner' | 'manager' | 'technician') {
  return renderRoute(<ServiceDetailPage />, {
    path: '/app/catalog/services/pkg-1',
    routePath: '/app/catalog/services/:serviceId',
    shop: shopValue({ membership: membership({ role }) }),
  });
}

beforeEach(() => {
  resetSupabaseMock();
  mockTables({
    services: {
      data: [
        { ...base, id: 'pkg-1', name: 'Showroom Package', kind: 'package' },
        { ...base, id: 'svc-2', name: 'Interior Detail', kind: 'service' },
        { ...base, id: 'add-1', name: 'Pet Hair', kind: 'addon' },
      ],
    },
    service_prices: {
      data: [
        {
          id: 'price-base',
          shop_id: 'shop-1',
          service_id: 'pkg-1',
          vehicle_category_id: null,
          price_cents: 30000,
          duration_minutes: null,
          created_at: '',
          updated_at: '',
        },
      ],
    },
    vehicle_categories: {
      data: [
        { id: 'vc-car', name: 'Car', sort: 1 },
        { id: 'vc-truck', name: 'Truck', sort: 2 },
      ],
    },
    service_categories: { data: [] },
    package_items: { data: [{ id: 'pi-1', service_id: 'svc-2', sort: 10 }] },
    service_addons: { data: [] },
  });
});

describe('ServiceDetailPage', () => {
  it('saves the price grid as minimal writes', async () => {
    const { user } = renderAs('manager');
    expect(await screen.findByRole('heading', { name: 'Showroom Package' })).toBeInTheDocument();
    const grid = await screen.findByRole('table', { name: 'Prices by vehicle size' });
    const truck = within(grid).getByRole('textbox', { name: 'Truck price' });
    await user.type(truck, '375');
    await user.type(within(grid).getByRole('textbox', { name: 'Truck time in minutes' }), '180');
    const basePrice = within(grid).getByRole('textbox', { name: 'Base price' });
    await user.clear(basePrice);
    await user.type(basePrice, '310');
    await user.click(screen.getByRole('button', { name: 'Save prices' }));

    await waitFor(() => {
      const calls = builders.service_prices ?? [];
      expect(calls.flatMap((b) => b.insert.mock.calls)).toEqual([
        [
          [
            {
              vehicle_category_id: 'vc-truck',
              price_cents: 37500,
              duration_minutes: 180,
              shop_id: 'shop-1',
              service_id: 'pkg-1',
            },
          ],
        ],
      ]);
      expect(calls.flatMap((b) => b.update.mock.calls)).toEqual([
        [{ price_cents: 31000, duration_minutes: null }],
      ]);
    });
  });

  it('requires a price before a duration override', async () => {
    const { user } = renderAs('owner');
    const grid = await screen.findByRole('table', { name: 'Prices by vehicle size' });
    await user.type(within(grid).getByRole('textbox', { name: 'Car time in minutes' }), '90');
    await user.click(screen.getByRole('button', { name: 'Save prices' }));
    expect(await within(grid).findByText('Enter a price to set a duration.')).toBeInTheDocument();
    expect((builders.service_prices ?? []).some((b) => b.insert.mock.calls.length > 0)).toBe(false);
  });

  it('shows and edits package contents and add-ons', async () => {
    const { user } = renderAs('manager');
    const contents = await screen.findByRole('list', { name: 'Included in this package' });
    expect(within(contents).getByText('Interior Detail')).toBeInTheDocument();
    await user.click(screen.getByRole('checkbox', { name: 'Pet Hair' }));
    await waitFor(() => {
      const inserts = (builders.service_addons ?? []).flatMap((b) => b.insert.mock.calls);
      expect(inserts).toEqual([[{ shop_id: 'shop-1', service_id: 'pkg-1', addon_id: 'add-1' }]]);
    });
    await user.click(screen.getByRole('button', { name: 'Remove Interior Detail from package' }));
    await waitFor(() =>
      expect((builders.package_items ?? []).some((b) => b.delete.mock.calls.length > 0)).toBe(true),
    );
  });

  it('is read-only for technicians', async () => {
    renderAs('technician');
    const grid = await screen.findByRole('table', { name: 'Prices by vehicle size' });
    expect(within(grid).getByText('$300.00')).toBeInTheDocument();
    expect(within(grid).queryByRole('textbox')).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Edit details' })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /Upload image/ })).not.toBeInTheDocument();
    expect(screen.queryByRole('checkbox')).not.toBeInTheDocument();
  });

  it('lets managers upload service images to <shop>/services/', async () => {
    const { user } = renderAs('manager');
    await screen.findByRole('button', { name: 'Upload image' });
    const input = document.querySelector<HTMLInputElement>('input[type="file"]');
    if (!input) throw new Error('file input missing');
    await user.upload(input, new File(['png'], 'car.png', { type: 'image/png' }));
    await waitFor(() =>
      expect(supabase.storage.from('shop-assets').upload).toHaveBeenCalledWith(
        'shop-1/services/pkg-1.png',
        expect.any(File),
        { upsert: true, contentType: 'image/png', cacheControl: '3600' },
      ),
    );
    await waitFor(() =>
      expect((builders.services ?? []).some((b) => b.update.mock.calls.length > 0)).toBe(true),
    );
  });

  it('shows not found as an error', async () => {
    mockTables({ ...results, services: { data: [] } });
    renderAs('manager');
    expect(await screen.findByText('That service could not be found.')).toBeInTheDocument();
  });

  it('warns before deleting an add-on that is the only one a service offers', async () => {
    mockTables({
      ...results,
      services: {
        data: [
          { ...base, id: 'add-1', name: 'Pet Hair', kind: 'addon' },
          { ...base, id: 'svc-2', name: 'Interior Detail', kind: 'service' },
          { ...base, id: 'pkg-1', name: 'Showroom Package', kind: 'package' },
        ],
      },
      service_addons: { data: [{ id: 'l1', service_id: 'svc-2', addon_id: 'add-1' }] },
    });
    const { user } = renderAs('manager');
    expect(await screen.findByRole('heading', { name: 'Pet Hair' })).toBeInTheDocument();
    await user.click(screen.getByRole('button', { name: 'More actions' }));
    await user.click(await screen.findByRole('menuitem', { name: 'Delete…' }));
    const dialog = await screen.findByRole('alertdialog', { name: 'Delete Pet Hair?' });
    expect(
      await within(dialog).findByText('Interior Detail only offers this add-on.'),
    ).toBeInTheDocument();
    expect(within(dialog).getByText(/will offer every add-on/)).toBeInTheDocument();
    expect(within(dialog).getByRole('button', { name: 'Delete anyway' })).toBeInTheDocument();
    const lookups = (builders.service_addons ?? []).flatMap((b) => b.eq.mock.calls);
    expect(lookups).toContainEqual(['addon_id', 'add-1']);
  });

  it('keeps add-on links manageable on products', async () => {
    mockTables({
      ...results,
      services: {
        data: [
          { ...base, id: 'prd-1', name: 'Ceramic Spray', kind: 'product' },
          { ...base, id: 'add-1', name: 'Pet Hair', kind: 'addon' },
        ],
      },
      service_addons: { data: [{ id: 'l1', addon_id: 'add-1' }] },
    });
    const { user } = renderAs('manager');
    expect(await screen.findByRole('heading', { name: 'Ceramic Spray' })).toBeInTheDocument();
    const box = await screen.findByRole('checkbox', { name: 'Pet Hair' });
    expect(box).toBeChecked();
    await user.click(box);
    await waitFor(() =>
      expect((builders.service_addons ?? []).some((b) => b.delete.mock.calls.length > 0)).toBe(
        true,
      ),
    );
  });

  it('adds a follow-up message and warns when the shop switch is off', async () => {
    results.message_templates = {
      data: [
        { channel: 'sms', enabled: false },
        { channel: 'email', enabled: false },
      ],
    };
    results.service_followups = {
      data: [
        {
          id: 'fu-1',
          shop_id: 'shop-1',
          service_id: 'pkg-1',
          channel: 'sms',
          offset_days: 90,
          subject: null,
          body: 'Time for a check-up: {{rebook_link}}',
          enabled: true,
          sort: 0,
          created_at: '',
          updated_at: '',
        },
      ],
    };
    const { user } = renderAs('manager');
    const card = await screen.findByRole('region', { name: 'Follow-up messages' });
    expect(await within(card).findByText('3 months after the visit')).toBeInTheDocument();
    expect(await within(card).findByText(/turned off for the whole shop/)).toBeInTheDocument();
    expect(within(card).getByRole('link', { name: 'Turn them on in Templates' })).toHaveAttribute(
      'href',
      '/app/settings/templates?edit=service_followup',
    );
    await user.click(within(card).getByRole('button', { name: 'Add follow-up' }));
    const dialog = await screen.findByRole('dialog', {
      name: /New follow-up for Showroom Package/,
    });
    await user.click(within(dialog).getByRole('radio', { name: 'Email' }));
    const amount = within(dialog).getByRole('textbox', { name: /After/ });
    await user.clear(amount);
    await user.type(amount, '2');
    await user.selectOptions(within(dialog).getByRole('combobox', { name: /Unit/ }), 'weeks');
    await user.type(within(dialog).getByRole('textbox', { name: /Subject/ }), 'How is your car?');
    await user.type(
      within(dialog).getByRole('textbox', { name: /Message/ }),
      'Hi {{{{customer_first_name}}!',
    );
    expect(within(dialog).getByText(/Preview/)).toBeInTheDocument();
    await user.click(within(dialog).getByRole('button', { name: 'Add follow-up' }));
    await waitFor(() => {
      const insert = builders.service_followups?.find((b) => b.insert.mock.calls.length > 0);
      expect(insert?.insert).toHaveBeenCalledWith({
        channel: 'email',
        offset_days: 14,
        subject: 'How is your car?',
        body: 'Hi {{customer_first_name}}!',
        enabled: true,
        shop_id: 'shop-1',
        service_id: 'pkg-1',
      });
    });
  });

  it('says email follow-ups aren’t sent while the shop has no mailing address (0119)', async () => {
    results.message_templates = {
      data: [
        { channel: 'sms', enabled: true },
        { channel: 'email', enabled: true },
      ],
    };
    const followup = {
      id: 'fu-2',
      shop_id: 'shop-1',
      service_id: 'pkg-1',
      channel: 'email',
      offset_days: 180,
      subject: 'Coating check-up',
      body: 'Time for a check-up: {{rebook_link}}',
      enabled: true,
      sort: 0,
      created_at: '',
      updated_at: '',
    };
    results.service_followups = { data: [followup] };
    results.shops = { data: [{ id: 'shop-1', address_line1: null, city: 'Birmingham' }] };
    const first = renderAs('manager');
    let card = await screen.findByRole('region', { name: 'Follow-up messages' });
    const notice = await within(card).findByRole('status', {
      name: 'Marketing email needs your mailing address',
    });
    expect(notice).toHaveTextContent('The email follow-ups here are on but aren’t being sent.');
    // Managers can't edit the business profile: they're told who can.
    expect(notice).toHaveTextContent('Ask an owner or admin to add it');
    first.unmount();

    results.shops = { data: [{ id: 'shop-1', address_line1: '1 Main St', city: 'Birmingham' }] };
    renderAs('owner');
    card = await screen.findByRole('region', { name: 'Follow-up messages' });
    expect(await within(card).findByText('6 months after the visit')).toBeInTheDocument();
    expect(within(card).queryByText(/aren’t being sent/)).not.toBeInTheDocument();
  });

  it('lists the materials a service uses (managers)', async () => {
    results.products = {
      data: [
        {
          id: 'prod-1',
          name: 'Coating kit',
          unit: 'kit',
          sku: null,
          active: true,
          archived_at: null,
        },
      ],
    };
    results.service_consumables = {
      data: [{ id: 'sc-1', product_id: 'prod-1', vehicle_category_id: 'vc-truck', quantity: 1.5 }],
    };
    renderAs('manager');
    const card = await screen.findByRole('region', { name: 'Materials used' });
    expect(await within(card).findByText('Coating kit')).toBeInTheDocument();
    expect(within(card).getByText('1.5 kit per unit · Truck')).toBeInTheDocument();
  });

  it('hides follow-ups and materials from technicians', async () => {
    renderAs('technician');
    await screen.findByRole('heading', { name: 'Showroom Package' });
    expect(screen.queryByRole('region', { name: 'Follow-up messages' })).not.toBeInTheDocument();
    expect(screen.queryByRole('region', { name: 'Materials used' })).not.toBeInTheDocument();
  });
});
