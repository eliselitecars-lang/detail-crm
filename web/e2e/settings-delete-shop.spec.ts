import { expect, test, type Page } from '@playwright/test';
import { membershipRow, OWNER, SHOP, type Role } from './support/fixtures';
import { mockSupabase } from './support/mockSupabase';

// Sorted after "Glacier Detailing", so the page opens on SHOP and the shell
// falls back to this one once SHOP is gone.
const SECOND_SHOP = {
  ...SHOP,
  id: '10000000-0000-4000-8000-000000000099',
  name: 'Harbor Coatings',
  slug: 'harbor-coatings',
};

interface Recorded {
  deletes: string[];
}

async function setup(
  page: Page,
  role: Role,
  { billingMemberships = 0 }: { billingMemberships?: number } = {},
): Promise<Recorded> {
  const recorded: Recorded = { deletes: [] };
  let deleted = false;
  await mockSupabase(page, {
    user: OWNER,
    counts: { memberships: billingMemberships },
    tables: {
      shop_members: () =>
        deleted
          ? [membershipRow(OWNER, 'owner', SECOND_SHOP)]
          : [membershipRow(OWNER, role, SHOP), membershipRow(OWNER, 'owner', SECOND_SHOP)],
      notifications: [],
      shops: ({ method, url }) => {
        if (method === 'DELETE') {
          recorded.deletes.push(url.searchParams.get('id') ?? '');
          deleted = true;
          return [{ id: SHOP.id }];
        }
        return [SHOP];
      },
    },
  });
  return recorded;
}

test.describe('settings — delete shop', () => {
  test('owner deletes the shop after typing its name and lands in the next shop', async ({
    page,
  }) => {
    const recorded = await setup(page, 'owner');
    await page.goto('/app/settings/delete-shop');
    await expect(page.getByRole('heading', { name: 'Delete shop', level: 2 })).toBeVisible();

    await page.getByRole('button', { name: 'Delete shop…' }).click();
    const dialog = page.getByRole('alertdialog', { name: `Delete ${SHOP.name}?` });
    const confirm = dialog.getByRole('button', { name: 'Delete shop permanently' });
    await expect(confirm).toBeDisabled();
    await dialog.getByLabel(/Type the shop name/).fill(SHOP.name);
    await expect(confirm).toBeEnabled();
    await confirm.click();

    await expect(page.getByText(`${SHOP.name} was deleted`)).toBeVisible();
    await expect(page).not.toHaveURL(/\/settings\/delete-shop/);
    expect(recorded.deletes).toEqual([`eq.${SHOP.id}`]);
    await expect(page.getByText(SECOND_SHOP.name).first()).toBeVisible();
  });

  test('deletion is blocked while memberships still bill through Stripe', async ({ page }) => {
    const recorded = await setup(page, 'owner', { billingMemberships: 1 });
    await page.goto('/app/settings/delete-shop');
    await expect(page.getByText(/1 membership still bills a customer/)).toBeVisible();
    await expect(page.getByRole('button', { name: 'Delete shop…' })).toBeDisabled();
    expect(recorded.deletes).toEqual([]);
  });

  test('admins do not see the section', async ({ page }) => {
    await setup(page, 'admin');
    await page.goto('/app/settings/delete-shop');
    await expect(page.getByText('You don’t have access to this page')).toBeVisible();
    await expect(
      page.getByRole('navigation', { name: 'Settings' }).getByRole('link', { name: 'Delete shop' }),
    ).toHaveCount(0);
  });
});
