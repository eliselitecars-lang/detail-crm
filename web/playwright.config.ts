import { defineConfig, devices } from '@playwright/test';

/**
 * Smoke tests against the Vite dev server with a MOCKED Supabase backend
 * (e2e/support/mockSupabase.ts intercepts every *.supabase.co request).
 *
 * Two servers:
 *  - :5173 configured with a fake project URL (all normal specs)
 *  - :5174 with the env vars blank (Setup screen spec)
 *
 * Browsers: CI runs `npx playwright install --with-deps chromium`. Locally,
 * PLAYWRIGHT_BROWSERS_PATH may point at a preinstalled build; set
 * PW_CHROMIUM_EXECUTABLE to force a specific Chromium binary.
 */
const CONFIGURED_PORT = 5173;
const UNCONFIGURED_PORT = 5174;
export const E2E_SUPABASE_URL = 'https://e2e-mock.supabase.co';

const executablePath = process.env.PW_CHROMIUM_EXECUTABLE;

export default defineConfig({
  testDir: './e2e',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  workers: process.env.CI ? 2 : undefined,
  reporter: process.env.CI ? [['list'], ['html', { open: 'never' }]] : [['list']],
  timeout: 30_000,
  expect: { timeout: 7_500 },
  use: {
    baseURL: `http://localhost:${CONFIGURED_PORT}`,
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
  },
  projects: [
    {
      name: 'chromium',
      use: {
        ...devices['Desktop Chrome'],
        ...(executablePath ? { launchOptions: { executablePath } } : {}),
      },
    },
  ],
  webServer: [
    {
      command: `npx vite --mode e2e --port ${CONFIGURED_PORT} --strictPort`,
      url: `http://localhost:${CONFIGURED_PORT}`,
      reuseExistingServer: !process.env.CI,
      timeout: 120_000,
      env: {
        VITE_SUPABASE_URL: E2E_SUPABASE_URL,
        VITE_SUPABASE_ANON_KEY: 'e2e-anon-key',
      },
    },
    {
      command: `npx vite --mode e2e --port ${UNCONFIGURED_PORT} --strictPort`,
      url: `http://localhost:${UNCONFIGURED_PORT}`,
      reuseExistingServer: !process.env.CI,
      timeout: 120_000,
      env: {
        VITE_SUPABASE_URL: '',
        VITE_SUPABASE_ANON_KEY: '',
      },
    },
  ],
});
