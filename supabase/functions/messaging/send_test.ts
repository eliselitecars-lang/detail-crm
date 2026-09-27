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

Deno.test("send: job-only templates without a job are refused (placeholders would go out blank)", async () => {
  const { db, handler } = setup();
  for (
    const key of [
      "booking_request_received",
      "booking_confirmed",
      "appointment_reminder",
      "on_the_way",
      "job_started",
      "job_completed",
      "quote_sent",
      "invoice_sent",
      "payment_receipt",
    ]
  ) {
    for (const channel of ["sms", "email"]) {
      const err = await expectError(
        await handler(
          sendRequest("tok-manager", { customer_id: CUSTOMER, channel, template_key: key }),
        ),
        422,
        "unprocessable",
      );
      assertEquals(err.details, { reason: "job_required" }, key);
    }
  }
  assertEquals(db.requests.some((r) => r.target === "enqueue_customer_template"), false);
  assertEquals(db.table("messages").length, 0);
  assertEquals(db.http.callsTo("POST", TWILIO_MESSAGES_URL).length, 0);
  assertEquals(db.http.callsTo("POST", RESEND_URL).length, 0);

  // The same template with its job goes out through the job path.
  const out = await responseJson<SendResponse>(
    await handler(
      sendRequest("tok-manager", {
        customer_id: CUSTOMER,
        job_id: JOB,
        channel: "email",
        template_key: "job_completed",
      }),
    ),
  );
  assertEquals(out.status, "sent");
});

Deno.test("send: customer-level templates (follow_up, review_request, membership_welcome) need no job", async () => {
  const { db, handler } = setup();
  db.seed(
    "message_templates",
    db.table("message_templates").map((t) => ({ ...t, enabled: true })),
  );
  for (const key of ["follow_up", "review_request", "membership_welcome"]) {
    const res = await handler(
      sendRequest("tok-manager", { customer_id: CUSTOMER, channel: "email", template_key: key }),
    );
    const body = await responseJson<Record<string, unknown>>(res);
    // Never refused for lacking a job (a template the fixture lacks is template_disabled).
    assert(
      (body.details as { reason?: string } | undefined)?.reason !== "job_required",
      `${key}: ${JSON.stringify(body)}`,
    );
  }
  const queued = db.requests.filter((r) => r.target === "enqueue_customer_template");
  assertEquals(queued.length, 3);
  assert(queued.every((r) => r.role === "service_role"));
});

/** Replaces (or adds) the shop's template for (key, channel). */
function useTemplate(
  db: ReturnType<typeof setup>["db"],
  key: string,
  channel: string,
  body: string,
  subject: string | null = null,
) {
  db.seed("message_templates", [
    ...db.table("message_templates").filter((t) => !(t.key === key && t.channel === channel)),
    { shop_id: SHOP, key, channel, subject, body, enabled: true },
  ]);
}

Deno.test("send: follow_up that mentions the vehicle needs a job (its {{vehicle}} would be blank)", async () => {
  const { db, handler } = setup();
  // The seeded default wording (0032).
  useTemplate(
    db,
    "follow_up",
    "sms",
    "Hi {{customer_first_name}}, it has been a while since your last visit to {{shop_name}}. " +
      "Ready to keep your {{vehicle}} looking its best? Book here: {{booking_page_link}}",
  );
  useTemplate(
    db,
    "follow_up",
    "email",
    "Regular care keeps your {{vehicle}} protected. Book: {{booking_page_link}}",
    "Time for your next visit? - {{shop_name}}",
  );
  for (const channel of ["sms", "email"]) {
    const err = await expectError(
      await handler(
        sendRequest("tok-manager", { customer_id: CUSTOMER, channel, template_key: "follow_up" }),
      ),
      422,
      "unprocessable",
    );
    assertEquals(err.details, { reason: "job_required", variables: ["vehicle"] }, channel);
  }
  assertEquals(db.requests.some((r) => r.target === "enqueue_customer_template"), false);
  assertEquals(db.table("messages").length, 0);

  // With the job whose vehicle it is, it goes out.
  const out = await responseJson<SendResponse>(
    await handler(
      sendRequest("tok-manager", { job_id: JOB, channel: "sms", template_key: "follow_up" }),
    ),
  );
  assertEquals(out.status, "sent");

  // A shop that reworded it without job details may still send it without a job.
  useTemplate(db, "follow_up", "sms", "Hi {{ customer_first_name }}, book: {{booking_page_link}}");
  const reworded = await responseJson<SendResponse>(
    await handler(
      sendRequest("tok-manager", {
        customer_id: CUSTOMER,
        channel: "sms",
        template_key: "follow_up",
      }),
    ),
  );
  assertEquals(reworded.status, "sent");
});

