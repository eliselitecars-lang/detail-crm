import { screen, waitFor, within } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { membership, renderRoute, shopValue } from '@/test/render';
import { builders, mockRpc, resetSupabaseMock, setTableResult } from '@/test/supabaseMock';
import InventoryPage from './InventoryPage';
import { isLowStock, movementQuantity, productDraft, productWrite, stockValueCents } from './model';

vi.mock('@/lib/supabase', () => import('@/test/supabaseMock'));

function product(id: string, extra: Record<string, unknown> = {}) {
  return {
    id,
    shop_id: 'shop-1',
    name: `Product ${id}`,
    sku: null,
    unit: 'bottle',
    unit_cost_cents: 1250,
    on_hand: 10,
    reorder_at: 3,
    reorder_qty: 12,
    supplier: null,
    notes: null,
    active: true,
    archived_at: null,
    low_stock_notified_at: null,
    created_at: '',
    updated_at: '',
    ...extra,
  };
}

function render() {
  return renderRoute(<InventoryPage />, {
    path: '/app/inventory',
    shop: shopValue({ membership: membership({ role: 'manager' }) }),
  });
}

beforeEach(() => {
  resetSupabaseMock();
});

describe('InventoryPage', () => {
  it('lists products with low-stock badges and the stock value', async () => {
    setTableResult('products', {
      data: [
        product('p1', { name: 'Ceramic coating', on_hand: 2 }),
        product('p2', { name: 'Microfiber towels', unit: 'pack', on_hand: 8, reorder_at: null }),
        product('p3', { name: 'Old wax', archived_at: '2026-01-01T00:00:00Z' }),
      ],
    });
    const { user } = render();
    const table = await screen.findByRole('table', { name: 'Products' });
    expect(within(table).getByRole('row', { name: /Ceramic coating/ })).toHaveTextContent(
      'Low stock',
    );
    expect(within(table).queryByText('Old wax')).not.toBeInTheDocument();
    const summary = screen.getByRole('group', { name: 'Inventory summary' });
    expect(summary).toHaveTextContent('$125.00'); // (2 + 8) × $12.50
    await user.click(screen.getByRole('checkbox', { name: 'Low stock only' }));
    expect(within(table).queryByText('Microfiber towels')).not.toBeInTheDocument();
  });

  it('receives stock through the ledger RPC with the purchase cost', async () => {
    setTableResult('products', { data: [product('p1', { name: 'Ceramic coating' })] });
    const calls = mockRpc({
      record_inventory_movement: {
        data: { id: 'mv-1', kind: 'receive', quantity: 6, product_id: 'p1' },
      },
    });
    const { user } = render();
    await user.click(
      (await screen.findAllByRole('button', { name: 'Receive Ceramic coating' }))[0]!,
    );
    const dialog = await screen.findByRole('dialog', { name: /Receive stock · Ceramic coating/ });
    await user.type(within(dialog).getByRole('textbox', { name: /Quantity received/ }), '6');
    await user.type(within(dialog).getByRole('textbox', { name: /Cost per unit paid/ }), '11.00');
    await user.click(within(dialog).getByRole('button', { name: 'Receive' }));
    await waitFor(() =>
      expect(calls[0]).toEqual({
        fn: 'record_inventory_movement',
        args: { p_product_id: 'p1', p_kind: 'receive', p_quantity: 6, p_unit_cost_cents: 1100 },
      }),
    );
  });

  it('creates a product with an opening count and never writes stock afterwards', async () => {
    setTableResult('products', { data: [] });
    const { user } = render();
    await user.click(await screen.findByRole('button', { name: 'Add product' }));
    const dialog = await screen.findByRole('dialog', { name: 'New product' });
    await user.type(within(dialog).getByRole('textbox', { name: /^Name/ }), 'Tire shine');
    await user.type(within(dialog).getByRole('textbox', { name: /^Unit/ }), 'gallon');
    await user.type(within(dialog).getByRole('textbox', { name: /In stock now/ }), '4');
    await user.click(within(dialog).getByRole('button', { name: 'Add product' }));
    await waitFor(() => {
      const insert = builders.products?.find((b) => b.insert.mock.calls.length > 0);
      expect(insert?.insert).toHaveBeenCalledWith(
        expect.objectContaining({
          name: 'Tire shine',
          unit: 'gallon',
          on_hand: 4,
          shop_id: 'shop-1',
        }),
      );
    });
  });
});

describe('inventory model', () => {
  it('validates product fields and stock changes', () => {
    const bad = productWrite({ ...productDraft(null), unit: '' }, true);
    expect(bad.errors).toMatchObject({ name: 'Name is required.', unit: expect.any(String) });
    const ok = productWrite(
      { ...productDraft(null), name: 'Pads', unit: 'pad', reorderAt: '2.5' },
      false,
    );
    expect(ok.values).toMatchObject({ name: 'Pads', reorder_at: 2.5 });
    expect(ok.values).not.toHaveProperty('on_hand');
    expect(movementQuantity('adjust', '-2')).toEqual({ quantity: -2, error: null });
    expect(movementQuantity('adjust', '0').error).toBeTruthy();
    expect(movementQuantity('receive', '0').error).toBeTruthy();
    expect(movementQuantity('count', '0')).toEqual({ quantity: 0, error: null });
    expect(movementQuantity('count', '1.2345').error).toBeTruthy();
  });

  it('flags low stock and values stock at cost', () => {
    expect(isLowStock({ on_hand: 3, reorder_at: 3, active: true, archived_at: null })).toBe(true);
    expect(isLowStock({ on_hand: 3, reorder_at: null, active: true, archived_at: null })).toBe(
      false,
    );
    expect(
      stockValueCents([
        { on_hand: 1.5, unit_cost_cents: 999 },
        { on_hand: -1, unit_cost_cents: 500 },
      ]),
    ).toBe(1499);
  });
});
