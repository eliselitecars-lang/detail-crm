/** Reusable zod schemas for request validation. */
import { z } from "zod";
import { STRIPE_MAX_AMOUNT_CENTS } from "./money.ts";

export const uuid = z.guid({ message: "must be a UUID" });

/** Positive integer cents within Stripe's limit (client-requested partial amounts). */
export const positiveCents = z.number().int("must be whole cents").positive()
  .max(STRIPE_MAX_AMOUNT_CENTS);

/** Non-negative integer cents (tips). */
export const nonNegativeCents = z.number().int("must be whole cents").min(0)
  .max(STRIPE_MAX_AMOUNT_CENTS);

/** E.164 phone number, e.g. +12055550123. */
export const e164 = z.string().regex(/^\+[1-9]\d{6,14}$/, "must be E.164");

export const email = z.email({ message: "must be an email address" });

/**
 * Public link token (booking/quote/invoice/form/invite links). Every token
 * column and `public_*` RPC parameter is `uuid` (gen_random_uuid()), so a
 * malformed or truncated link fails validation here (400) instead of reaching
 * Postgres and failing the uuid cast (22P02 -> 500).
 */
export const publicToken = z.guid({ message: "must be a link token" });

/** Client-supplied idempotency nonce for user-initiated money actions. */
export const requestNonce = z.string().min(8).max(64).regex(
  /^[A-Za-z0-9_-]+$/,
  "must be 8-64 url-safe characters",
);
