import { expect, test } from '@playwright/test';
import { createShop, rpc, signUpUser } from './support/stackApi';
import { stackEnv } from './support/stackEnv';

/**
 * Smoke tests against the REAL local Supabase stack (scripts/stack/up.sh).
 * Journey specs live next to this file; they share support/stackApi.ts.
 */

test('login page renders and shows real GoTrue errors', async ({ page }) => {
  await page.goto('/login');
  await expect(page.getByRole('heading', { name: 'Sign in' })).toBeVisible();
  await page.getByLabel('Email').fill(`nobody-${Date.now()}@stack.test`);
  await page.getByLabel(/^Password/).fill('definitely-wrong');
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page.getByRole('alert')).toContainText('Email or password is incorrect.');
});

test('a real owner signs in and lands on the dashboard of their shop', async ({ page }) => {
  const owner = await signUpUser({ fullName: 'Stack Owner' });
  await createShop(owner);

  // Every API call the dashboard makes must succeed on the real stack
  // (PostgREST grants, RPC signatures, RLS) — mocks cannot prove that.
  const apiFailures: string[] = [];
  page.on('response', (response) => {
    if (response.url().startsWith(stackEnv().apiUrl) && response.status() >= 400) {
      apiFailures.push(
        `${response.request().method()} ${response.url()} -> ${String(response.status())}`,
      );
    }
  });

  await page.goto('/login');
  await page.getByLabel('Email').fill(owner.email);
  await page.getByLabel(/^Password/).fill(owner.password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/app$/);
  await expect(page.getByRole('heading', { name: 'Dashboard', level: 1 })).toBeVisible();
  await page.waitForLoadState('networkidle');
  await expect(page.getByText('Couldn’t load this')).toHaveCount(0);
  expect(apiFailures).toEqual([]);
});

test('a signed-in user without a shop is sent to onboarding', async ({ page }) => {
  const user = await signUpUser();
  await page.goto('/login');
  await page.getByLabel('Email').fill(user.email);
  await page.getByLabel(/^Password/).fill(user.password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/app\/onboarding$/);
});

test('the public shop profile RPC serves a newly created shop to anon', async () => {
  const owner = await signUpUser();
  const shop = await createShop(owner);
  const profile = await rpc<Record<string, unknown>>('public_shop_profile', { p_slug: shop.slug });
  expect(JSON.stringify(profile)).toContain(shop.slug);
});