Deno.test("send: a review request is refused while the shop has no review link", async () => {
  const { db, handler } = setup();
  useTemplate(
    db,
    "review_request",
    "sms",
    "Thanks for choosing {{shop_name}}! We would really appreciate a review: {{review_link}}",
  );
  for (const reviewUrl of [null, "   "]) {
    db.seed("shops", db.table("shops").map((s) => ({ ...s, review_url: reviewUrl })));
    for (const body of [{ customer_id: CUSTOMER }, { job_id: JOB }]) {
      const err = await expectError(
        await handler(
          sendRequest("tok-manager", { ...body, channel: "sms", template_key: "review_request" }),
        ),
        422,
        "unprocessable",
      );
      assertEquals(err.details, { reason: "missing_link", variables: ["review_link"] });
      assertEquals(
        err.error,
        "Add the shop's review link in settings before sending this message.",
      );
    }
  }
  assertEquals(db.table("messages").length, 0);
  assertEquals(db.http.callsTo("POST", TWILIO_MESSAGES_URL).length, 0);

  db.seed(
    "shops",
    db.table("shops").map((s) => ({ ...s, review_url: "https://g.page/r/shine/review" })),
  );
  const out = await responseJson<SendResponse>(
    await handler(
      sendRequest("tok-manager", {
        customer_id: CUSTOMER,
        channel: "sms",
        template_key: "review_request",
      }),
    ),
  );
  assertEquals(out.status, "sent");
});

Deno.test("send: a job link the job does not have yet is refused, not sent blank", async () => {
  const { db, handler } = setup();
  useTemplate(db, "invoice_sent", "email", "Pay online: {{invoice_link}}", "Invoice");
  const err = await expectError(
    await handler(
      sendRequest("tok-manager", { job_id: JOB, channel: "email", template_key: "invoice_sent" }),
    ),
    422,
    "unprocessable",
  );
  assertEquals(err.details, { reason: "missing_link", variables: ["invoice_link"] });

  db.seed(
    "jobs",
    db.table("jobs").map((j) =>
      j.id === JOB ? { ...j, invoice_token: "0b3c9a5e-1111-4222-8333-944455556666" } : j
    ),
  );
  const out = await responseJson<SendResponse>(
    await handler(
      sendRequest("tok-manager", { job_id: JOB, channel: "email", template_key: "invoice_sent" }),
    ),
  );
  assertEquals(out.status, "sent");
});

