/**
 * Outbound webhook signatures (the `webhooks` function), Stripe-style:
 *
 *   X-DetailCRM-Signature: t=<unix seconds>,v1=<hex HMAC-SHA256>
 *
 * where the HMAC key is the endpoint's whole secret string (UTF-8, including
 * its "whsec_" prefix) and the signed message is `${t}.${raw request body}`.
 * Receivers recompute it over the exact bytes they received, compare in
 * constant time and reject timestamps outside their tolerance (5 minutes is
 * a good default) to stop replays. `verifySignatureHeader` is the reference
 * implementation documented in supabase/functions/README.md.
 */
import { hmacHex, timingSafeEqual } from "./crypto.ts";

export const SIGNATURE_HEADER = "X-DetailCRM-Signature";
export const DEFAULT_TOLERANCE_SECONDS = 300;

/** Hex HMAC-SHA256(secret, `${timestamp}.${body}`). */
export function computeSignature(
  secret: string,
  timestamp: number,
  body: string,
): Promise<string> {
  if (!Number.isInteger(timestamp) || timestamp < 0) {
    throw new RangeError("timestamp must be whole unix seconds");
  }
  return hmacHex("SHA-256", secret, `${timestamp}.${body}`);
}

/** The X-DetailCRM-Signature header value. */
export async function signatureHeader(
  secret: string,
  timestamp: number,
  body: string,
): Promise<string> {
  return `t=${timestamp},v1=${await computeSignature(secret, timestamp, body)}`;
}

export interface VerifyOptions {
  toleranceSeconds?: number;
  /** Current unix seconds (tests). */
  now?: number;
}

/**
 * True when `header` carries a v1 signature of `body` by `secret` whose
 * timestamp is within the tolerance. Several v1 entries are allowed (any
 * may match), so a receiver keeps working while a secret is rotated.
 */
export async function verifySignatureHeader(
  secret: string,
  header: string | null,
  body: string,
  options: VerifyOptions = {},
): Promise<boolean> {
  if (!header) return false;
  let timestamp: number | null = null;
  const signatures: string[] = [];
  for (const part of header.split(",")) {
    const [key, value] = part.trim().split("=", 2);
    if (key === "t" && value && /^\d{1,12}$/.test(value)) timestamp = Number(value);
    else if (key === "v1" && value && /^[0-9a-f]{64}$/.test(value)) signatures.push(value);
  }
  if (timestamp === null || signatures.length === 0) return false;
  const now = options.now ?? Math.floor(Date.now() / 1000);
  const tolerance = options.toleranceSeconds ?? DEFAULT_TOLERANCE_SECONDS;
  if (Math.abs(now - timestamp) > tolerance) return false;
  const expected = await computeSignature(secret, timestamp, body);
  let ok = false;
  for (const candidate of signatures) ok = timingSafeEqual(candidate, expected) || ok;
  return ok;
}
