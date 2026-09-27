import { expect, test } from '@playwright/test';
import { membershipRow, OWNER } from './support/fixtures';
import { mockSupabase, reply, sessionFor, STORAGE_KEY } from './support/mockSupabase';

/** /account: every role can delete their own account (App Store 5.1.1(v)). */

test.describe('account deletion', () => {
  test('a shop owner is told to transfer or delete the shop first', async ({ page }) => {
    const calls: unknown[] = [];
    await mockSupabase(page, {
      user: OWNER,
      tables: { shop_members: [membershipRow(OWNER, 'owner')], notifications: [] },
      functions: {
        account: ({ body }) => {
          calls.push(body);
          return reply(409, {
            error: 'Transfer ownership or delete these shops first.',
            code: 'conflict',
            details: {
              reason: 'owns_shops',
              shops: [
                { shop_id: '10000000-0000-4000-8000-000000000001', name: 'Glacier Detailing' },
              ],
            },
          });
        },
      },
    });
    // Reached from the staff shell's user menu.
    await page.goto('/app');
    await page.getByRole('button', { name: /Account menu/ }).click();
    await page.getByRole('menuitem', { name: 'Your account' }).click();
    await expect(page).toHaveURL(/\/account$/);
    await expect(page.getByRole('heading', { name: 'Your account', level: 1 })).toBeVisible();

    await page.getByRole('button', { name: 'Delete account…' }).click();
    const dialog = page.getByRole('alertdialog', { name: 'Delete your account?' });
    const confirm = dialog.getByRole('button', { name: 'Delete account permanently' });
    await expect(confirm).toBeDisabled();
    await dialog.getByLabel('Type DELETE to confirm').fill('DELETE');
    await confirm.click();

    const shops = dialog.getByRole('list', { name: 'Shops you own' });
    await expect(shops).toContainText('Glacier Detailing');
    await expect(
      shops.getByRole('link', { name: 'Transfer ownership of Glacier Detailing' }),
    ).toHaveAttribute('href', '/app/team');
    await expect(shops.getByRole('link', { name: 'Delete Glacier Detailing' })).toHaveAttribute(
      'href',
      '/app/settings/delete-shop',
    );
    expect(calls).toEqual([{ action: 'delete_account' }]);
    await expect(page).toHaveURL(/\/account$/);
  });

  test('a portal client deletes their account and is signed out', async ({ page }) => {
    const client = {
      id: '00000000-0000-4000-8000-0000000000c1',
      email: 'ana@example.com',
      fullName: 'Ana Diaz',
    };
    // Signed in until the account is deleted: the full reload to
    // /login?account=deleted must find no session (the server revoked it).
    await page.addInitScript(
      ({ key, value }) => {
        if (window.location.search.includes('account=deleted')) window.localStorage.removeItem(key);
        else if (!window.localStorage.getItem(key)) window.localStorage.setItem(key, value);
      },
      { key: STORAGE_KEY, value: JSON.stringify(sessionFor(client)) },
    );
    await mockSupabase(page, { functions: { account: { deleted: true } } });
    await page.setViewportSize({ width: 360, height: 740 });
    await page.goto('/account');
    await expect(page.getByText('Signed in as ana@example.com')).toBeVisible();
    const overflow = await page.evaluate(
      () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
    );
    expect(overflow).toBeLessThanOrEqual(0);

    await page.getByRole('button', { name: 'Delete account…' }).click();
    const dialog = page.getByRole('alertdialog', { name: 'Delete your account?' });
    await dialog.getByLabel('Type DELETE to confirm').fill('delete');
    await dialog.getByRole('button', { name: 'Delete account permanently' }).click();
    await expect(page).toHaveURL(/\/login\?account=deleted$/);
    await expect(page.getByText('Your account was deleted.')).toBeVisible();
    await expect(page.getByRole('heading', { name: 'Sign in' })).toBeVisible();
  });

  test('signed-out visitors are sent to sign in first', async ({ page }) => {
    await mockSupabase(page, {});
    await page.goto('/account');
    await expect(page).toHaveURL(/\/login\?next=%2Faccount$/);
  });
});
