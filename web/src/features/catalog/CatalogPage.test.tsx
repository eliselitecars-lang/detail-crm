import { screen, waitFor, within } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { membership, renderRoute, shopValue } from '@/test/render';
import { builders, resetSupabaseMock, setTableResult } from '@/test/supabaseMock';
import CatalogPage from './CatalogPage';

vi.mock('@/lib/supabase', () => import('@/test/supabaseMock'));

function service(id: string, name: string, extra: Record<string, unknown> = {}) {
  return {
    id,
    shop_id: 'shop-1',
    category_id: 'cat-1',
    name,
    description: null,
    kind: 'service',
    duration_minutes: 120,
    taxable: true,
    online_bookable: true,
    active: true,
    sort: 10,
    image_path: null,
    archived_at: null,
    commission_kind: 'none',
    commission_value: 0,
    min_before_photos: 0,
    min_after_photos: 0,
    created_at: '2026-01-01T00:00:00Z',
    updated_at: '2026-01-01T00:00:00Z',
    ...extra,
  };
}

const categories = [
  {
    id: 'cat-1',
    shop_id: 'shop-1',
    name: 'Exterior',
    sort: 10,
    bookable_weekdays: null,
    created_at: '',
    updated_at: '',
  },
  {
    id: 'cat-2',
    shop_id: 'shop-1',
    name: 'Interior',
    sort: 20,
    bookable_weekdays: [1, 3],
    created_at: '',
    updated_at: '',
  },
];

function renderAs(role: 'owner' | 'manager' | 'technician', path = '/app/catalog') {
  return renderRoute(<CatalogPage />, {
    path,
    routePath: '/app/catalog',
    routes: [{ path: '/app/catalog/services/:id', element: <p>Service page</p> }],
    shop: shopValue({ membership: membership({ role }) }),
  });
}

beforeEach(() => {
  resetSupabaseMock();
  setTableResult('services', {
    data: [
      service('svc-1', 'Full Detail'),
      service('svc-2', 'Clay Bar', { kind: 'addon', online_bookable: false }),
      service('svc-3', 'Old Wax', { archived_at: '2026-02-01T00:00:00Z' }),
    ],
  });
  setTableResult('service_categories', { data: categories });
  setTableResult('service_prices', { data: [{ service_id: 'svc-1', price_cents: 24900 }] });
  setTableResult('checklist_templates', { data: [] });
});

