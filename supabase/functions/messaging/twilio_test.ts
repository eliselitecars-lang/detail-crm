import { assertEquals, assertMatch } from "@std/assert";
import type { ErrorBody } from "../_shared/http.ts";
import { formRequest, responseJson } from "../_shared/testing/requests.ts";
import { computeTwilioSignature } from "../_shared/twilio.ts";
import { mapTwilioStatus } from "./twilio_webhooks.ts";
import {
  CUSTOMER,
  CUSTOMER_PHONE,
  message,
  OTHER_SHOP,
  PUBLIC_BASE,
  queuedMessage,
  setup,
  SHOP,
  SHOP_NUMBER,
} from "./test_fixtures.ts";

const AUTH_TOKEN = "fake-twilio-auth-token";
const EMPTY_TWIML = '<?xml version="1.0" encoding="UTF-8"?><Response></Response>';

function inboundParams(
  body: string,
  overrides: Record<string, string> = {},
): Record<string, string> {
  return {
    AccountSid: "AC00000000000000000000000000000000",
    MessageSid: "SM" + "a".repeat(32),
    SmsSid: "SM" + "a".repeat(32),
    From: CUSTOMER_PHONE,
    To: SHOP_NUMBER,
    Body: body,
    NumMedia: "0",
    ...overrides,
  };
}

/** Query Twilio calls with: inbound numbers are provisioned with their shop_id. */
function webhookQuery(action: string, shopId: string | null = SHOP): Record<string, string> {
  return action === "twilio_inbound" && shopId !== null ? { action, shop_id: shopId } : { action };
}

async function signedForm(
  action: string,
  params: Record<string, string>,
  options: {
    signUrl?: string;
    token?: string;
    requestUrl?: string;
    signature?: string;
    query?: Record<string, string>;
  } = {},
): Promise<Request> {
  const query = options.query ?? webhookQuery(action);
  const signUrl = options.signUrl ??
    `${PUBLIC_BASE}/messaging?${new URLSearchParams(query).toString()}`;
  const signature = options.signature ??
    await computeTwilioSignature(options.token ?? AUTH_TOKEN, signUrl, params);
  return formRequest(options.requestUrl ?? "messaging", params, {
    query,
    headers: { "x-twilio-signature": signature },
  });
}

Deno.test("twilio_inbound: a valid signature records the text and answers empty TwiML", async () => {
  const { db, handler } = setup();
  const res = await handler(await signedForm("twilio_inbound", inboundParams("Running late?")));
  assertEquals(res.status, 200);
  assertEquals(res.headers.get("content-type"), "text/xml; charset=utf-8");
  assertEquals(await res.text(), EMPTY_TWIML);
  const call = db.requests.find((r) => r.target === "record_inbound_sms");
  assertEquals(call?.role, "service_role");
  const inbound = db.table("messages").find((m) => m.direction === "inbound");
  assertEquals(
    [inbound?.shop_id, inbound?.customer_id, inbound?.body, inbound?.provider_message_id],
    [SHOP, CUSTOMER, "Running late?", "SM" + "a".repeat(32)],
  );
});

Deno.test("twilio_inbound: STOP passes through to the database opt-out, no auto-reply", async () => {
  const { db, handler, logs } = setup();
  const res = await handler(await signedForm("twilio_inbound", inboundParams("STOP")));
  assertEquals(await res.text(), EMPTY_TWIML);
  const customer = db.table("customers").find((c) => c.id === CUSTOMER);
  assertEquals(typeof customer?.sms_opted_out_at, "string");
  assertEquals(logs.events("inbound_sms_recorded")[0]?.opt_action, "opt_out");
  // Phone numbers and message text are not logged.
  const logged = JSON.stringify(logs.records);
  assertEquals(logged.includes(CUSTOMER_PHONE), false);
  assertEquals(logged.includes('STOP"'), false);
  // No outbound SMS was sent in reply.
  assertEquals(db.http.callsTo("POST", "https://api.twilio.com/:path*").length, 0);
});

Deno.test("twilio_inbound: invalid, missing and wrong-token signatures are rejected", async () => {
  const { db, handler } = setup();
  const params = inboundParams("hello");
  const cases = [
    await signedForm("twilio_inbound", params, { signature: "bogus" }),
    formRequest("messaging", params, { query: webhookQuery("twilio_inbound") }),
    await signedForm("twilio_inbound", params, { token: "another-token" }),
  ];
  for (const req of cases) {
    const res = await handler(req);
    assertEquals(res.status, 400);
    assertEquals((await responseJson<ErrorBody>(res)).code, "invalid_signature");
  }
  // Tampered body: signed "hello", delivered "STOP".
  const tampered = await signedForm("twilio_inbound", params);
  const forged = formRequest("messaging", { ...params, Body: "STOP" }, {
    query: webhookQuery("twilio_inbound"),
    headers: { "x-twilio-signature": tampered.headers.get("x-twilio-signature") ?? "" },
  });
  assertEquals((await handler(forged)).status, 400);
  assertEquals(db.requests.some((r) => r.target === "record_inbound_sms"), false);
});