Deno.test("send: missing marketing consent and closed appointments get their own reasons", async () => {
  const { db, handler } = setup();
  db.seed(
    "customers",
    db.table("customers").map((c) => c.id === CUSTOMER ? { ...c, sms_opt_in: false } : c),
  );
  const consent = await expectError(
    await handler(
      sendRequest("tok-manager", {
        customer_id: CUSTOMER,
        channel: "sms",
        template_key: "follow_up",
      }),
    ),
    422,
    "unprocessable",
  );
  assertEquals(consent.details, { reason: "no_marketing_consent" });
  assertEquals(consent.error, "This customer has not agreed to receive marketing text messages.");
  // Transactional templates only need an address.
  const transactional = await responseJson<SendResponse>(
    await handler(
      sendRequest("tok-manager", { job_id: JOB, channel: "sms", template_key: "on_the_way" }),
    ),
  );
  assertEquals(transactional.status, "sent");

  for (const status of ["cancelled", "no_show"]) {
    db.seed("jobs", db.table("jobs").map((j) => j.id === JOB ? { ...j, status } : j));
    for (const token of ["tok-manager", "tok-tech"]) {
      const closed = await expectError(
        await handler(
          sendRequest(token, { job_id: JOB, channel: "sms", template_key: "on_the_way" }),
        ),
        422,
        "unprocessable",
      );
      assertEquals(closed.details, { reason: "appointment_closed" }, `${status} ${token}`);
    }
  }
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

Deno.test("send: a retried request returns the original message instead of a second copy", async () => {
  const { db, handler } = setup();
  const request = () =>
    sendRequest("tok-manager", { customer_id: CUSTOMER, channel: "sms", body: "See you at 10!" });
  const first = await responseJson<SendResponse>(await handler(request()));
  assertEquals(first.status, "sent");
  // The response was lost; the app retries the same send.
  const again = await responseJson<SendResponse>(await handler(request()));
  assertEquals(again, first);
  assertEquals(db.http.callsTo("POST", TWILIO_MESSAGES_URL).length, 1);
  assertEquals(db.table("messages").length, 1);
});

Deno.test("send: a double tap delivers once", async () => {
  const { db, handler } = setup();
  const tap = () =>
    sendRequest("tok-tech", { job_id: JOB, channel: "sms", template_key: "on_the_way" });
  const [a, b] = await Promise.all([handler(tap()), handler(tap())]);
  const outs = [await responseJson<SendResponse>(a), await responseJson<SendResponse>(b)];
  assertEquals(outs[0]?.message_id, outs[1]?.message_id);
  assertEquals(db.http.callsTo("POST", TWILIO_MESSAGES_URL).length, 1);
  assertEquals(db.table("messages").length, 1);
});

Deno.test("send: different content, another sender, a failed original or an old one send again", async () => {
  const { db, handler } = setup();
  const sms = (token: string, body: string) =>
    sendRequest(token, { customer_id: CUSTOMER, channel: "sms", body });
  await (await handler(sms("tok-manager", "See you at 10!"))).body?.cancel();
  await (await handler(sms("tok-manager", "Actually 11"))).body?.cancel();
  await (await handler(sms("tok-owner", "See you at 10!"))).body?.cancel();
  assertEquals(db.http.callsTo("POST", TWILIO_MESSAGES_URL).length, 3);

  // An identical message that failed is not a reason to withhold the retry.
  db.http.on("POST", TWILIO_MESSAGES_URL, () => jsonResponse({ code: 21614, message: "x" }, 400));
  const failed = await responseJson<SendResponse>(await handler(sms("tok-manager", "Call me")));
  assertEquals(failed.status, "failed");
  db.http.on("POST", TWILIO_MESSAGES_URL, () => jsonResponse({ sid: "SM" + "9".repeat(32) }, 201));
  const resent = await responseJson<SendResponse>(await handler(sms("tok-manager", "Call me")));
  assertEquals(resent.status, "sent");
  assert(resent.message_id !== failed.message_id);

  // Outside the window it is a new message.
  const stale = queuedMessage({
    status: "sent",
    body: "Still coming?",
    sent_by: "10000000-0000-4000-8000-000000000002",
    created_at: "2026-09-27T14:50:00.000Z",
  });
  const recent = queuedMessage({
    status: "sent",
    body: "Ready soon",
    sent_by: "10000000-0000-4000-8000-000000000002",
    created_at: "2026-09-27T14:58:00.000Z",
  });
  db.seed("messages", [...db.table("messages"), stale, recent]);
  const late = await responseJson<SendResponse>(await handler(sms("tok-manager", "Still coming?")));
  assert(late.message_id !== stale.id);
  const dup = await responseJson<SendResponse>(await handler(sms("tok-manager", "Ready soon")));
  assertEquals([dup.message_id, dup.status], [recent.id, "sent"]);
});
