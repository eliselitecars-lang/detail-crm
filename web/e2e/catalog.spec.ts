import { expect, test, type Page } from '@playwright/test';
import { membershipRow, OWNER, SHOP, TECH, type MockUser } from './support/fixtures';
import { mockSupabase } from './support/mockSupabase';

type Json = null | boolean | number | string | Json[] | { [key: string]: Json };
type Row = { [key: string]: Json };

const MANAGER: MockUser = {
  id: '00000000-0000-4000-8000-000000000003',
  email: 'manager@glacier.test',
  fullName: 'Mia Manager',
};

const PKG = '30000000-0000-4000-8000-000000000001';
const SVC = '30000000-0000-4000-8000-000000000002';
const ADDON = '30000000-0000-4000-8000-000000000003';
const CAT = '31000000-0000-4000-8000-000000000001';
const VC_CAR = '32000000-0000-4000-8000-000000000001';
const VC_TRUCK = '32000000-0000-4000-8000-000000000002';

function service(id: string, name: string, kind: string, extra: Row = {}): Row {
  return {
    id,
    shop_id: SHOP.id,
    category_id: CAT,
    name,
    description: null,
    kind,
    duration_minutes: 120,
    taxable: true,
    online_bookable: true,
    active: true,
    sort: 10,
    image_path: null,
    archived_at: null,
    created_at: '2026-01-01T00:00:00Z',
    updated_at: '2026-01-01T00:00:00Z',
    ...extra,
  };
}

/** Applies `col=eq.value` filters from a PostgREST URL (enough for these fixtures). */
function filterEq(rows: Row[], url: URL): Row[] {
  let out = rows;
  for (const [key, value] of url.searchParams) {
    if (!value.startsWith('eq.')) continue;
    const wanted = value.slice(3);
    out = out.filter((r) => {
      const v = r[key];
      return (typeof v === 'string' || typeof v === 'number') && String(v) === wanted;
    });
  }
  return out;
}

interface Captured {
  method: string;
  table: string;
  body: unknown;
  search: string;
}

async function setup(page: Page, user: MockUser, role: 'manager' | 'technician' | 'owner') {
  const writes: Captured[] = [];
  const addons: Row[] = [];
  const services: Row[] = [
    service(PKG, 'Showroom Package', 'package'),
    service(SVC, 'Interior Detail', 'service'),
    service(ADDON, 'Pet Hair Removal', 'addon', { online_bookable: false }),
  ];
  const prices: Row[] = [
    {
      id: '33000000-0000-4000-8000-000000000001',
      shop_id: SHOP.id,
      service_id: PKG,
      vehicle_category_id: null,
      price_cents: 30000,
      duration_minutes: null,
      created_at: '2026-01-01T00:00:00Z',
      updated_at: '2026-01-01T00:00:00Z',
    },
  ];
  const record =
    (table: string, rows: () => Row[]) =>
    ({ url, method, body }: { url: URL; method: string; body: unknown }) => {
      if (method !== 'GET') {
        writes.push({ method, table, body, search: url.search });
        const target = filterEq(rows(), url);
        return method === 'POST' ? [{ id: '39000000-0000-4000-8000-000000000001' }] : target;
      }
      return filterEq(rows(), url);
    };

  await mockSupabase(page, {
    user,
    tables: {
      shop_members: [membershipRow(user, role)],
      notifications: [],
      services: record('services', () => services),
      service_categories: [
        { id: CAT, shop_id: SHOP.id, name: 'Exterior', sort: 10, created_at: '', updated_at: '' },
      ],
      service_prices: ({ url, method, body }) => {
        if (method !== 'GET') {
          writes.push({ method, table: 'service_prices', body, search: url.search });
          return [{ id: prices[0]!.id as string }];
        }
        // base-price list uses vehicle_category_id=is.null; detail uses service_id=eq.
        return filterEq(prices, url);
      },
      vehicle_categories: [
        { id: VC_CAR, name: 'Car', sort: 1 },
        { id: VC_TRUCK, name: 'Truck', sort: 2 },
      ],
      package_items: record('package_items', () => [
        {
          id: '34000000-0000-4000-8000-000000000001',
          shop_id: SHOP.id,
          service_id: SVC,
          sort: 10,
          package_id: PKG,
        },
      ]),
      service_addons: ({ url, method, body }) => {
        if (method === 'POST') {
          writes.push({ method, table: 'service_addons', body, search: url.search });
          addons.push({ id: '36000000-0000-4000-8000-000000000001', ...(body as Row) });
          return [];
        }
        return filterEq(addons, url);
      },
      checklist_templates: [
        {
          id: '35000000-0000-4000-8000-000000000001',
          shop_id: SHOP.id,
          name: 'Exterior QC',
          items: [
            { id: 'a', label: 'Wheels clean' },
            { id: 'b', label: 'Glass streak-free' },
          ],
          service_id: PKG,
          created_at: '',
          updated_at: '',
        },
      ],
    },
    counts: {},
  });
  return writes;
}

