import { expect, test } from '@playwright/test';
import { createShop, signUpUser, uniqueSuffix } from './support/stackApi';
import { stackEnv } from './support/stackEnv';
import {
  cronHeaders,
  eventually,
  fn,
  http,
  loginViaUi,
  providerLog,
  rest,
  rpcOk,
  trackApiFailures,
  trackPageErrors,
} from './support/journey';
import { userHeaders } from './support/stackApi';

/**
 * J7 — field ops on the real stack: a job photo goes through the real Storage
 * API (job-photos bucket + RLS) and is displayed from a signed URL; a form is
 * signed on /f/<token> with a drawn signature uploaded ANONYMOUSLY to the
 * signatures bucket (storage policy keyed by the form token) and recorded by
 * public_sign_form; messaging.run_automations (cron secret) queues the
 * appointment reminder and process_queue delivers it to the Resend mock.
 */

test.use({ actionTimeout: 15_000, navigationTimeout: 30_000 });

// 1×1 PNG (a real image the browser can decode).
const PNG = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
  'base64',
);

test('J7: photo upload + view, anonymous form signature, reminder automation', async ({
  page,
  browser,
}) => {
  test.setTimeout(240_000);
  const sfx = uniqueSuffix();
  const owner = await signUpUser({
    fullName: 'Frankie Field',
    email: `j7-owner-${sfx}@stack.test`,
  });
  const shop = await createShop(owner, `J7 Detail ${sfx}`);
  const custEmail = `j7-cust-${sfx}@stack.test`;
  const cust = await rest<Array<{ id: string }>>('POST', 'customers', owner, {
    shop_id: shop.id,
    first_name: 'Robin',
    last_name: `Field${sfx.slice(0, 4)}`,
    email: custEmail,
  });
  expect(cust.status, cust.text).toBe(201);
  const customerId = cust.json[0]?.id ?? '';
  // Starts in 3 hours: inside the default appointment-reminder window.
  const start = new Date(Date.now() + 3 * 3600 * 1000);
  start.setUTCSeconds(0, 0);
  const job = await rest<Array<{ id: string; number: number }>>(
    'POST',
    'jobs?select=id,number',
    owner,
    {
      shop_id: shop.id,
      customer_id: customerId,
      scheduled_start: start.toISOString(),
      scheduled_end: new Date(start.getTime() + 2 * 3600 * 1000).toISOString(),
    },
  );
  expect(job.status, job.text).toBe(201);
  const jobId = job.json[0]?.id ?? '';
  const template = await rest<Array<{ id: string }>>('POST', 'form_templates?select=id', owner, {
    shop_id: shop.id,
    name: `Vehicle waiver ${sfx}`,
    body: '## Waiver\n\nI agree to **the terms**.',
    requires_signature: true,
    attach_to: 'manual',
    active: true,
  });
  expect(template.status, template.text).toBe(201);
  const apiFailures = trackApiFailures(page);
  const pageErrors = trackPageErrors(page);

  // --- 1. Upload a before photo on the job and see it rendered from Storage
  await loginViaUi(page, owner);
  await page.goto(`/app/jobs/${jobId}`);
  await expect(
    page.getByRole('heading', { name: `Job #${String(job.json[0]?.number)}`, level: 1 }),
  ).toBeVisible();
  await page.getByLabel('Photo type').selectOption('before');
  const uploaded = page.waitForResponse(
    (r) => r.url().includes('/storage/v1/object/job-photos/') && r.request().method() === 'POST',
  );
  await page
    .locator('input[type="file"]')
    .first()
    .setInputFiles({ name: 'front.png', mimeType: 'image/png', buffer: PNG });
  expect((await uploaded).status()).toBe(200);
  await expect(page.getByText('Photo uploaded')).toBeVisible();
  const photos = page.getByRole('region', { name: 'Before photos' });
  const img = photos.getByRole('img').first();
  await expect(img).toBeVisible();
  await expect.poll(() => img.evaluate((el) => (el as HTMLImageElement).naturalWidth)).toBe(1);
  const photoRow = await rest<Array<{ storage_path: string; kind: string }>>(
    'GET',
    `job_photos?job_id=eq.${jobId}&select=storage_path,kind`,
    owner,
  );
  expect(photoRow.json).toEqual([
    {
      kind: 'before',
      storage_path: expect.stringMatching(new RegExp(`^${shop.id}/${jobId}/`)) as unknown as string,
    },
  ]);
  // Storage RLS: anon cannot read the private object.
  const anonRead = await http(
    'GET',
    `${stackEnv().apiUrl}/storage/v1/object/job-photos/${photoRow.json[0]?.storage_path ?? ''}`,
    {
      headers: { apikey: stackEnv().anonKey, authorization: `Bearer ${stackEnv().anonKey}` },
    },
  );
  expect(anonRead.status).toBeGreaterThanOrEqual(400);

  // --- 2. Attach the waiver and sign it on /f/<token> anonymously
  const forms = page.getByRole('region', { name: 'Forms' });
  await forms.getByLabel('Form template').selectOption({ label: `Vehicle waiver ${sfx}` });
  await forms.getByRole('button', { name: 'Add' }).click();
  await expect(page.getByText('Form added')).toBeVisible();
  const submissions = await rest<Array<{ id: string }>>(
    'GET',
    `form_submissions?job_id=eq.${jobId}&select=id`,
    owner,
  );
  expect(submissions.json).toHaveLength(1);
  const submissionId = submissions.json[0]?.id ?? '';
  const formToken = await rpcOk<string>(
    'form_link_token',
    { p_submission_id: submissionId },
    owner,
  );

  const anon = await browser.newContext();
  const pub = await anon.newPage();
  // The anonymous customer page must run clean too (no API >= 400, no page errors).
  const publicApiFailures = trackApiFailures(pub);
  const publicPageErrors = trackPageErrors(pub);
  const sigUploads: number[] = [];
  pub.on('response', (r) => {
    if (r.url().includes('/storage/v1/object/signatures/') && r.request().method() === 'POST')
      sigUploads.push(r.status());
  });
  await pub.goto(`/f/${formToken}`);
  await expect(pub.getByRole('heading', { name: `Vehicle waiver ${sfx}`, level: 1 })).toBeVisible();
  await expect(pub.locator('strong', { hasText: 'the terms' })).toBeVisible();
  await pub.getByLabel(/^Your full name/).fill('Robin Field');
  const pad = pub.getByRole('img', { name: /Your signature/ });
  const box = await pad.boundingBox();
  if (!box) throw new Error('signature pad not visible');
  await pub.mouse.move(box.x + 30, box.y + box.height / 2);
  await pub.mouse.down();
  await pub.mouse.move(box.x + 90, box.y + box.height / 3, { steps: 5 });
  await pub.mouse.move(box.x + 160, box.y + (box.height * 2) / 3, { steps: 5 });
  await pub.mouse.up();
  await expect(pub.getByRole('img', { name: /Your signature \(signed\)/ })).toBeVisible();
  await pub.getByRole('button', { name: 'Sign form' }).click();
  await expect(pub.getByText('Signed — thank you!')).toBeVisible();
  await expect(pub.getByText(/Signed by Robin Field/)).toBeVisible();
  expect(sigUploads).toEqual([200]);
  expect(publicApiFailures, 'anonymous page API failures').toEqual([]);
  expect(publicPageErrors, 'anonymous page errors').toEqual([]);
  await anon.close();

  const signed = await rest<
    Array<{ signer_name: string; signature_path: string; signed_at: string }>
  >(
    'GET',
    `form_submissions?id=eq.${submissionId}&select=signer_name,signature_path,signed_at`,
    owner,
  );
  expect(signed.json[0]?.signer_name).toBe('Robin Field');
  expect(signed.json[0]?.signed_at).toBeTruthy();
  const sigPath = signed.json[0]?.signature_path ?? '';
  expect(sigPath).toMatch(new RegExp(`^${shop.id}/forms/${formToken}/[^/]+\\.png$`));
  // Staff can read the stored signature through the Storage API (RLS: shop member).
  const sig = await http('GET', `${stackEnv().apiUrl}/storage/v1/object/signatures/${sigPath}`, {
    headers: userHeaders(owner),
  });
  expect(sig.status).toBe(200);
  expect(sig.headers.get('content-type')).toContain('image/png');
  // The job page shows the form as signed.
  await page.reload();
  await expect(
    page.getByRole('region', { name: 'Forms' }).getByText('Signed', { exact: true }),
  ).toBeVisible();

  // --- 3. Automations: run_automations (cron secret) queues the reminder, process_queue sends it
  const noSecret = await fn('messaging', { action: 'run_automations' }, 'anon');
  expect(noSecret.status).toBe(401);
  const run = await fn<{ queued: number }>(
    'messaging',
    { action: 'run_automations' },
    cronHeaders(),
  );
  expect(run.status, run.text).toBe(200);
  const reminder = await eventually(
    async () =>
      (
        await rest<Array<Record<string, unknown>>>(
          'GET',
          `messages?job_id=eq.${jobId}&template_key=eq.appointment_reminder&select=id,channel,status,to_address`,
          owner,
        )
      ).json,
    (rows) => rows.length > 0,
    'appointment reminder queued for the job',
  );
  expect(reminder[0]).toMatchObject({ channel: 'email', to_address: custEmail });
  const drained = await fn<{ sent: number }>(
    'messaging',
    { action: 'process_queue' },
    cronHeaders(),
  );
  expect(drained.status, drained.text).toBe(200);
  await eventually(
    async () =>
      (await providerLog('resend')).filter((r) => JSON.stringify(r.body).includes(custEmail)),
    (list) => list.length > 0,
    'reminder email delivered to the Resend mock',
  );
  const sentRow = await eventually(
    async () =>
      (
        await rest<Array<{ status: string }>>(
          'GET',
          `messages?id=eq.${String(reminder[0]?.id)}&select=status`,
          owner,
        )
      ).json[0]?.status,
    (status) => status === 'sent' || status === 'delivered',
    'reminder marked sent',
  );
  expect(sentRow).toMatch(/sent|delivered/);
  const marked = await rest<Array<{ reminder_sent_at: string | null }>>(
    'GET',
    `jobs?id=eq.${jobId}&select=reminder_sent_at`,
    owner,
  );
  expect(marked.json[0]?.reminder_sent_at).toBeTruthy();
  // Exactly once: a second run queues nothing new for this job.
  const again = await fn<{ queued: number }>(
    'messaging',
    { action: 'run_automations' },
    cronHeaders(),
  );
  expect(again.status).toBe(200);
  const count = await rest<unknown[]>(
    'GET',
    `messages?job_id=eq.${jobId}&template_key=eq.appointment_reminder&select=id`,
    owner,
  );
  expect(count.json).toHaveLength(reminder.length);
  expect(apiFailures).toEqual([]);
  expect(pageErrors).toEqual([]);
});
