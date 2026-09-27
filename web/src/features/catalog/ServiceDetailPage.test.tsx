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
  supabase.from.mockImplementation(((table: string) => {
    const result = results[table] ?? { data: [] };
    const builder = createBuilder(result);
    builder.maybeSingle.mockImplementation(() =>
      createBuilder({ data: Array.isArray(result.data) ? (result.data[0] ?? null) : null }),
    );
    (builders[table] ??= []).push(builder);
    return builder;
  }));
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

  it('only lets owners and admins upload images', async () => {
    renderAs('manager');
    expect(
      await screen.findByText('Only an owner or admin can change images.'),
    ).toBeInTheDocument();
  });

  it('shows not found as an error', async () => {
    mockTables({ ...results, services: { data: [] } });
    renderAs('manager');
    expect(await screen.findByText('That service could not be found.')).toBeInTheDocument();
  });
});
