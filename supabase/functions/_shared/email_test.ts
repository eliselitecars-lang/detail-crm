import { assertEquals } from "@std/assert";
import {
  emailAddressOf,
  fromWithDisplayName,
  MAX_DISPLAY_NAME_LENGTH,
  sanitizeDisplayName,
} from "./email.ts";

Deno.test("email: address of named and bare senders", () => {
  assertEquals(emailAddressOf("Detail CRM <notify@example.com>"), "notify@example.com");
  assertEquals(emailAddressOf("  notify@example.com "), "notify@example.com");
  assertEquals(emailAddressOf("not an address"), null);
  assertEquals(emailAddressOf("Name <broken>"), null);
});

Deno.test("email: display names are sanitized", () => {
  assertEquals(sanitizeDisplayName('  Joe\'s "Best"\r\n<Detailing>\\ '), "Joe's Best Detailing");
  assertEquals(sanitizeDisplayName("\u0000\u0007"), "");
  assertEquals(sanitizeDisplayName("x".repeat(200)).length, MAX_DISPLAY_NAME_LENGTH);
});

Deno.test("email: from header carries the shop name", () => {
  const from = "Detail CRM <notify@example.com>";
  assertEquals(
    fromWithDisplayName(from, "Eli's Elite Detailing"),
    "Eli's Elite Detailing <notify@example.com>",
  );
  assertEquals(
    fromWithDisplayName(from, "Joe's Detailing, LLC"),
    '"Joe\'s Detailing, LLC" <notify@example.com>',
  );
  assertEquals(fromWithDisplayName("notify@example.com", "Shine"), "Shine <notify@example.com>");
  // Header injection attempts cannot break out of the display name.
  assertEquals(
    fromWithDisplayName(from, 'Evil"\r\nBcc: x@evil.test <a@b.c>'),
    '"Evil Bcc: x@evil.test a@b.c" <notify@example.com>',
  );
  assertEquals(fromWithDisplayName(from, "   "), from);
  assertEquals(fromWithDisplayName(from, null), from);
  assertEquals(fromWithDisplayName("garbage", "Shop"), "garbage");
});
