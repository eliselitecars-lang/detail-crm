import { expect, test, type Page } from '@playwright/test';
import { membershipRow, OWNER, SHOP, type Role } from './support/fixtures';
import { mockSupabase, reply, type MockReply } from './support/mockSupabase';

// Sorted after "Glacier Detailing", so the page opens on SHOP and the shell
// falls back to this one once SHOP is gone.
const SECOND_SHOP = {
  ...SHOP,
  id: '10000000-0000-4000-8000-000000000099',
  name: 'Harbor Coatings',
  slug: 'harbor-coatings',
};

interface Recorded {
  /** Bodies sent to the payments function. */
  calls: unknown[];
  /** Direct table deletes (there must be none: the server deletes). */
  tableDeletes: string[];
}

async function setup(
  page: Page,
  role: Role,
  {
    billingMemberships = 0,
    refusal = null,
  }: { billingMemberships?: number; refusal?: MockReply | null } = {},
): Promise<Recorded> {
  const recorded: Recorded = { calls: [], tableDeletes: [] };
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
        if (method === 'DELETE') recorded.tableDeletes.push(url.search);
        return [SHOP];
      },
    },
    functions: {
      payments: ({ body }) => {
        recorded.calls.push(body);
        if (refusal) return refusal;
        deleted = true;
        return { deleted: true, memberships_cancelled: billingMemberships, sessions_expired: 0 };
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
    expect(recorded.calls).toEqual([
      { action: 'delete_shop', shop_id: SHOP.id, confirm_name: SHOP.name },
    ]);
    expect(recorded.tableDeletes).toEqual([]);
    await expect(page.getByText(SECOND_SHOP.name).first()).toBeVisible();
  });

  test('billing memberships are cancelled in Stripe as part of the deletion', async ({ page }) => {
    const recorded = await setup(page, 'owner', { billingMemberships: 2 });
    await page.goto('/app/settings/delete-shop');
    await expect(page.getByText(/2 active memberships will be cancelled in Stripe/)).toBeVisible();
    await page.getByRole('button', { name: 'Delete shop…' }).click();
    const dialog = page.getByRole('alertdialog', { name: `Delete ${SHOP.name}?` });
    await dialog.getByLabel(/Type the shop name/).fill(SHOP.name);
    await dialog.getByRole('button', { name: 'Delete shop permanently' }).click();
    await expect(page.getByText(`${SHOP.name} was deleted`)).toBeVisible();
    expect(recorded.calls).toHaveLength(1);
  });

  test('a card payment still processing refuses the deletion', async ({ page }) => {
    const recorded = await setup(page, 'owner', {
      refusal: reply(409, {
        error: 'A payment for this is already being processed. Refresh in a moment.',
        code: 'conflict',
        details: { reason: 'payment_in_progress' },
      }),
    });
    await page.goto('/app/settings/delete-shop');
    await page.getByRole('button', { name: 'Delete shop…' }).click();
    const dialog = page.getByRole('alertdialog', { name: `Delete ${SHOP.name}?` });
    await dialog.getByLabel(/Type the shop name/).fill(SHOP.name);
    await dialog.getByRole('button', { name: 'Delete shop permanently' }).click();
    await expect(dialog.getByRole('alert')).toContainText('still being processed');
    await expect(dialog.getByRole('alert')).toContainText('Nothing was deleted.');
    await expect(page).toHaveURL(/\/settings\/delete-shop/);
    expect(recorded.calls).toHaveLength(1);
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
