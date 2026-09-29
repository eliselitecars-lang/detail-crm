import { expect, test, type Page } from '@playwright/test';
import { membershipRow, OWNER, TECH } from './support/fixtures';
import { mockSupabase, reply } from './support/mockSupabase';

const CUSTOMER = {
  id: '30000000-0000-4000-8000-000000000001',
  shop_id: '10000000-0000-4000-8000-000000000001',
  first_name: 'Jane',
  last_name: 'Doe',
  company: null,
  email: 'jane.doe@example.com',
  phone: '+12055550123',
  address_line1: '1 Main St',
  address_line2: null,
  city: 'Birmingham',
  region: 'AL',
  postal_code: '35203',
  country: 'US',
  lat: null,
  lng: null,
  notes: null,
  tags: ['VIP'],
  lifecycle: 'customer',
  source: 'staff',
  sms_opt_in: true,
  email_opt_in: true,
  portal_user_id: null,
  stripe_customer_id: null,
  archived_at: null,
  created_at: '2026-01-05T15:00:00Z',
  updated_at: '2026-01-05T15:00:00Z',
  search_text: 'jane doe',
  sms_opted_out_at: null,
  email_opted_out_at: null,
};
const OTHER = {
  ...CUSTOMER,
  id: '30000000-0000-4000-8000-000000000002',
  first_name: null,
  last_name: null,
  company: 'Acme Fleet Services',
  email: null,
  phone: null,
  tags: [],
  lifecycle: 'lead',
};

/** Applies `id=eq.<uuid>` so single-row reads get exactly one row. */
function byId<T extends { id: string }>(rows: T[]) {
  return ({ url }: { url: URL }) => {
    const id = url.searchParams.get('id');
    return id?.startsWith('eq.') ? rows.filter((r) => r.id === id.slice(3)) : rows;
  };
}

async function horizontalOverflow(page: Page) {
  return page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
}

