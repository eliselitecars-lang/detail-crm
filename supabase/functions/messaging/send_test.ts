import { assert, assertEquals } from "@std/assert";
import type { ErrorBody } from "../_shared/http.ts";
import { jsonResponse } from "../_shared/testing/fake_fetch.ts";
import { FakeRpcError } from "../_shared/testing/fake_supabase.ts";
import { jsonRequest, responseJson } from "../_shared/testing/requests.ts";
import type { SendResponse } from "./send.ts";
import {
  CUSTOMER,
  CUSTOMER_PHONE,
  JOB,
  message,
  NO_EMAIL_CUSTOMER,
  OPTED_OUT_CUSTOMER,
  OPTED_OUT_JOB,
  OTHER_SHOP,
  OTHER_SHOP_CUSTOMER,
  queuedMessage,
  RESEND_URL,
  setup,
  SHOP,
  SHOP_NUMBER,
  TWILIO_MESSAGES_URL,
  UNASSIGNED_JOB,
} from "./test_fixtures.ts";

const APP = "https://app.example.com";

function sendRequest(token: string | null, body: Record<string, unknown>): Request {
  return jsonRequest("messaging", { action: "send", shop_id: SHOP, ...body }, {
    ...(token ? { token } : {}),
    origin: APP,
  });
}

async function expectError(res: Response, status: number, code: string): Promise<ErrorBody> {
  const body = await responseJson<ErrorBody>(res);
  assertEquals([res.status, body.code], [status, code], JSON.stringify(body));
  return body;
}

Deno.test("send: manager free-form SMS is queued as the caller and delivered immediately", async () => {
  const { db, handler } = setup();
  const res = await handler(
    sendRequest("tok-manager", { customer_id: CUSTOMER, channel: "sms", body: "See you at 10!" }),
  );
  assertEquals(res.status, 200);
  assertEquals(res.headers.get("access-control-allow-origin"), APP);
  const out = await responseJson<SendResponse>(res);
  assertEquals([out.channel, out.status, out.error], ["sms", "sent", null]);
  const row = message(db, out.message_id);
  assertEquals([row.status, row.attempts, row.from_address], ["sent", 1, SHOP_NUMBER]);
  const call = db.http.callsTo("POST", TWILIO_MESSAGES_URL)[0];
  assertEquals([call?.form.get("To"), call?.form.get("Body")], [CUSTOMER_PHONE, "See you at 10!"]);
  // queue_message ran with the caller's JWT (RLS/role checks in the DB apply).
  const queued = db.requests.find((r) => r.target === "queue_message");
  assertEquals([queued?.role, queued?.userId], [
    "authenticated",
    "10000000-0000-4000-8000-000000000002",
  ]);
});

Deno.test("send: free-form email with subject", async () => {
  const { db, handler } = setup();
  const out = await responseJson<SendResponse>(
    await handler(
      sendRequest("tok-owner", {
        customer_id: CUSTOMER,
        channel: "email",
        subject: "Your appointment",
        body: "Hi Dana",
      }),
    ),
  );
  assertEquals(out.status, "sent");
  const email = db.http.callsTo("POST", RESEND_URL)[0]?.json as Record<string, unknown>;
  assertEquals([email.subject, email.text, email.to], ["Your appointment", "Hi Dana", [
    "dana@example.com",
  ]]);
});

Deno.test("send: template for a job (manager) uses enqueue_template_message", async () => {
  const { db, handler } = setup();
  const out = await responseJson<SendResponse>(
    await handler(
      sendRequest("tok-manager", { job_id: JOB, channel: "email", template_key: "job_completed" }),
    ),
  );
  assertEquals(out.status, "sent");
  const row = message(db, out.message_id);
  assertEquals([row.template_key, row.job_id, row.customer_id], ["job_completed", JOB, CUSTOMER]);
  assertEquals(
    db.requests.find((r) => r.target === "enqueue_template_message")?.role,
    "authenticated",
  );
});

Deno.test("send: customer-level template without a job (manager) uses the service core, scoped", async () => {
  const { db, handler } = setup();
  const out = await responseJson<SendResponse>(
    await handler(
      sendRequest("tok-manager", {
        customer_id: CUSTOMER,
        channel: "sms",
        template_key: "follow_up",
      }),
    ),
  );
  assertEquals(out.status, "sent");
  const row = message(db, out.message_id);
  assertEquals([row.template_key, row.sent_by], [
    "follow_up",
    "10000000-0000-4000-8000-000000000002",
  ]);
  // A customer of another shop is not reachable through this shop.
  const other = await handler(
    sendRequest("tok-manager", {
      customer_id: OTHER_SHOP_CUSTOMER,
      channel: "sms",
      template_key: "follow_up",
    }),
  );
  await expectError(other, 404, "not_found");
});

