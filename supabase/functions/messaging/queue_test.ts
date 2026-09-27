import { assert, assertEquals, assertMatch } from "@std/assert";
import type { ErrorBody } from "../_shared/http.ts";
import { jsonResponse } from "../_shared/testing/fake_fetch.ts";
import { jsonRequest, responseJson } from "../_shared/testing/requests.ts";
import {
  classifyFailure,
  CONSENT_UNVERIFIED,
  CONSENT_WITHDRAWN,
  type QueueRunSummary,
} from "./deliver.ts";
import { NOT_PROVISIONED } from "./sender.ts";
import {
  CRON_SECRET,
  CUSTOMER,
  CUSTOMER_PHONE,
  inboundWebhookUrl,
  message,
  OPTED_OUT_CUSTOMER,
  OTHER_SHOP,
  OTHER_SHOP_CUSTOMER,
  queuedMessage,
  RESEND_URL,
  setup,
  SHOP,
  SHOP_NUMBER,
  TWILIO_MESSAGES_URL,
  TWILIO_NUMBERS_URL,
} from "./test_fixtures.ts";
import { ResendError } from "../_shared/resend.ts";
import { TwilioError } from "../_shared/twilio.ts";
import { EnvError } from "../_shared/env.ts";

const cron = (body: Record<string, unknown> = {}, secret: string | null = CRON_SECRET) =>
  jsonRequest("messaging", { action: "process_queue", ...body }, {
    headers: secret === null ? {} : { "x-cron-secret": secret },
  });

Deno.test("process_queue: rejects a missing or wrong cron secret before touching the queue", async () => {
  const { db, handler } = setup({ messages: [queuedMessage()] });
  for (const secret of [null, "", "wrong-secret-0123456789abcdef", `${CRON_SECRET}x`]) {
    const res = await handler(cron({}, secret));
    assertEquals(res.status, 401);
    assertEquals((await responseJson<ErrorBody>(res)).code, "unauthorized");
  }
  assertEquals(db.requests.length, 0);
  assertEquals(db.http.callsTo("POST", TWILIO_MESSAGES_URL).length, 0);
});

Deno.test("process_queue: an unset CRON_SECRET is a server misconfiguration, never open", async () => {
  const { handler } = setup({ env: { CRON_SECRET: undefined }, messages: [queuedMessage()] });
  const res = await handler(cron({}, "anything-at-all-0123456789"));
  assertEquals(res.status, 500);
  assertEquals((await responseJson<ErrorBody>(res)).code, "server_misconfigured");
});

Deno.test("process_queue: sends SMS via Twilio from the shop number with a status callback", async () => {
  const msg = queuedMessage({ body: "Your car is ready" });
  const { db, handler } = setup({ messages: [msg] });
  const res = await handler(cron());
  assertEquals(res.status, 200);
  const summary = await responseJson<QueueRunSummary>(res);
  assertEquals(summary, {
    batches: 1,
    claimed: 1,
    sent: 1,
    failed: 0,
    retried: 0,
    cancelled: 0,
    unrecorded: 0,
    more: false,
  });
  const call = db.http.callsTo("POST", TWILIO_MESSAGES_URL)[0];
  assert(call);
  assertEquals(
    call.url.pathname,
    "/2010-04-01/Accounts/AC00000000000000000000000000000000/Messages.json",
  );
  assertEquals(call.form.get("To"), CUSTOMER_PHONE);
  assertEquals(call.form.get("From"), SHOP_NUMBER);
  assertEquals(call.form.get("Body"), "Your car is ready");
  assertEquals(
    call.form.get("StatusCallback"),
    // Connection overrides: Twilio retries the callback on a 5xx.
    "https://fake-project.supabase.co/functions/v1/messaging?action=twilio_status#rc=3&rp=all",
  );
  const row = message(db, String(msg.id));
  assertEquals([row.status, row.attempts], ["sent", 1]);
  assertMatch(String(row.provider_message_id), /^SM/);
  // Sender pipeline RPCs run as service_role only.
  assert(db.requests.filter((r) => r.kind === "rpc").every((r) => r.role === "service_role"));
});

