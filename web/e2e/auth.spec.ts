import { expect, test } from '@playwright/test';
import { membershipRow, OWNER, TECH } from './support/fixtures';
import { mockSupabase, sessionFor, STORAGE_KEY } from './support/mockSupabase';

test.describe('sign in', () => {
  test('login page validates and shows server errors', async ({ page }) => {
    await mockSupabase(page, { accounts: [OWNER] });
    await page.goto('/login');
    await expect(page.getByRole('heading', { name: 'Sign in' })).toBeVisible();
    await page.getByRole('button', { name: 'Sign in' }).click();
    await expect(page.getByText('Email is required.')).toBeVisible();

    await page.getByLabel('Email').fill('nobody@glacier.test');
    await page.getByLabel(/^Password/).fill('whatever');
    await page.getByRole('button', { name: 'Sign in' }).click();
    await expect(page.getByRole('alert')).toContainText('Email or password is incorrect.');
  });

  test('each sign-in page names itself in the tab title (WCAG 2.4.2)', async ({ page }) => {
    await mockSupabase(page, { accounts: [OWNER] });
    for (const [path, title] of [
      ['/login', 'Sign in · Detail CRM'],
      ['/signup', 'Create your account · Detail CRM'],
      ['/forgot-password', 'Reset your password · Detail CRM'],
    ] as const) {
      await page.goto(path);
      await expect(page.getByRole('heading', { level: 1 })).toBeVisible();
      await expect(page).toHaveTitle(title);
    }
  });

  test('signing in lands on the dashboard of the user’s shop', async ({ page }) => {
    await mockSupabase(page, {
      accounts: [OWNER],
      tables: { shop_members: [membershipRow(OWNER, 'owner')] },
    });
    await page.goto('/login');
    await page.getByLabel('Email').fill(OWNER.email);
    await page.getByLabel(/^Password/).fill('correct-horse');
    await page.getByRole('button', { name: 'Sign in' }).click();
    await expect(page).toHaveURL(/\/app$/);
    await expect(page.getByRole('heading', { name: 'Dashboard', level: 1 })).toBeVisible();
  });

  test('protected routes redirect to login and come back after sign-in', async ({ page }) => {
    await mockSupabase(page, {
      accounts: [OWNER],
      tables: { shop_members: [membershipRow(OWNER, 'owner')] },
    });
    await page.goto('/app/customers');
    await expect(page).toHaveURL(/\/login\?next=%2Fapp%2Fcustomers$/);
    await page.getByLabel('Email').fill(OWNER.email);
    await page.getByLabel(/^Password/).fill('correct-horse');
    await page.getByRole('button', { name: 'Sign in' }).click();
    await expect(page).toHaveURL(/\/app\/customers$/);
    await expect(page.getByRole('heading', { name: 'Customers', level: 1 })).toBeVisible();
  });
});

test.describe('password reset', () => {
  test('a valid recovery link opens the new-password form', async ({ page }) => {
    await mockSupabase(page, { user: OWNER });
    const { access_token, refresh_token } = sessionFor(OWNER);
    await page.goto(
      `/reset-password#access_token=${access_token}&refresh_token=${refresh_token}` +
        '&expires_in=3600&expires_at=' +
        String(Math.floor(Date.now() / 1000) + 3600) +
        '&token_type=bearer&type=recovery',
    );
    await expect(page.getByLabel(/^New password/)).toBeVisible();
    await expect(page.getByRole('button', { name: 'Update password' })).toBeVisible();
  });

  test('an ordinary signed-in session gets no password form', async ({ page }) => {
    await mockSupabase(page, {
      user: OWNER,
      tables: { shop_members: [membershipRow(OWNER, 'owner')] },
    });
    await page.goto('/reset-password');
    await expect(page.getByRole('alert')).toContainText(
      'open the reset link from your latest email',
    );
    await expect(page.getByLabel(/^New password/)).toHaveCount(0);
  });
});

test.describe('sign-in links in the URL (login CSRF)', () => {
  test('another account’s tokens on an app page never replace the signed-in session', async ({
    page,
  }) => {
    await mockSupabase(page, {
      user: OWNER,
      tables: { shop_members: [membershipRow(OWNER, 'owner')] },
    });
    const attacker = sessionFor(TECH);
    await page.goto(
      `/app#access_token=${attacker.access_token}&refresh_token=${attacker.refresh_token}` +
        '&expires_in=3600&token_type=bearer&type=magiclink',
    );
    await expect(page).toHaveURL(/\/app(?:\/[a-z-]*)?$/);
    const stored = await page.evaluate(
      (key) =>
        JSON.parse(window.localStorage.getItem(key) ?? '{}') as {
          access_token?: string;
          refresh_token?: string;
        },
      STORAGE_KEY,
    );
    expect(stored.refresh_token).toBe(sessionFor(OWNER).refresh_token);
    expect(stored.access_token).not.toBe(attacker.access_token);
    // …and the tokens are gone from the address bar.
    expect(await page.evaluate(() => window.location.hash)).toBe('');
  });
});
