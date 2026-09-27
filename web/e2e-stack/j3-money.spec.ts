import { expect, test } from '@playwright/test';
import { createShop, signUpUser, uniqueSuffix, type StackUser } from './support/stackApi';
import {
  connectStripe,
  eventually,
  loginViaUi,
  postStripeEvent,
  providerLog,
  rest,
  rpcOk,
  stripeCharge,
  stripeId,
  stripePaymentIntent,
  stubStripeHostedPages,
  trackApiFailures,
  trackPageErrors,
} from './support/journey';

/**
 * J3 — money on the real stack: invoice from a completed job, public pay page
 * → invoice_checkout (stripe-mock) → signed checkout.session.completed →
 * invoice paid; a cash payment on a second invoice; a card refund through
 * payments.refund (stripe-mock) followed by the Stripe webhook; dashboard and
 * report numbers are net of refunds with tips reported separately.
 */

test.use({ actionTimeout: 15_000, navigationTimeout: 30_000 });

interface Row {
  id: string;
  number: number;
}

/** Arranges a completed job with one taxable custom line (owner JWT, RLS applies). */
async function completedJob(
  owner: StackUser,
  shopId: string,
  customerId: string,
  name: string,
  cents: number,
  day: number,
) {
  const job = await rest<Row[]>('POST', 'jobs?select=id,number', owner, {
    shop_id: shopId,
    customer_id: customerId,
    scheduled_start: `2030-05-${String(day).padStart(2, '0')}T15:00:00Z`,
    scheduled_end: `2030-05-${String(day).padStart(2, '0')}T17:00:00Z`,
  });
  expect(job.status, job.text).toBe(201);
  const jobId = job.json[0]?.id ?? '';
  const line = await rest('POST', 'job_line_items', owner, {
    shop_id: shopId,
    job_id: jobId,
    name,
    quantity: 1,
    unit_price_cents: cents,
    taxable: true,
  });
  expect(line.status, line.text).toBe(201);
  for (const status of ['confirmed', 'en_route', 'in_progress', 'completed']) {
    const r = await rest('PATCH', `jobs?id=eq.${jobId}&select=id,status`, owner, { status });
    expect(r.status, `${status}: ${r.text}`).toBe(200);
  }
  return job.json[0] as Row;
}