Deno.test("process_queue: emails via Resend as the shop, reply-to shop, message-id idempotency", async () => {
  const msg = queuedMessage({
    channel: "email",
    to_address: "dana@example.com",
    subject: "Your invoice",
    body: "Pay here: https://app.example.com/i/abc\n\nThanks <3",
  });
  const { db, handler } = setup({ messages: [msg] });
  const res = await handler(cron());
  assertEquals((await responseJson<QueueRunSummary>(res)).sent, 1);
  const call = db.http.callsTo("POST", RESEND_URL)[0];
  assert(call);
  const body = call.json as Record<string, unknown>;
  assertEquals(body.from, "Shine Auto Spa <notifications@example.com>");
  assertEquals(body.to, ["dana@example.com"]);
  assertEquals(body.reply_to, ["hello@shine.example"]);
  assertEquals(body.subject, "Your invoice");
  assertEquals(body.text, "Pay here: https://app.example.com/i/abc\n\nThanks <3");
  assertEquals(
    body.html,
    '<p>Pay here: <a href="https://app.example.com/i/abc">https://app.example.com/i/abc</a></p>\n<p>Thanks &lt;3</p>',
  );
  assertEquals(body.headers, undefined);
  assertEquals(call.headers.get("idempotency-key"), `message-${msg.id}`);
  assertEquals(call.headers.get("authorization"), "Bearer re_FakeResendKey000000");
  const row = message(db, String(msg.id));
  assertEquals([row.status, row.provider_message_id], ["sent", "email-1"]);
  assertEquals(row.from_address, "Shine Auto Spa <notifications@example.com>");
});

Deno.test("process_queue: campaign emails carry RFC 8058 one-click List-Unsubscribe", async () => {
  const msg = queuedMessage({
    channel: "email",
    to_address: "dana@example.com",
    subject: "Fall special",
    campaign_id: "60000000-0000-4000-8000-000000000001",
  });
  const { db, handler } = setup({ messages: [msg] });
  await (await handler(cron())).body?.cancel();
  const body = db.http.callsTo("POST", RESEND_URL)[0]?.json as Record<string, unknown>;
  assertEquals(body.headers, {
    "List-Unsubscribe":
      `<https://fake-project.supabase.co/functions/v1/messaging?action=unsubscribe&token=${msg.id}>`,
    "List-Unsubscribe-Post": "List-Unsubscribe=One-Click",
  });
});