test.describe('catalog', () => {
  test('manager prices a package by vehicle size and archives it', async ({ page }) => {
    const writes = await setup(page, MANAGER, 'manager');
    await page.goto('/app/catalog');
    const table = page.getByRole('table', { name: 'Catalog items' });
    await expect(table.getByRole('row', { name: /Showroom Package/ })).toContainText('$300.00');
    await table.getByRole('link', { name: 'Showroom Package' }).click();

    await expect(page.getByRole('heading', { name: 'Showroom Package' })).toBeVisible();
    await expect(
      page.getByRole('list', { name: 'Included in this package' }).getByText('Interior Detail'),
    ).toBeVisible();
    const grid = page.getByRole('table', { name: 'Prices by vehicle size' });
    await grid.getByRole('textbox', { name: 'Truck price' }).fill('375');
    await grid.getByRole('textbox', { name: 'Truck time in minutes' }).fill('180');
    await page.getByRole('button', { name: 'Save prices' }).click();
    await expect(page.getByText('Prices saved')).toBeVisible();
    expect(writes.filter((w) => w.table === 'service_prices')).toEqual([
      {
        method: 'POST',
        table: 'service_prices',
        search: expect.any(String),
        body: [
          {
            vehicle_category_id: VC_TRUCK,
            price_cents: 37500,
            duration_minutes: 180,
            shop_id: SHOP.id,
            service_id: PKG,
          },
        ],
      },
    ]);

    const petHair = page.getByRole('checkbox', { name: 'Pet Hair Removal' });
    await petHair.click();
    await expect(petHair).toBeChecked();
    await expect
      .poll(() => writes.filter((w) => w.table === 'service_addons').map((w) => w.body))
      .toEqual([{ shop_id: SHOP.id, service_id: PKG, addon_id: ADDON }]);

    await page.getByRole('button', { name: 'More actions' }).click();
    await page.getByRole('menuitem', { name: 'Archive' }).click();
    await page
      .getByRole('dialog', { name: /Archive Showroom Package/ })
      .getByRole('button', { name: 'Archive' })
      .click();
    await expect(page.getByText('Archived', { exact: true }).first()).toBeVisible();
    const archive = writes.find((w) => w.table === 'services' && w.method === 'PATCH');
    expect(archive?.body).toEqual({ archived_at: expect.any(String) });
    expect(archive?.search).toContain(`id=eq.${PKG}`);
  });

  test('deleting an item in use offers archiving instead', async ({ page }) => {
    const writes = await setup(page, MANAGER, 'manager');
    await page.route('**/rest/v1/job_line_items**', (route) =>
      route.fulfill({
        status: 200,
        headers: {
          'content-range': '0-2/3',
          'access-control-expose-headers': 'content-range',
          'access-control-allow-origin': '*',
        },
      }),
    );
    await page.goto(`/app/catalog/services/${SVC}`);
    await expect(page.getByRole('heading', { name: 'Interior Detail' })).toBeVisible();
    await page.getByRole('button', { name: 'More actions' }).click();
    await page.getByRole('menuitem', { name: 'Delete…' }).click();
    const dialog = page.getByRole('dialog', { name: /Delete Interior Detail/ });
    await expect(dialog).toContainText('3 job lines');
    await expect(dialog).toContainText('can’t be deleted');
    await dialog.getByRole('button', { name: 'Archive instead' }).click();
    await expect(page.getByText('Archived', { exact: true }).first()).toBeVisible();
    expect(writes.some((w) => w.table === 'services' && w.method === 'DELETE')).toBe(false);
  });

  test('technician reads the catalog without edit controls', async ({ page }) => {
    await setup(page, TECH, 'technician');
    await page.goto('/app/catalog');
    await expect(page.getByRole('table', { name: 'Catalog items' })).toBeVisible();
    await expect(page.getByRole('button', { name: 'New item' })).toHaveCount(0);

    await page.getByRole('tab', { name: 'Checklists' }).click();
    const list = page.getByRole('list', { name: 'Checklist templates' });
    await expect(list).toContainText('Exterior QC');
    await expect(list).toContainText('Auto-added with Showroom Package');
    await list.getByRole('button', { name: 'View' }).click();
    await expect(page.getByRole('dialog', { name: 'Exterior QC' })).toContainText(
      'Glass streak-free',
    );
    await page.keyboard.press('Escape');

    await page.goto(`/app/catalog/services/${PKG}`);
    await expect(page.getByRole('heading', { name: 'Showroom Package' })).toBeVisible();
    const grid = page.getByRole('table', { name: 'Prices by vehicle size' });
    await expect(grid).toContainText('$300.00');
    await expect(grid.getByRole('textbox')).toHaveCount(0);
    await expect(page.getByRole('button', { name: 'Edit details' })).toHaveCount(0);
  });

  test('owner catalog page fits a 360px screen', async ({ page }) => {
    await page.setViewportSize({ width: 360, height: 780 });
    await setup(page, OWNER, 'owner');
    await page.goto(`/app/catalog/services/${PKG}`);
    await expect(page.getByRole('heading', { name: 'Showroom Package' })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Upload image' })).toBeVisible();
    const overflow = await page.evaluate(
      () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
    );
    expect(overflow).toBeLessThanOrEqual(0);
  });
});
