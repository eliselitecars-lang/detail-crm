import { defineConfig, devices } from '@playwright/test';
import { stackEnv } from './e2e-stack/support/stackEnv';

/**
 * End-to-end tests against the REAL local Supabase stack (no mocks):
 * GoTrue, PostgREST, Storage, Realtime and the edge functions started by
 * `scripts/stack/up.sh` (with stripe-mock and the Twilio/Resend mock).
 *
 *   scripts/stack/up.sh
 *   cd web && npx playwright test -c playwright.stack.config.ts
 *
 * The Vite dev server is started on 127.0.0.1:5173 (the stack's
 * APP_BASE_URL / GoTrue site_url) pointed at the local API with the local
 * anon key. Stack URLs and keys come from scripts/stack/.state/stack.env or
 * the STACK_* environment variables (see e2e-stack/support/stackEnv.ts).
 * Every test creates its own uniquely named users and shops, so specs can run
 * in parallel and repeatedly against one stack.
 */
const env = stackEnv();
const executablePath = process.env.PW_CHROMIUM_EXECUTABLE;
const APP_URL = env.appUrl;
const port = Number(new URL(APP_URL).port || 5173);

export default defineConfig({
  testDir: './e2e-stack',
  outputDir: './test-results-stack',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  // A journey that only passes on retry is a real race: fail CI instead of hiding it.
  failOnFlakyTests: !!process.env.CI,
  workers: process.env.CI ? 2 : undefined,
  reporter: process.env.CI
    ? [['list'], ['html', { open: 'never', outputFolder: 'playwright-report-stack' }]]
    : [['list']],
  timeout: 60_000,
  expect: { timeout: 15_000 },
  use: {
    baseURL: APP_URL,
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
  webServer: {
    command: `npx vite --host 127.0.0.1 --port ${port} --strictPort`,
    url: APP_URL,
    reuseExistingServer: !process.env.CI,
    timeout: 120_000,
    env: {
      VITE_SUPABASE_URL: env.apiUrl,
      VITE_SUPABASE_ANON_KEY: env.anonKey,
    },
  },
});