Deno.test("process_queue: partial failures are isolated per message", async () => {
  const ok = queuedMessage({ send_after: "2026-09-27T14:00:00.000Z" });
  const unsubscribed = queuedMessage({
    to_address: "+12055550199",
    send_after: "2026-09-27T14:01:00.000Z",
  });
  const throttled = queuedMessage({
    to_address: "+12055550188",
    send_after: "2026-09-27T14:02:00.000Z",
  });
  const emailDown = queuedMessage({
    channel: "email",
    to_address: "dana@example.com",
    subject: "Hi",
    send_after: "2026-09-27T14:03:00.000Z",
  });
  const emailRejected = queuedMessage({
    channel: "email",
    to_address: "bad@example.com",
    subject: "Hi",
    send_after: "2026-09-27T14:04:00.000Z",
  });
  const optedOut = queuedMessage({
    customer_id: OPTED_OUT_CUSTOMER,
    to_address: "+12055550122",
    send_after: "2026-09-27T14:05:00.000Z",
  });
  const noNumber = queuedMessage({
    shop_id: OTHER_SHOP,
    customer_id: null,
    send_after: "2026-09-27T14:06:00.000Z",
  });
  const { db, handler } = setup({
    messages: [ok, unsubscribed, throttled, emailDown, emailRejected, optedOut, noNumber],
  });
  db.http.on("POST", TWILIO_MESSAGES_URL, (_req, { call }) => {
    const to = call.form.get("To");
    if (to === "+12055550199") {
      return jsonResponse(
        { code: 21610, message: "Attempt to send to unsubscribed recipient" },
        400,
      );
    }
    if (to === "+12055550188") {
      return jsonResponse({ code: 20429, message: "Too Many Requests" }, 429);
    }
    return jsonResponse({ sid: "SM11111111111111111111111111111111", status: "queued" }, 201);
  });
  db.http.on("POST", RESEND_URL, (_req, { call }) => {
    const to = (call.json as { to: string[] }).to[0];
    if (to === "bad@example.com") {
      return jsonResponse({ name: "validation_error", message: "Invalid `to` field" }, 422);
    }
    return jsonResponse({ name: "internal_server_error", message: "boom" }, 500);
  });

  const res = await handler(cron());
  assertEquals(res.status, 200);
  const summary = await responseJson<QueueRunSummary>(res);
  assertEquals(
    [summary.claimed, summary.sent, summary.failed, summary.retried, summary.unrecorded],
    [5, 1, 2, 2, 0],
  );
  assertEquals(message(db, String(ok.id)).status, "sent");
  const unsub = message(db, String(unsubscribed.id));
  assertEquals(unsub.status, "failed");
  assertEquals(unsub.error, "Twilio 21610: Attempt to send to unsubscribed recipient");
  const retry = message(db, String(throttled.id));
  assertEquals([retry.status, retry.error], ["queued", "Twilio 20429: Too Many Requests"]);
  assertEquals(retry.send_after, "2026-09-27T15:02:00.000Z"); // 2^1 minutes backoff
  assertEquals(message(db, String(emailDown.id)).status, "queued");
  assertEquals(message(db, String(emailRejected.id)).status, "failed");
  assertEquals(
    message(db, String(emailRejected.id)).error,
    "Resend validation_error: Invalid `to` field",
  );
  assertEquals(message(db, String(optedOut.id)).status, "cancelled");
  assertEquals(message(db, String(noNumber.id)).status, "failed");
  // Only claimed, sendable messages reached a provider.
  assertEquals(db.http.callsTo("POST", TWILIO_MESSAGES_URL).length, 3);
  assertEquals(db.http.callsTo("POST", RESEND_URL).length, 2);
});

Deno.test("process_queue: Twilio unreachable fails the SMS instead of risking a double send", async () => {
  const msg = queuedMessage();
  const { db, handler } = setup({ messages: [msg] });
  db.http.on("POST", TWILIO_MESSAGES_URL, () => {
    throw new TypeError("connection reset");
  });
  const summary = await responseJson<QueueRunSummary>(await handler(cron()));
  assertEquals([summary.failed, summary.retried], [1, 0]);
  const row = message(db, String(msg.id));
  assertEquals(row.status, "failed");
  assertMatch(String(row.error), /may not have been sent/);
});

Deno.test("process_queue: a failed result write is logged and does not abort the batch", async () => {
  const first = queuedMessage({ send_after: "2026-09-27T14:00:00.000Z" });
  const second = queuedMessage({ send_after: "2026-09-27T14:01:00.000Z" });
  const { db, handler, logs } = setup({ messages: [first, second] });
  const original = db.table("messages");
  let failures = 0;
  db.onRpc("mark_message_result", (args) => {
    if (args.p_id === first.id) {
      failures += 1;
      throw new Error("db down");
    }
    const rows = db.table("messages");
    const row = rows.find((m) => m.id === args.p_id);
    if (row) Object.assign(row, { status: args.p_status, provider_message_id: args.p_provider_id });
    db.seed("messages", rows);
    return row;
  });
  const summary = await responseJson<QueueRunSummary>(await handler(cron()));
  assertEquals([summary.claimed, summary.sent, summary.unrecorded], [2, 1, 1]);
  assertEquals(failures, 2); // retried once
  assertEquals(message(db, String(first.id)).status, "sending"); // left for the stuck-send sweep
  assertEquals(message(db, String(second.id)).status, "sent");
  assertEquals(logs.events("mark_message_result_failed").length, 2);
  assertEquals(original.length, 2);
});

