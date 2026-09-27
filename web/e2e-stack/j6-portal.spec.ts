import { expect, test } from '@playwright/test';
import { createShop, signUpUser, uniqueSuffix, type StackUser } from './support/stackApi';
import {
  arrangeBookableShop,
  bookOnline,
  loginViaUi,
  rest,
  rpcAs,
  rpcOk,
  trackApiFailures,
  trackPageErrors,
} from './support/journey';

/**
 * J6 — client portal + tenant isolation on the real stack: a customer who
 * booked online signs up with the booking email, /portal claims the record
 * (portal_claim_customers needs a CONFIRMED GoTrue email) and shows the
 * booking and its invoice; the owner of another shop cannot see that
 * customer through the UI or PostgREST.
 */

test.use({ actionTimeout: 15_000, navigationTimeout: 30_000 });

test('J6: a client sees their booking and invoice in /portal; another shop cannot see the customer', async ({
  page,
  browser,
}) => {
  test.setTimeout(240_000);
  const sfx = uniqueSuffix();
  const owner1 = await signUpUser({ fullName: 'Owner One', email: `j6-owner1-${sfx}@stack.test` });
  const shop1 = await createShop(owner1, `J6 Shop One ${sfx}`);
  const bookable = await arrangeBookableShop(owner1, shop1.id, {
    name: `Express Wash ${sfx}`,
    cents: 6000,
  });
  const client = {
    first_name: 'Cleo',
    last_name: `Portal${sfx.slice(0, 4)}`,
    email: `j6-client-${sfx}@stack.test`,
  };
  const booking = await bookOnline(shop1.slug, bookable, client);
  expect(booking.status).toBe('requested');

  // Shop 1 approves the booking and invoices it.
  const jobs = await rest<Array<{ id: string; customer_id: string; number: number }>>(
    'GET',
    `jobs?shop_id=eq.${shop1.id}&select=id,customer_id,number`,
    owner1,
  );
  expect(jobs.json).toHaveLength(1);
  const job = jobs.json[0] ?? { id: '', customer_id: '', number: 0 };
  const approve = await rest('PATCH', `jobs?id=eq.${job.id}&select=id,status`, owner1, {
    status: 'scheduled',
  });
  expect(approve.status, approve.text).toBe(200);
  const invoice = await rpcOk<{ id: string; status: string; total_cents: number }>(
    'create_invoice_from_job',
    { p_job_id: job.id },
    owner1,
  );
  expect(invoice).toMatchObject({ status: 'open', total_cents: 6000 });
  const invoiceToken = await rpcOk<string>(
    'invoice_link_token',
    { p_invoice_id: invoice.id },
    owner1,
  );
  const apiFailures = trackApiFailures(page);
  const pageErrors = trackPageErrors(page);

  // --- 1. The client signs up with the booking email and opens the portal
  await page.goto('/signup?next=%2Fportal');
  await page.getByLabel('Your name').fill('Cleo Portal');
  await page.getByLabel('Email').fill(client.email);
  const password = `Pw-${sfx}-client!`;
  await page.getByLabel(/^Password/).fill(password);
  await page.getByLabel('Confirm password').fill(password);
  await page.getByRole('button', { name: 'Create account' }).click();
  await expect(page).toHaveURL(/\/portal$/);
  await expect(page.getByRole('heading', { name: 'My account', level: 1 })).toBeVisible();
  await expect(page.getByText(`Signed in as ${client.email}`)).toBeVisible();

  const upcoming = page.getByRole('list', { name: 'Upcoming appointments' });
  await expect(upcoming.getByRole('link').first()).toHaveAttribute(
    'href',
    `/booking/${booking.job_token}`,
  );
  const invoices = page.getByRole('list', { name: 'Invoices' });
  await expect(invoices.getByRole('link').first()).toHaveAttribute('href', `/i/${invoiceToken}`);
  await expect(invoices).toContainText('$60.00');
  await expect(page.getByRole('list', { name: 'Vehicles' })).toContainText('2021 Toyota Camry');

  // The claim linked exactly this shop's customer to the client's auth user…
  const session = await page.evaluate(() => {
    const key = Object.keys(localStorage).find((k) => k.endsWith('-auth-token'));
    return key
      ? (JSON.parse(localStorage.getItem(key) ?? '{}') as {
          access_token?: string;
          user?: { id: string };
        })
      : {};
  });
  const clientUser: StackUser = {
    id: session.user?.id ?? '',
    email: client.email,
    password,
    accessToken: session.access_token ?? '',
  };
  const linked = await rest<Array<{ portal_user_id: string | null }>>(
    'GET',
    `customers?id=eq.${job.customer_id}&select=portal_user_id`,
    owner1,
  );
  expect(linked.json[0]?.portal_user_id).toBe(clientUser.id);
  // …but clients still have no direct table access (curated portal_* RPCs only).
  for (const table of ['customers', 'jobs', 'invoices']) {
    const r = await rest<unknown[]>('GET', `${table}?select=id`, clientUser);
    // A denial is an empty 2xx or a 4xx — never a server error.
    expect(r.status, `${table}: ${r.text}`).toBeLessThan(500);
    expect(r.status === 200 ? r.json : [], `${table}: ${r.text}`).toEqual([]);
  }
  const overview = await rpcOk<Record<string, unknown>>('portal_overview', {}, clientUser);
  const overviewText = JSON.stringify(overview);
  expect(overviewText).toContain(booking.job_token);
  expect(overviewText).not.toMatch(/internal_notes|stripe_customer_id|portal_user_id/);

  // The booking page linked from the portal works for the client.
  await upcoming.getByRole('link').first().click();
  await expect(page).toHaveURL(new RegExp(`/booking/${booking.job_token}$`));
  await expect(page.getByText(`#${String(booking.job_number)}`).first()).toBeVisible();
  expect(apiFailures).toEqual([]);
  expect(pageErrors).toEqual([]);

  // --- 2. Another shop's owner cannot see shop 1's customer (UI + REST)
  const owner2 = await signUpUser({ fullName: 'Owner Two', email: `j6-owner2-${sfx}@stack.test` });
  const shop2 = await createShop(owner2, `J6 Shop Two ${sfx}`);
  const other = await browser.newContext();
  const page2 = await other.newPage();
  await loginViaUi(page2, owner2);
  await page2.goto('/app/customers');
  await expect(page2.getByRole('heading', { name: 'Customers', level: 1 })).toBeVisible();
  await expect(page2.getByText(client.last_name)).toHaveCount(0);
  await page2.goto(`/app/customers/${job.customer_id}`);
  await expect(page2.getByText('Customer not found')).toBeVisible();
  await other.close();

  const direct = await rest<unknown[]>(
    'GET',
    `customers?id=eq.${job.customer_id}&select=id,email`,
    owner2,
  );
  expect(direct.status).toBe(200);
  expect(direct.json).toEqual([]);
  const byEmail = await rest<unknown[]>(
    'GET',
    `customers?email=eq.${client.email}&select=id`,
    owner2,
  );
  expect(byEmail.json).toEqual([]);
  const patch = await rest<unknown[]>(
    'PATCH',
    `customers?id=eq.${job.customer_id}&select=id`,
    owner2,
    { notes: 'mine now' },
  );
  // A denial is an empty 2xx or a 4xx — never a server error.
  expect(patch.status, patch.text).toBeLessThan(500);
  expect(patch.status === 200 ? patch.json : [], patch.text).toEqual([]);
  const steal = await rest('POST', 'customers', owner2, {
    shop_id: shop1.id,
    first_name: 'Intruder',
  });
  expect(steal.status, steal.text).toBeGreaterThanOrEqual(400);
  const search = await rpcAs<unknown>(
    'search_shop',
    { p_shop_id: shop1.id, p_query: client.last_name },
    owner2,
  );
  // A denial is an empty 2xx or a 4xx — never a server error.
  expect(search.status, search.text).toBeLessThan(500);
  expect(search.status === 200 ? JSON.stringify(search.json) : '', search.text).not.toContain(
    client.last_name,
  );
  const notes = await rest<Array<{ notes: string | null }>>(
    'GET',
    `customers?id=eq.${job.customer_id}&select=notes`,
    owner1,
  );
  expect(notes.json[0]?.notes ?? null).not.toBe('mine now');
  expect(shop2.id).not.toBe(shop1.id);
});
