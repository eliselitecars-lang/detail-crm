import { expect, test } from '@playwright/test';
import { createShop, signUpUser, uniqueSuffix } from './support/stackApi';
import {
  eventually,
  fn,
  loginViaUi,
  postTwilioInbound,
  providerLog,
  provisionSmsNumber,
  rest,
  trackApiFailures,
  trackPageErrors,
  uniquePhone,
} from './support/journey';
import { recordRealtime } from './support/realtime';

/**
 * J5 — two-way SMS on the real stack: staff sends a text with
 * messaging.send (Twilio mock records it with the shop's from-number), a
 * signed Twilio inbound webhook appears in the open inbox thread through
 * Realtime (no reload), and an inbound STOP opts the customer out so the
 * next send is refused by the server.
 */

test.use({ actionTimeout: 15_000, navigationTimeout: 30_000 });

test('J5: staff texts a customer, the reply arrives live, STOP opts out and later sends are refused', async ({
  page,
}) => {
  test.setTimeout(240_000);
  const sfx = uniqueSuffix();
  const owner = await signUpUser({ fullName: 'Sam Sender', email: `j5-owner-${sfx}@stack.test` });
  const shop = await createShop(owner, `J5 Detail ${sfx}`);
  const shopNumber = uniquePhone();
  const customerPhone = uniquePhone();
  const last = `Texter${sfx.slice(0, 4)}`;
  const cust = await rest<Array<{ id: string }>>('POST', 'customers', owner, {
    shop_id: shop.id,
    first_name: 'Riley',
    last_name: last,
    phone: customerPhone,
    sms_opt_in: true,
  });
  expect(cust.status, cust.text).toBe(201);
  const customerId = cust.json[0]?.id ?? '';
  // Platform operator provisions the shop's Twilio number (service role +
  // Twilio mock); an unprovisioned number is refused (checked below).
  await provisionSmsNumber(shop.id, shopNumber);
  const apiFailures = trackApiFailures(page);
  const pageErrors = trackPageErrors(page);
  // Realtime frames received by the browser (postgres_changes carry the row).
  const realtime = recordRealtime(page);
  const realtimeFrames = realtime.frames;

  // --- 1. Owner saves the SMS from-number in Settings → SMS
  const stranger = await rest<{ message?: string }>(
    'PATCH',
    `shops?id=eq.${shop.id}&select=id`,
    owner,
    {
      sms_from_number: uniquePhone(),
    },
  );
  expect(stranger.status, stranger.text).toBe(409);
  expect(stranger.json.message).toMatch(/not provisioned for this shop/);
  await loginViaUi(page, owner);
  await page.goto('/app/settings/sms');
  await page.getByLabel('SMS from number').fill(shopNumber);
  await page.getByRole('button', { name: 'Save changes' }).click();
  await expect(page.getByText('SMS number saved')).toBeVisible();

  // --- 2. Staff sends a text from the inbox (messaging.send → Twilio mock)
  const inboxJoins = realtime.mark();
  await page.goto(`/app/messages?customer=${customerId}`);
  const thread = page.getByRole('region', { name: `Conversation with Riley ${last}` });
  await expect(thread).toBeVisible();
  const outbound = `Your car is ready ${sfx}`;
  await thread.getByRole('textbox', { name: 'Message' }).fill(outbound);
  await thread.getByRole('button', { name: 'Send text' }).click();
  await expect(page.getByText('Message sent')).toBeVisible();
  const sent = await eventually(
    async () =>
      (await providerLog('twilio')).filter(
        (r) => r.method === 'POST' && typeof r.body === 'object' && r.body?.Body === outbound,
      ),
    (list) => list.length === 1,
    'the text reached the Twilio mock exactly once',
  );
  expect(sent[0]?.body).toMatchObject({ To: customerPhone, From: shopNumber, Body: outbound });
  await expect(thread.getByText(outbound)).toBeVisible();
  const row = await rest<Array<Record<string, unknown>>>(
    'GET',
    `messages?customer_id=eq.${customerId}&direction=eq.outbound&select=status,from_address,to_address,provider_message_id`,
    owner,
  );
  expect(row.json[0]).toMatchObject({
    status: 'sent',
    from_address: shopNumber,
    to_address: customerPhone,
  });
  expect(String(row.json[0]?.provider_message_id)).toMatch(/^SM/);

  // --- 3. The customer replies: signed Twilio webhook → inbox thread updates live
  // Wait until Realtime confirms the INBOX page's `messages` subscription is
  // live (otherwise an event racing the page's subscribe would be missed by
  // design). Any "Subscribed" frame is not enough: the dashboard and
  // NotificationsBell subscribe too, and StrictMode re-joins channels.
  await realtime.waitForSubscription('messages', inboxJoins);
  const reply = `Thanks, see you soon ${sfx}`;
  const inbound = await postTwilioInbound(shop.id, {
    From: customerPhone,
    To: shopNumber,
    Body: reply,
  });
  expect(inbound.status, inbound.text).toBe(200);
  await expect(
    thread.getByRole('article', { name: /Received text/ }).filter({ hasText: reply }),
  ).toBeVisible();
  // ...delivered by a Realtime postgres_changes event on `messages` (RLS-filtered).
  expect(
    realtimeFrames.some((f) => f.includes('postgres_changes') && f.includes('"messages"')),
  ).toBe(true);

  // A forged (unsigned) inbound is rejected and never lands in the inbox.
  const forged = await fn(
    'messaging',
    { Body: 'forged' },
    'anon',
    `?action=twilio_inbound&shop_id=${shop.id}`,
  );
  expect(forged.status).toBeGreaterThanOrEqual(400);

  // --- 4. STOP opts the customer out; the next send is refused server-side
  const stop = await postTwilioInbound(shop.id, {
    From: customerPhone,
    To: shopNumber,
    Body: 'STOP',
  });
  expect(stop.status, stop.text).toBe(200);
  await eventually(
    async () =>
      (
        await rest<Array<{ sms_opt_in: boolean }>>(
          'GET',
          `customers?id=eq.${customerId}&select=sms_opt_in`,
          owner,
        )
      ).json[0]?.sms_opt_in,
    (optIn) => optIn === false,
    'customer opted out after STOP',
  );
  const refused = await fn<{ code?: string; details?: { reason?: string } }>(
    'messaging',
    {
      action: 'send',
      shop_id: shop.id,
      customer_id: customerId,
      channel: 'sms',
      body: `After stop ${sfx}`,
    },
    owner,
  );
  expect(refused.status, refused.text).toBe(422);
  expect(refused.json.details?.reason).toBe('opted_out');
  const twilioAfter = await providerLog('twilio');
  expect(
    twilioAfter.some((r) => typeof r.body === 'object' && r.body?.Body === `After stop ${sfx}`),
  ).toBe(false);

  // The inbox UI reflects it too (no "Send text" for an opted-out customer).
  await page.reload();
  await expect(thread).toBeVisible();
  await expect(thread.getByText(/opted out|unsubscribed|replied STOP/i).first()).toBeVisible();
  expect(apiFailures).toEqual([]);
  expect(pageErrors).toEqual([]);
});