Deno.test("process_queue: bounded by limit and batch size, reports more work", async () => {
  const messages = Array.from(
    { length: 7 },
    (_, i) => queuedMessage({ send_after: `2026-09-27T14:0${i}:00.000Z` }),
  );
  const { db, handler } = setup({ messages });
  const summary = await responseJson<QueueRunSummary>(await handler(cron({ limit: 5 })));
  assertEquals([summary.claimed, summary.sent, summary.more], [5, 5, true]);
  const claims = db.requests.filter((r) => r.target === "claim_queued_messages").length;
  assertEquals(claims, 1);
  assertEquals(db.table("messages").filter((m) => m.status === "queued").length, 2);

  const rest = await responseJson<QueueRunSummary>(await handler(cron({ limit: 5 })));
  assertEquals([rest.claimed, rest.more], [2, false]);
});

Deno.test("process_queue: an empty queue does one claim and sends nothing", async () => {
  const { db, handler } = setup();
  const summary = await responseJson<QueueRunSummary>(await handler(cron()));
  assertEquals(summary.claimed, 0);
  assertEquals(db.http.callsTo("POST", TWILIO_MESSAGES_URL).length, 0);
});

Deno.test("process_queue: rejects unexpected params and oversize limits", async () => {
  const { handler } = setup();
  for (const body of [{ limit: 0 }, { limit: 5000 }, { shop_id: "x" }]) {
    const res = await handler(cron(body));
    assertEquals((await responseJson<ErrorBody>(res)).code, "validation_failed");
  }
});

Deno.test("run_automations: secret-guarded call to enqueue_due_automations", async () => {
  const { db, handler } = setup();
  const denied = await handler(jsonRequest("messaging", { action: "run_automations" }));
  assertEquals(denied.status, 401);
  await denied.body?.cancel();
  const res = await handler(
    jsonRequest("messaging", { action: "run_automations" }, {
      headers: { "x-cron-secret": CRON_SECRET },
    }),
  );
  assertEquals(await res.json(), { queued: 3 });
  const call = db.requests.find((r) => r.target === "enqueue_due_automations");
  assertEquals(call?.role, "service_role");
});

Deno.test("classifyFailure: retry vs permanent policy", () => {
  const tw = (status: number | null, code: string | null = null) =>
    classifyFailure(new TwilioError("x", { httpStatus: status, providerCode: code }), "sms").status;
  assertEquals(tw(400, "21211"), "failed");
  assertEquals(tw(400, "21614"), "failed");
  assertEquals(tw(401, "20003"), "failed");
  assertEquals(tw(429), "queued");
  assertEquals(tw(503), "queued");
  assertEquals(tw(null), "failed");
  assertEquals(tw(200), "failed"); // accepted but unreadable: never resend
  const rs = (status: number | null) =>
    classifyFailure(new ResendError("x", { httpStatus: status }), "email").status;
  assertEquals([rs(null), rs(429), rs(502), rs(422), rs(403)], [
    "queued",
    "queued",
    "queued",
    "failed",
    "failed",
  ]);
  assertEquals(classifyFailure(new EnvError("TWILIO_AUTH_TOKEN", "missing"), "sms"), {
    status: "queued",
    error: "the SMS provider is not configured",
  });
  assertEquals(classifyFailure(new TypeError("sendSms: bad"), "sms").status, "failed");
});

Deno.test("process_queue: missing Twilio secrets schedule a retry, not a crash", async () => {
  const msg = queuedMessage();
  const { db, handler } = setup({ env: { TWILIO_AUTH_TOKEN: undefined }, messages: [msg] });
  const summary = await responseJson<QueueRunSummary>(await handler(cron()));
  assertEquals(summary.retried, 1);
  assertEquals(message(db, String(msg.id)).error, "the SMS provider is not configured");
});

