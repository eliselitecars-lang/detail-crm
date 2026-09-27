/** Identifier helpers. */

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const REQUEST_ID_RE = /^[A-Za-z0-9_-]{8,64}$/;

export function isUuid(value: unknown): value is string {
  return typeof value === "string" && UUID_RE.test(value);
}

/**
 * Request id for log correlation: reuse a well-formed inbound `x-request-id`
 * (so web/iOS logs can be joined to function logs), otherwise mint one.
 */
export function requestIdFor(req: Request): string {
  const inbound = req.headers.get("x-request-id");
  return inbound && REQUEST_ID_RE.test(inbound) ? inbound : crypto.randomUUID();
}

const STRIPE_ACCOUNT_RE = /^acct_[A-Za-z0-9]{6,}$/;

export function isStripeAccountId(value: unknown): value is string {
  return typeof value === "string" && STRIPE_ACCOUNT_RE.test(value);
}
