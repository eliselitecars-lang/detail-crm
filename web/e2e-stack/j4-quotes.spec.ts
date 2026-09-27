import { expect, test } from '@playwright/test';
import { createShop, signUpUser, uniqueSuffix } from './support/stackApi';
import {
  eventually,
  loginViaUi,
  providerLog,
  rest,
  trackApiFailures,
  trackPageErrors,
} from './support/journey';

/**
 * J4 — quotes on the real stack: the owner builds a quote with an optional
 * upsell, emails it (Resend mock), the customer approves it on /q/<token>
 * choosing the optional item (public_respond_quote), and the owner converts
 * it to a job (convert_quote_to_job) that carries the chosen lines.
 */

test.use({ actionTimeout: 15_000, navigationTimeout: 30_000 });

test('J4: quote with an optional line is approved publicly with the option and converted to a job', async ({
  page,
  browser,
}) => {
  test.setTimeout(240_000);
  const sfx = uniqueSuffix();
  const owner = await signUpUser({ fullName: 'Quinn Quotes', email: `j4-owner-${sfx}@stack.test` });
  const shop = await createShop(owner, `J4 Detail ${sfx}`);
  const custEmail = `j4-cust-${sfx}@stack.test`;
  const cust = await rest<Array<{ id: string }>>('POST', 'customers', owner, {
    shop_id: shop.id,
    first_name: 'Ana',
    last_name: `Diaz${sfx.slice(0, 4)}`,
    email: custEmail,
  });
  expect(cust.status, cust.text).toBe(201);
  const customerId = cust.json[0]?.id ?? '';
  const apiFailures = trackApiFailures(page);
  const pageErrors = trackPageErrors(page);

  // --- 1. Build the quote: one required line and one optional upsell
  await loginViaUi(page, owner);
  await page.goto(`/app/quotes/new?customerId=${customerId}`);
  await expect(page.getByRole('heading', { name: 'New quote' })).toBeVisible();
  await expect(page.getByRole('combobox', { name: 'Customer' })).toHaveValue(
    `Ana Diaz${sfx.slice(0, 4)}`,
  );
  await page.getByRole('button', { name: 'Create quote' }).click();
  await expect(page).toHaveURL(/\/app\/quotes\/[0-9a-f-]{36}$/);
  const quoteId = page.url().split('/').pop() ?? '';

  const addLine = async (name: string, dollars: string, optional: boolean) => {
    await page.getByRole('button', { name: 'Custom line' }).click();
    const dialog = page.getByRole('dialog', { name: 'Add custom line' });
    await dialog.getByLabel('Name').fill(name);
    await dialog.getByLabel('Unit price').fill(dollars);
    if (optional) await dialog.getByRole('checkbox', { name: 'Optional item' }).check();
    await dialog.getByRole('button', { name: 'Add line' }).click();
    await expect(dialog).toBeHidden();
    await expect(page.getByRole('list', { name: 'Line items' }).getByText(name)).toBeVisible();
  };
  await addLine('Ceramic coating', '800', false);
  await addLine('Wheel coating', '150', true);
  await expect(
    page.getByText('Optional items are not included until the customer chooses them.'),
  ).toBeVisible();
  const draft = await rest<Array<Record<string, unknown>>>(
    'GET',
    `quotes?id=eq.${quoteId}&select=status,total_cents,public_token,number`,
    owner,
  );
  expect(draft.json[0]).toMatchObject({ status: 'draft', total_cents: 80000 });
  const token = String(draft.json[0]?.public_token);
  const number = Number(draft.json[0]?.number);

  // --- 2. Send it by email (messaging.send → Resend mock)
  await page.getByRole('button', { name: 'Send quote' }).click();
  const send = page.getByRole('dialog');
  await send.getByText('Email', { exact: true }).click();
  await send.getByRole('button', { name: 'Send email' }).click();
  await expect(page.getByText(/sent by email/)).toBeVisible();
  await eventually(
    async () =>
      (await providerLog('resend')).filter((r) => JSON.stringify(r.body).includes(custEmail)),
    (list) => list.some((r) => JSON.stringify(r.body).includes(`/q/${token}`)),
    'quote email with the /q/<token> link recorded by the Resend mock',
  );

  // --- 3. The customer approves on /q/<token> and picks the optional item
  const anon = await browser.newContext();
  const pub = await anon.newPage();
  // The anonymous customer page must run clean too (no API >= 400, no page errors).
  const publicApiFailures = trackApiFailures(pub);
  const publicPageErrors = trackPageErrors(pub);
  await pub.goto(`/q/${token}`);
  await expect(
    pub.getByRole('heading', { name: `Quote #${String(number)}`, level: 1 }),
  ).toBeVisible();
  const optional = pub.getByRole('list', { name: 'Optional add-ons' });
  await optional.getByRole('checkbox', { name: /Wheel coating/ }).check();
  await pub.getByLabel(/^Your full name/).fill('Ana Diaz');
  await pub.getByRole('button', { name: 'Approve quote' }).click();
  await expect(pub.getByText('Quote approved', { exact: true })).toBeVisible();
  await expect(pub.getByText(/Approved by Ana Diaz/)).toBeVisible();
  await expect(pub.getByText('$950.00').last()).toBeVisible();
  expect(publicApiFailures, 'anonymous page API failures').toEqual([]);
  expect(publicPageErrors, 'anonymous page errors').toEqual([]);
  await anon.close();

  const approved = await rest<Array<Record<string, unknown>>>(
    'GET',
    `quotes?id=eq.${quoteId}&select=status,total_cents,approved_by_name,viewed_at`,
    owner,
  );
  expect(approved.json[0]).toMatchObject({
    status: 'approved',
    total_cents: 95000,
    approved_by_name: 'Ana Diaz',
  });
  expect(approved.json[0]?.viewed_at).toBeTruthy();

  // --- 4. Owner converts the approved quote into a scheduled job
  await page.goto(`/app/quotes/${quoteId}`);
  await expect(page.getByText('Approved', { exact: true }).first()).toBeVisible();
  await page.getByRole('button', { name: 'Convert to job' }).click();
  const convert = page.getByRole('dialog', { name: `Convert quote #${String(number)} to a job` });
  await convert.getByText('Schedule it now').click();
  await convert.getByLabel('Start date').fill('2030-06-10');
  await convert.getByLabel('Start time').fill('09:00');
  await convert.getByRole('button', { name: 'Create job' }).click();
  await expect(page).toHaveURL(/\/app\/jobs\/[0-9a-f-]{36}$/);
  const jobId = page.url().split('/').pop() ?? '';
  const services = page.getByRole('region', { name: 'Services & items' });
  await expect(services.getByText('Ceramic coating')).toBeVisible();
  await expect(services.getByText('Wheel coating')).toBeVisible();
  await expect(services.getByText('$950.00').last()).toBeVisible();

  const job = await rest<Array<Record<string, unknown>>>(
    'GET',
    `jobs?id=eq.${jobId}&select=status,source,quote_id,total_cents,customer_id`,
    owner,
  );
  expect(job.json[0]).toMatchObject({
    source: 'quote',
    quote_id: quoteId,
    total_cents: 95000,
    customer_id: customerId,
    status: 'scheduled',
  });
  const converted = await rest<Array<Record<string, unknown>>>(
    'GET',
    `quotes?id=eq.${quoteId}&select=status,converted_job_id`,
    owner,
  );
  expect(converted.json[0]).toEqual({ status: 'converted', converted_job_id: jobId });
  expect(apiFailures).toEqual([]);
  expect(pageErrors).toEqual([]);
});
