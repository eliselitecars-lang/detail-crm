import { assertEquals, assertRejects } from "@std/assert";
import { RESEND_API_URL, ResendError, sendEmail } from "./resend.ts";
import { FakeFetch, jsonResponse } from "./testing/fake_fetch.ts";

function http(): FakeFetch {
  return new FakeFetch().on("POST", RESEND_API_URL, () => jsonResponse({ id: "email_123" }));
}

Deno.test("resend: request shape (bearer auth, JSON body, idempotency header)", async () => {
  const fake = http();
  const sent = await sendEmail(
    "re_key",
    {
      from: "Shop <notifications@example.com>",
      to: "customer@example.com",
      subject: "Your invoice",
      text: "Hello",
      html: "<p>Hello</p>",
      replyTo: "shop@example.com",
      idempotencyKey: "message-123",
      tags: [{ name: "shop_id", value: "abc-123" }],
    },
    fake.fetch,
  );
  assertEquals(sent, { id: "email_123" });
  const call = fake.calls[0];
  assertEquals(call?.headers.get("authorization"), "Bearer re_key");
  assertEquals(call?.headers.get("content-type"), "application/json");
  assertEquals(call?.headers.get("idempotency-key"), "message-123");
  assertEquals(call?.json, {
    from: "Shop <notifications@example.com>",
    to: ["customer@example.com"],
    subject: "Your invoice",
    text: "Hello",
    html: "<p>Hello</p>",
    reply_to: ["shop@example.com"],
    tags: [{ name: "shop_id", value: "abc-123" }],
  });
});

Deno.test("resend: minimal text-only email omits optional fields", async () => {
  const fake = http();
  await sendEmail("re_key", {
    from: "a@example.com",
    to: ["b@example.com"],
    subject: "s",
    text: "t",
  }, fake.fetch);
  assertEquals(fake.calls[0]?.json, {
    from: "a@example.com",
    to: ["b@example.com"],
    subject: "s",
    text: "t",
  });
  assertEquals(fake.calls[0]?.headers.has("idempotency-key"), false);
});

Deno.test("resend: API errors become ResendError", async () => {
  const fake = new FakeFetch().on(
    "POST",
    RESEND_API_URL,
    () =>
      jsonResponse(
        { statusCode: 422, name: "validation_error", message: "Invalid `from` field." },
        422,
      ),
  );
  const err = await assertRejects(
    () =>
      sendEmail(
        "re_key",
        { from: "a@example.com", to: "b@example.com", subject: "s", text: "t" },
        fake.fetch,
      ),
    ResendError,
  );
  assertEquals(err.httpStatus, 422);
  assertEquals(err.providerCode, "validation_error");
  assertEquals(err.provider, "Resend");
});

Deno.test("resend: rejects invalid input before calling the API", async () => {
  const fake = http();
  const base = { from: "a@example.com", to: "b@example.com", subject: "s", text: "t" };
  await assertRejects(
    () => sendEmail("re_key", { ...base, to: "not-an-email" }, fake.fetch),
    TypeError,
  );
  await assertRejects(() => sendEmail("re_key", { ...base, to: [] }, fake.fetch), TypeError);
  await assertRejects(() => sendEmail("re_key", { ...base, subject: " " }, fake.fetch), TypeError);
  await assertRejects(
    () => sendEmail("re_key", { ...base, text: undefined }, fake.fetch),
    TypeError,
  );
  await assertRejects(
    () => sendEmail("re_key", { ...base, tags: [{ name: "bad tag", value: "x" }] }, fake.fetch),
    TypeError,
  );
  assertEquals(fake.calls.length, 0);
});
