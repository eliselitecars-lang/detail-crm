/**
 * Twilio webhooks (PUBLIC; authenticated only by X-Twilio-Signature).
 *
 * The signature covers the exact URL Twilio called, so it is validated
 * against the PUBLIC function URL, never `req.url` (which can carry an
 * internal host). Configure on EACH shop's number in the Twilio Console
 * (not on a Messaging Service; see supabase/setup/twilio.md):
 *
 *   A message comes in (HTTP POST):
 *     https://<PROJECT_REF>.supabase.co/functions/v1/messaging?action=twilio_inbound&shop_id=<SHOP UUID>#rc=3&rp=all
 *   Status callback: sent automatically with every outbound SMS:
 *     https://<PROJECT_REF>.supabase.co/functions/v1/messaging?action=twilio_status#rc=3&rp=all
 *
 * `shop_id` is the platform's binding of the number to its shop (sender.ts):
 * an inbound text is only recorded when it matches the shop whose
 * sms_from_number is the `To` number. `#rc=3&rp=all` makes Twilio retry a 5xx
 * (by default it retries only connect timeouts), so a transient database
 * error answers 500 and the webhook is redelivered; both handlers are
 * idempotent (per MessageSid / forward-only status).
 *
 * The base is FUNCTIONS_PUBLIC_URL when set (e.g. a tunnel in local dev),
 * otherwise `${SUPABASE_URL}/functions/v1`.
 */
import { HttpError } from "../_shared/errors.ts";
import { readForm } from "../_shared/http.ts";
import { publicRequestUrl } from "../_shared/links.ts";
import { emptyTwiml, validateTwilioSignature } from "../_shared/twilio.ts";
import { DbError, errorText, type Services } from "./lib.ts";
import { recordSmsOptOut, TWILIO_UNSUBSCRIBED } from "./optout.ts";
import { shopIdFromWebhookUrl, withConnectionOverrides } from "./sender.ts";

/** Twilio form posts are a few KB; anything larger is not Twilio. */
export const MAX_TWILIO_FORM_BYTES = 64 * 1024;

/** Reads the form and verifies X-Twilio-Signature; `invalid_signature` (400) otherwise. */
export async function verifiedTwilioForm(svc: Services, req: Request): Promise<URLSearchParams> {
  const form = await readForm(req, { maxBytes: MAX_TWILIO_FORM_BYTES });
  const { authToken } = svc.env.twilio();
  const url = publicRequestUrl(svc.env.functionsPublicUrl(), "messaging", req);
  const signature = req.headers.get("x-twilio-signature");
  // The configured URL carries the connection-override fragment, which the
  // request itself never shows: accept a signature over either form.
  let valid = false;
  for (const candidate of [url, withConnectionOverrides(url)]) {
    if (await validateTwilioSignature(authToken, signature, candidate, form)) valid = true;
  }
  if (!valid) {
    throw new HttpError("invalid_signature", "The Twilio signature is missing or invalid.");
  }
  return form;
}

interface InboundRow {
  message_id: string | null;
  shop_id: string | null;
  customer_id: string | null;
  opt_action: string | null;
}

/**
 * Inbound SMS -> record_inbound_sms (routes by To to the shop, by From to the
 * customer, applies STOP/START opt-out keywords, notifies staff). Always
 * answers with empty TwiML: carrier-level opt-out replies come from Twilio
 * (Advanced Opt-Out), so we never auto-reply.
 */