Deno.test("twilio_inbound: signature must match the public URL, not req.url", async () => {
  const params = inboundParams("hi");
  // Signed for a different action's URL -> mismatch.
  const { handler } = setup();
  const wrongAction = await signedForm("twilio_inbound", params, {
    signUrl: `${PUBLIC_BASE}/messaging?action=twilio_status`,
  });
  assertEquals((await handler(wrongAction)).status, 400);
  // Signed for another host -> mismatch.
  const wrongHost = await signedForm("twilio_inbound", params, {
    signUrl: "https://evil.example.com/functions/v1/messaging?action=twilio_inbound",
  });
  assertEquals((await handler(wrongHost)).status, 400);

  // Behind a tunnel: Twilio signs the public URL while the runtime sees an
  // internal one; FUNCTIONS_PUBLIC_URL makes the check use the public URL.
  const tunnel = "https://abc123.ngrok.example/functions/v1";
  const tunnelled = setup({ env: { FUNCTIONS_PUBLIC_URL: tunnel } });
  const ok = await tunnelled.handler(
    await signedForm("twilio_inbound", params, {
      signUrl: `${tunnel}/messaging?action=twilio_inbound&shop_id=${SHOP}`,
      requestUrl: "http://edge-runtime.internal:9000/messaging",
    }),
  );
  assertEquals(ok.status, 200);
  await ok.body?.cancel();
  // ...and the internal URL itself is not accepted.
  const internal = await tunnelled.handler(
    await signedForm("twilio_inbound", params, {
      signUrl: `http://edge-runtime.internal:9000/messaging?action=twilio_inbound&shop_id=${SHOP}`,
      requestUrl: "http://edge-runtime.internal:9000/messaging",
    }),
  );
  assertEquals(internal.status, 400);
  await internal.body?.cancel();
});

Deno.test("twilio_inbound: unknown shop number and non-E.164 senders are acknowledged", async () => {
  const { db, handler, logs } = setup();
  const unknown = await handler(
    await signedForm("twilio_inbound", inboundParams("hi", { To: "+12055559999" })),
  );
  assertEquals(await unknown.text(), EMPTY_TWIML);
  const shortCode = await handler(
    await signedForm("twilio_inbound", inboundParams("hi", { From: "12345" })),
  );
  assertEquals([shortCode.status, await shortCode.text()], [200, EMPTY_TWIML]);
  assertEquals(db.table("messages").length, 0);
  assertEquals(logs.events("inbound_sms_ignored").map((r) => r.reason), [
    "unknown_number",
    "invalid_address",
  ]);
});

Deno.test("twilio_inbound: a database failure answers 500 so Twilio retries", async () => {
  const { db, handler } = setup();
  db.onRpc("record_inbound_sms", () => {
    throw new Error("db down");
  });
  const res = await handler(await signedForm("twilio_inbound", inboundParams("hi")));
  assertEquals(res.status, 500);
  assertEquals((await responseJson<ErrorBody>(res)).code, "internal_error");
});

Deno.test("twilio_inbound: only reachable by query action and form bodies", async () => {
  const { handler } = setup();
  const viaJson = await handler(
    new Request(`${PUBLIC_BASE}/messaging`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ action: "twilio_inbound", From: CUSTOMER_PHONE }),
    }),
  );
  assertEquals((await responseJson<ErrorBody>(viaJson)).code, "unknown_action");
  const wrongType = await handler(
    new Request(`${PUBLIC_BASE}/messaging?action=twilio_inbound`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: "{}",
    }),
  );
  assertEquals(wrongType.status, 415);
  await wrongType.body?.cancel();
});