// ---------------------------------------------------------------------------
// Sender provisioning (shops.sms_from_number is tenant-editable)
// ---------------------------------------------------------------------------

Deno.test("process_queue: never sends from a number the platform did not provision for the shop", async () => {
  // OTHER_SHOP typed SHOP's platform number into its settings.
  const hijack = queuedMessage({
    shop_id: OTHER_SHOP,
    customer_id: OTHER_SHOP_CUSTOMER,
    to_address: "+12055550144",
  });
  const { db, handler } = setup({ messages: [hijack] });
  db.seed(
    "shops",
    db.table("shops").map((s) => ({
      ...s,
      sms_from_number: s.id === OTHER_SHOP ? SHOP_NUMBER : null,
    })),
  );
  const summary = await responseJson<QueueRunSummary>(await handler(cron()));
  assertEquals([summary.sent, summary.failed], [0, 1]);
  const row = message(db, String(hijack.id));
  assertEquals(row.status, "failed");
  assertEquals(row.error, NOT_PROVISIONED);
  assertEquals(db.http.callsTo("POST", TWILIO_MESSAGES_URL).length, 0);
  // The lookup ran against the platform account for exactly that number.
  const lookup = db.http.callsTo("GET", TWILIO_NUMBERS_URL)[0];
  assertEquals(lookup?.url.searchParams.get("PhoneNumber"), SHOP_NUMBER);
});

Deno.test("process_queue: a number off the account or with an unbound webhook is refused", async () => {
  const cases: Array<Record<string, unknown>[]> = [
    [], // not on the platform account
    [{ phone_number: SHOP_NUMBER, sms_url: null }],
    [{
      phone_number: SHOP_NUMBER,
      sms_url: "https://fake-project.supabase.co/functions/v1/messaging?action=twilio_inbound",
    }],
    [{ phone_number: SHOP_NUMBER, sms_url: inboundWebhookUrl(OTHER_SHOP) }],
    [{
      phone_number: SHOP_NUMBER,
      sms_url:
        `https://evil.example.com/functions/v1/messaging?action=twilio_inbound&shop_id=${SHOP}`,
    }],
  ];
  for (const twilioNumbers of cases) {
    const msg = queuedMessage();
    const { db, handler } = setup({ messages: [msg], twilioNumbers });
    await (await handler(cron())).body?.cancel();
    assertEquals(message(db, String(msg.id)).status, "failed", JSON.stringify(twilioNumbers));
    assertEquals(db.http.callsTo("POST", TWILIO_MESSAGES_URL).length, 0);
  }
});

Deno.test("process_queue: sender lookup is memoized per run; a lookup outage retries", async () => {
  const first = queuedMessage({ send_after: "2026-09-27T14:00:00.000Z" });
  const second = queuedMessage({ send_after: "2026-09-27T14:01:00.000Z" });
  const ok = setup({ messages: [first, second] });
  const summary = await responseJson<QueueRunSummary>(await ok.handler(cron()));
  assertEquals(summary.sent, 2);
  assertEquals(ok.db.http.callsTo("GET", TWILIO_NUMBERS_URL).length, 1);

  const msg = queuedMessage();
  const down = setup({ messages: [msg] });
  down.db.http.on("GET", TWILIO_NUMBERS_URL, () => jsonResponse({ message: "busy" }, 503));
  const retried = await responseJson<QueueRunSummary>(await down.handler(cron()));
  assertEquals(retried.retried, 1);
  assertEquals(message(down.db, String(msg.id)).status, "queued");
  assertEquals(down.db.http.callsTo("POST", TWILIO_MESSAGES_URL).length, 0);
});

// ---------------------------------------------------------------------------
// Twilio 21610 -> opt-out; campaign consent at send time
// ---------------------------------------------------------------------------

