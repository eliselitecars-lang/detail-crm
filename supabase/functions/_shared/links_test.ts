import { assertEquals, assertThrows } from "@std/assert";
import { functionUrl, links, publicRequestUrl } from "./links.ts";

Deno.test("links: customer-facing web routes", () => {
  const base = "https://app.example.com/";
  assertEquals(links.booking(base, "tok"), "https://app.example.com/booking/tok");
  assertEquals(links.quote(base, "tok"), "https://app.example.com/q/tok");
  assertEquals(links.invoice(base, "tok"), "https://app.example.com/i/tok");
  assertEquals(links.form(base, "tok"), "https://app.example.com/f/tok");
  assertEquals(links.invite(base, "tok"), "https://app.example.com/invite/tok");
  assertEquals(links.bookingPage(base, "eli-detail"), "https://app.example.com/book/eli-detail");
  assertEquals(links.portal("https://x.example.com/crm"), "https://x.example.com/crm/portal");
  assertEquals(links.quote(base, "a/b?c"), "https://app.example.com/q/a%2Fb%3Fc");
  assertThrows(() => links.quote(base, ""), TypeError);
});

Deno.test("links: functionUrl", () => {
  const base = "https://p.supabase.co/functions/v1/";
  assertEquals(
    functionUrl(base, "stripe-webhook"),
    "https://p.supabase.co/functions/v1/stripe-webhook",
  );
  assertEquals(
    functionUrl(base, "messaging", { action: "twilio_inbound" }),
    "https://p.supabase.co/functions/v1/messaging?action=twilio_inbound",
  );
  assertThrows(() => functionUrl(base, "../x"), TypeError);
});

Deno.test("links: publicRequestUrl keeps the query verbatim and swaps the host", () => {
  const req = new Request("http://internal:9000/messaging?b=2&action=twilio_inbound&a=1");
  assertEquals(
    publicRequestUrl("https://p.supabase.co/functions/v1", "messaging", req),
    "https://p.supabase.co/functions/v1/messaging?b=2&action=twilio_inbound&a=1",
  );
});
