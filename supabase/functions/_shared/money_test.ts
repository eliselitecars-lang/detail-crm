import { assertEquals, assertThrows } from "@std/assert";
import {
  applicationFeeCents,
  assertCents,
  assertChargeableCents,
  bpsOf,
  clampCents,
  divRoundHalfUp,
  formatCents,
  isCents,
  STRIPE_MAX_AMOUNT_CENTS,
  sumCents,
} from "./money.ts";

Deno.test("money: isCents / assertCents", () => {
  assertEquals(isCents(100), true);
  assertEquals(isCents(1.5), false);
  assertEquals(isCents("100"), false);
  assertEquals(isCents(Number.MAX_SAFE_INTEGER + 1), false);
  assertThrows(() => assertCents(-1), RangeError);
  assertEquals(assertCents(-1, "x", { allowNegative: true }), -1);
  assertThrows(() => assertCents(0.1), TypeError);
});

Deno.test("money: rounding is half away from zero like Postgres round(numeric)", () => {
  assertEquals(divRoundHalfUp(5n, 10n), 1n);
  assertEquals(divRoundHalfUp(4n, 10n), 0n);
  assertEquals(divRoundHalfUp(-5n, 10n), -1n);
  assertEquals(divRoundHalfUp(15n, 10n), 2n);
  assertEquals(divRoundHalfUp(25n, 10n), 3n);
  assertThrows(() => divRoundHalfUp(1n, 0n), RangeError);
});

Deno.test("money: bpsOf (tax / fees / percent deposits)", () => {
  assertEquals(bpsOf(10_000, 1000), 1000); // 10% of $100
  assertEquals(bpsOf(1999, 925), 185); // 184.9075 -> 185
  assertEquals(bpsOf(250, 200), 5);
  assertEquals(bpsOf(25, 200), 1); // 0.5 -> 1 (half up)
  assertEquals(bpsOf(24, 200), 0); // 0.48 -> 0
  assertEquals(bpsOf(-25, 200), -1);
  assertEquals(bpsOf(0, 5000), 0);
  // No float error at large magnitudes.
  assertEquals(bpsOf(9_007_199_254_740_991, 10_000), 9_007_199_254_740_991);
  assertThrows(() => bpsOf(100, -1), RangeError);
  assertThrows(() => bpsOf(100, 1.5), RangeError);
});

Deno.test("money: applicationFeeCents", () => {
  assertEquals(applicationFeeCents(5000, 0), 0);
  assertEquals(applicationFeeCents(5000, 290), 145);
  assertThrows(() => applicationFeeCents(5000, 10_001), RangeError);
  assertThrows(() => applicationFeeCents(-1, 100), RangeError);
});

Deno.test("money: sumCents / clampCents", () => {
  assertEquals(sumCents([100, 250, -50]), 300);
  assertEquals(sumCents([]), 0);
  assertThrows(() => sumCents([1.5]), TypeError);
  assertThrows(() => sumCents([Number.MAX_SAFE_INTEGER, 1]), RangeError);
  assertEquals(clampCents(500, 0, 300), 300);
  assertEquals(clampCents(-5, 0, 300), 0);
  assertThrows(() => clampCents(1, 5, 0), RangeError);
});

Deno.test("money: assertChargeableCents enforces Stripe limits", () => {
  assertEquals(assertChargeableCents(50), 50);
  assertThrows(() => assertChargeableCents(49), RangeError, "at least 50");
  assertThrows(() => assertChargeableCents(0), RangeError, "positive");
  assertThrows(() => assertChargeableCents(STRIPE_MAX_AMOUNT_CENTS + 1), RangeError);
  assertEquals(assertChargeableCents(STRIPE_MAX_AMOUNT_CENTS), STRIPE_MAX_AMOUNT_CENTS);
});

Deno.test("money: formatCents", () => {
  assertEquals(formatCents(123456), "$1,234.56");
  assertEquals(formatCents(5), "$0.05");
  assertEquals(formatCents(-500), "-$5.00");
  assertEquals(formatCents(1000, "jpy"), "¥1,000");
});
