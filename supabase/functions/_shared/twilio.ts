/**
 * Twilio SMS over the REST API (no SDK): sending, webhook signature
 * validation (X-Twilio-Signature) and inbound helpers.
 *
 * Signature algorithm (Twilio "Webhooks security"): take the full URL Twilio
 * requested (scheme, host, path, query), append every POST parameter sorted by
 * name as name+value with no delimiters, HMAC-SHA1 with the account auth
 * token, base64. Compare in constant time.
 */
import { apiBaseFromEnv, DEFAULT_TWILIO_API_BASE } from "./api_base.ts";
import { hmacBase64, timingSafeEqual, toBase64 } from "./crypto.ts";
import { UpstreamError } from "./errors.ts";

/** https://api.twilio.com/2010-04-01 unless TWILIO_API_BASE (local harness only) overrides it. */
export const TWILIO_API_BASE = apiBaseFromEnv("TWILIO_API_BASE", DEFAULT_TWILIO_API_BASE);

const E164 = /^\+[1-9]\d{6,14}$/;

export interface TwilioCredentials {
  accountSid: string;
  authToken: string;
}

export interface SendSmsParams {
  to: string;
  /** Shop's sending number (E.164) or a Messaging Service SID (MG…). */
  from: string;
  body: string;
  /** Delivery status webhook (messaging?action=twilio_status). */
  statusCallback?: string;
}

export interface SentSms {
  sid: string;
  status: string;
}

export class TwilioError extends UpstreamError {
  constructor(
    message: string,
    options: { httpStatus?: number | null; providerCode?: string | null; cause?: unknown } = {},
  ) {
    super("Twilio", message, options);
    this.name = "TwilioError";
  }
}

/**
 * Twilio error codes meaning "this recipient can't receive SMS from us"
 * (unsubscribed, invalid, landline…) — permanent failures to record, not retry.
 */
export const PERMANENT_RECIPIENT_ERRORS: ReadonlySet<string> = new Set([
  "21211", // invalid 'To' number
  "21214", // 'To' number cannot be reached
  "21408", // permission to send to region not enabled
  "21610", // recipient replied STOP (unsubscribed)
  "21612", // 'To' not reachable via this 'From'
  "21614", // 'To' is not a mobile number
]);

export function basicAuth(accountSid: string, authToken: string): string {
  return `Basic ${toBase64(new TextEncoder().encode(`${accountSid}:${authToken}`))}`;
}

export async function sendSms(
  credentials: TwilioCredentials,
  params: SendSmsParams,
  fetchFn: typeof fetch = fetch,
): Promise<SentSms> {
  if (!E164.test(params.to)) throw new TypeError("sendSms: 'to' must be an E.164 number");
  const fromIsService = /^MG[0-9a-fA-F]{32}$/.test(params.from);
  if (!fromIsService && !E164.test(params.from)) {
    throw new TypeError("sendSms: 'from' must be an E.164 number or Messaging Service SID");
  }
  if (params.body.trim() === "") throw new TypeError("sendSms: body must not be empty");

  const form = new URLSearchParams();
  form.set("To", params.to);
  form.set(fromIsService ? "MessagingServiceSid" : "From", params.from);
  form.set("Body", params.body);
  if (params.statusCallback) form.set("StatusCallback", params.statusCallback);

  const url = `${TWILIO_API_BASE}/Accounts/${
    encodeURIComponent(credentials.accountSid)
  }/Messages.json`;
  let response: Response;
  try {
    response = await fetchFn(url, {
      method: "POST",
      headers: {
        Authorization: basicAuth(credentials.accountSid, credentials.authToken),
        "Content-Type": "application/x-www-form-urlencoded",
        Accept: "application/json",
      },
      body: form.toString(),
    });
  } catch (cause) {
    throw new TwilioError("Twilio request failed to send", { cause });
  }

  const payload = await response.json().catch(() => null) as Record<string, unknown> | null;
  if (!response.ok) {
    const code = payload?.code;
    throw new TwilioError(
      typeof payload?.message === "string" ? payload.message : `HTTP ${response.status}`,
      {
        httpStatus: response.status,
        providerCode: typeof code === "number" || typeof code === "string" ? String(code) : null,
      },
    );
  }
  const sid = payload?.sid;
  if (typeof sid !== "string") {
    throw new TwilioError("Twilio response did not include a message sid", {
      httpStatus: response.status,
    });
  }
  return { sid, status: typeof payload?.status === "string" ? payload.status : "queued" };
}

