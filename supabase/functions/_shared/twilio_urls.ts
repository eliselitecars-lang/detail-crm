/**
 * The platform's Twilio webhook URLs (messaging function). A shop's number
 * is bound to its shop by the inbound URL configured on it in Twilio (the
 * signed `shop_id` query parameter; see messaging/sender.ts). Shared by the
 * messaging function and sms-provisioning, which configures the numbers it
 * buys.
 *
 * `#rc=3&rp=all` are Twilio connection overrides: Twilio only retries a
 * webhook on connect timeout by default, not on a 5xx, so without them a
 * transient database error would lose an inbound text (or a STOP) for good.
 */
import { functionUrl } from "./links.ts";

/** Twilio connection overrides: retry every failure (incl. 5xx) up to 3 times. */
export const TWILIO_CONNECTION_OVERRIDES = "rc=3&rp=all";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** `url` plus the connection-override fragment. */
export function withConnectionOverrides(url: string): string {
  return `${url}#${TWILIO_CONNECTION_OVERRIDES}`;
}

/** The inbound SMS webhook URL to configure on a shop's number in Twilio. */
export function twilioInboundUrl(functionsPublicUrl: string, shopId: string): string {
  if (!UUID.test(shopId)) throw new TypeError("shop id must be a UUID");
  return withConnectionOverrides(
    functionUrl(functionsPublicUrl, "messaging", { action: "twilio_inbound", shop_id: shopId }),
  );
}

/** The delivery-status webhook (sent with every outbound SMS / Messaging Service). */
export function twilioStatusUrl(functionsPublicUrl: string): string {
  return withConnectionOverrides(
    functionUrl(functionsPublicUrl, "messaging", { action: "twilio_status" }),
  );
}

/** The shop a signed inbound webhook URL was provisioned for (null when absent/invalid). */
export function shopIdFromWebhookUrl(url: string): string | null {
  const value = new URL(url).searchParams.get("shop_id");
  return value !== null && UUID.test(value) ? value.toLowerCase() : null;
}
