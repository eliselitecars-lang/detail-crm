import { assertEquals } from "@std/assert";
import type { ErrorBody } from "../_shared/http.ts";
import { emptyRequest, formRequest, responseJson } from "../_shared/testing/requests.ts";
import { CUSTOMER, queuedMessage, setup } from "./test_fixtures.ts";

const campaignEmail = () =>
  queuedMessage({
    channel: "email",
    to_address: "dana@example.com",
    subject: "Fall special",
    status: "sent",
    campaign_id: "60000000-0000-4000-8000-000000000001",
    unsubscribe_token: crypto.randomUUID(),
  });

function oneClick(token: string): Request {
  return formRequest("messaging", { "List-Unsubscribe": "One-Click" }, {
    query: { action: "unsubscribe", token },
  });
}

Deno.test("unsubscribe: RFC 8058 one-click POST records the marketing opt-out", async () => {
  const msg = campaignEmail();
  const { db, handler, unsubscribeSources } = setup({ messages: [msg] });
  const res = await handler(oneClick(String(msg.unsubscribe_token)));
  assertEquals(res.status, 200);
  assertEquals(await responseJson(res), { unsubscribed: true });
  // 0126: marketing only (no email_opted_out_at stamp: invoices and
  // reminders keep going), recorded as the one-click source
  const customer = db.table("customers").find((c) => c.id === CUSTOMER);
  assertEquals([customer?.email_opted_out_at, customer?.email_opt_in], [null, false]);
  assertEquals(unsubscribeSources, ["list_unsubscribe"]);
  assertEquals(db.requests.find((r) => r.target === "public_unsubscribe")?.role, "service_role");
  // Idempotent: a repeated POST (provider retry) succeeds again.
  const again = await handler(oneClick(String(msg.unsubscribe_token)));
  assertEquals(again.status, 200);
  await again.body?.cancel();
});

Deno.test("unsubscribe: GET never unsubscribes; it redirects to the confirmation page", async () => {
  const msg = campaignEmail();
  const { db, handler } = setup({ messages: [msg] });
  const res = await handler(
    emptyRequest("messaging", {
      query: { action: "unsubscribe", token: String(msg.unsubscribe_token) },
    }),
  );
  assertEquals(res.status, 303);
  assertEquals(res.headers.get("location"), `https://app.example.com/u/${msg.unsubscribe_token}`);
  await res.body?.cancel();
  assertEquals(db.requests.some((r) => r.target === "public_unsubscribe"), false);
  assertEquals(db.table("customers").find((c) => c.id === CUSTOMER)?.email_opt_in, true);
});

Deno.test("unsubscribe: a message id is not an unsubscribe token (transactional mail has none)", async () => {
  // Regression: public_unsubscribe accepted any outbound email's id, which
  // staff RPCs return to technicians.
  const campaign = campaignEmail();
  const transactional = queuedMessage({
    channel: "email",
    to_address: "dana@example.com",
    subject: "Your vehicle is ready",
    status: "sent",
    template_key: "job_completed",
  });
  const { db, handler } = setup({ messages: [campaign, transactional] });
  for (const id of [String(campaign.id), String(transactional.id)]) {
    const res = await handler(oneClick(id));
    assertEquals([res.status, (await responseJson<ErrorBody>(res)).code], [404, "not_found"]);
  }
  assertEquals(db.table("customers").find((c) => c.id === CUSTOMER)?.email_opt_in, true);
});

Deno.test("unsubscribe: malformed and unknown tokens", async () => {
  const { handler } = setup();
  const bad = await handler(oneClick("not-a-token"));
  assertEquals([bad.status, (await responseJson<ErrorBody>(bad)).code], [400, "validation_failed"]);
  const missing = await handler(
    formRequest("messaging", {}, { query: { action: "unsubscribe" } }),
  );
  assertEquals(missing.status, 400);
  await missing.body?.cancel();
  const unknown = await handler(oneClick("70000000-0000-4000-8000-000000000001"));
  assertEquals([unknown.status, (await responseJson<ErrorBody>(unknown)).code], [
    404,
    "not_found",
  ]);
});

Deno.test("messaging: GET is only for unsubscribe links", async () => {
  const { db, handler } = setup();
  for (const action of ["process_queue", "twilio_inbound", "send"]) {
    const res = await handler(emptyRequest("messaging", { query: { action } }));
    assertEquals(res.status, 405, action);
    assertEquals(res.headers.get("allow"), "POST, OPTIONS");
    await res.body?.cancel();
  }
  const bare = await handler(emptyRequest("messaging"));
  assertEquals(bare.status, 405);
  await bare.body?.cancel();
  assertEquals(db.requests.length, 0);
});