// ---------------------------------------------------------------------------
// Webhook signatures
// ---------------------------------------------------------------------------

export type TwilioParams = URLSearchParams | Readonly<Record<string, string | readonly string[]>>;

function paramEntries(params: TwilioParams): Map<string, string[]> {
  const map = new Map<string, string[]>();
  const add = (key: string, value: string) => {
    const list = map.get(key);
    if (list) list.push(value);
    else map.set(key, [value]);
  };
  if (params instanceof URLSearchParams) {
    for (const [key, value] of params) add(key, value);
  } else {
    for (const [key, value] of Object.entries(params)) {
      if (typeof value === "string") add(key, value);
      else for (const item of value) add(key, item);
    }
  }
  return map;
}

/** The string Twilio signs: URL + sorted name/value pairs. */
export function twilioSignaturePayload(url: string, params: TwilioParams): string {
  const entries = paramEntries(params);
  let payload = url;
  // Case-sensitive code-unit sort, like Twilio's reference libraries.
  for (const key of [...entries.keys()].sort()) {
    for (const value of [...(entries.get(key) ?? [])].sort()) payload += key + value;
  }
  return payload;
}

export function computeTwilioSignature(
  authToken: string,
  url: string,
  params: TwilioParams,
): Promise<string> {
  return hmacBase64("SHA-1", authToken, twilioSignaturePayload(url, params));
}

/**
 * URL variants Twilio may have signed: as given, and with/without the
 * default port (Twilio's own validators accept both).
 */
export function twilioUrlVariants(url: string): string[] {
  const match = /^(https?:\/\/)([^/?#]*)(.*)$/is.exec(url);
  if (!match) return [url];
  const [, scheme = "", authority = "", rest = ""] = match;
  const defaultPort = scheme.toLowerCase() === "https://" ? "443" : "80";
  const host = authority.replace(/:\d+$/, "");
  return [...new Set([url, `${scheme}${host}${rest}`, `${scheme}${host}:${defaultPort}${rest}`])];
}

/**
 * Validates X-Twilio-Signature for a form-encoded webhook. `url` must be the
 * exact public URL configured in Twilio (see Env.functionsPublicUrl) plus the
 * request's query string — not `req.url`, which may be an internal address.
 */
export async function validateTwilioSignature(
  authToken: string,
  signature: string | null,
  url: string,
  params: TwilioParams,
): Promise<boolean> {
  if (!signature) return false;
  let valid = false;
  for (const candidate of twilioUrlVariants(url)) {
    const expected = await computeTwilioSignature(authToken, candidate, params);
    // Evaluate every variant (no early exit) to keep timing uniform.
    if (timingSafeEqual(expected, signature)) valid = true;
  }
  return valid;
}

// ---------------------------------------------------------------------------
// Inbound helpers
// ---------------------------------------------------------------------------

/** Twilio's default opt-out / opt-in / help keywords (whole message, case-insensitive). */
const OPT_OUT = new Set([
  "STOP",
  "STOPALL",
  "UNSUBSCRIBE",
  "CANCEL",
  "END",
  "QUIT",
  "OPTOUT",
  "REVOKE",
]);
const OPT_IN = new Set(["START", "YES", "UNSTOP"]);
const HELP = new Set(["HELP", "INFO"]);

export type OptKeyword = "opt_out" | "opt_in" | "help";

export function classifyOptKeyword(body: string): OptKeyword | null {
  const word = body.trim().replace(/[.!\s]+$/, "").toUpperCase();
  if (OPT_OUT.has(word)) return "opt_out";
  if (OPT_IN.has(word)) return "opt_in";
  if (HELP.has(word)) return "help";
  return null;
}

/** Empty TwiML response (acknowledge without auto-reply). */
export function emptyTwiml(): Response {
  return new Response('<?xml version="1.0" encoding="UTF-8"?><Response></Response>', {
    status: 200,
    headers: { "Content-Type": "text/xml; charset=utf-8" },
  });
}