test.describe('customers', () => {
  test('owner searches, opens a customer and adds a vehicle from its VIN', async ({ page }) => {
    const created: unknown[] = [];
    const searches: string[] = [];
    await mockSupabase(page, {
      user: OWNER,
      tables: {
        shop_members: [membershipRow(OWNER, 'owner')],
        notifications: [],
        customers: ({ url }) => {
          const q = url.searchParams.getAll('search_text');
          if (q.length) searches.push(...q);
          return byId([CUSTOMER, OTHER])({ url });
        },
        vehicle_categories: [{ id: 'cat-1', name: 'Sedan', sort: 1 }],
        vehicles: ({ method, body }) => {
          if (method === 'POST') {
            created.push(body);
            return [{ id: 'v-new' }];
          }
          return [];
        },
      },
    });
    await page.route('https://vpic.nhtsa.dot.gov/**', (route) =>
      route.fulfill({
        status: 200,
        contentType: 'application/json',
        headers: { 'access-control-allow-origin': '*' },
        body: JSON.stringify({
          Results: [{ ModelYear: '2003', Make: 'HONDA', Model: 'Accord', Trim: 'EX-L' }],
        }),
      }),
    );

    await page.goto('/app/customers');
    await expect(page.getByRole('heading', { name: 'Customers', level: 1 })).toBeVisible();
    const table = page.getByRole('table', { name: 'Customers' });
    await expect(table.getByRole('link', { name: 'Jane Doe' })).toBeVisible();
    await expect(table.getByText('Acme Fleet Services')).toBeVisible();

    await page.getByRole('searchbox', { name: 'Search customers' }).fill('jane_d');
    await expect(page).toHaveURL(/q=jane_d/);
    await expect.poll(() => searches).toContain('ilike.%jane\\_d%');

    await table.getByRole('link', { name: 'Jane Doe' }).click();
    await expect(page.getByRole('heading', { name: 'Jane Doe', level: 1 })).toBeVisible();
    await expect(page.getByRole('link', { name: 'Call' })).toHaveAttribute(
      'href',
      'tel:+12055550123',
    );

    await page.getByRole('tab', { name: 'Vehicles' }).click();
    await expect(page.getByText('No vehicles yet')).toBeVisible();
    await page.getByRole('button', { name: 'Add vehicle' }).first().click();
    const dialog = page.getByRole('dialog', { name: 'Add vehicle' });
    await dialog.getByLabel('VIN').fill('1HGCM82633A004352');
    await dialog.getByRole('button', { name: 'Decode VIN' }).click();
    await expect(dialog.getByText(/Filled in 2003 Honda Accord EX-L/)).toBeVisible();
    await expect(dialog.getByLabel('Model')).toHaveValue('Accord');
    await dialog.getByLabel('Color').fill('Silver');
    await dialog.getByRole('button', { name: 'Add vehicle' }).click();
    await expect(dialog).toBeHidden();
    expect(created[0]).toMatchObject({
      customer_id: CUSTOMER.id,
      vin: '1HGCM82633A004352',
      year: 2003,
      make: 'Honda',
      model: 'Accord',
      trim: 'EX-L',
      color: 'Silver',
    });
  });

  test('signing out from a customer leaves no customer name in the tab title (WCAG 2.4.2)', async ({
    page,
  }) => {
    await mockSupabase(page, {
      user: OWNER,
      tables: {
        shop_members: [membershipRow(OWNER, 'owner')],
        notifications: [],
        customers: byId([CUSTOMER, OTHER]),
        vehicles: [],
      },
    });
    await page.goto(`/app/customers/${CUSTOMER.id}`);
    await expect(page.getByRole('heading', { name: 'Jane Doe', level: 1 })).toBeVisible();
    await expect(page).toHaveTitle('Jane Doe · Detail CRM');

    await page.getByRole('button', { name: /^Account menu for / }).click();
    await page.getByRole('menuitem', { name: 'Sign out' }).click();
    // The session ends first, so RequireAuth may get there (?next=) before
    // the menu's own navigation: either way the sign-in page names itself.
    await expect(page).toHaveURL(/\/login(\?|$)/);
    await expect(page.getByRole('button', { name: 'Sign in' })).toBeVisible();
    await expect(page).toHaveTitle('Sign in · Detail CRM');
  });

  test('a pause after a space keeps multi-word search intact', async ({ page }) => {
    const searches: string[][] = [];
    await mockSupabase(page, {
      user: OWNER,
      tables: {
        shop_members: [membershipRow(OWNER, 'owner')],
        notifications: [],
        customers: ({ url }) => {
          const q = url.searchParams.getAll('search_text');
          if (q.length) searches.push(q);
          return [CUSTOMER];
        },
      },
    });
    await page.goto('/app/customers');
    const box = page.getByRole('searchbox', { name: 'Search customers' });
    await expect(page.getByRole('table', { name: 'Customers' })).toBeVisible();
    await box.pressSequentially('jane ');
    await expect(page).toHaveURL(/q=jane\+$/);
    await page.waitForTimeout(400);
    await expect(box).toHaveValue('jane ');
    await box.pressSequentially('doe');
    await expect(box).toHaveValue('jane doe');
    await expect(page).toHaveURL(/q=jane\+doe$/);
    await expect.poll(() => searches.at(-1)).toEqual(['ilike.%jane%', 'ilike.%doe%']);
  });

  test('a page past the end steps back instead of claiming there are no customers', async ({
    page,
  }) => {
    await mockSupabase(page, {
      user: OWNER,
      tables: {
        shop_members: [membershipRow(OWNER, 'owner')],
        notifications: [],
        // PostgREST answers an offset beyond the total with 416 when counting.
        customers: ({ url, method }) =>
          method === 'GET' && Number(url.searchParams.get('offset')) >= 26
            ? reply(416, {
                code: 'PGRST103',
                message: 'Requested range not satisfiable',
                details: 'An offset of 200 was requested, but there are only 26 rows.',
                hint: null,
              })
            : [CUSTOMER],
      },
      counts: { customers: 26 },
    });
    await page.goto('/app/customers?page=9');
    await expect(page).toHaveURL(/\/app\/customers\?page=2$/);
    await expect(
      page.getByRole('table', { name: 'Customers' }).getByRole('link', { name: 'Jane Doe' }),
    ).toBeVisible();
    await expect(page.getByText('No customers yet')).toHaveCount(0);
  });

  test('owner creates a customer', async ({ page }) => {
    let inserted: unknown = null;
    await mockSupabase(page, {
      user: OWNER,
      tables: {
        shop_members: [membershipRow(OWNER, 'owner')],
        notifications: [],
        customers: ({ url, method, body }) => {
          if (method === 'POST') {
            inserted = body;
            return [{ id: CUSTOMER.id }];
          }
          return inserted ? byId([CUSTOMER])({ url }) : [];
        },
      },
    });
    await page.goto('/app/customers');
    await expect(page.getByText('No customers yet')).toBeVisible();
    await page.getByRole('button', { name: 'New customer' }).click();
    const dialog = page.getByRole('dialog', { name: 'New customer' });
    await dialog.getByLabel('First name').fill('Jane');
    await dialog.getByLabel('Last name').fill('Doe');
    await dialog.getByLabel('Mobile phone').fill('205-555-0123');
    await dialog.getByLabel('Email', { exact: true }).fill('Jane.Doe@Example.com');
    await dialog.getByRole('button', { name: 'Add customer' }).click();
    await expect(page).toHaveURL(new RegExp(`/app/customers/${CUSTOMER.id}$`));
    await expect(page.getByRole('heading', { name: 'Jane Doe', level: 1 })).toBeVisible();
    expect(inserted).toMatchObject({
      first_name: 'Jane',
      last_name: 'Doe',
      phone: '+12055550123',
      email: 'jane.doe@example.com',
      shop_id: CUSTOMER.shop_id,
    });
  });

  test('technician sees assigned customers read-only', async ({ page }) => {
    await mockSupabase(page, {
      user: TECH,
      tables: {
        shop_members: [membershipRow(TECH, 'technician')],
        notifications: [],
        customers: byId([CUSTOMER]),
      },
    });
    await page.goto('/app/customers');
    await expect(page.getByText('Customers on jobs assigned to you.')).toBeVisible();
    await expect(page.getByRole('button', { name: 'New customer' })).toHaveCount(0);
    await page
      .getByRole('table', { name: 'Customers' })
      .getByRole('link', { name: 'Jane Doe' })
      .click();
    await expect(page.getByRole('heading', { name: 'Jane Doe', level: 1 })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Edit' })).toHaveCount(0);
    await expect(page.getByRole('tab', { name: 'Saved cards' })).toHaveCount(0);
    await expect(page.getByRole('tab', { name: 'Invoices' })).toHaveCount(0);
  });

  test.describe('at 360px', () => {
    test.use({ viewport: { width: 360, height: 740 } });

    test('list and detail never scroll sideways', async ({ page }) => {
      await mockSupabase(page, {
        user: OWNER,
        tables: {
          shop_members: [membershipRow(OWNER, 'owner')],
          notifications: [],
          customers: byId([
            {
              ...CUSTOMER,
              email: 'christopher.washington-montgomery@detailprofessionals.example.com',
            },
            OTHER,
          ]),
        },
      });
      await page.goto('/app/customers');
      await expect(page.getByRole('list', { name: 'Customers' })).toBeVisible();
      expect(await horizontalOverflow(page)).toBeLessThanOrEqual(0);
      await page.goto(`/app/customers/${CUSTOMER.id}`);
      await expect(page.getByRole('heading', { name: 'Jane Doe', level: 1 })).toBeVisible();
      expect(await horizontalOverflow(page)).toBeLessThanOrEqual(0);
    });

    test('the stacked list can still be sorted', async ({ page }) => {
      const orders: string[] = [];
      await mockSupabase(page, {
        user: OWNER,
        tables: {
          shop_members: [membershipRow(OWNER, 'owner')],
          notifications: [],
          customers: ({ url }) => {
            if (url.searchParams.get('select')?.includes('lifecycle')) {
              orders.push(url.searchParams.getAll('order').join(','));
            }
            return [CUSTOMER, OTHER];
          },
        },
      });
      await page.goto('/app/customers');
      await expect(page.getByRole('list', { name: 'Customers' })).toBeVisible();
      // The header sort buttons live in the hidden desktop table.
      await expect(page.getByRole('table', { name: 'Customers' })).toBeHidden();
      const sortBy = page.getByRole('combobox', { name: 'Sort customers by' });
      await expect(sortBy).toBeVisible();
      await sortBy.selectOption({ label: 'Last updated' });
      await expect(page).toHaveURL(/sort=updated_at/);
      await expect.poll(() => orders.some((o) => o.startsWith('updated_at.'))).toBe(true);
      const direction = page.getByRole('button', { name: /Ascending|Descending/ });
      const before = await direction.textContent();
      await direction.click();
      await expect(direction).not.toHaveText(before ?? '');
      expect(await horizontalOverflow(page)).toBeLessThanOrEqual(0);
    });
  });
});
