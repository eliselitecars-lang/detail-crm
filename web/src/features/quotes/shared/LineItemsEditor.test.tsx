import { screen, waitFor, within } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { renderRoute } from '@/test/render';
import { createBuilder, resetSupabaseMock, setTableResult, supabase } from '@/test/supabaseMock';
import { LineItemsEditor } from './LineItemsEditor';
import type { DocLine } from './lines';

vi.mock('@/lib/supabase', () => import('@/test/supabaseMock'));

beforeEach(() => resetSupabaseMock());

const line: DocLine = {
  id: 'l1',
  service_id: null,
  vehicle_id: null,
  name: 'Headlight restoration',
  description: null,
  quantity: 2,
  unit_price_cents: 5000,
  discount_cents: 1000,
  taxable: false,
  total_cents: 9000,
  sort: 1,
  optional: true,
  selected: false,
  duration_minutes: 30,
  discount_eligible: true,
  fee_id: null,
  option_id: null,
  job_id: null,
};

function renderEditor(props: Partial<Parameters<typeof LineItemsEditor>[0]> = {}) {
  const onAdd = vi.fn(() => Promise.resolve());
  const onUpdate = vi.fn(() => Promise.resolve());
  const onRemove = vi.fn(() => Promise.resolve());
  const utils = renderRoute(
    <LineItemsEditor
      lines={[line]}
      currency="usd"
      editable
      supportsOptional
      pricing={{ customerId: 'c1', vehicleId: 'v1', vehicleCategoryId: 'cat-suv' }}
      onAdd={onAdd}
      onUpdate={onUpdate}
      onRemove={onRemove}
      {...props}
    />,
  );
  return { ...utils, onAdd, onUpdate, onRemove };
}

describe('LineItemsEditor', () => {
  it('renders server line totals and flags', () => {
    renderEditor();
    const list = screen.getByRole('list', { name: 'Line items' });
    expect(within(list).getByText('$90.00')).toBeInTheDocument();
    expect(within(list).getByText('Optional')).toBeInTheDocument();
    expect(within(list).getByText('Not taxable')).toBeInTheDocument();
    expect(within(list).getByText(/2 × \$50\.00 · discount \$10\.00/)).toBeInTheDocument();
  });

  it('adds catalog services priced by the price_services RPC for the vehicle size', async () => {
    setTableResult('vehicle_categories', { data: [{ id: 'cat-suv', name: 'SUV', sort: 1 }] });
    setTableResult('services', {
      data: [
        {
          id: 'svc-1',
          name: 'Interior detail',
          kind: 'service',
          description: null,
          taxable: true,
          duration_minutes: 120,
          sort: 0,
        },
      ],
    });
    supabase.rpc.mockReturnValue(
      createBuilder({
        data: {
          vehicle_category_id: 'cat-suv',
          tax_rate_bps: 800,
          duration_minutes: 120,
          priced: true,
          lines: [
            {
              service_id: 'svc-1',
              name: 'Interior detail',
              kind: 'service',
              taxable: true,
              duration_minutes: 120,
              catalog_price_cents: 18000,
              unit_price_cents: 18000,
              membership_included: false,
              note: null,
            },
          ],
          memberships: [],
          suggested_discount_kind: 'none',
          suggested_discount_value: 0,
          totals: { subtotal_cents: 18000, discount_cents: 0, tax_cents: 1440, total_cents: 19440 },
        },
      }),
    );
    const { user, onAdd } = renderEditor();
    await user.click(screen.getByRole('button', { name: 'From catalog' }));
    const dialog = await screen.findByRole('dialog', { name: 'Add from catalog' });
    await user.click(await within(dialog).findByRole('checkbox', { name: /Interior detail/ }));
    expect(await within(dialog).findByText('$180.00')).toBeInTheDocument();
    expect(supabase.rpc).toHaveBeenCalledWith('price_services', {
      p_shop: 'shop-1',
      p_customer_id: 'c1',
      p_vehicle_category_id: 'cat-suv',
      p_service_ids: ['svc-1'],
      p_vehicle_id: 'v1',
    });
    await user.click(within(dialog).getByRole('button', { name: 'Add 1 item' }));
    await waitFor(() =>
      expect(onAdd).toHaveBeenCalledWith([
        {
          service_id: 'svc-1',
          name: 'Interior detail',
          description: null,
          quantity: 1,
          unit_price_cents: 18000,
          discount_cents: 0,
          taxable: true,
          optional: false,
          duration_minutes: 120,
        },
      ]),
    );
  });

  it('blocks adding services without a catalog price', async () => {
    setTableResult('vehicle_categories', { data: [{ id: 'cat-suv', name: 'SUV', sort: 1 }] });
    setTableResult('services', {
      data: [
        {
          id: 'svc-2',
          name: 'Paint correction',
          kind: 'service',
          description: null,
          taxable: true,
          duration_minutes: 240,
          sort: 0,
        },
      ],
    });
    supabase.rpc.mockReturnValue(
      createBuilder({
        data: {
          vehicle_category_id: 'cat-suv',
          tax_rate_bps: 0,
          duration_minutes: 240,
          priced: false,
          lines: [
            {
              service_id: 'svc-2',
              name: 'Paint correction',
              kind: 'service',
              taxable: true,
              duration_minutes: 240,
              catalog_price_cents: null,
              unit_price_cents: null,
              membership_included: false,
              note: null,
            },
          ],
          memberships: [],
          suggested_discount_kind: 'none',
          suggested_discount_value: 0,
          totals: null,
        },
      }),
    );
    const { user } = renderEditor();
    await user.click(screen.getByRole('button', { name: 'From catalog' }));
    const dialog = await screen.findByRole('dialog');
    await user.click(await within(dialog).findByRole('checkbox', { name: /Paint correction/ }));
    expect(await within(dialog).findByText('No price')).toBeInTheDocument();
    expect(within(dialog).getByRole('button', { name: 'Add 1 item' })).toBeDisabled();
  });

  it('adds a custom line with validation', async () => {
    const { user, onAdd } = renderEditor({ lines: [] });
    expect(screen.getByText('No line items yet')).toBeInTheDocument();
    await user.click(screen.getByRole('button', { name: 'Custom line' }));
    const dialog = await screen.findByRole('dialog', { name: 'Add custom line' });
    await user.click(within(dialog).getByRole('button', { name: 'Add line' }));
    expect(await within(dialog).findByText('Name is required.')).toBeInTheDocument();
    expect(within(dialog).getByText('Enter an amount.')).toBeInTheDocument();
    await user.type(within(dialog).getByLabelText(/^Name/), 'Pet hair removal');
    const qty = within(dialog).getByLabelText(/Quantity/);
    await user.clear(qty);
    await user.type(qty, '1.5');
    await user.type(within(dialog).getByLabelText(/Unit price/), '40');
    await user.click(within(dialog).getByRole('checkbox', { name: /Optional item/ }));
    await user.click(within(dialog).getByRole('button', { name: 'Add line' }));
    await waitFor(() =>
      expect(onAdd).toHaveBeenCalledWith([
        {
          service_id: null,
          name: 'Pet hair removal',
          description: null,
          quantity: 1.5,
          unit_price_cents: 4000,
          discount_cents: 0,
          taxable: true,
          optional: true,
          duration_minutes: 0,
        },
      ]),
    );
  });

  it('is read-only when locked', () => {
    renderEditor({ editable: false, lockedMessage: 'Locked for a reason.' });
    expect(screen.getByText('Locked for a reason.')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'From catalog' })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /Edit/ })).not.toBeInTheDocument();
  });
});
