import { expect, test } from '@playwright/test';

test.use({ baseURL: 'http://localhost:5174' });

test('shows the Setup screen instead of crashing when Supabase env is missing', async ({
  page,
}) => {
  const errors: string[] = [];
  page.on('pageerror', (error) => errors.push(error.message));
  await page.goto('/');
  await expect(page.getByRole('heading', { name: 'Finish setting up Detail CRM' })).toBeVisible();
  await expect(page.getByText('VITE_SUPABASE_URL', { exact: true })).toBeVisible();
  await expect(page.getByText('VITE_SUPABASE_ANON_KEY', { exact: true })).toBeVisible();
  expect(errors).toEqual([]);
});
