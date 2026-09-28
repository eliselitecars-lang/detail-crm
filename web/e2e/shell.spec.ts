import { expect, test, type Page } from '@playwright/test';
import { membershipRow, OWNER, TECH } from './support/fixtures';
import { mockSupabase } from './support/mockSupabase';

async function navLabels(page: Page) {
  const nav = page.getByRole('navigation', { name: 'Main' });
  await expect(nav).toBeVisible();
  return nav.getByRole('link').allInnerTexts();
}

test.describe('staff shell', () => {
  test('owner sees every section, shop name and role', async ({ page }) => {
    await mockSupabase(page, {
      user: OWNER,
      tables: { shop_members: [membershipRow(OWNER, 'owner')], notifications: [] },
      counts: { notifications: 3 },
    });
    await page.goto('/app');
    await expect(page.getByRole('heading', { name: 'Dashboard', level: 1 })).toBeVisible();
    expect(await navLabels(page)).toEqual([
      'Dashboard',
      'Calendar',
      'Jobs',
      'Customers',
      'Tasks',
      'Quotes',
      'Invoices',
      'Payments',
      'Memberships',
      'Gift cards',
      'Messages',
      'Campaigns',
      'Reports',
      'Inventory',
      'Team',
      'Timesheets',
      'Catalog',
      'Settings',
    ]);
    await expect(
      page.getByRole('button', { name: /Current shop: Glacier Detailing/ }),
    ).toContainText('Owner');
    await expect(page.getByRole('button', { name: 'Notifications, 3 unread' })).toBeVisible();

    await page.getByRole('link', { name: 'Invoices' }).click();
    await expect(page).toHaveURL(/\/app\/invoices$/);
    await expect(page.getByRole('heading', { name: 'Invoices', level: 1 })).toBeVisible();
  });

  test('technician sees only their sections and is blocked from owner pages', async ({ page }) => {
    await mockSupabase(page, {
      user: TECH,
      tables: { shop_members: [membershipRow(TECH, 'technician')], notifications: [] },
    });
    await page.goto('/app');
    expect(await navLabels(page)).toEqual([
      'Dashboard',
      'Calendar',
      'Jobs',
      'Tasks',
      'Reports',
      'Timesheets',
      'Catalog',
      'Settings',
    ]);
    await expect(
      page.getByRole('button', { name: /Current shop: Glacier Detailing/ }),
    ).toContainText('Technician');

    await page.goto('/app/invoices');
    await expect(page.getByText('You don’t have access to this page')).toBeVisible();
  });

  test('user without a shop is sent to onboarding', async ({ page }) => {
    await mockSupabase(page, { user: OWNER, tables: { shop_members: [] } });
    await page.goto('/app');
    await expect(page).toHaveURL(/\/app\/onboarding$/);
    await expect(page.getByRole('heading', { name: 'Set up your shop' })).toBeVisible();
  });

  test('Cmd/Ctrl-K opens global search', async ({ page }) => {
    await mockSupabase(page, {
      user: OWNER,
      tables: { shop_members: [membershipRow(OWNER, 'owner')], notifications: [] },
      rpc: {
        search_shop: [
          { kind: 'customer', id: 'c-1', title: 'Casey Customer', subtitle: '(205) 555-0123' },
        ],
      },
    });
    await page.goto('/app');
    await expect(page.getByRole('heading', { name: 'Dashboard', level: 1 })).toBeVisible();
    await page.keyboard.press('ControlOrMeta+k');
    const dialog = page.getByRole('dialog', { name: 'Search' });
    await expect(dialog).toBeVisible();
    await dialog.getByRole('combobox', { name: 'Search this shop' }).fill('cas');
    await expect(dialog.getByRole('option', { name: /Casey Customer/ })).toBeVisible();
    await page.keyboard.press('Escape');
    await expect(dialog).toBeHidden();
  });

  test('works at 360px: drawer navigation and no horizontal scroll', async ({ page }) => {
    await page.setViewportSize({ width: 360, height: 740 });
    await mockSupabase(page, {
      user: OWNER,
      tables: { shop_members: [membershipRow(OWNER, 'owner')], notifications: [] },
    });
    await page.goto('/app');
    await expect(page.getByRole('heading', { name: 'Dashboard', level: 1 })).toBeVisible();
    const overflow = await page.evaluate(
      () => document.documentElement.scrollWidth - window.innerWidth,
    );
    expect(overflow).toBeLessThanOrEqual(0);

    await page.getByRole('button', { name: 'Open menu' }).click();
    const drawer = page.getByRole('dialog', { name: 'Menu' });
    await drawer.getByRole('link', { name: 'Calendar' }).click();
    await expect(drawer).toBeHidden();
    await expect(page.getByRole('heading', { name: 'Calendar', level: 1 })).toBeVisible();
  });
});