Deno.test("send: technician may send on_the_way for an assigned job", async () => {
  const { db, handler } = setup();
  const out = await responseJson<SendResponse>(
    await handler(
      sendRequest("tok-tech", { job_id: JOB, channel: "sms", template_key: "on_the_way" }),
    ),
  );
  assertEquals(out.status, "sent");
  assertEquals(message(db, out.message_id).body, "On our way!");
});

Deno.test("send: technician restrictions", async () => {
  const { db, handler } = setup();
  // free-form
  await expectError(
    await handler(sendRequest("tok-tech", { job_id: JOB, channel: "sms", body: "hi" })),
    403,
    "forbidden",
  );
  // another template key
  await expectError(
    await handler(
      sendRequest("tok-tech", { job_id: JOB, channel: "sms", template_key: "follow_up" }),
    ),
    403,
    "forbidden",
  );
  // allowed key but no job
  await expectError(
    await handler(
      sendRequest("tok-tech", {
        customer_id: CUSTOMER,
        channel: "sms",
        template_key: "on_the_way",
      }),
    ),
    403,
    "forbidden",
  );
  // allowed key, job not assigned to them
  await expectError(
    await handler(
      sendRequest("tok-tech", {
        job_id: UNASSIGNED_JOB,
        channel: "sms",
        template_key: "on_the_way",
      }),
    ),
    403,
    "forbidden",
  );
  await expectError(
    await handler(
      sendRequest("tok-other-tech", { job_id: JOB, channel: "sms", template_key: "job_started" }),
    ),
    403,
    "forbidden",
  );
  assertEquals(db.table("messages").length, 0);
  assertEquals(db.http.callsTo("POST", TWILIO_MESSAGES_URL).length, 0);
});

Deno.test("send: the database re-check refuses even if the function check were bypassed", async () => {
  const { db, handler } = setup();
  // Simulate a role that passes the function (manager) but the DB says no.
  db.onRpc("queue_message", () => {
    throw new FakeRpcError("42501", "only owners, admins and managers can message customers");
  });
  const body = await expectError(
    await handler(sendRequest("tok-manager", { customer_id: CUSTOMER, channel: "sms", body: "x" })),
    403,
    "forbidden",
  );
  // The SQL text is not leaked.
  assertEquals(body.error, "Your role does not allow this message.");
});

Deno.test("send: signed-out, outsiders and other shops are refused", async () => {
  const { handler } = setup();
  await expectError(
    await handler(sendRequest(null, { customer_id: CUSTOMER, channel: "sms", body: "x" })),
    401,
    "unauthorized",
  );
  await expectError(
    await handler(sendRequest("tok-bogus", { customer_id: CUSTOMER, channel: "sms", body: "x" })),
    401,
    "unauthorized",
  );
  await expectError(
    await handler(
      sendRequest("tok-outsider", { customer_id: CUSTOMER, channel: "sms", body: "x" }),
    ),
    403,
    "forbidden",
  );
  // A manager naming another shop is not a member there.
  await expectError(
    await handler(
      sendRequest("tok-manager", {
        shop_id: OTHER_SHOP,
        customer_id: OTHER_SHOP_CUSTOMER,
        channel: "sms",
        body: "x",
      }),
    ),
    403,
    "forbidden",
  );
  // A job of the shop named in the request only.
  await expectError(
    await handler(
      sendRequest("tok-outsider", {
        shop_id: OTHER_SHOP,
        job_id: JOB,
        channel: "sms",
        template_key: "on_the_way",
      }),
    ),
    404,
    "not_found",
  );
});

Deno.test("send: opt-outs and missing addresses surface as unprocessable with a reason", async () => {
  const { db, handler } = setup();
  const optedFree = await expectError(
    await handler(
      sendRequest("tok-manager", { customer_id: OPTED_OUT_CUSTOMER, channel: "sms", body: "x" }),
    ),
    422,
    "unprocessable",
  );
  assertEquals(optedFree.details, { reason: "opted_out" });
  assertEquals(optedFree.error, "This customer has opted out of text messages.");

  // Template path: the DB no-ops (returns null) for an opted-out customer.
  const optedTemplate = await expectError(
    await handler(
      sendRequest("tok-tech", {
        job_id: OPTED_OUT_JOB,
        channel: "sms",
        template_key: "on_the_way",
      }),
    ),
    422,
    "unprocessable",
  );
  assertEquals(optedTemplate.details, { reason: "opted_out" });

  const noEmail = await expectError(
    await handler(
      sendRequest("tok-manager", { customer_id: NO_EMAIL_CUSTOMER, channel: "email", body: "x" }),
    ),
    422,
    "unprocessable",
  );
  assertEquals(noEmail.details, { reason: "no_address" });

  const disabled = await expectError(
    await handler(
      sendRequest("tok-manager", {
        customer_id: CUSTOMER,
        channel: "sms",
        template_key: "review_request",
      }),
    ),
    422,
    "unprocessable",
  );
  assertEquals(disabled.details, { reason: "template_disabled" });

  const mismatch = await expectError(
    await handler(
      sendRequest("tok-manager", {
        customer_id: OPTED_OUT_CUSTOMER,
        job_id: JOB,
        channel: "sms",
        body: "x",
      }),
    ),
    422,
    "unprocessable",
  );
  assertEquals(mismatch.details, { reason: "job_customer_mismatch" });
  assertEquals(db.http.callsTo("POST", TWILIO_MESSAGES_URL).length, 0);
});