Deno.test("twilio_status: delivery callbacks update the message by provider id", async () => {
  const sid = "SM" + "b".repeat(32);
  const msg = queuedMessage({ status: "sent", provider_message_id: sid });
  const { db, handler } = setup({ messages: [msg] });
  const status = (value: string, extra: Record<string, string> = {}) =>
    signedForm("twilio_status", {
      MessageSid: sid,
      MessageStatus: value,
      AccountSid: "AC00000000000000000000000000000000",
      ...extra,
    });

  const delivered = await handler(await status("delivered"));
  assertEquals([delivered.status, await delivered.text()], [200, EMPTY_TWIML]);
  assertEquals(message(db, String(msg.id)).status, "delivered");

  const failed = await handler(await status("undelivered", { ErrorCode: "30003" }));
  await failed.body?.cancel();
  const row = message(db, String(msg.id));
  assertEquals(row.status, "failed");
  assertMatch(String(row.error), /^Twilio 30003: message undelivered$/);

  // Intermediate statuses are acknowledged without a database call.
  const before = db.requests.length;
  const sending = await handler(await status("sending"));
  assertEquals(sending.status, 200);
  await sending.body?.cancel();
  assertEquals(db.requests.length, before);
});

Deno.test("twilio_status: rejects unsigned callbacks", async () => {
  const { db, handler } = setup();
  const res = await handler(
    formRequest("messaging", { MessageSid: "SM1", MessageStatus: "delivered" }, {
      query: { action: "twilio_status" },
      headers: { "x-twilio-signature": "nope" },
    }),
  );
  assertEquals(res.status, 400);
  await res.body?.cancel();
  assertEquals(db.requests.length, 0);
});

Deno.test("mapTwilioStatus", () => {
  assertEquals(
    ["queued", "sending", "sent", "delivered", "read", "undelivered", "failed", "accepted"].map(
      mapTwilioStatus,
    ),
    [null, null, "sent", "delivered", "delivered", "failed", "failed", null],
  );
});

Deno.test("twilio_inbound: accepts a signature over the configured URL with connection overrides", async () => {
  const { db, handler } = setup();
  const params = inboundParams("hello");
  const res = await handler(
    await signedForm("twilio_inbound", params, {
      signUrl: `${PUBLIC_BASE}/messaging?action=twilio_inbound&shop_id=${SHOP}#rc=3&rp=all`,
    }),
  );
  assertEquals([res.status, await res.text()], [200, EMPTY_TWIML]);
  assertEquals(db.table("messages").filter((m) => m.direction === "inbound").length, 1);
  // ...but not over some other fragment.
  const other = await handler(
    await signedForm("twilio_inbound", params, {
      signUrl: `${PUBLIC_BASE}/messaging?action=twilio_inbound&shop_id=${SHOP}#rc=5`,
    }),
  );
  assertEquals(other.status, 400);
  await other.body?.cancel();
});

Deno.test("twilio_inbound: a number not provisioned for the shop never routes replies or STOPs", async () => {
  // Another tenant typed SHOP's platform number into its own settings
  // (SHOP has not configured it yet). Twilio still calls the webhook the
  // platform provisioned for SHOP.
  const { db, handler, logs } = setup();
  db.seed(
    "shops",
    db.table("shops").map((s) => ({
      ...s,
      sms_from_number: s.id === OTHER_SHOP ? SHOP_NUMBER : null,
    })),
  );
  db.seed("customers", [
    ...db.table("customers"),
    {
      id: "30000000-0000-4000-8000-000000000009",
      shop_id: OTHER_SHOP,
      phone: CUSTOMER_PHONE,
      email: null,
      sms_opted_out_at: null,
      email_opted_out_at: null,
    },
  ]);
  const provisioned = await handler(await signedForm("twilio_inbound", inboundParams("STOP")));
  assertEquals([provisioned.status, await provisioned.text()], [200, EMPTY_TWIML]);
  // A webhook without the platform binding is not routed either.
  const unbound = await handler(
    await signedForm("twilio_inbound", inboundParams("STOP"), {
      query: { action: "twilio_inbound" },
    }),
  );
  assertEquals([unbound.status, await unbound.text()], [200, EMPTY_TWIML]);

  assertEquals(db.requests.some((r) => r.target === "record_inbound_sms"), false);
  assertEquals(db.table("messages").length, 0);
  const stamped = db.table("customers").filter((c) =>
    c.phone === CUSTOMER_PHONE && c.sms_opted_out_at !== null
  );
  assertEquals(stamped.length, 0);
  assertEquals(logs.events("inbound_sms_ignored").map((r) => r.reason), [
    "number_not_provisioned",
    "number_not_provisioned",
  ]);
});

