import { assert, assertEquals } from "@std/assert";
import {
  ERROR_STATUS,
  HttpError,
  paymentRequiredReason,
  SUBSCRIPTION_INACTIVE_MESSAGE,
  subscriptionRefusal,
  subscriptionRefusalIn,
} from "./errors.ts";

const INACTIVE = "This shop's subscription is inactive, so new records can't be created right now.";

Deno.test("errors: payment_required is a 402 code of the public contract", () => {
  assertEquals(ERROR_STATUS.payment_required, 402);
  // The database's own sentence (0102 billing_inactive_message).
  assertEquals(SUBSCRIPTION_INACTIVE_MESSAGE, INACTIVE);
});

Deno.test("errors: paymentRequiredReason tells the seat limit from an inactive subscription", () => {
  assertEquals(paymentRequiredReason("This shop's plan allows 5 team members."), "seat_limit");
  assertEquals(paymentRequiredReason("This shop's plan allows 1 team member."), "seat_limit");
  assertEquals(paymentRequiredReason("  This shop's plan allows 12 team members.  "), "seat_limit");
  assertEquals(paymentRequiredReason(INACTIVE), "subscription_inactive");
  assertEquals(paymentRequiredReason(""), "subscription_inactive");
});

Deno.test("errors: a PT402 is 402 payment_required with the database's sentence verbatim", () => {
  const error = { code: "PT402", message: INACTIVE, details: null, hint: null };
  const mapped = subscriptionRefusal(error);
  assert(mapped instanceof HttpError);
  assertEquals([mapped.status, mapped.code, mapped.message], [402, "payment_required", INACTIVE]);
  assertEquals(mapped.details, { reason: "subscription_inactive" });
  assertEquals(mapped.cause, error);

  const seats = subscriptionRefusal({
    code: "PT402",
    message: "This shop's plan allows 3 team members.",
  });
  assertEquals([seats?.status, seats?.code, seats?.message], [
    402,
    "payment_required",
    "This shop's plan allows 3 team members.",
  ]);
  assertEquals(seats?.details, { reason: "seat_limit" });
});

Deno.test("errors: a PT402 without text gets the neutral sentence; whitespace is folded", () => {
  assertEquals(subscriptionRefusal({ code: "PT402" })?.message, INACTIVE);
  assertEquals(subscriptionRefusal({ code: "PT402", message: "   " })?.message, INACTIVE);
  assertEquals(
    subscriptionRefusal({ code: "PT402", message: "This shop's plan allows\n 2 team members. " })
      ?.message,
    "This shop's plan allows 2 team members.",
  );
});

Deno.test("errors: anything but PT402 is not a subscription refusal", () => {
  for (const code of ["P0002", "42501", "22023", "402", "pt402x", undefined, null, 402]) {
    assertEquals(subscriptionRefusal({ code, message: INACTIVE }), null, String(code));
  }
  assertEquals(subscriptionRefusal(null), null);
  assertEquals(subscriptionRefusal(undefined), null);
});

Deno.test("errors: subscriptionRefusalIn finds the innermost PT402 in a cause chain", () => {
  const pg = { code: "PT402", message: "This shop's plan allows 4 team members." };
  const wrapped = new Error("invite_member failed", { cause: pg });
  const twice = new Error("outer", { cause: wrapped });
  const found = subscriptionRefusalIn(twice);
  assertEquals([found?.status, found?.code, found?.message], [402, "payment_required", pg.message]);
  assertEquals(found?.details, { reason: "seat_limit" });
  // The database's own error wins over an outer object that also says PT402.
  const outer = Object.assign(new Error("wrapper"), { code: "PT402", cause: { code: "PT402" } });
  assertEquals(subscriptionRefusalIn(outer)?.message, INACTIVE);
  assertEquals(subscriptionRefusalIn(new Error("x", { cause: { code: "23505" } })), null);
  assertEquals(subscriptionRefusalIn("PT402"), null);
  assertEquals(subscriptionRefusalIn(null), null);
});