Deno.test("send: SMS without a shop number is not queued", async () => {
  const { db, handler } = setup();
  db.seed("shops", db.table("shops").map((s) => ({ ...s, sms_from_number: null })));
  const res = await handler(
    sendRequest("tok-manager", {
      customer_id: CUSTOMER,
      channel: "sms",
      template_key: "follow_up",
    }),
  );
  assertEquals((await expectError(res, 422, "unprocessable")).details, {
    reason: "sms_not_configured",
  });
});

Deno.test("send: provider failure is reported as the message status, not an HTTP error", async () => {
  const { db, handler } = setup();
  db.http.on(
    "POST",
    TWILIO_MESSAGES_URL,
    () => jsonResponse({ code: 21614, message: "'To' number is not a valid mobile number" }, 400),
  );
  const res = await handler(
    sendRequest("tok-manager", { customer_id: CUSTOMER, channel: "sms", body: "hello" }),
  );
  assertEquals(res.status, 200);
  const out = await responseJson<SendResponse>(res);
  assertEquals(out.status, "failed");
  assertEquals(out.error, "Twilio 21614: 'To' number is not a valid mobile number");
  assertEquals(message(db, out.message_id).status, "failed");

  db.http.on("POST", TWILIO_MESSAGES_URL, () => jsonResponse({ message: "busy" }, 503));
  const retry = await responseJson<SendResponse>(
    await handler(
      sendRequest("tok-manager", { customer_id: CUSTOMER, channel: "sms", body: "again" }),
    ),
  );
  assertEquals([retry.status, retry.error], ["queued", "Twilio: busy"]);
});

Deno.test("send: a message the cron worker already claimed is not sent twice", async () => {
  const { db, handler } = setup();
  // The DB queues the row, but a concurrent worker claims it first.
  db.onRpc("queue_message", (_args, ctx) => {
    const row = queuedMessage({ status: "sending", attempts: 1 });
    ctx.db.seed("messages", [...ctx.db.table("messages"), row]);
    return row;
  });
  const out = await responseJson<SendResponse>(
    await handler(sendRequest("tok-manager", { customer_id: CUSTOMER, channel: "sms", body: "x" })),
  );
  assertEquals(out.status, "sending");
  assertEquals(db.http.callsTo("POST", TWILIO_MESSAGES_URL).length, 0);
});

Deno.test("send: a customer who opted out after queueing is cancelled at claim", async () => {
  const { db, handler } = setup();
  db.onRpc("queue_message", (_args, ctx) => {
    const row = queuedMessage({ customer_id: OPTED_OUT_CUSTOMER, to_address: "+12055550122" });
    ctx.db.seed("messages", [...ctx.db.table("messages"), row]);
    return row;
  });
  const out = await responseJson<SendResponse>(
    await handler(sendRequest("tok-manager", { customer_id: CUSTOMER, channel: "sms", body: "x" })),
  );
  assertEquals(out.status, "cancelled");
  assertEquals(db.http.callsTo("POST", TWILIO_MESSAGES_URL).length, 0);
});

Deno.test("send: input validation", async () => {
  const { handler } = setup();
  const invalid = [
    { customer_id: CUSTOMER, channel: "sms" }, // neither body nor template
    { customer_id: CUSTOMER, channel: "sms", body: "   " },
    { customer_id: CUSTOMER, channel: "sms", body: "x", template_key: "on_the_way" },
    { customer_id: CUSTOMER, channel: "sms", body: "x", subject: "nope" },
    { customer_id: CUSTOMER, channel: "sms", body: "x".repeat(1601) },
    { channel: "sms", body: "x" }, // no recipient
    { customer_id: CUSTOMER, channel: "fax", body: "x" },
    { customer_id: CUSTOMER, channel: "email", template_key: "invite" },
    { customer_id: CUSTOMER, channel: "email", template_key: "job_completed", subject: "x" },
    { customer_id: CUSTOMER, channel: "sms", body: "x", to_address: "+12055550000" },
    { customer_id: "not-a-uuid", channel: "sms", body: "x" },
  ];
  for (const body of invalid) {
    await expectError(await handler(sendRequest("tok-manager", body)), 400, "validation_failed");
  }
});

