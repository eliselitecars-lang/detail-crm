import { expect, test, type Page } from '@playwright/test';
import { createShop, signUpUser, uniqueSuffix } from './support/stackApi';
import { loginViaUi, rest, rpcOk, trackApiFailures, trackPageErrors } from './support/journey';

/**
 * Real-stack page tour: every staff screen (and every settings section) is
 * opened by an owner of a shop with real data, and the technician's screens
 * by an assigned technician. Mocks cannot prove that each screen's PostgREST
 * selects, column grants, RPC signatures and RLS work together; this does —
 * no API response >= 400, no uncaught error, no error state on screen.
 */

test.use({ actionTimeout: 15_000, navigationTimeout: 30_000 });

const OWNER_PAGES = [
  '/app',
  '/app/calendar',
  '/app/jobs',
  '/app/customers',
  '/app/quotes',
  '/app/invoices',
  '/app/payments',
  '/app/memberships',
  '/app/messages',
  '/app/campaigns',
  '/app/reports',
  '/app/team',
  '/app/timesheets',
  '/app/catalog',
  '/app/notifications',
  '/app/settings/business',
  '/app/settings/booking',
  '/app/settings/hours',
  '/app/settings/blocked-times',
  '/app/settings/resources',
  '/app/settings/taxes',
  '/app/settings/vehicle-categories',
  '/app/settings/coupons',
  '/app/settings/templates',
  '/app/settings/forms',
  '/app/settings/payments',
  '/app/settings/sms',
  '/app/settings/delete-shop',
];

const TECH_PAGES = [
  '/app',
  '/app/calendar',
  '/app/jobs',
  '/app/timesheets',
  '/app/reports',
  '/app/notifications',
];

async function visitAll(page: Page, paths: string[], extra: string[] = []): Promise<string[]> {
  const problems: string[] = [];
  for (const path of [...paths, ...extra]) {
    await page.goto(path);
    await page.waitForLoadState('networkidle');
    await expect(page.getByRole('heading', { level: 1 }).first()).toBeVisible();
    // Every error-state wording the app uses for a failed read (web/src):
    // "Couldn’t load/count …", "Couldn’t reach …" and the error boundary's
    // "Something went wrong …".
    const errorStates = await page
      .getByText(/^(Couldn’t (load|count|reach)|Something went wrong)/)
      .allTextContents();
    if (errorStates.length > 0) problems.push(`${path}: ${errorStates.join(' | ')}`);
    const denied = await page.getByText('You don’t have access to this page').count();
    if (denied > 0) problems.push(`${path}: access denied`);
  }
  return problems;
}

test('tour: every owner screen and every technician screen loads cleanly on the real stack', async ({
  page,
  browser,
}) => {
  test.setTimeout(300_000);
  const sfx = uniqueSuffix();
  const owner = await signUpUser({ fullName: 'Tour Owner', email: `tour-owner-${sfx}@stack.test` });
  const shop = await createShop(owner, `Tour Detail ${sfx}`);
  const tech = await signUpUser({ fullName: 'Tour Tech', email: `tour-tech-${sfx}@stack.test` });

  // Data on every screen: customer, vehicle, job with a line, invoice + cash
  // payment, quote, message, notification-producing booking request.
  const cust = await rest<Array<{ id: string }>>('POST', 'customers', owner, {
    shop_id: shop.id,
    first_name: 'Tess',
    last_name: `Tour${sfx.slice(0, 4)}`,
    email: `tour-cust-${sfx}@stack.test`,
  });
  expect(cust.status, cust.text).toBe(201);
  const customerId = cust.json[0]?.id ?? '';
  const vehicle = await rest<Array<{ id: string }>>('POST', 'vehicles?select=id', owner, {
    shop_id: shop.id,
    customer_id: customerId,
    year: 2020,
    make: 'Honda',
    model: 'Civic',
  });
  expect(vehicle.status, vehicle.text).toBe(201);
  const now = new Date();
  const start = new Date(
    Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate(), 16, 0),
  );
  const job = await rest<Array<{ id: string }>>('POST', 'jobs?select=id', owner, {
    shop_id: shop.id,
    customer_id: customerId,
    vehicle_id: vehicle.json[0]?.id,
    scheduled_start: start.toISOString(),
    scheduled_end: new Date(start.getTime() + 3600_000).toISOString(),
  });
  expect(job.status, job.text).toBe(201);
  const jobId = job.json[0]?.id ?? '';
  const line = await rest('POST', 'job_line_items', owner, {
    shop_id: shop.id,
    job_id: jobId,
    name: 'Interior detail',
    quantity: 1,
    unit_price_cents: 12000,
    taxable: true,
  });
  expect(line.status, line.text).toBe(201);
  const invoice = await rpcOk<{ id: string }>(
    'create_invoice_from_job',
    { p_job_id: jobId },
    owner,
  );
  await rpcOk(
    'record_manual_payment',
    { p_invoice_id: invoice.id, p_amount_cents: 5000, p_method: 'cash' },
    owner,
  );
  const quote = await rest<Array<{ id: string }>>('POST', 'quotes?select=id', owner, {
    shop_id: shop.id,
    customer_id: customerId,
  });
  expect(quote.status, quote.text).toBe(201);
  // The technician is a member assigned to the job (membership row as harness plumbing:
  // the invite flow itself is covered by J2).
  const member = await rest<Array<{ id: string }>>('POST', 'shop_members?select=id', 'service', {
    shop_id: shop.id,
    user_id: tech.id,
    role: 'technician',
    display_name: 'Tour Tech',
  });
  expect(member.status, member.text).toBe(201);
  const assign = await rest('POST', 'job_assignments', owner, {
    shop_id: shop.id,
    job_id: jobId,
    member_id: member.json[0]?.id,
  });
  expect(assign.status, assign.text).toBe(201);

  // --- Owner tour
  const apiFailures = trackApiFailures(page);
  const pageErrors = trackPageErrors(page);
  await loginViaUi(page, owner);
  const ownerProblems = await visitAll(page, OWNER_PAGES, [
    `/app/jobs/${jobId}`,
    `/app/customers/${customerId}`,
    `/app/invoices/${invoice.id}`,
    `/app/quotes/${quote.json[0]?.id ?? ''}`,
    '/app/jobs/new',
    '/app/quotes/new',
    '/app/invoices/new',
  ]);
  expect(ownerProblems).toEqual([]);
  expect(apiFailures).toEqual([]);
  expect(pageErrors).toEqual([]);

  // --- Technician tour
  const techCtx = await browser.newContext();
  const techPage = await techCtx.newPage();
  const techApi = trackApiFailures(techPage);
  const techErrors = trackPageErrors(techPage);
  await loginViaUi(techPage, tech);
  const techProblems = await visitAll(techPage, TECH_PAGES, [`/app/jobs/${jobId}`]);
  expect(techProblems).toEqual([]);
  expect(techApi).toEqual([]);
  expect(techErrors).toEqual([]);
  await techCtx.close();
});
