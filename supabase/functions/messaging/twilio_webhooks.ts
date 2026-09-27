/**
 * Twilio webhooks (PUBLIC; authenticated only by X-Twilio-Signature).
 *
 * The signature covers the exact URL Twilio called, so it is validated
 * against the PUBLIC function URL, never `req.url` (which can carry an
 * internal host). Configure on EACH shop's number in the Twilio Console (the
 * number's A2P Messaging Service must be set to "Defer to sender's webhook";
 * see supabase/setup/twilio.md):
 *
 *   A message comes in (HTTP POST):
 *     https://<PROJECT_REF>.supabase.co/functions/v1/messaging?action=twilio_inbound&shop_id=<SHOP UUID>#rc=3&rp=all
 *   Status callback: sent automatically with every outbound SMS:
 *     https://<PROJECT_REF>.supabase.co/functions/v1/messaging?action=twilio_status#rc=3&rp=all
 *
 * `shop_id` is the platform's binding of the number to its shop (sender.ts):
 * an inbound text is only recorded when it matches the shop the `To` number
 * is bound to in shop_sms_numbers (0033), whether or not that shop currently
 * sends from it (shops.sms_from_number may be cleared to pause texting; the
 * replies and STOPs to the number must still land). `#rc=3&rp=all` makes Twilio retry a 5xx
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
import { classifyOptKeyword, emptyTwiml, validateTwilioSignature } from "../_shared/twilio.ts";
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
 * customer, applies STOP/START opt-out keywords, notifies staff; YES is
 * applied here, see applyMissedOptIn). Always
 * answers with empty TwiML: carrier-level opt-out replies come from Twilio
 * (Advanced Opt-Out), so we never auto-reply.
 */
export async function twilioInbound(svc: Services, req: Request): Promise<Response> {
  const form = await verifiedTwilioForm(svc, req);
  const to = form.get("To") ?? "";
  const from = form.get("From") ?? "";
  const body = form.get("Body") ?? "";
  const sid = form.get("MessageSid") ?? form.get("SmsSid") ?? null;

  // Route only through the platform's binding of `To` to its shop
  // (shop_sms_numbers), never the tenant-editable sms_from_number, and only
  // when the signed URL's shop_id is that shop. A shop that cleared its
  // sending number still gets the replies and STOPs sent to its number.
  const boundShop = shopIdFromWebhookUrl(req.url);
  const { data: binding, error: bindingError } = await svc.admin.from("shop_sms_numbers")
    .select("shop_id").eq("phone_number", to).maybeSingle();
  if (bindingError) throw new DbError("shop_sms_numbers lookup", bindingError);
  const shopId = (binding as { shop_id: string } | null)?.shop_id ?? null;
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
    // The number was re-bound between the check and the insert.
    svc.log.error("inbound_sms_routing_changed", {
      message_id: row.message_id,
      shop_id: row.shop_id,
      webhook_shop_id: boundShop,
    });
  } else {
    const optAction = row.opt_action ??
      (await applyMissedOptIn(svc, shopId, from, body, row.message_id));
    svc.log.info("inbound_sms_recorded", {
      message_id: row.message_id,
      shop_id: row.shop_id,
      matched_customer: row.customer_id !== null,
      opt_action: optAction,
    });
  }
  return emptyTwiml();
}

/**
 * The keyword as record_inbound_sms reads it (0033): trimmed, trailing
 * whitespace/punctuation dropped, upper-cased.
 */
export function smsKeyword(body: string): string {
  return body.trim().replace(/[\s\p{P}\p{S}]+$/u, "").toUpperCase();
}

/**
 * Twilio's default opt-in keywords are START, YES and UNSTOP; on any of them
 * Twilio lifts its own block on the number. record_inbound_sms (0033) only
 * honours START and UNSTOP, so a customer who replied YES would be texting-
 * enabled at Twilio but stay opted out here for good (staff cannot clear an
 * SMS opt-out). When the database did not act on an opt-in keyword, apply
 * the same opt-in it applies for START: comms_unsuppress(shop, 'sms', from)
 * (drops the suppression and clears sms_opted_out_at for the shop's
 * customers with that number; marketing consent sms_opt_in is NOT restored,
 * exactly like START).
 *
 * Only for the newest inbound text from that number to the shop, so a late
 * Twilio retry of an old YES never undoes a STOP sent after it. A database
 * error answers 500 and Twilio redelivers (the replay is idempotent).
 */
async function applyMissedOptIn(
  svc: Services,
  shopId: string,
  from: string,
  body: string,
  messageId: string,
): Promise<string | null> {
  if (classifyOptKeyword(smsKeyword(body)) !== "opt_in") return null;
  const { data: latest, error } = await svc.admin.from("messages")
    .select("id")
    .eq("shop_id", shopId).eq("direction", "inbound").eq("channel", "sms")
    .eq("from_address", from)
    .order("created_at", { ascending: false }).order("id", { ascending: false })
    .limit(1);
  if (error) throw new DbError("messages lookup", error);
  const newest = Array.isArray(latest) ? (latest[0] as { id?: unknown } | undefined) : undefined;
  if (newest?.id !== messageId) {
    svc.log.info("sms_opt_in_skipped", { message_id: messageId, reason: "newer_inbound_text" });
    return null;
  }
  const { error: unsuppressError } = await svc.admin.rpc("comms_unsuppress", {
    p_shop_id: shopId,
    p_channel: "sms",
    p_address: from,
  });
  if (unsuppressError) throw new DbError("comms_unsuppress", unsuppressError);
  return "opt_in";
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
