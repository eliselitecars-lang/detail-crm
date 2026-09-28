import { expect, test } from '@playwright/test';
import { membershipRow, OWNER, SHOP, TECH } from './support/fixtures';
import { mockSupabase, type Json } from './support/mockSupabase';

/**
 * Inventory (/app/inventory, managers): low-stock products stand out, stock
 * changes go through the ledger RPC (never a direct on_hand write), and each
 * product's history shows receipts and job usage. Technicians can't open it.
 */

type Row = { [key: string]: Json };

const COATING = '80000000-0000-4000-8000-000000000001';
const TOWELS = '80000000-0000-4000-8000-000000000002';

function product(id: string, extra: Row): Row {
  return {
    id,
    shop_id: SHOP.id,
    name: 'Product',
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
    created_at: '2026-09-01T15:00:00Z',
    updated_at: '2026-09-01T15:00:00Z',
    ...extra,
  };
}

test.describe('inventory', () => {
  test('a manager receives stock through the ledger and reads the history', async ({ page }) => {
    const products: Row[] = [
      product(COATING, { name: 'Ceramic coating', on_hand: 2, supplier: 'Detail Supply Co' }),
      product(TOWELS, { name: 'Microfiber towels', unit: 'pack', on_hand: 8, reorder_at: null }),
    ];
    const movements: Record<string, unknown>[] = [];
    const productWrites: string[] = [];
    await mockSupabase(page, {
      user: OWNER,
      tables: {
        shop_members: [membershipRow(OWNER, 'owner')],
        notifications: [],
        products: ({ method }) => {
          if (method !== 'GET') productWrites.push(method);
          return products;
        },
        inventory_movements: [
          {
            id: '81000000-0000-4000-8000-000000000001',
            kind: 'consume',
            quantity: -1,
            unit_cost_cents: null,
            job_id: '50000000-0000-4000-8000-000000000001',
            note: null,
            created_at: '2026-09-25T18:30:00Z',
            job: { id: '50000000-0000-4000-8000-000000000001', number: 1042 },
          },
        ],
      },
      rpc: {
        record_inventory_movement: ({ body }) => {
          movements.push(body as Record<string, unknown>);
          const target = products.find((p) => p.id === COATING);
          if (target) target.on_hand = 8;
          return { id: '81000000-0000-4000-8000-000000000002', kind: 'receive', quantity: 6 };
        },
      },
    });

    await page.goto('/app/inventory');
    const table = page.getByRole('table', { name: 'Products' });
    await expect(table.getByRole('row', { name: /Ceramic coating/ })).toContainText('Low stock');
    await expect(page.getByRole('group', { name: 'Inventory summary' })).toContainText('$125.00');

    await table.getByRole('button', { name: 'Receive Ceramic coating' }).click();
    const dialog = page.getByRole('dialog', { name: /Receive stock · Ceramic coating/ });
    await expect(dialog).toContainText('On hand: 2 bottle');
    await dialog.getByRole('textbox', { name: /Quantity received/ }).fill('6');
    await dialog.getByRole('textbox', { name: /Cost per unit paid/ }).fill('11.00');
    await dialog.getByRole('textbox', { name: /^Note/ }).fill('Invoice 5521');
    await dialog.getByRole('button', { name: 'Receive', exact: true }).click();
    await expect(page.getByText('Stock received')).toBeVisible();

    expect(movements[0]).toEqual({
      p_product_id: COATING,
      p_kind: 'receive',
      p_quantity: 6,
      p_unit_cost_cents: 1100,
      p_note: 'Invoice 5521',
    });
    expect(productWrites).toEqual([]);
    await expect(table.getByRole('row', { name: /Ceramic coating/ })).not.toContainText(
      'Low stock',
    );

    await table.getByRole('button', { name: 'More actions for Ceramic coating' }).click();
    await page.getByRole('menuitem', { name: 'Stock history' }).click();
    const history = page.getByRole('dialog', { name: 'Ceramic coating · stock history' });
    const changes = history.getByRole('list', { name: 'Stock changes' });
    await expect(changes).toContainText('Used on a job');
    await expect(changes.getByRole('link', { name: 'job #1042' })).toHaveAttribute(
      'href',
      '/app/jobs/50000000-0000-4000-8000-000000000001',
    );
  });

  test('technicians don’t get the inventory page', async ({ page }) => {
    let productReads = 0;
    await mockSupabase(page, {
      user: TECH,
      tables: {
        shop_members: [membershipRow(TECH, 'technician')],
        notifications: [],
        products: () => {
          productReads += 1;
          return [];
        },
      },
    });
    await page.goto('/app/inventory');
    await expect(page.getByText('You don’t have access to this page')).toBeVisible();
    await expect(page.getByRole('heading', { name: 'Inventory', exact: true })).toHaveCount(0);
    await expect(page.getByRole('table', { name: 'Products' })).toHaveCount(0);
    expect(productReads).toBe(0);
  });
});