Deno.test("twilio_status: Twilio 21610 (unsubscribed) records the customer's SMS opt-out", async () => {
  const sid = "SM" + "c".repeat(32);
  const sent = queuedMessage({ status: "sent", provider_message_id: sid });
  const pending = queuedMessage({ body: "Reminder" });
  const { db, handler } = setup({ messages: [sent, pending] });
  const res = await handler(
    await signedForm("twilio_status", {
      MessageSid: sid,
      MessageStatus: "undelivered",
      ErrorCode: "21610",
      AccountSid: "AC00000000000000000000000000000000",
    }),
  );
  assertEquals(res.status, 200);
  await res.body?.cancel();
  assertEquals(message(db, String(sent.id)).status, "failed");
  const customer = db.table("customers").find((c) => c.id === CUSTOMER);
  assertEquals([typeof customer?.sms_opted_out_at, customer?.sms_opt_in], ["string", false]);
  assertEquals(message(db, String(pending.id)).status, "cancelled");
});

function customerRow(db: ReturnType<typeof setup>["db"]) {
  return db.table("customers").find((c) => c.id === CUSTOMER);
}

const sid = (ch: string) => "SM" + ch.repeat(32);

Deno.test("twilio_inbound: YES (a Twilio opt-in keyword) clears the SMS opt-out like START", async () => {
  for (const reply of ["YES", "yes!", " Yes. "]) {
    const { db, handler, logs } = setup();
    await (await handler(
      await signedForm("twilio_inbound", inboundParams("STOP", { MessageSid: sid("1") })),
    )).body?.cancel();
    assertEquals(typeof customerRow(db)?.sms_opted_out_at, "string");

    const res = await handler(
      await signedForm("twilio_inbound", inboundParams(reply, { MessageSid: sid("2") })),
    );
    assertEquals(await res.text(), EMPTY_TWIML);
    assertEquals(customerRow(db)?.sms_opted_out_at, null, reply);
    const call = db.requests.find((r) => r.target === "comms_unsuppress");
    assertEquals(call?.role, "service_role");
    assertEquals(logs.events("inbound_sms_recorded")[1]?.opt_action, "opt_in");
  }
});

Deno.test("twilio_inbound: START is left to the database; ordinary replies never opt in", async () => {
  const { db, handler } = setup();
  for (
    const [body, ch] of [["STOP", "1"], ["START", "2"], ["Yes see you then", "3"]] as const
  ) {
    await (await handler(
      await signedForm("twilio_inbound", inboundParams(body, { MessageSid: sid(ch) })),
    )).body?.cancel();
  }
  assertEquals(customerRow(db)?.sms_opted_out_at, null); // by record_inbound_sms (START)
  assertEquals(db.requests.some((r) => r.target === "comms_unsuppress"), false);
});

Deno.test("twilio_inbound: a late retry of an old YES never undoes a newer STOP", async () => {
  const { db, handler, logs } = setup();
  const yes = inboundParams("YES", { MessageSid: sid("1") });
  await (await handler(await signedForm("twilio_inbound", yes))).body?.cancel();
  await (await handler(
    await signedForm("twilio_inbound", inboundParams("STOP", { MessageSid: sid("2") })),
  )).body?.cancel();
  assertEquals(typeof customerRow(db)?.sms_opted_out_at, "string");

  // Twilio redelivers the first YES (same MessageSid) after the STOP.
  const res = await handler(await signedForm("twilio_inbound", yes));
  assertEquals(res.status, 200);
  await res.body?.cancel();
  assertEquals(typeof customerRow(db)?.sms_opted_out_at, "string");
  assertEquals(logs.events("sms_opt_in_skipped").length, 1);
});

Deno.test("twilio_inbound: a failed YES opt-in answers 500 so Twilio redelivers", async () => {
  const { db, handler } = setup();
  await (await handler(
    await signedForm("twilio_inbound", inboundParams("STOP", { MessageSid: sid("1") })),
  )).body?.cancel();
  db.onRpc("comms_unsuppress", () => {
    throw new Error("db down");
  });
  const yes = inboundParams("YES", { MessageSid: sid("2") });
  const failed = await handler(await signedForm("twilio_inbound", yes));
  assertEquals(failed.status, 500);
  await failed.body?.cancel();
  assertEquals(typeof customerRow(db)?.sms_opted_out_at, "string");

  db.onRpc("comms_unsuppress", (args, ctx) => {
    const rows = ctx.db.table("customers");
    for (const c of rows) if (c.phone === args.p_address) c.sms_opted_out_at = null;
    ctx.db.seed("customers", rows);
    return true;
  });
  const retried = await handler(await signedForm("twilio_inbound", yes));
  assertEquals(retried.status, 200);
  await retried.body?.cancel();
  assertEquals(customerRow(db)?.sms_opted_out_at, null);
});
