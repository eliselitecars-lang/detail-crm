/**
 * Stripe test helpers: sign webhook payloads exactly like Stripe does
 * (`t=<unix>,v1=hex(HMAC-SHA256(secret, "<t>.<payload>"))`) and build events.
 */
import { hmacHex } from "../crypto.ts";

export async function signStripePayload(
  payload: string,
  secret: string,
  timestampSeconds = Math.floor(Date.now() / 1000),
): Promise<string> {
  const signature = await hmacHex("SHA-256", secret, `${timestampSeconds}.${payload}`);
  return `t=${timestampSeconds},v1=${signature}`;
}

export interface StripeEventInput {
  id?: string;
  type: string;
  object: Record<string, unknown>;
  /** Connected account id for Connect events. */
  account?: string;
  created?: number;
  livemode?: boolean;
}

/** A Stripe Event JSON object as delivered to a webhook endpoint. */
export function stripeEvent(input: StripeEventInput): Record<string, unknown> {
  return {
    id: input.id ?? `evt_${crypto.randomUUID().replaceAll("-", "")}`,
    object: "event",
    api_version: "2026-08-26.dahlia",
    created: input.created ?? Math.floor(Date.now() / 1000),
    livemode: input.livemode ?? false,
    pending_webhooks: 1,
    request: { id: null, idempotency_key: null },
    type: input.type,
    ...(input.account ? { account: input.account } : {}),
    data: { object: input.object },
  };
}

/** Stripe API error body (what the SDK turns into StripeError subclasses). */
export function stripeErrorBody(
  type: "card_error" | "invalid_request_error" | "api_error" | "idempotency_error",
  message: string,
  extra: Record<string, unknown> = {},
): Record<string, unknown> {
  return { error: { type, message, ...extra } };
}
