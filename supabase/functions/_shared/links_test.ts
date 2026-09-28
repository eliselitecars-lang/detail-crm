import { assertEquals, assertThrows } from "@std/assert";
import { functionUrl, links, publicRequestUrl, withQuery } from "./links.ts";

Deno.test("links: customer-facing web routes", () => {
  const base = "https://app.example.com/";
  assertEquals(links.booking(base, "tok"), "https://app.example.com/booking/tok");
  assertEquals(links.quote(base, "tok"), "https://app.example.com/q/tok");
  assertEquals(links.invoice(base, "tok"), "https://app.example.com/i/tok");
  assertEquals(links.form(base, "tok"), "https://app.example.com/f/tok");
  assertEquals(links.invite(base, "tok"), "https://app.example.com/invite/tok");
  assertEquals(links.bookingPage(base, "eli-detail"), "https://app.example.com/book/eli-detail");
  assertEquals(links.portal("https://x.example.com/crm"), "https://x.example.com/crm/portal");
  assertEquals(links.checkoutDone(base, "shine-co"), "https://app.example.com/done/shine-co");
  assertThrows(() => links.checkoutDone(base, ""), TypeError);
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

Deno.test("links: Stripe Connect return/refresh pages", () => {
  assertEquals(
    links.stripeConnect("https://app.example.com/", "return"),
    "https://app.example.com/app/settings/payments?stripe=return",
  );
  assertEquals(
    links.stripeConnect("https://x.example.com/crm", "refresh"),
    "https://x.example.com/crm/app/settings/payments?stripe=refresh",
  );
});

Deno.test("links: withQuery adds or replaces parameters", () => {
  assertEquals(
    withQuery(links.invoice("https://app.example.com", "tok"), { paid: "1" }),
    "https://app.example.com/i/tok?paid=1",
  );
  assertEquals(
    withQuery("https://app.example.com/portal?card=x&a=1", { card: "saved" }),
    "https://app.example.com/portal?card=saved&a=1",
  );
  assertThrows(() => withQuery("not a url", { a: "1" }), TypeError);
});
