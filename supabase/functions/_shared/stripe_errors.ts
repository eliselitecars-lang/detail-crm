/**
 * Maps Stripe SDK errors to client-safe HttpErrors. Duck-typed on the SDK's
 * `type` discriminator so the generic handler can use it without importing
 * (and loading) the Stripe SDK in functions that never talk to Stripe.
 */
import { HttpError } from "./errors.ts";

export interface StripeLikeError {
  type: string;
  message?: string;
  code?: string;
  decline_code?: string;
  statusCode?: number;
  requestId?: string;
}

export function isStripeError(err: unknown): err is StripeLikeError {
  if (typeof err !== "object" || err === null) return false;
  const type = (err as { type?: unknown }).type;
  return typeof type === "string" && /^Stripe[A-Za-z]*Error$/.test(type);
}

const GENERIC_DECLINE = "The card was declined.";

export function stripeErrorToHttpError(err: StripeLikeError): HttpError {
  switch (err.type) {
    case "StripeCardError":
      // Card-error messages are written by Stripe for end users
      // ("Your card has insufficient funds.") and are safe to show.
      return new HttpError("payment_failed", err.message || GENERIC_DECLINE, {
        details: {
          stripe_code: err.code ?? null,
          decline_code: err.decline_code ?? null,
        },
        cause: err,
      });
    case "StripeIdempotencyError":
      return new HttpError(
        "conflict",
        "This payment request conflicts with an earlier one. Refresh and try again.",
        { cause: err },
      );
    case "StripeRateLimitError":
      return new HttpError(
        "service_unavailable",
        "The payment provider is busy. Try again in a moment.",
        { cause: err, headers: { "Retry-After": "2" } },
      );
    case "StripeConnectionError":
    case "StripeAPIError":
      return new HttpError(
        "service_unavailable",
        "The payment provider is unavailable. Try again in a moment.",
        { cause: err },
      );
    default:
      // Invalid request / authentication / permission / signature errors are
      // our bugs or misconfiguration: generic message, details only in logs.
      return new HttpError("upstream_error", "The payment provider rejected the request.", {
        cause: err,
      });
  }
}