test('J3: invoice paid by card via Checkout + webhook, cash on another, refund, net revenue', async ({
  page,
  browser,
}) => {
  test.setTimeout(240_000);
  const sfx = uniqueSuffix();
  const owner = await signUpUser({ fullName: 'Morgan Money', email: `j3-owner-${sfx}@stack.test` });
  const shop = await createShop(owner, `J3 Detail ${sfx}`);
  const account = await connectStripe(owner, shop.id);
  const custEmail = `j3-cust-${sfx}@stack.test`;
  const cust = await rest<Array<{ id: string }>>('POST', 'customers', owner, {
    shop_id: shop.id,
    first_name: 'Pat',
    last_name: `Payer${sfx.slice(0, 4)}`,
    email: custEmail,
    email_opt_in: true,
  });
  expect(cust.status, cust.text).toBe(201);
  const customerId = cust.json[0]?.id ?? '';
  const jobA = await completedJob(owner, shop.id, customerId, 'Full detail', 20000, 6);
  const jobB = await completedJob(owner, shop.id, customerId, 'Maintenance wash', 8000, 7);
  const apiFailures = trackApiFailures(page);
  const pageErrors = trackPageErrors(page);

  // --- 1. Owner creates the invoice from the completed job and sends it by email
  await loginViaUi(page, owner);
  await page.goto(`/app/jobs/${jobA.id}`);
  await expect(
    page.getByRole('heading', { name: `Job #${String(jobA.number)}`, level: 1 }),
  ).toBeVisible();
  await page.getByRole('button', { name: 'Create invoice' }).click();
  await expect(page.getByText('Invoice created')).toBeVisible();
  await expect(page).toHaveURL(/\/app\/invoices\/[0-9a-f-]{36}$/);
  const invoiceAId = page.url().split('/').pop() ?? '';
  await expect(page.getByRole('heading', { name: /^Invoice #\d+$/, level: 1 })).toBeVisible();
  // create_invoice_from_job issues the invoice right away (status open), so
  // the header offers "Resend" rather than "Send invoice".
  await page.getByRole('button', { name: /^(Send invoice|Resend)$/ }).click();
  const send = page.getByRole('dialog');
  await send.getByText('Email', { exact: true }).click();
  await send.getByRole('button', { name: 'Send email' }).click();
  await expect(page.getByText(/sent by email/)).toBeVisible();
  const invA = await rest<Array<{ status: string; balance_cents: number; number: number }>>(
    'GET',
    `invoices?id=eq.${invoiceAId}&select=status,balance_cents,number`,
    owner,
  );
  expect(invA.json[0]).toMatchObject({ status: 'open', balance_cents: 20000 });
  // invoices.public_token is not selectable by staff (column grants); the app uses this RPC.
  const tokenA = await rpcOk<string>('invoice_link_token', { p_invoice_id: invoiceAId }, owner);
  // The email went out through the Resend mock with the public pay link.
  await eventually(
    async () =>
      (await providerLog('resend')).filter((r) => JSON.stringify(r.body).includes(custEmail)),
    (list) => list.some((r) => JSON.stringify(r.body).includes(`/i/${tokenA}`)),
    'invoice email with the /i/<token> link recorded by the Resend mock',
  );

  // --- 2. The customer opens /i/<token>, adds a 20% tip and goes to Checkout
  const anon = await browser.newContext();
  const pub = await anon.newPage();
  // The anonymous customer page must run clean too (no API >= 400, no page errors).
  const publicApiFailures = trackApiFailures(pub);
  const publicPageErrors = trackPageErrors(pub);
  const stripePages = await stubStripeHostedPages(pub);
  const checkouts: Array<{ status: number; body: Record<string, unknown> }> = [];
  await pub.route('**/functions/v1/payments', async (route) => {
    const response = await route.fetch();
    checkouts.push({
      status: response.status(),
      body: (await response.json()) as Record<string, unknown>,
    });
    await route.fulfill({ response });
  });
  await pub.goto(`/i/${tokenA}`);
  await expect(
    pub.getByRole('heading', { name: `Invoice #${String(invA.json[0]?.number)}`, level: 1 }),
  ).toBeVisible();
  await expect(pub.getByText('$200.00').first()).toBeVisible();
  await pub.getByText('20%', { exact: true }).click();
  await pub.getByRole('button', { name: 'Pay $200.00 + $40.00 tip' }).click();
  await expect.poll(() => checkouts.length).toBe(1);
  expect(checkouts[0]).toMatchObject({
    status: 200,
    body: { amount_cents: 20000, tip_cents: 4000, currency: 'usd' },
  });
  await expect.poll(() => stripePages.length).toBe(1);

  // --- 3. Stripe reports the Checkout Session paid (signed Connect webhook)
  const pi = stripeId('pi');
  const ch = stripeId('ch');
  const metadata = {
    shop_id: shop.id,
    invoice_id: invoiceAId,
    job_id: jobA.id,
    customer_id: customerId,
    kind: 'payment',
    tip_cents: '4000',
    source: 'invoice_checkout',
  };
  const completed = await postStripeEvent('checkout.session.completed', account, {
    id: stripeId('cs'),
    object: 'checkout.session',
    mode: 'payment',
    status: 'complete',
    payment_status: 'paid',
    amount_total: 24000,
    currency: 'usd',
    customer: null,
    client_reference_id: invoiceAId,
    metadata,
    payment_intent: stripePaymentIntent({
      paymentIntentId: pi,
      chargeId: ch,
      amount: 24000,
      metadata,
    }),
  });
  expect(completed.status, completed.text).toBe(200);
  expect(completed.json).toMatchObject({ received: true, handled: true, result: 'applied' });
  // A replay of the same delivery never double-counts (idempotent upsert by PI).
  const replay = await postStripeEvent(
    'payment_intent.succeeded',
    account,
    stripePaymentIntent({ paymentIntentId: pi, chargeId: ch, amount: 24000, metadata }),
  );
  expect(replay.status, replay.text).toBe(200);

  await pub.goto(`/i/${tokenA}?paid=1`);
  await expect(pub.getByText('Payment received — thank you!')).toBeVisible();
  await expect(pub.getByRole('button', { name: /^Pay / })).toHaveCount(0);
  expect(publicApiFailures, 'anonymous page API failures').toEqual([]);
  expect(publicPageErrors, 'anonymous page errors').toEqual([]);
  await anon.close();

  await page.goto(`/app/invoices/${invoiceAId}`);
  await expect(page.getByText('Paid', { exact: true }).first()).toBeVisible();
  await expect(page.getByText('Visa •••• 4242')).toBeVisible();
  const paidA = await rest<Array<Record<string, number | string>>>(
    'GET',
    `invoices?id=eq.${invoiceAId}&select=status,amount_paid_cents,balance_cents,tip_cents`,
    owner,
  );
  expect(paidA.json[0]).toEqual({
    status: 'paid',
    amount_paid_cents: 20000,
    balance_cents: 0,
    tip_cents: 4000,
  });

  // --- 4. Cash on the second invoice (record_manual_payment through the UI)
  await page.goto(`/app/jobs/${jobB.id}`);
  await page.getByRole('button', { name: 'Create invoice' }).click();
  await expect(page).toHaveURL(/\/app\/invoices\/[0-9a-f-]{36}$/);
  const invoiceBId = page.url().split('/').pop() ?? '';
  await page.getByRole('button', { name: 'Record payment' }).click();
  const record = page.getByRole('dialog');
  await expect(record.getByLabel(/^Amount/)).toHaveValue('80.00');
  await record.getByRole('button', { name: 'Record payment' }).click();
  await expect(page.getByText('$80.00 payment recorded')).toBeVisible();
  const paidB = await rest<Array<Record<string, number | string>>>(
    'GET',
    `invoices?id=eq.${invoiceBId}&select=status,amount_paid_cents,balance_cents`,
    owner,
  );
  expect(paidB.json[0]).toEqual({ status: 'paid', amount_paid_cents: 8000, balance_cents: 0 });

  // --- 5. Refund part of the card payment through payments.refund (stripe-mock)
  // stripe-mock is stateless: every Charge it returns is its fixture of 100
  // cents, so the function caps what is refundable at $1.00 (min(payment,
  // Stripe charge amount)). A $1.00 partial refund is the most it can prove.
  await page.goto(`/app/invoices/${invoiceAId}`);
  await page.getByRole('button', { name: /^Refund Visa/ }).click();
  const refund = page.getByRole('dialog', { name: 'Refund payment' });
  await refund.getByLabel(/^Refund amount/).fill('1');
  await refund.getByRole('button', { name: 'Refund $1.00' }).click();
  await expect(refund).toBeHidden();
  const payment = await eventually(
    async () =>
      (
        await rest<Array<Record<string, number | string>>>(
          'GET',
          `payments?stripe_payment_intent_id=eq.${pi}&select=id,status,amount_cents,tip_cents,refunded_cents`,
          owner,
        )
      ).json[0],
    (p) => p?.refunded_cents === 100,
    'refund recorded on the payment',
  );
  expect(payment).toMatchObject({
    status: 'partially_refunded',
    amount_cents: 20000,
    tip_cents: 4000,
    refunded_cents: 100,
  });

  // Stripe then sends charge.refunded; it must not count the refund twice.
  const refunded = await postStripeEvent(
    'charge.refunded',
    account,
    stripeCharge({ chargeId: ch, paymentIntentId: pi, amount: 24000, amountRefunded: 100 }),
  );
  expect(refunded.status, refunded.text).toBe(200);
  const afterWebhook = await rest<Array<Record<string, number | string>>>(
    'GET',
    `payments?stripe_payment_intent_id=eq.${pi}&select=status,refunded_cents`,
    owner,
  );
  expect(afterWebhook.json[0]).toEqual({ status: 'partially_refunded', refunded_cents: 100 });
  // Refunds reopen the invoice for the refunded amount; tips never touch balances.
  const reopened = await rest<Array<Record<string, number | string>>>(
    'GET',
    `invoices?id=eq.${invoiceAId}&select=status,amount_paid_cents,balance_cents,tip_cents`,
    owner,
  );
  expect(reopened.json[0]).toEqual({
    status: 'partially_paid',
    amount_paid_cents: 19900,
    balance_cents: 100,
    tip_cents: 4000,
  });

  // --- 6. Revenue is net of refunds; tips are reported separately
  const summary = await rpcOk<{
    revenue: { today: { net_cents: number; tips_cents: number; payments_count: number } };
  }>('dashboard_summary', { p_shop_id: shop.id }, owner);
  expect(summary.revenue.today).toEqual({ net_cents: 27900, tips_cents: 4000, payments_count: 2 });
  await page.goto('/app');
  const todayTile = page.getByRole('link', { name: /^Revenue today \$279\.00/ });
  await expect(todayTile).toBeVisible();
  await expect(todayTile).toContainText('2 payments · $40.00 tips (not in revenue)');

  const today = new Date().toISOString().slice(0, 10);
  const byMethod = await rpcOk<Array<Record<string, unknown>>>(
    'report_payments',
    { p_shop_id: shop.id, p_from: '2026-01-01', p_to: '2031-12-31' },
    owner,
  );
  const totals = byMethod.reduce<Record<string, number>>((acc, row) => {
    for (const [k, v] of Object.entries(row)) if (typeof v === 'number') acc[k] = (acc[k] ?? 0) + v;
    return acc;
  }, {});
  expect(totals.net_cents).toBe(27900);
  expect(totals.tip_cents ?? totals.tips_cents).toBe(4000);
  expect(today).toMatch(/^\d{4}-\d{2}-\d{2}$/);
  expect(apiFailures).toEqual([]);
  expect(pageErrors).toEqual([]);
});

// Regression (fixed, I-55): with the default invoice_due_days = 0 an invoice
// is due at the END of its local issue date (invoices_compute in
// 0012_money_invoices_payments.sql sets due_at to 23:59:59 shop time), so
// isInvoiceOverdue() and dashboard_summary do not flag it overdue on the day
// it is issued; it becomes overdue from the next local midnight.
test('J3b: a due-on-receipt invoice is not flagged overdue right after it is issued', async ({
  page,
}) => {
  const sfx = uniqueSuffix();
  const owner = await signUpUser({ fullName: 'Dana Due', email: `j3b-owner-${sfx}@stack.test` });
  const shop = await createShop(owner, `J3b Detail ${sfx}`);
  const cust = await rest<Array<{ id: string }>>('POST', 'customers', owner, {
    shop_id: shop.id,
    first_name: 'Val',
    last_name: 'Due',
  });
  expect(cust.status, cust.text).toBe(201);
  const job = await completedJob(owner, shop.id, cust.json[0]?.id ?? '', 'Wash', 5000, 8);
  const invoice = await rpcOk<{ id: string; status: string }>(
    'create_invoice_from_job',
    { p_job_id: job.id },
    owner,
  );
  expect(invoice.status).toBe('open');
  await loginViaUi(page, owner);
  await page.goto(`/app/invoices/${invoice.id}`);
  await expect(page.getByRole('heading', { name: /^Invoice #\d+$/, level: 1 })).toBeVisible();
  await expect(page.getByText('Overdue', { exact: true })).toHaveCount(0);
  // The dashboard's "Overdue" tile (dashboard_summary.overdue_invoices, due_at < now) agrees.
  const summary = await rpcOk<{ overdue_invoices: { count: number } }>(
    'dashboard_summary',
    { p_shop_id: shop.id },
    owner,
  );
  expect(summary.overdue_invoices.count).toBe(0);
});

// Regression (fixed, I-1 / I-56): the send dialog no longer renders the
// template in the browser. The server renders invoice_sent for the invoice
// (preview_document_message for the preview, messaging.send with invoice_id
// for the send), applying comms_omit_unavailable_values, so a shop without a
// phone gets no "Call us at ." line.
test('J3c: an emailed invoice from a shop without a phone omits the "Call us" line', async ({
  page,
}) => {
  const sfx = uniqueSuffix();
  const owner = await signUpUser({
    fullName: 'Nia Nophone',
    email: `j3c-owner-${sfx}@stack.test`,
  });
  const shop = await createShop(owner, `J3c Detail ${sfx}`);
  const email = `j3c-cust-${sfx}@stack.test`;
  const cust = await rest<Array<{ id: string }>>('POST', 'customers', owner, {
    shop_id: shop.id,
    first_name: 'Ola',
    last_name: 'Nophone',
    email,
  });
  expect(cust.status, cust.text).toBe(201);
  const job = await completedJob(owner, shop.id, cust.json[0]?.id ?? '', 'Wash', 5000, 9);
  const invoice = await rpcOk<{ id: string }>(
    'create_invoice_from_job',
    { p_job_id: job.id },
    owner,
  );
  await loginViaUi(page, owner);
  await page.goto(`/app/invoices/${invoice.id}`);
  await page.getByRole('button', { name: /^(Send invoice|Resend)$/ }).click();
  const send = page.getByRole('dialog');
  await send.getByText('Email', { exact: true }).click();
  await send.getByRole('button', { name: 'Send email' }).click();
  await expect(page.getByText(/sent by email/)).toBeVisible();
  const mail = await eventually(
    async () => (await providerLog('resend')).filter((r) => JSON.stringify(r.body).includes(email)),
    (list) => list.length > 0,
    'invoice email recorded by the Resend mock',
  );
  expect(JSON.stringify(mail[0]?.body)).not.toContain('Call us at .');
});
