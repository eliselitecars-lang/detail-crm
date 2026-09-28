/**
 * The Twilio REST calls of sms-provisioning and payments delete_shop (no
 * SDK): phone numbers (2010-04-01 API), Messaging Services, toll-free
 * verification and A2P 10DLC brands/campaigns (messaging v1), and Trust Hub
 * profiles (trusthub v1). Requests are form-encoded with Basic auth, capped at 15 s, and a
 * non-2xx answer becomes a TwilioError carrying Twilio's error code.
 */
import { withTimeout } from "./fetch_timeout.ts";
import { basicAuth, TWILIO_API_BASE, TwilioError } from "./twilio.ts";

export const MESSAGING_API = "https://messaging.twilio.com/v1";
export const TRUSTHUB_API = "https://trusthub.twilio.com/v1";
export const REQUEST_TIMEOUT_MS = 15_000;

/** Trust Hub policies (Twilio's published policy sids for A2P 10DLC ISVs). */
export const SECONDARY_CUSTOMER_PROFILE_POLICY = "RNdfbf3fae0e1107f8aded0e7cead80bf5";
export const A2P_MESSAGING_PROFILE_POLICY = "RNb0d4771c2c98518d916a3d4cd70a8f8b";

export type FormValue = string | number | boolean | readonly string[] | null | undefined;
export type Json = Record<string, unknown>;

export interface TwilioClient {
  accountSid: string;
  /** GET/POST/DELETE; `form` is sent form-encoded (arrays repeat the key). */
  request(
    method: "GET" | "POST" | "DELETE",
    url: string,
    form?: Record<string, FormValue>,
  ): Promise<Json>;
  /** Like request, but a 404 answers null (already gone). */
  requestOrNull(method: "GET" | "DELETE", url: string): Promise<Json | null>;
  /** 2010-04-01 account-scoped URL, e.g. account("IncomingPhoneNumbers.json"). */
  account(path: string): string;
}

export function encodeForm(form: Record<string, FormValue>): URLSearchParams {
  const params = new URLSearchParams();
  for (const [key, value] of Object.entries(form)) {
    if (value === null || value === undefined) continue;
    if (Array.isArray(value)) { for (const item of value) params.append(key, item); }
    else params.set(key, String(value));
  }
  return params;
}

export function twilioClient(
  credentials: { accountSid: string; authToken: string },
  fetchFn: typeof fetch,
): TwilioClient {
  const timed = withTimeout(fetchFn, REQUEST_TIMEOUT_MS);
  const authorization = basicAuth(credentials.accountSid, credentials.authToken);

  const send = async (
    method: string,
    url: string,
    form?: Record<string, FormValue>,
  ): Promise<{ status: number; body: Json | null }> => {
    const headers: Record<string, string> = {
      Authorization: authorization,
      Accept: "application/json",
    };
    let body: string | undefined;
    if (form && method === "POST") {
      headers["Content-Type"] = "application/x-www-form-urlencoded";
      body = encodeForm(form).toString();
    }
    let response: Response;
    try {
      response = await timed(url, { method, headers, body });
    } catch (cause) {
      throw new TwilioError("Twilio request failed to send", { cause });
    }
    const text = await response.text();
    let parsed: Json | null = null;
    if (text) {
      try {
        parsed = JSON.parse(text) as Json;
      } catch {
        parsed = null;
      }
    }
    return { status: response.status, body: parsed };
  };

  const fail = (status: number, body: Json | null): never => {
    const code = body?.code;
    throw new TwilioError(
      typeof body?.message === "string" ? body.message : `HTTP ${status}`,
      {
        httpStatus: status,
        providerCode: typeof code === "number" || typeof code === "string" ? String(code) : null,
      },
    );
  };

  return {
    accountSid: credentials.accountSid,
    account: (path) =>
      `${TWILIO_API_BASE}/Accounts/${encodeURIComponent(credentials.accountSid)}/${path}`,
    async request(method, url, form) {
      const { status, body } = await send(method, url, form);
      if (status < 200 || status >= 300) fail(status, body);
      return body ?? {};
    },
    async requestOrNull(method, url) {
      const { status, body } = await send(method, url);
      if (status === 404) return null;
      if (status < 200 || status >= 300) fail(status, body);
      return body ?? {};
    },
  };
}

export function str(value: unknown): string | null {
  return typeof value === "string" && value !== "" ? value : null;
}

/** A number the platform bought for a shop (a shop_sms_numbers row with a Twilio sid). */
export interface PlatformNumber {
  phone_number: string;
  twilio_number_sid: string;
  messaging_service_sid: string | null;
}

/**
 * Gives a number the platform bought back to Twilio (it stops being rented):
 * DELETE the IncomingPhoneNumber (a 404 means it is already gone), then its
 * Messaging Service. A failure on the number throws; one on the service is
 * handed to `onServiceError` only, since an empty service costs nothing.
 */
export async function releasePlatformNumber(
  client: TwilioClient,
  number: PlatformNumber,
  onServiceError: (err: unknown) => void,
): Promise<void> {
  await client.requestOrNull(
    "DELETE",
    client.account(`IncomingPhoneNumbers/${encodeURIComponent(number.twilio_number_sid)}.json`),
  );
  if (!number.messaging_service_sid) return;
  try {
    await client.requestOrNull(
      "DELETE",
      `${MESSAGING_API}/Services/${encodeURIComponent(number.messaging_service_sid)}`,
    );
  } catch (err) {
    onServiceError(err);
  }
}
