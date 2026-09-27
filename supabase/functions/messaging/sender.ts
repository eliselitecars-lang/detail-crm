/**
 * Which shop may send from (and receive on) which Twilio number.
 *
 * Every shop shares the platform Twilio account, and `shops.sms_from_number`
 * is writable by any shop owner/admin (settings page). That column alone is
 * therefore NOT proof that the number belongs to the shop: a tenant could
 * type in a platform number provisioned for someone else and both send from
 * it and receive its replies/STOPs. The binding the platform controls is the
 * number's own inbound webhook in Twilio, which only the platform operator
 * can set when provisioning a number for a shop:
 *
 *   A message comes in (HTTP POST):
 *     <FUNCTIONS_PUBLIC_URL>/messaging?action=twilio_inbound&shop_id=<SHOP UUID>#rc=3&rp=all
 *
 * (see supabase/setup/twilio.md). US numbers must also be in a Messaging
 * Service with an approved A2P 10DLC campaign (carriers block unregistered
 * 10DLC traffic, error 30034): ONE SERVICE PER SHOP, under the shop's own
 * brand and campaign, never shared between shops (Twilio applies STOP per
 * service, so a shared one would let a STOP to one shop block every shop and
 * make 21610 record opt-outs in shops the customer never left; optout.ts).
 * The service is set to "Defer to sender's webhook", so the number keeps
 * this per-number SmsUrl. Before sending we look the `From` number
 * up in the account (IncomingPhoneNumbers) and require that its SmsUrl points
 * at this function with this message's shop_id; inbound webhooks carry the
 * same shop_id inside the signed URL and are only routed when it matches the
 * shop the `To` number is bound to in shop_sms_numbers (whether or not that
 * shop currently sends from it).
 *
 * `#rc=3&rp=all` are Twilio connection overrides: Twilio only retries a
 * webhook on connect timeout by default, not on a 5xx, so without them a
 * transient database error would lose an inbound text (or a STOP) for good.
 * The fragment is part of the URL configured in Twilio, so signatures are
 * checked against the URL both with and without it.
 */
import { functionUrl } from "../_shared/links.ts";
import { basicAuth, TWILIO_API_BASE, TwilioError } from "../_shared/twilio.ts";
import { errorText, type Services } from "./lib.ts";

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

/** The shop a signed inbound webhook URL was provisioned for (null when absent/invalid). */
export function shopIdFromWebhookUrl(url: string): string | null {
  const value = new URL(url).searchParams.get("shop_id");
  return value !== null && UUID.test(value) ? value.toLowerCase() : null;
}

export type SenderCheck =
  | { ok: true }
  /** retry: a transient lookup problem (the text was not sent; try again later). */
  | { ok: false; retry: boolean; reason: string };

export const NOT_PROVISIONED =
  "this shop's text number is not provisioned for it on the platform; contact support";

interface IncomingNumber {
  phone_number?: unknown;
  sms_url?: unknown;
}

/** Does `smsUrl` route this number's inbound texts to our messaging function for `shopId`? */
export function isBoundToShop(
  smsUrl: unknown,
  functionsPublicUrl: string,
  shopId: string,
): boolean {
  if (typeof smsUrl !== "string" || smsUrl === "") return false;
  let url: URL;
  try {
    url = new URL(smsUrl);
  } catch {
    return false;
  }
  const endpoint = `${url.origin}${url.pathname}`.replace(/\/+$/, "");
  return endpoint === functionUrl(functionsPublicUrl, "messaging") &&
    url.searchParams.get("action") === "twilio_inbound" &&
    shopIdFromWebhookUrl(url.href) === shopId.toLowerCase();
}

async function lookupSender(svc: Services, shopId: string, from: string): Promise<SenderCheck> {
  const { accountSid, authToken } = svc.env.twilio();
  const url = `${TWILIO_API_BASE}/Accounts/${encodeURIComponent(accountSid)}` +
    `/IncomingPhoneNumbers.json?PhoneNumber=${encodeURIComponent(from)}&PageSize=20`;
  let response: Response;
  try {
    response = await svc.fetch(url, {
      method: "GET",
      headers: { Authorization: basicAuth(accountSid, authToken), Accept: "application/json" },
    });
  } catch (cause) {
    svc.log.warn("sms_sender_lookup_failed", { shop_id: shopId, error: cause });
    return { ok: false, retry: true, reason: "the SMS provider could not be reached" };
  }
  const payload = await response.json().catch(() => null) as
    | { incoming_phone_numbers?: unknown; code?: unknown; message?: unknown }
    | null;
  if (!response.ok) {
    const code = payload?.code;
    const error = new TwilioError(
      typeof payload?.message === "string" ? payload.message : `HTTP ${response.status}`,
      {
        httpStatus: response.status,
        providerCode: typeof code === "number" || typeof code === "string" ? String(code) : null,
      },
    );
    svc.log.warn("sms_sender_lookup_failed", { shop_id: shopId, error });
    // Credentials/permissions (401/403), throttling and outages are fixable
    // without touching the message: retry (the DB gives up after 5 attempts).
    const retry = response.status === 401 || response.status === 403 ||
      response.status === 429 || response.status >= 500;
    return {
      ok: false,
      retry,
      reason: errorText(
        `Twilio${error.providerCode ? ` ${error.providerCode}` : ""}: ${error.message}`,
      ),
    };
  }
  const numbers = Array.isArray(payload?.incoming_phone_numbers)
    ? payload.incoming_phone_numbers as IncomingNumber[]
    : [];
  const number = numbers.find((n) => n.phone_number === from);
  if (!number || !isBoundToShop(number.sms_url, svc.env.functionsPublicUrl(), shopId)) {
    svc.log.error("sms_sender_not_provisioned", { shop_id: shopId, on_account: !!number });
    return { ok: false, retry: false, reason: NOT_PROVISIONED };
  }
  return { ok: true };
}

/**
 * Checks that `from` is provisioned for `shopId` (memoized per request, so a
 * queue run looks each shop's number up once). Throws only EnvError
 * (Twilio secrets missing), which the caller maps to a retry.
 */
export function checkSmsSender(svc: Services, shopId: string, from: string): Promise<SenderCheck> {
  const key = `${shopId}|${from}`;
  let pending = svc.senderChecks.get(key);
  if (!pending) {
    pending = lookupSender(svc, shopId, from);
    svc.senderChecks.set(key, pending);
    // A transient failure must not stick for the rest of the run.
    pending.then((result) => {
      if (!result.ok && result.retry) svc.senderChecks.delete(key);
    }, () => svc.senderChecks.delete(key));
  }
  return pending;
}
