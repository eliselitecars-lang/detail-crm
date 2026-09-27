/** Email via the Resend REST API (no SDK). */
import { apiBaseFromEnv, DEFAULT_RESEND_API_BASE } from "./api_base.ts";
import { UpstreamError } from "./errors.ts";

/** https://api.resend.com/emails unless RESEND_API_BASE (local harness only) overrides the host. */
export const RESEND_API_URL = `${
  apiBaseFromEnv("RESEND_API_BASE", DEFAULT_RESEND_API_BASE)
}/emails`;

export interface SendEmailParams {
  /** "Shop Name <notifications@yourdomain>" — must be a verified Resend domain. */
  from: string;
  to: string | readonly string[];
  subject: string;
  text?: string;
  html?: string;
  replyTo?: string | readonly string[];
  /** Resend de-duplicates sends with the same key for 24 hours. */
  idempotencyKey?: string;
  /** Resend tags (ASCII letters, digits, _ and - only). */
  tags?: ReadonlyArray<{ name: string; value: string }>;
  headers?: Readonly<Record<string, string>>;
}

export interface SentEmail {
  id: string;
}

export class ResendError extends UpstreamError {
  constructor(
    message: string,
    options: { httpStatus?: number | null; providerCode?: string | null; cause?: unknown } = {},
  ) {
    super("Resend", message, options);
    this.name = "ResendError";
  }
}

const TAG_PART = /^[A-Za-z0-9_-]{1,256}$/;
const ADDRESS = /^[^\s<>@]+@[^\s<>@]+\.[^\s<>@]+$/;

function toList(value: string | readonly string[]): string[] {
  return typeof value === "string" ? [value] : [...value];
}

export async function sendEmail(
  apiKey: string,
  params: SendEmailParams,
  fetchFn: typeof fetch = fetch,
): Promise<SentEmail> {
  const to = toList(params.to);
  if (to.length === 0 || to.length > 50) throw new TypeError("sendEmail: 1-50 recipients required");
  for (const address of to) {
    if (!ADDRESS.test(address)) throw new TypeError("sendEmail: invalid recipient address");
  }
  if (params.subject.trim() === "") throw new TypeError("sendEmail: subject must not be empty");
  if (!params.text?.trim() && !params.html?.trim()) {
    throw new TypeError("sendEmail: text or html body is required");
  }
  for (const tag of params.tags ?? []) {
    if (!TAG_PART.test(tag.name) || !TAG_PART.test(tag.value)) {
      throw new TypeError("sendEmail: tag names/values may only contain letters, digits, _ and -");
    }
  }

  const body: Record<string, unknown> = { from: params.from, to, subject: params.subject };
  if (params.text) body.text = params.text;
  if (params.html) body.html = params.html;
  if (params.replyTo) body.reply_to = toList(params.replyTo);
  if (params.tags?.length) body.tags = params.tags;
  if (params.headers && Object.keys(params.headers).length) body.headers = params.headers;

  const headers: Record<string, string> = {
    Authorization: `Bearer ${apiKey}`,
    "Content-Type": "application/json",
    Accept: "application/json",
  };
  if (params.idempotencyKey) headers["Idempotency-Key"] = params.idempotencyKey;

  let response: Response;
  try {
    response = await fetchFn(RESEND_API_URL, {
      method: "POST",
      headers,
      body: JSON.stringify(body),
    });
  } catch (cause) {
    throw new ResendError("Resend request failed to send", { cause });
  }
  const payload = await response.json().catch(() => null) as Record<string, unknown> | null;
  if (!response.ok) {
    throw new ResendError(
      typeof payload?.message === "string" ? payload.message : `HTTP ${response.status}`,
      {
        httpStatus: response.status,
        providerCode: typeof payload?.name === "string" ? payload.name : null,
      },
    );
  }
  if (typeof payload?.id !== "string") {
    throw new ResendError("Resend response did not include an email id", {
      httpStatus: response.status,
    });
  }
  return { id: payload.id };
}
