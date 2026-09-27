/**
 * Money is always integer cents (SPEC §4.5); rates are basis points. These
 * helpers never use floating point for arithmetic, and round half away from
 * zero exactly like Postgres `round(numeric)`, so edge functions and SQL
 * always agree to the cent.
 */

/** Stripe's maximum charge for USD (and most 2-decimal currencies): $999,999.99. */
export const STRIPE_MAX_AMOUNT_CENTS = 99_999_999;

/** Stripe's minimum charge for USD: $0.50. */
export const STRIPE_MIN_AMOUNT_CENTS_USD = 50;

export function isCents(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value);
}

/** Throws a TypeError unless `value` is a safe integer (optionally ≥ 0). */
export function assertCents(
  value: unknown,
  label = "amount",
  { allowNegative = false } = {},
): number {
  if (!isCents(value)) throw new TypeError(`${label} must be an integer number of cents`);
  if (!allowNegative && value < 0) throw new RangeError(`${label} must not be negative`);
  return value;
}

/** Integer division rounding half away from zero (Postgres numeric semantics). */
export function divRoundHalfUp(numerator: bigint, denominator: bigint): bigint {
  if (denominator === 0n) throw new RangeError("division by zero");
  const negative = (numerator < 0n) !== (denominator < 0n);
  const n = numerator < 0n ? -numerator : numerator;
  const d = denominator < 0n ? -denominator : denominator;
  let quotient = n / d;
  if ((n % d) * 2n >= d) quotient += 1n;
  return negative ? -quotient : quotient;
}

/** round_half_up(amount × bps / 10000) — tax, fees, percent deposits. */
export function bpsOf(amountCents: number, bps: number): number {
  assertCents(amountCents, "amountCents", { allowNegative: true });
  if (!Number.isSafeInteger(bps) || bps < 0) {
    throw new RangeError("bps must be a non-negative integer");
  }
  return Number(divRoundHalfUp(BigInt(amountCents) * BigInt(bps), 10_000n));
}

/** Platform application fee for a charge; 0 when no fee is configured. */
export function applicationFeeCents(amountCents: number, feeBps: number): number {
  if (feeBps > 10_000) throw new RangeError("feeBps must be at most 10000");
  return bpsOf(assertCents(amountCents, "amountCents"), feeBps);
}

export function sumCents(values: Iterable<number>): number {
  let total = 0;
  for (const value of values) {
    total += assertCents(value, "value", { allowNegative: true });
    if (!Number.isSafeInteger(total)) throw new RangeError("sum exceeds safe integer range");
  }
  return total;
}

export function clampCents(value: number, min: number, max: number): number {
  assertCents(value, "value", { allowNegative: true });
  if (min > max) throw new RangeError("min must not exceed max");
  return Math.min(Math.max(value, min), max);
}

/**
 * Validates an amount before sending it to Stripe: positive integer cents,
 * within Stripe's limits. Returns the amount unchanged.
 */
export function assertChargeableCents(amountCents: number, currency = "usd"): number {
  assertCents(amountCents, "amountCents");
  if (amountCents <= 0) throw new RangeError("amount must be positive");
  if (currency.toLowerCase() === "usd" && amountCents < STRIPE_MIN_AMOUNT_CENTS_USD) {
    throw new RangeError(`amount must be at least ${STRIPE_MIN_AMOUNT_CENTS_USD} cents`);
  }
  if (amountCents > STRIPE_MAX_AMOUNT_CENTS) throw new RangeError("amount exceeds Stripe maximum");
  return amountCents;
}

const formatters = new Map<string, Intl.NumberFormat>();

/** 123456 → "$1,234.56" (for SMS/email copy; the UI formats on its own side). */
export function formatCents(cents: number, currency = "usd", locale = "en-US"): string {
  assertCents(cents, "cents", { allowNegative: true });
  const key = `${locale}|${currency}`;
  let formatter = formatters.get(key);
  if (!formatter) {
    formatter = new Intl.NumberFormat(locale, {
      style: "currency",
      currency: currency.toUpperCase(),
    });
    formatters.set(key, formatter);
  }
  const digits = formatter.resolvedOptions().maximumFractionDigits ?? 2;
  return formatter.format(cents / 10 ** digits);
}