describe('CatalogPage', () => {
  it('lists active items with base prices and hides archived ones by default', async () => {
    renderAs('manager');
    const table = await screen.findByRole('table', { name: 'Catalog items' });
    const row = within(table).getByRole('row', { name: /Full Detail/ });
    expect(row).toHaveTextContent('$249.00');
    expect(row).toHaveTextContent('Exterior');
    expect(row).toHaveTextContent('2 h');
    expect(within(table).getByRole('row', { name: /Clay Bar/ })).toHaveTextContent('Not set');
    expect(within(table).queryByText('Old Wax')).not.toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'New item' })).toBeInTheDocument();
  });

  it('shows archived items when asked and filters by type', async () => {
    const { user } = renderAs('manager');
    const table = await screen.findByRole('table', { name: 'Catalog items' });
    await user.click(screen.getByRole('switch', { name: 'Show archived' }));
    expect(within(table).getByText('Old Wax')).toBeInTheDocument();
    await user.selectOptions(screen.getByRole('combobox', { name: 'Type' }), 'addon');
    expect(within(table).queryByText('Full Detail')).not.toBeInTheDocument();
    expect(within(table).getByText('Clay Bar')).toBeInTheDocument();
  });

  it('is read-only for technicians', async () => {
    renderAs('technician');
    await screen.findByRole('table', { name: 'Catalog items' });
    expect(screen.queryByRole('button', { name: 'New item' })).not.toBeInTheDocument();
  });

  it('creates an item and opens it', async () => {
    const { user, router } = renderAs('owner');
    await screen.findByRole('table', { name: 'Catalog items' });
    await user.click(screen.getByRole('button', { name: 'New item' }));
    const dialog = await screen.findByRole('dialog', { name: 'New catalog item' });
    await user.type(within(dialog).getByRole('textbox', { name: /Name/ }), 'Ceramic Coating');
    await user.selectOptions(within(dialog).getByRole('combobox', { name: 'Type' }), 'package');
    await user.selectOptions(within(dialog).getByRole('combobox', { name: 'Category' }), 'cat-2');
    const duration = within(dialog).getByRole('textbox', { name: /Duration/ });
    await user.clear(duration);
    await user.type(duration, '480');
    await user.click(within(dialog).getByRole('button', { name: 'Create' }));

    await waitFor(() => expect(router.state.location.pathname).toBe('/app/catalog/services/svc-1'));
    const insert = builders.services?.find((b) => b.insert.mock.calls.length > 0);
    expect(insert?.insert).toHaveBeenCalledWith({
      shop_id: 'shop-1',
      name: 'Ceramic Coating',
      description: null,
      kind: 'package',
      category_id: 'cat-2',
      duration_minutes: 480,
      taxable: true,
      online_bookable: false,
      active: true,
      sort: 0,
      min_before_photos: 0,
      min_after_photos: 0,
      commission_kind: 'none',
      commission_value: 0,
    });
  });

  it('sets photo minimums and a service commission (owners only)', async () => {
    const { user } = renderAs('owner');
    await screen.findByRole('table', { name: 'Catalog items' });
    await user.click(screen.getByRole('button', { name: 'New item' }));
    const dialog = await screen.findByRole('dialog', { name: 'New catalog item' });
    await user.type(within(dialog).getByRole('textbox', { name: /Name/ }), 'Ceramic Coating');
    const after = within(dialog).getByRole('textbox', { name: /Minimum “after” photos/ });
    await user.clear(after);
    await user.type(after, '4');
    await user.selectOptions(
      within(dialog).getByRole('combobox', { name: 'Commission' }),
      'percent',
    );
    await user.click(within(dialog).getByRole('button', { name: 'Create' }));
    expect(
      await within(dialog).findByText('Enter a percentage between 0 and 100.'),
    ).toBeInTheDocument();
    await user.type(within(dialog).getByRole('textbox', { name: /Percent of the line/ }), '12.5');
    await user.click(within(dialog).getByRole('button', { name: 'Create' }));
    await waitFor(() => {
      const insert = builders.services?.find((b) => b.insert.mock.calls.length > 0);
      expect(insert?.insert).toHaveBeenCalledWith(
        expect.objectContaining({
          min_after_photos: 4,
          min_before_photos: 0,
          commission_kind: 'percent',
          commission_value: 1250,
        }),
      );
    });
  });

  it('never sends commission columns for managers', async () => {
    const { user } = renderAs('manager');
    await screen.findByRole('table', { name: 'Catalog items' });
    await user.click(screen.getByRole('button', { name: 'New item' }));
    const dialog = await screen.findByRole('dialog', { name: 'New catalog item' });
    expect(within(dialog).queryByRole('combobox', { name: 'Commission' })).not.toBeInTheDocument();
    await user.type(within(dialog).getByRole('textbox', { name: /Name/ }), 'Interior Refresh');
    await user.click(within(dialog).getByRole('button', { name: 'Create' }));
    await waitFor(() => {
      const insert = builders.services?.find((b) => b.insert.mock.calls.length > 0);
      expect(insert?.insert).toHaveBeenCalledTimes(1);
    });
    const insert = builders.services?.find((b) => b.insert.mock.calls.length > 0);
    const values = insert?.insert.mock.calls[0]?.[0] as Record<string, unknown>;
    expect(values).not.toHaveProperty('commission_kind');
    expect(values).not.toHaveProperty('commission_value');
  });

  it('limits a category to online booking weekdays', async () => {
    const { user } = renderAs('manager', '/app/catalog?tab=categories');
    const list = await screen.findByRole('list', { name: 'Service categories' });
    expect(within(list).getByText(/Online booking: Mon, Wed/)).toBeInTheDocument();
    await user.click(screen.getByRole('button', { name: 'Online booking days for Exterior' }));
    const dialog = await screen.findByRole('dialog', { name: /Online booking days · Exterior/ });
    await user.click(within(dialog).getByRole('checkbox', { name: 'Sunday' }));
    await user.click(within(dialog).getByRole('checkbox', { name: 'Saturday' }));
    await user.click(within(dialog).getByRole('button', { name: 'Save days' }));
    await waitFor(() => {
      const updates = (builders.service_categories ?? []).flatMap((b) => b.update.mock.calls);
      expect(updates).toContainEqual([{ bookable_weekdays: [1, 2, 3, 4, 5] }]);
    });
  });

  it('validates the new item form', async () => {
    const { user } = renderAs('owner');
    await screen.findByRole('table', { name: 'Catalog items' });
    await user.click(screen.getByRole('button', { name: 'New item' }));
    const dialog = await screen.findByRole('dialog', { name: 'New catalog item' });
    await user.click(within(dialog).getByRole('button', { name: 'Create' }));
    expect(await within(dialog).findByText('Name is required.')).toBeInTheDocument();
    expect(builders.services?.some((b) => b.insert.mock.calls.length > 0)).toBe(false);
  });

  it('reorders categories', async () => {
    const { user } = renderAs('manager', '/app/catalog?tab=categories');
    const list = await screen.findByRole('list', { name: 'Service categories' });
    expect(within(list).getByText('Exterior')).toBeInTheDocument();
    await user.click(screen.getByRole('button', { name: 'Move Interior up' }));
    await waitFor(() => {
      const updates = (builders.service_categories ?? []).flatMap((b) => b.update.mock.calls);
      expect(updates).toEqual([[{ sort: 10 }], [{ sort: 20 }]]);
    });
  });

  it('creates a checklist template with items and a linked service', async () => {
    const { user } = renderAs('manager', '/app/catalog?tab=checklists');
    await screen.findByText('No checklist templates yet');
    await user.click(screen.getByRole('button', { name: 'New checklist' }));
    const dialog = await screen.findByRole('dialog', { name: 'New checklist' });
    await user.type(within(dialog).getByRole('textbox', { name: /Name/ }), 'Exterior QC');
    await user.selectOptions(
      within(dialog).getByRole('combobox', { name: /Linked service/ }),
      'svc-1',
    );
    const newItem = within(dialog).getByRole('textbox', { name: 'New item' });
    await user.type(newItem, 'Wheels clean{Enter}');
    await user.type(newItem, 'Glass streak-free{Enter}');
    await user.click(within(dialog).getByRole('button', { name: 'Move item 2 up' }));
    await user.click(within(dialog).getByRole('button', { name: 'Create checklist' }));

    await waitFor(() => {
      const insert = builders.checklist_templates?.find((b) => b.insert.mock.calls.length > 0);
      expect(insert?.insert).toHaveBeenCalledWith({
        shop_id: 'shop-1',
        name: 'Exterior QC',
        service_id: 'svc-1',
        items: [{ label: 'Glass streak-free' }, { label: 'Wheels clean' }],
        required: false,
      });
    });
  });

  it('shows an error state with retry', async () => {
    setTableResult('services', { error: { code: '57014', message: 'timeout' } });
    renderAs('manager');
    expect(await screen.findByText('Couldn’t load the catalog')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Try again' })).toBeInTheDocument();
  });

  it('never shows "Not set" prices when base prices failed to load', async () => {
    setTableResult('service_prices', { error: { code: '57014', message: 'timeout' } });
    renderAs('manager');
    const table = await screen.findByRole('table', { name: 'Catalog items' });
    expect(await screen.findByText('Couldn’t load base prices')).toBeInTheDocument();
    const row = within(table).getByRole('row', { name: /Full Detail/ });
    expect(row).toHaveTextContent('Unavailable');
    expect(within(table).queryByText('Not set')).not.toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Try again' })).toBeInTheDocument();
  });

  it('keeps checklist service links honest when services fail to load', async () => {
    setTableResult('services', { error: { code: '57014', message: 'timeout' } });
    setTableResult('checklist_templates', {
      data: [
        {
          id: 'tpl-1',
          shop_id: 'shop-1',
          name: 'Coating QC',
          service_id: 'svc-1',
          items: [{ id: 'i1', label: 'Panel wipe' }],
          created_at: '',
          updated_at: '',
        },
      ],
    });
    renderAs('manager', '/app/catalog?tab=checklists');
    const list = await screen.findByRole('list', { name: 'Checklist templates' });
    expect(await screen.findByText('Couldn’t load linked service names')).toBeInTheDocument();
    expect(within(list).getByText('Auto-added with a linked service')).toBeInTheDocument();
    expect(within(list).queryByText('Added manually')).not.toBeInTheDocument();
  });

  it('does not report 0 items per category when services fail to load', async () => {
    setTableResult('services', { error: { code: '57014', message: 'timeout' } });
    renderAs('manager', '/app/catalog?tab=categories');
    const list = await screen.findByRole('list', { name: 'Service categories' });
    expect(await screen.findByText('Couldn’t count items per category')).toBeInTheDocument();
    expect(within(list).getAllByText(/Item count unavailable/)).toHaveLength(2);
    expect(within(list).queryByText('0 items')).not.toBeInTheDocument();
  });
});