Deno.test("process_queue: Twilio 21610 records the SMS opt-out and cancels queued texts", async () => {
  const rejected = queuedMessage({ send_after: "2026-09-27T14:00:00.000Z" });
  const later = queuedMessage({ body: "Reminder", send_after: "2026-09-28T09:00:00.000Z" });
  const email = queuedMessage({
    channel: "email",
    to_address: "dana@example.com",
    subject: "Receipt",
    send_after: "2026-09-28T09:00:00.000Z",
  });
  const { db, handler } = setup({ messages: [rejected, later, email] });
  db.http.on(
    "POST",
    TWILIO_MESSAGES_URL,
    () => jsonResponse({ code: 21610, message: "Attempt to send to unsubscribed recipient" }, 400),
  );
  const summary = await responseJson<QueueRunSummary>(await handler(cron()));
  assertEquals(summary.failed, 1);
  const customer = db.table("customers").find((c) => c.id === CUSTOMER);
  assertEquals([customer?.sms_opted_out_at, customer?.sms_opt_in], [
    "2026-09-27T15:00:00.000Z",
    false,
  ]);
  assertEquals(customer?.email_opted_out_at, null);
  assertEquals(message(db, String(rejected.id)).status, "failed");
  assertEquals(message(db, String(later.id)).status, "cancelled");
  assertEquals(message(db, String(email.id)).status, "queued"); // email unaffected
  // Only 21610 is an opt-out; other permanent errors just fail the message.
  const twilio = (code: string) =>
    classifyFailure(new TwilioError("x", { httpStatus: 400, providerCode: code }), "sms");
  assertEquals(twilio("21610"), {
    status: "failed",
    error: "Twilio 21610: x",
    recipientOptedOut: true,
  });
  assertEquals(twilio("21211"), { status: "failed", error: "Twilio 21211: x" });
});

Deno.test("process_queue: campaign messages are cancelled when marketing consent was withdrawn", async () => {
  const campaign = "60000000-0000-4000-8000-000000000001";
  const blast = queuedMessage({ campaign_id: campaign, body: "Fall special!" });
  const blastEmail = queuedMessage({
    campaign_id: campaign,
    channel: "email",
    to_address: "dana@example.com",
    subject: "Fall special",
  });
  const transactional = queuedMessage({ body: "Your car is ready" });
  const { db, handler } = setup({ messages: [blast, blastEmail, transactional] });
  // Staff unticked SMS marketing after launch; email marketing still allowed.
  db.seed(
    "customers",
    db.table("customers").map((c) => c.id === CUSTOMER ? { ...c, sms_opt_in: false } : c),
  );
  const summary = await responseJson<QueueRunSummary>(await handler(cron()));
  assertEquals([summary.claimed, summary.sent, summary.cancelled], [3, 2, 1]);
  const row = message(db, String(blast.id));
  assertEquals([row.status, row.error], ["cancelled", CONSENT_WITHDRAWN]);
  assertEquals(message(db, String(blastEmail.id)).status, "sent");
  assertEquals(message(db, String(transactional.id)).status, "sent");
  const texts = db.http.callsTo("POST", TWILIO_MESSAGES_URL);
  assertEquals(texts.map((c) => c.form.get("Body")), ["Your car is ready"]);
});

Deno.test("process_queue: campaign consent that cannot be read is retried, never sent", async () => {
  const blast = queuedMessage({ campaign_id: "60000000-0000-4000-8000-000000000001" });
  const transactional = queuedMessage({ body: "Your car is ready" });
  const { db, handler } = setup({ messages: [blast, transactional] });
  db.http.on(
    "GET",
    "https://fake-project.supabase.co/rest/v1/customers",
    () => jsonResponse({ code: "08006", message: "connection failure" }, 500),
  );
  const summary = await responseJson<QueueRunSummary>(await handler(cron()));
  assertEquals([summary.sent, summary.retried], [1, 1]);
  const row = message(db, String(blast.id));
  assertEquals([row.status, row.error], ["queued", CONSENT_UNVERIFIED]);
  assertEquals(db.http.callsTo("POST", TWILIO_MESSAGES_URL).length, 1);
});
