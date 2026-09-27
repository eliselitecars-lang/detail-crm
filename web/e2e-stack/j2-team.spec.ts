import { expect, test } from '@playwright/test';
import { createShop, signUpUser, uniqueSuffix, type StackUser } from './support/stackApi';
import { stackEnv } from './support/stackEnv';
import {
  connectStripe,
  eventually,
  fn,
  loginViaUi,
  provisionSmsNumber,
  providerLog,
  rest,
  rpcAs,
  rpcOk,
  stripeId,
  trackApiFailures,
  trackPageErrors,
  uniquePhone,
} from './support/journey';

/**
 * J2 — team: the owner invites a technician through the real `invites`
 * function (email captured by the Resend mock), the technician signs up and
 * accepts, sees only assigned jobs, moves one through en_route →
 * in_progress → completed, and is denied settings/reports/money in the UI
 * AND by RLS when calling the API directly.
 */

test.use({ actionTimeout: 15_000, navigationTimeout: 30_000 });

interface Row {
  id: string;
  number?: number;
  status?: string;
}

test('J2: invited technician works only their assigned job and is denied owner data', async ({
  page,
  browser,
}) => {
  test.setTimeout(240_000);
  const sfx = uniqueSuffix();
  const owner = await signUpUser({ fullName: 'Tara Owner', email: `j2-owner-${sfx}@stack.test` });
  const shop = await createShop(owner, `J2 Detail ${sfx}`);
  const techEmail = `j2-tech-${sfx}@stack.test`;
  const techPassword = `Pw-${sfx}-tech!`;

  // Texts go out from the shop's provisioned number (operator step + owner setting).
  const shopNumber = uniquePhone();
  const customerPhone = uniquePhone();
  await provisionSmsNumber(shop.id, shopNumber);
  const sms = await rest('PATCH', `shops?id=eq.${shop.id}&select=id`, owner, {
    sms_from_number: shopNumber,
  });
  expect(sms.status, sms.text).toBe(200);

  // --- Owner arranges a customer and two jobs through PostgREST (RLS as owner)
  const cust = await rest<Row[]>('POST', 'customers', owner, {
    shop_id: shop.id,
    first_name: 'Jordan',
    last_name: `Client${sfx.slice(0, 4)}`,
    phone: customerPhone,
    sms_opt_in: true,
  });
  expect(cust.status, cust.text).toBe(201);
  const customerId = cust.json[0]?.id ?? '';
  const mkJob = async (day: number) => {
    const r = await rest<Row[]>('POST', 'jobs?select=id,number,status', owner, {
      shop_id: shop.id,
      customer_id: customerId,
      scheduled_start: `2030-04-${String(day).padStart(2, '0')}T15:00:00Z`,
      scheduled_end: `2030-04-${String(day).padStart(2, '0')}T17:00:00Z`,
      notes: `J2 job ${String(day)}`,
    });
    expect(r.status, r.text).toBe(201);
    return r.json[0] as Required<Row>;
  };
  const assignedJob = await mkJob(2);
  const otherJob = await mkJob(3);
  // A priced line so the assigned job can be invoiced later (positive control
  // for the direct-API money denials at the end).
  const line = await rest('POST', 'job_line_items', owner, {
    shop_id: shop.id,
    job_id: assignedJob.id,
    name: 'J2 maintenance wash',
    quantity: 1,
    unit_price_cents: 5000,
    taxable: false,
  });
  expect(line.status, line.text).toBe(201);

  // --- 1. Owner invites the technician from the Team page (invites function)
  await loginViaUi(page, owner);
  await page.goto('/app/team');
  await page.getByRole('button', { name: 'Invite member' }).click();
  const dialog = page.getByRole('dialog', { name: 'Invite a team member' });
  await dialog.getByRole('textbox', { name: /Email/ }).fill(techEmail);
  await dialog.getByText('Technician', { exact: true }).click();
  await dialog.getByRole('button', { name: 'Send invite' }).click();
  await expect(page.getByText('Invite sent')).toBeVisible();

  // --- 2. The invite email reached the Resend mock with a link to APP_BASE_URL
  const mail = await eventually(
    async () =>
      (await providerLog('resend')).filter((r) => JSON.stringify(r.body).includes(techEmail)),
    (list) => list.length > 0,
    'invite email recorded by the Resend mock',
  );
  const mailBody = JSON.stringify(mail[0]?.body);
  const link = new RegExp(
    `${stackEnv().appUrl.replace(/[.:/]/g, '\\$&')}/invite/([0-9a-f-]{36})`,
  ).exec(mailBody);
  expect(link, `invite link in ${mailBody.slice(0, 400)}`).not.toBeNull();
  const invitePath = `/invite/${link?.[1] ?? ''}`;

  // --- 3. Technician opens the link signed out, signs up, accepts
  const techCtx = await browser.newContext();
  const tech = await techCtx.newPage();
  const techApiFailures = trackApiFailures(tech);
  const techPageErrors = trackPageErrors(tech);
  const ownerPageErrors = trackPageErrors(page);
  await tech.goto(invitePath);
  await expect(tech.getByRole('heading', { name: `Join ${shop.name}` })).toBeVisible();
  await tech.getByRole('link', { name: 'Create account' }).click();
  await expect(tech).toHaveURL(/\/signup\?/);
  await tech.getByLabel('Your name').fill('Theo Tech');
  const emailBox = tech.getByLabel('Email');
  if ((await emailBox.inputValue()) === '') await emailBox.fill(techEmail);
  await expect(emailBox).toHaveValue(techEmail);
  await tech.getByLabel(/^Password/).fill(techPassword);
  await tech.getByLabel('Confirm password').fill(techPassword);
  await tech.getByRole('button', { name: 'Create account' }).click();
  await expect(tech).toHaveURL(new RegExp(`${invitePath}$`));
  await tech.getByRole('button', { name: 'Accept invite' }).click();
  await expect(tech).toHaveURL(/\/app$/);

  // Technician's own session (to prove RLS with direct API calls later).
  const techSession = await tech.evaluate(() => {
    const key = Object.keys(localStorage).find((k) => k.endsWith('-auth-token'));
    return key
      ? (JSON.parse(localStorage.getItem(key) ?? '{}') as {
          access_token?: string;
          user?: { id: string };
        })
      : {};
  });
  const techUser: StackUser = {
    id: techSession.user?.id ?? '',
    email: techEmail,
    password: techPassword,
    accessToken: techSession.access_token ?? '',
  };
  const members = await rest<Array<{ id: string; role: string }>>(
    'GET',
    `shop_members?shop_id=eq.${shop.id}&user_id=eq.${techUser.id}&select=id,role`,
    owner,
  );
  expect(members.json).toEqual([expect.objectContaining({ role: 'technician' })]);
  const techMemberId = members.json[0]?.id ?? '';

  // Owner assigns ONE job to the technician.
  const assign = await rest('POST', 'job_assignments', owner, {
    shop_id: shop.id,
    job_id: assignedJob.id,
    member_id: techMemberId,
  });
  expect(assign.status, assign.text).toBe(201);

  // --- 4. Technician sees only the assigned job
  await tech.goto('/app/jobs');
  const table = tech.getByRole('table', { name: 'Jobs' });
  await expect(
    table.getByRole('link', { name: new RegExp(`#${String(assignedJob.number)}\\b`) }).first(),
  ).toBeVisible();
  await expect(
    table.getByRole('link', { name: new RegExp(`#${String(otherJob.number)}\\b`) }),
  ).toHaveCount(0);
  const visible = await rest<Row[]>('GET', `jobs?shop_id=eq.${shop.id}&select=id`, techUser);
  expect(visible.json.map((j) => j.id)).toEqual([assignedJob.id]);

  // --- 5. Forward-only status moves on the assigned job
  await tech.goto(`/app/jobs/${assignedJob.id}`);
  await expect(
    tech.getByRole('heading', { name: `Job #${String(assignedJob.number)}`, level: 1 }),
  ).toBeVisible();
  await expect(tech.getByRole('button', { name: 'Cancel job' })).toHaveCount(0);
  await expect(tech.getByRole('button', { name: 'Add service' })).toHaveCount(0);

  // Technicians may send the templated "on my way" text for their assigned job.
  await tech.getByRole('button', { name: 'On my way' }).click();
  await expect(tech.getByText('“On my way” sent')).toBeVisible();
  const texts = await eventually(
    async () =>
      (await providerLog('twilio')).filter(
        (r) => r.method === 'POST' && typeof r.body === 'object' && r.body?.To === customerPhone,
      ),
    (list) => list.length === 1,
    'the "on my way" text reached the Twilio mock',
  );
  expect(texts[0]?.body).toMatchObject({ From: shopNumber });
  // ...but not free-form texts, and not for a job they are not assigned to.
  const freeForm = await fn(
    'messaging',
    { action: 'send', job_id: assignedJob.id, channel: 'sms', body: 'hi from tech' },
    techUser,
  );
  expect(freeForm.status, freeForm.text).toBe(403);
  const otherJobText = await fn(
    'messaging',
    { action: 'send', job_id: otherJob.id, channel: 'sms', template_key: 'on_the_way' },
    techUser,
  );
  expect([403, 404], otherJobText.text).toContain(otherJobText.status);
  for (const label of ['On the way', 'In progress', 'Completed']) {
    await tech.getByRole('button', { name: `Mark as ${label}` }).click();
    const confirm = tech
      .getByRole('dialog')
      .getByRole('button', { name: /^(Mark as|Complete|Confirm)/ });
    if (await confirm.isVisible().catch(() => false)) await confirm.click();
    await expect(tech.getByRole('button', { name: `Mark as ${label}` })).toHaveCount(0);
  }
  const done = await rest<Array<Record<string, unknown>>>(
    'GET',
    `jobs?id=eq.${assignedJob.id}&select=status,en_route_at,started_at,completed_at`,
    owner,
  );
  expect(done.json[0]).toMatchObject({ status: 'completed' });
  expect(done.json[0]?.en_route_at).toBeTruthy();
  expect(done.json[0]?.started_at).toBeTruthy();
  expect(done.json[0]?.completed_at).toBeTruthy();

  // Technicians cannot move a job backward (server-side trigger).
  const back = await rest<{ code?: string; message?: string }>(
    'PATCH',
    `jobs?id=eq.${assignedJob.id}&select=id,status`,
    techUser,
    { status: 'in_progress' },
  );
  expect(back.status, back.text).toBeGreaterThanOrEqual(400);
  expect(back.json.message, back.text).toMatch(/technicians cannot move a job from completed/);
  const still = await rest<Array<{ status: string }>>(
    'GET',
    `jobs?id=eq.${assignedJob.id}&select=status`,
    owner,
  );
  expect(still.json[0]?.status).toBe('completed');

  // --- 6. No settings / money in the UI
  const nav = tech.getByRole('navigation').first();
  await expect(nav.getByRole('link', { name: 'Settings' })).toHaveCount(0);
  await expect(nav.getByRole('link', { name: 'Invoices' })).toHaveCount(0);
  await expect(nav.getByRole('link', { name: 'Payments' })).toHaveCount(0);
  for (const path of ['/app/settings/booking', '/app/invoices', '/app/payments', '/app/team']) {
    await tech.goto(path);
    await expect(tech.getByText('You don’t have access to this page')).toBeVisible();
  }
  await tech.goto('/app/reports');
  await expect(tech.getByRole('heading', { name: 'My numbers' })).toBeVisible();
  await expect(tech.getByRole('tablist')).toHaveCount(0);

  // --- 7. ...and the server refuses the same data when asked directly
  const shopPatch = await rest<Row[]>('PATCH', `shops?id=eq.${shop.id}&select=id`, techUser, {
    name: 'Hijacked',
  });
  // A denial is an empty 2xx or a 4xx — never a server error.
  expect(shopPatch.status, shopPatch.text).toBeLessThan(500);
  expect(shopPatch.status === 200 ? shopPatch.json.length : 0, shopPatch.text).toBe(0);
  const settingsPatch = await rest<Row[]>(
    'PATCH',
    `booking_settings?shop_id=eq.${shop.id}&select=shop_id`,
    techUser,
    { enabled: true },
  );
  // A denial is an empty 2xx or a 4xx — never a server error.
  expect(settingsPatch.status, settingsPatch.text).toBeLessThan(500);
  expect(settingsPatch.status === 200 ? settingsPatch.json.length : 0, settingsPatch.text).toBe(0);
  const shopAfter = await rest<Array<{ name: string }>>(
    'GET',
    `shops?id=eq.${shop.id}&select=name`,
    owner,
  );
  expect(shopAfter.json[0]?.name).toBe(shop.name);
  const bookingAfter = await rest<Array<{ enabled: boolean }>>(
    'GET',
    `booking_settings?shop_id=eq.${shop.id}&select=enabled`,
    owner,
  );
  expect(bookingAfter.json[0]?.enabled).toBe(false);
  // Positive control: an empty result only proves a denial if the rows exist.
  // Give the shop an invoice on the technician's OWN assigned job
  // (techs_can_collect_payments is off, so it must stay hidden — SPEC §3), a
  // cash payment, a Stripe Connect account (real stripe-connect → stripe-mock)
  // and a saved card (written only by the Stripe webhook = service role, so the
  // harness inserts it the same way); the owner must read each one with the
  // very query the technician is refused.
  const invoice = await rpcOk<{ id: string; balance_cents: number }>(
    'create_invoice_from_job',
    { p_job_id: assignedJob.id },
    owner,
  );
  expect(invoice.balance_cents).toBeGreaterThan(0);
  await rpcOk(
    'record_manual_payment',
    { p_invoice_id: invoice.id, p_amount_cents: 1000, p_method: 'cash' },
    owner,
  );
  await connectStripe(owner, shop.id);
  const card = await rest('POST', 'customer_payment_methods', 'service', {
    shop_id: shop.id,
    customer_id: customerId,
    stripe_payment_method_id: stripeId('pm'),
    brand: 'visa',
    last4: '4242',
    exp_month: 12,
    exp_year: 2031,
  });
  expect(card.status, card.text).toBe(201);
  for (const table of [
    'invoices',
    'payments',
    'customer_payment_methods',
    'shop_stripe_accounts',
    'shop_invites',
  ]) {
    // select=shop_id (granted to every staff role), NOT select=*: money tables
    // have column-level grants, so `*` answers 42501 to EVERY role, owner
    // included — the technician would be "denied" by column privileges and the
    // row-level policies this check is about would never run.
    const q = `${table}?shop_id=eq.${shop.id}&select=shop_id`;
    const visible = await rest<unknown[]>('GET', q, owner);
    expect(visible.status, `owner ${table}: ${visible.text}`).toBe(200);
    expect(visible.json.length, `owner sees ${table} rows (control)`).toBeGreaterThan(0);
    const r = await rest<unknown[]>('GET', q, techUser);
    // RLS hides the rows: an empty 200 where the owner's identical query is not.
    expect(r.status, `${table}: ${r.text}`).toBe(200);
    expect(r.json, `${table}: ${r.text}`).toEqual([]);
  }
  const report = await rpcAs(
    'report_revenue',
    { p_shop_id: shop.id, p_from: '2030-01-01', p_to: '2030-12-31' },
    techUser,
  );
  expect(report.status, report.text).toBeGreaterThanOrEqual(400);
  const summary = await rpcAs(
    'report_payments',
    { p_shop_id: shop.id, p_from: '2030-01-01', p_to: '2030-12-31' },
    techUser,
  );
  expect(summary.status, summary.text).toBeGreaterThanOrEqual(400);
  const invite = await rest('POST', 'shop_invites', techUser, {
    shop_id: shop.id,
    email: `evil-${sfx}@stack.test`,
    role: 'admin',
  });
  expect(invite.status, invite.text).toBeGreaterThanOrEqual(400);
  expect(techApiFailures).toEqual([]);
  expect(techPageErrors).toEqual([]);
  expect(ownerPageErrors).toEqual([]);
  await techCtx.close();
});