Deno.test("send: CORS preflight from the app origin", async () => {
  const { handler } = setup();
  const res = await handler(
    new Request("https://fake-project.supabase.co/functions/v1/messaging", {
      method: "OPTIONS",
      headers: { origin: APP, "access-control-request-method": "POST" },
    }),
  );
  assertEquals(res.status, 204);
  assert(res.headers.get("access-control-allow-headers")?.includes("authorization"));
});

Deno.test("send: clock skew does not defer an immediate send; a scheduled one waits", async () => {
  const { db, handler } = setup();
  let sendAfter = "2026-09-27T15:00:30.000Z"; // DB clock 30 s ahead of the edge clock
  db.onRpc("queue_message", (_args, ctx) => {
    const row = queuedMessage({ send_after: sendAfter });
    ctx.db.seed("messages", [...ctx.db.table("messages"), row]);
    return row;
  });
  const skewed = await responseJson<SendResponse>(
    await handler(sendRequest("tok-manager", { customer_id: CUSTOMER, channel: "sms", body: "x" })),
  );
  assertEquals(skewed.status, "sent");

  sendAfter = "2026-09-28T09:00:00.000Z";
  const later = await responseJson<SendResponse>(
    await handler(sendRequest("tok-manager", { customer_id: CUSTOMER, channel: "sms", body: "y" })),
  );
  assertEquals(later.status, "queued");
  assertEquals(db.http.callsTo("POST", TWILIO_MESSAGES_URL).length, 1);
});

/** The web inbox's body: no shop_id (the shop comes from the customer/job). */
function inboxRequest(token: string, body: Record<string, unknown>): Request {
  return jsonRequest("messaging", { action: "send", ...body }, { token, origin: APP });
}

Deno.test("send: without shop_id the shop is derived from the customer or the job", async () => {
  const { db, handler } = setup();
  const free = await responseJson<SendResponse>(
    await handler(
      inboxRequest("tok-manager", { customer_id: CUSTOMER, channel: "sms", body: "Hi Dana" }),
    ),
  );
  assertEquals(free.status, "sent");
  assertEquals(message(db, free.message_id).shop_id, SHOP);
  assertEquals(db.requests.find((r) => r.target === "queue_message")?.role, "authenticated");

  const templated = await responseJson<SendResponse>(
    await handler(
      inboxRequest("tok-manager", {
        customer_id: CUSTOMER,
        channel: "sms",
        template_key: "follow_up",
      }),
    ),
  );
  assertEquals(templated.status, "sent");

  // Technician: the job's shop, and the assignment check still applies.
  const tech = await responseJson<SendResponse>(
    await handler(
      inboxRequest("tok-tech", { job_id: JOB, channel: "sms", template_key: "on_the_way" }),
    ),
  );
  assertEquals(tech.status, "sent");
  await expectError(
    await handler(
      inboxRequest("tok-tech", {
        job_id: UNASSIGNED_JOB,
        channel: "sms",
        template_key: "on_the_way",
      }),
    ),
    403,
    "forbidden",
  );
  await expectError(
    await handler(inboxRequest("tok-tech", { customer_id: CUSTOMER, channel: "sms", body: "x" })),
    403,
    "forbidden",
  );
});

Deno.test("send: a derived shop never reaches another tenant's customer or job", async () => {
  const { db, handler } = setup();
  // Another shop's customer: indistinguishable from a missing one.
  await expectError(
    await handler(
      inboxRequest("tok-manager", { customer_id: OTHER_SHOP_CUSTOMER, channel: "sms", body: "x" }),
    ),
    404,
    "not_found",
  );
  await expectError(
    await handler(
      inboxRequest("tok-outsider", { customer_id: CUSTOMER, channel: "sms", body: "x" }),
    ),
    404,
    "not_found",
  );
  await expectError(
    await handler(
      inboxRequest("tok-outsider", { job_id: JOB, channel: "sms", template_key: "on_the_way" }),
    ),
    404,
    "not_found",
  );
  await expectError(
    await handler(
      inboxRequest("tok-manager", {
        customer_id: "30000000-0000-4000-8000-00000000ffff",
        channel: "sms",
        body: "x",
      }),
    ),
    404,
    "not_found",
  );
  // Signed-out callers are rejected before any lookup.
  const before = db.requests.filter((r) => r.kind === "rest").length;
  await expectError(
    await handler(
      jsonRequest("messaging", {
        action: "send",
        customer_id: CUSTOMER,
        channel: "sms",
        body: "x",
      }, { origin: APP }),
    ),
    401,
    "unauthorized",
  );
  assertEquals(db.requests.filter((r) => r.kind === "rest").length, before);
  assertEquals(db.table("messages").length, 0);
  assertEquals(db.http.callsTo("POST", TWILIO_MESSAGES_URL).length, 0);
});