export async function twilioInbound(svc: Services, req: Request): Promise<Response> {
  const form = await verifiedTwilioForm(svc, req);
  const to = form.get("To") ?? "";
  const from = form.get("From") ?? "";
  const body = form.get("Body") ?? "";
  const sid = form.get("MessageSid") ?? form.get("SmsSid") ?? null;

  // Route only through a number the platform bound to its shop: the signed
  // URL's shop_id must be the shop whose (tenant-editable) sms_from_number
  // is `To`. Otherwise a tenant that typed in someone else's number would
  // receive that number's replies and opt-outs.
  const boundShop = shopIdFromWebhookUrl(req.url);
  const { data: shop, error: shopError } = await svc.admin.from("shops")
    .select("id").eq("sms_from_number", to).maybeSingle();
  if (shopError) throw new DbError("shops lookup", shopError);
  const shopId = (shop as { id: string } | null)?.id ?? null;
  if (shopId === null) {
    svc.log.warn("inbound_sms_ignored", { reason: "unknown_number", message_sid: sid });
    return emptyTwiml();
  }
  if (boundShop === null || boundShop !== shopId.toLowerCase()) {
    svc.log.error("inbound_sms_ignored", {
      reason: "number_not_provisioned",
      message_sid: sid,
      shop_id: shopId,
      webhook_shop_id: boundShop,
    });
    return emptyTwiml();
  }

  const { data, error } = await svc.admin.rpc("record_inbound_sms", {
    p_to: to,
    p_from: from,
    p_body: body,
    p_provider_id: sid,
  });
  if (error) {
    if (error.code === "22023") {
      // Not an E.164 sender (short code / alphanumeric): nothing to route.
      // Acknowledge so Twilio does not retry.
      svc.log.warn("inbound_sms_ignored", { reason: "invalid_address", message_sid: sid });
      return emptyTwiml();
    }
    // 500 -> Twilio retries (the #rc/rp connection overrides on the
    // configured URL); record_inbound_sms is idempotent per MessageSid.
    throw new DbError("record_inbound_sms", error);
  }
  const row = (Array.isArray(data) ? data[0] : data) as InboundRow | undefined;
  if (!row?.message_id) {
    svc.log.warn("inbound_sms_ignored", { reason: "unknown_number", message_sid: sid });
  } else if (row.shop_id !== shopId) {
    // sms_from_number changed between the check and the insert.
    svc.log.error("inbound_sms_routing_changed", {
      message_id: row.message_id,
      shop_id: row.shop_id,
      webhook_shop_id: boundShop,
    });
  } else {
    svc.log.info("inbound_sms_recorded", {
      message_id: row.message_id,
      shop_id: row.shop_id,
      matched_customer: row.customer_id !== null,
      opt_action: row.opt_action,
    });
  }
  return emptyTwiml();
}

/** Twilio MessageStatus -> our status (others are intermediate and ignored). */
export function mapTwilioStatus(status: string): "sent" | "delivered" | "failed" | null {
  switch (status) {
    case "sent":
      return "sent";
    case "delivered":
    case "read":
      return "delivered";
    case "undelivered":
    case "failed":
      return "failed";
    default:
      return null;
  }
}

/** Delivery status callback -> update_message_status_by_provider_id. */
export async function twilioStatus(svc: Services, req: Request): Promise<Response> {
  const form = await verifiedTwilioForm(svc, req);
  const sid = form.get("MessageSid") ?? form.get("SmsSid") ?? "";
  const twilioStatus = form.get("MessageStatus") ?? form.get("SmsStatus") ?? "";
  const status = mapTwilioStatus(twilioStatus);
  if (!sid || !status) {
    svc.log.info("twilio_status_ignored", {
      message_sid: sid || null,
      twilio_status: twilioStatus,
    });
    return emptyTwiml();
  }
  const code = form.get("ErrorCode");
  const detail = form.get("ErrorMessage");
  const errorMessage = status === "failed"
    ? errorText(
      `Twilio${code ? ` ${code}` : ""}: ${detail?.trim() ? detail : `message ${twilioStatus}`}`,
    )
    : null;
  const { data, error } = await svc.admin.rpc("update_message_status_by_provider_id", {
    p_provider_id: sid,
    p_status: status,
    p_error: errorMessage,
  });
  if (error) throw new DbError("update_message_status_by_provider_id", error);
  const messageId = typeof data === "string" ? data : null;
  svc.log.info("twilio_status_recorded", { message_sid: sid, status, message_id: messageId });
  if (status === "failed" && code === TWILIO_UNSUBSCRIBED && messageId) {
    await recordOptOutForMessage(svc, messageId);
  }
  return emptyTwiml();
}

/** Twilio reported 21610 (unsubscribed) for one of our texts: record the opt-out. */
async function recordOptOutForMessage(svc: Services, messageId: string): Promise<void> {
  const { data, error } = await svc.admin.from("messages")
    .select("shop_id, to_address, channel, direction").eq("id", messageId).maybeSingle();
  if (error) throw new DbError("messages lookup", error);
  const msg = data as
    | { shop_id: string; to_address: string; channel: string; direction: string }
    | null;
  if (!msg || msg.channel !== "sms" || msg.direction !== "outbound") return;
  await recordSmsOptOut(svc, msg.shop_id, msg.to_address);
}
