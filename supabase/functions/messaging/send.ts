/**
 * `send` — a staff member messages a customer, then the message is delivered
 * immediately through the same pipeline as the cron sender.
 *
 *   owner/admin/manager  free-form `body` (queue_message) or `template_key`
 *                        (enqueue_template_message for a job, or — only for
 *                        CUSTOMER_TEMPLATE_KEYS whose wording uses only
 *                        CUSTOMER_TEMPLATE_VARS — the customer-level template
 *                        when no job is given; anything else without a job is
 *                        422 `job_required`, since its date, vehicle, link and
 *                        amount placeholders would render blank)
 *   technician           ONLY template_key on_the_way / job_started /
 *                        job_completed, on a job assigned to them
 *
 * `shop_id` is optional: without it the shop is the one the job (or else the
 * customer) belongs to, looked up server-side (the web inbox sends only the
 * customer/job). With it, the job/customer must belong to that shop. Either
 * way the caller must be an active member of that shop; a job/customer the
 * caller cannot see is `not_found`.
 *
 * Authorization happens here (JWT + role + job assignment) AND again in the
 * database: staff RPCs run with the caller's own client so their checks
 * apply. Consent is enforced by the database (opted-out customers are never
 * queued, and are re-checked at claim time); when the database refuses or
 * no-ops, the response is 422 `unprocessable` with `details.reason`.
 *
 * A template whose link placeholder would render blank (no review URL set
 * for the shop, no sent quote / issued invoice for the job...) is refused
 * before anything is queued: 422 `missing_link` with `details.variables`.
 *
 * Quotes and invoices (`quote_id` / `invoice_id`, owner/admin/manager only):
 * the quote_sent / invoice_sent template is rendered and queued by the
 * database (enqueue_document_message, 0090) with the document's own link,
 * amount and balance; clients never render or send the text themselves. A
 * draft quote or a draft / void invoice has no link yet: 422 `missing_link`.
 *
 * Idempotent for retries: a `request_nonce` (one per compose, reused on a
 * retry) makes the database return the message that nonce already queued
 * (messages.request_nonce, 0033), and that message is never delivered twice
 * (claimOne only claims a still-queued row). Without a nonce, repeating the
 * same send (same caller, customer, channel, job, template/body) within
 * DUPLICATE_WINDOW_MS returns the original message instead of delivering a
 * second copy (earlierDuplicate).
 */
import { z } from "zod";
import {
  getMembership,
  hasRole,
  type Membership,
  requireJobAccess,
  requireShopRole,
  requireUser,
  ROLES,
} from "../_shared/auth.ts";
import { errors, HttpError } from "../_shared/errors.ts";
import { requestNonce, uuid } from "../_shared/schemas.ts";
import { userClient } from "../_shared/supabase.ts";
import { placeholdersIn } from "../_shared/templates.ts";
import { type Channel, claimOne, deliverClaimed, type MessageStatus } from "./deliver.ts";
import { DbError, type PgError, rpcRefusal, type Services } from "./lib.ts";

/** Every template key except `invite` (staff invites are emailed by the invites function). */
export const SENDABLE_TEMPLATE_KEYS = [
  "booking_request_received",
  "booking_confirmed",
  "appointment_reminder",
  "on_the_way",
  "job_started",
  "job_completed",
  "quote_sent",
  "invoice_sent",
  "payment_receipt",
  "review_request",
  "follow_up",
  "membership_welcome",
] as const;

export const TECHNICIAN_TEMPLATE_KEYS: readonly string[] = [
  "on_the_way",
  "job_started",
  "job_completed",
];

/**
 * Templates that may be sent without a job, as long as the shop's wording
 * for the channel uses only CUSTOMER_TEMPLATE_VARS (checked per send: the
 * seeded follow_up says "your {{vehicle}}", which only a job provides, so
 * it needs a job unless the shop reworded it). Every other key is about a
 * specific job (date/time, vehicle, services, booking/quote/invoice links,
 * amount/balance) and always needs job_id.
 */
export const CUSTOMER_TEMPLATE_KEYS: readonly string[] = [
  "review_request",
  "follow_up",
  "membership_welcome",
];

/**
 * The variables enqueue_customer_template renders without a job
 * (comms_customer_vars, 0033). Any other placeholder would render blank.
 */
export const CUSTOMER_TEMPLATE_VARS: ReadonlySet<string> = new Set([
  "customer_first_name",
  "customer_name",
  "shop_name",
  "shop_phone",
  "review_link",
  "booking_page_link",
]);

/**
 * Link variables (comms_customer_vars / comms_job_vars). A message whose
 * link renders blank ("we would really appreciate a review: ") is pointless,
 * so it is refused instead of sent. Values: what staff must set up first.
 */
export const LINK_VARS: Readonly<Record<string, string>> = {
  review_link: "Add the shop's review link in settings before sending this message.",
  booking_page_link: "The shop's online booking page is not available.",
  booking_link: "This job has no appointment link.",
  quote_link: "This job has no sent quote to link to.",
  invoice_link: "This job has no issued invoice to link to.",
};

/**
 * Mirrors comms_is_marketing_key (0033 / 0083): needs the channel's
 * marketing opt-in, and a marketing email also needs the shop's postal
 * address on file (0119). Only follow_up is sendable by hand; the per-
 * service follow-up (service_followup) is sent by its automation.
 */
export const MARKETING_TEMPLATE_KEYS: readonly string[] = ["follow_up", "service_followup"];

/** Mirrors comms_is_appointment_key (0033): refused once the job is cancelled / no-show. */
export const APPOINTMENT_TEMPLATE_KEYS: readonly string[] = [
  "booking_request_received",
  "booking_confirmed",
  "appointment_reminder",
  "on_the_way",
  "job_started",
];

/** The template each document is sent with (enqueue_document_message). */
export const DOCUMENT_TEMPLATE_KEYS = { quote: "quote_sent", invoice: "invoice_sent" } as const;

export const SMS_MAX_LENGTH = 1600;
export const EMAIL_MAX_LENGTH = 50_000;
export const SUBJECT_MAX_LENGTH = 500;

export const sendInput = z.object({
  /** Optional: derived from the job/customer (or the quote/invoice) when omitted. */
  shop_id: uuid.optional(),
  customer_id: uuid.optional(),
  job_id: uuid.optional(),
  /** Send this quote (template quote_sent); the customer comes from the quote. */
  quote_id: uuid.optional(),
  /** Send this invoice (template invoice_sent); the customer comes from the invoice. */
  invoice_id: uuid.optional(),
  channel: z.enum(["sms", "email"]),
  template_key: z.enum(SENDABLE_TEMPLATE_KEYS).optional(),
  subject: z.string().max(SUBJECT_MAX_LENGTH).optional(),
  body: z.string().max(EMAIL_MAX_LENGTH).optional(),
  /** One per compose, reused on a retry of it: the database queues it once. */
  request_nonce: requestNonce.optional(),
}).strict().superRefine((input, ctx) => {
  const issue = (path: string, message: string) =>
    ctx.addIssue({ code: "custom", path: [path], message });
  if (input.quote_id !== undefined || input.invoice_id !== undefined) {
    if (input.quote_id !== undefined && input.invoice_id !== undefined) {
      issue("invoice_id", "send either quote_id or invoice_id, not both");
      return;
    }
    const key = input.quote_id !== undefined
      ? DOCUMENT_TEMPLATE_KEYS.quote
      : DOCUMENT_TEMPLATE_KEYS.invoice;
    const path = input.quote_id !== undefined ? "quote_id" : "invoice_id";
    if (input.template_key !== key) {
      issue("template_key", `${path} is sent with template_key ${key}`);
    }
    if (input.body !== undefined) issue("body", "quotes and invoices are sent with their template");
    if (input.subject !== undefined) issue("subject", "templates provide their own subject");
    if (input.job_id !== undefined) issue("job_id", `the ${path.slice(0, -3)} decides its job`);
    if (input.customer_id !== undefined) {
      issue("customer_id", `the ${path.slice(0, -3)} decides its customer`);
    }
    return;
  }
  if (input.template_key !== undefined) {
    if (input.body !== undefined) issue("body", "send either template_key or body, not both");
    if (input.subject !== undefined) issue("subject", "templates provide their own subject");
    if (input.job_id === undefined && input.customer_id === undefined) {
      issue("customer_id", "customer_id or job_id is required");
    }
    return;
  }
  if (input.body === undefined || input.body.trim() === "") {
    issue("body", "body or template_key is required");
  } else if (input.channel === "sms" && input.body.length > SMS_MAX_LENGTH) {
    issue("body", `text messages are limited to ${SMS_MAX_LENGTH} characters`);
  }
  if (input.channel === "sms" && input.subject !== undefined) {
    issue("subject", "text messages have no subject");
  }
  if (input.customer_id === undefined && input.job_id === undefined) {
    issue("customer_id", "customer_id or job_id is required");
  }
});

export type SendInput = z.output<typeof sendInput>;

/** The input once the shop is known (given, or derived from the job/customer). */
type ScopedInput = SendInput & { shop_id: string };

export interface SendResponse {
  message_id: string;
  channel: Channel;
  /** Status after the immediate delivery attempt: sent, failed, queued (retry scheduled), sending, cancelled. */
  status: MessageStatus;
  error: string | null;
}

/** Why the database would not queue a message (details.reason on 422). */
export type RefusalReason =
  | "opted_out"
  | "no_address"
  | "sms_not_configured"
  | "template_disabled"
  | "no_marketing_consent"
  | "appointment_closed"
  | "missing_link"
  | "postal_address_required"
  | "empty_message"
  | "job_customer_mismatch"
  | "job_required"
  | "not_sendable";

const REFUSAL_MESSAGES: Record<RefusalReason, (channel: Channel) => string> = {
  opted_out: (c) =>
    c === "sms"
      ? "This customer has opted out of text messages."
      : "This customer has unsubscribed from email.",
  no_address: (c) =>
    c === "sms" ? "This customer has no mobile number." : "This customer has no email address.",
  sms_not_configured: () => "Text messaging is not set up for this shop.",
  template_disabled: () => "This message template is turned off for this channel.",
  no_marketing_consent: (c) =>
    c === "sms"
      ? "This customer has not agreed to receive marketing text messages."
      : "This customer has not agreed to receive marketing email.",
  appointment_closed: () =>
    "This appointment is cancelled or was a no-show; its appointment messages can no longer be sent.",
  missing_link: () => "This message would go out with a blank link.",
  postal_address_required: () =>
    "Add your shop's mailing address (Settings → Business profile) before sending marketing email: the law requires it in every marketing email.",
  empty_message: () => "The template produced an empty message.",
  job_customer_mismatch: () => "The job belongs to a different customer.",
  job_required: () => "This message is about a job: choose the job to send it for.",
  not_sendable: () => "This message cannot be sent.",
};

export function refusal(
  reason: RefusalReason,
  channel: Channel,
  cause?: unknown,
  extra?: { message?: string; details?: Record<string, unknown> },
): HttpError {
  return new HttpError("unprocessable", extra?.message ?? REFUSAL_MESSAGES[reason](channel), {
    details: { reason, ...extra?.details },
    cause,
  });
}

/**
 * Works out why a message was refused / not queued (service-role reads,
 * shop-scoped), following the checks of enqueue_template_message /
 * enqueue_customer_template / queue_message (0033).
 */
async function diagnose(
  svc: Services,
  shopId: string,
  customerId: string,
  channel: Channel,
  templateKey?: string,
  jobId?: string,
): Promise<RefusalReason> {
  const { admin } = svc;
  const { data: customer, error } = await admin.from("customers")
    .select("phone, email, sms_opted_out_at, email_opted_out_at, sms_opt_in, email_opt_in")
    .eq("shop_id", shopId).eq("id", customerId).maybeSingle();
  if (error) throw new DbError("customers lookup", error);
  const row = customer as
    | {
      phone: string | null;
      email: string | null;
      sms_opted_out_at: string | null;
      email_opted_out_at: string | null;
      sms_opt_in: boolean | null;
      email_opt_in: boolean | null;
    }
    | null;
  if (!row) return "not_sendable";
  if (templateKey && jobId && APPOINTMENT_TEMPLATE_KEYS.includes(templateKey)) {
    // Checked first by the database (55000 / no-op), before consent.
    const { data: job, error: jobError } = await admin.from("jobs").select("status")
      .eq("shop_id", shopId).eq("id", jobId).maybeSingle();
    if (jobError) throw new DbError("jobs lookup", jobError);
    const status = (job as { status?: string } | null)?.status;
    if (status === "cancelled" || status === "no_show") return "appointment_closed";
  }
  if (channel === "sms" ? row.sms_opted_out_at : row.email_opted_out_at) return "opted_out";
  if (!(channel === "sms" ? row.phone : row.email)) return "no_address";
  if (channel === "sms") {
    const { data: shop, error: shopError } = await admin.from("shops")
      .select("sms_from_number").eq("id", shopId).maybeSingle();
    if (shopError) throw new DbError("shops lookup", shopError);
    if (!(shop as { sms_from_number: string | null } | null)?.sms_from_number) {
      return "sms_not_configured";
    }
  }
  if (templateKey) {
    const { data: template, error: templateError } = await admin.from("message_templates")
      .select("enabled").eq("shop_id", shopId).eq("key", templateKey).eq("channel", channel)
      .maybeSingle();
    if (templateError) throw new DbError("message_templates lookup", templateError);
    if (!(template as { enabled: boolean } | null)?.enabled) return "template_disabled";
    if (
      MARKETING_TEMPLATE_KEYS.includes(templateKey) &&
      (channel === "sms" ? row.sms_opt_in : row.email_opt_in) !== true
    ) {
      return "no_marketing_consent";
    }
    if (channel === "email" && MARKETING_TEMPLATE_KEYS.includes(templateKey)) {
      // 0119 messages_02_marketing_postal_address: a marketing email is not
      // queued while the shop has no street line and city on file.
      const { data: address, error: addressError } = await admin.rpc(
        "comms_shop_postal_address",
        { p_shop_id: shopId },
      );
      if (addressError) throw new DbError("comms_shop_postal_address", addressError);
      if (typeof address !== "string" || address.trim() === "") return "postal_address_required";
    }
    return "empty_message";
  }
  return "not_sendable";
}

interface JobRow {
  id: string;
  shop_id: string;
  customer_id: string;
}

async function loadJob(svc: Services, shopId: string, jobId: string): Promise<JobRow> {
  const { data, error } = await svc.admin.from("jobs").select("id, shop_id, customer_id")
    .eq("shop_id", shopId).eq("id", jobId).maybeSingle();
  if (error) throw new DbError("jobs lookup", error);
  if (!data) throw errors.notFound("Job not found.");
  return data as JobRow;
}

/** A quote or invoice being sent (send's `quote_id` / `invoice_id`). */
export interface DocumentRef {
  kind: "quote" | "invoice";
  id: string;
}

interface DocumentRow {
  id: string;
  shop_id: string;
  customer_id: string;
  status: string;
}

function documentOf(input: SendInput): DocumentRef | null {
  if (input.quote_id !== undefined) return { kind: "quote", id: input.quote_id };
  if (input.invoice_id !== undefined) return { kind: "invoice", id: input.invoice_id };
  return null;
}

const DOCUMENT_LABELS = { quote: "Quote", invoice: "Invoice" } as const;

/** The document in the shop (service role, scoped); `not_found` otherwise. */
async function loadDocument(svc: Services, shopId: string, doc: DocumentRef): Promise<DocumentRow> {
  const columns = "id, shop_id, customer_id, status";
  const { data, error } = doc.kind === "quote"
    ? await svc.admin.from("quotes").select(columns)
      .eq("shop_id", shopId).eq("id", doc.id).maybeSingle()
    : await svc.admin.from("invoices").select(columns)
      .eq("shop_id", shopId).eq("id", doc.id).maybeSingle();
  if (error) throw new DbError(`${doc.kind} lookup`, error);
  if (!data) throw errors.notFound(`${DOCUMENT_LABELS[doc.kind]} not found.`);
  return data as DocumentRow;
}

/** What the caller sees when the message's own row is missing / not theirs. */
function notFoundLabel(input: SendInput): string {
  const doc = documentOf(input);
  if (doc) return `${DOCUMENT_LABELS[doc.kind]} not found.`;
  return input.job_id ? "Job not found." : "Customer not found.";
}

/** shop_id of one row by id (service role); null when there is none. */
async function shopOfRow(
  svc: Services,
  input: SendInput,
): Promise<{ data: unknown; error: PgError | null }> {
  if (input.quote_id !== undefined) {
    return await svc.admin.from("quotes").select("shop_id").eq("id", input.quote_id).maybeSingle();
  }
  if (input.invoice_id !== undefined) {
    return await svc.admin.from("invoices").select("shop_id").eq("id", input.invoice_id)
      .maybeSingle();
  }
  if (input.job_id !== undefined) {
    return await svc.admin.from("jobs").select("shop_id").eq("id", input.job_id).maybeSingle();
  }
  if (input.customer_id !== undefined) {
    return await svc.admin.from("customers").select("shop_id").eq("id", input.customer_id)
      .maybeSingle();
  }
  throw errors.badRequest("customer_id or job_id is required.");
}

/**
 * The shop the message is for: the quote's / invoice's shop, else the job's,
 * else the customer's (service-role lookup by id). Missing rows are
 * `not_found`.
 */
async function deriveShopId(svc: Services, input: SendInput): Promise<string> {
  const { data, error } = await shopOfRow(svc, input);
  if (error) throw new DbError("shop lookup", error);
  const shopId = (data as { shop_id?: unknown } | null)?.shop_id;
  if (typeof shopId !== "string") throw errors.notFound(notFoundLabel(input));
  return shopId;
}

/**
 * The caller's membership in the message's shop. When the shop was derived
 * from the row, a non-member gets `not_found` (as if the row did not exist)
 * rather than learning it belongs to some other shop.
 */
async function authorize(
  svc: Services,
  caller: { id: string },
  input: SendInput,
): Promise<{ scoped: ScopedInput; membership: Membership }> {
  if (input.shop_id !== undefined) {
    const membership = await requireShopRole(svc.admin, caller, input.shop_id, ROLES.anyStaff);
    return { scoped: { ...input, shop_id: input.shop_id }, membership };
  }
  const shopId = await deriveShopId(svc, input);
  const membership = await getMembership(svc.admin, shopId, caller.id);
  if (!membership) throw errors.notFound(notFoundLabel(input));
  if (!hasRole(membership, ROLES.anyStaff)) {
    throw errors.forbidden("Your role does not allow this action.");
  }
  return { scoped: { ...input, shop_id: shopId }, membership };
}

export async function send(
  svc: Services,
  req: Request,
  rawInput: SendInput,
): Promise<SendResponse> {
  const caller = await requireUser(req, { admin: svc.admin });
  const { scoped: input, membership } = await authorize(svc, caller, rawInput);
  const isManager = hasRole(membership, ROLES.managerPlus);
  const channel: Channel = input.channel;
  const doc = documentOf(input);

  if (!isManager) {
    if (doc) {
      throw errors.forbidden("Only owners, admins and managers can send quotes and invoices.");
    }
    if (!input.template_key || !TECHNICIAN_TEMPLATE_KEYS.includes(input.template_key)) {
      throw errors.forbidden(
        "Technicians can only send the on-my-way, job-started and job-complete messages.",
      );
    }
    if (!input.job_id) {
      throw errors.forbidden("Technicians can only message customers of jobs assigned to them.");
    }
    // not_found when the job is not in this shop; forbidden when not assigned.
    await requireJobAccess(svc.admin, membership, input.job_id);
  }

  let customerId: string | undefined;
  let document: DocumentRow | null = null;
  if (doc) {
    document = await loadDocument(svc, input.shop_id, doc);
    customerId = document.customer_id;
  } else {
    if (
      input.template_key !== undefined && !input.job_id &&
      !CUSTOMER_TEMPLATE_KEYS.includes(input.template_key)
    ) {
      // Without a job its dates, vehicle, links and amounts would go out blank.
      throw refusal("job_required", channel);
    }
    let job: JobRow | null = null;
    if (input.job_id) {
      job = await loadJob(svc, input.shop_id, input.job_id);
      if (input.customer_id && input.customer_id !== job.customer_id) {
        throw refusal("job_customer_mismatch", channel);
      }
    }
    customerId = input.customer_id ?? job?.customer_id;
  }
  if (!customerId) throw errors.badRequest("customer_id or job_id is required.");

  if (input.template_key !== undefined) {
    await checkTemplateVariables(svc, input, input.template_key, customerId, channel, document);
  }

  const messageId = await queue(svc, req, input, caller.id, customerId, channel);

  // With a request_nonce the database already returned the message this
  // compose queued (or the one it queued on an earlier attempt).
  const original = input.request_nonce === undefined
    ? await earlierDuplicate(svc, input.shop_id, caller.id, customerId, channel, messageId)
    : null;
  if (original) {
    svc.log.info("message_send_deduplicated", {
      message_id: original.id,
      duplicate_of_request: messageId,
      shop_id: input.shop_id,
      channel,
    });
    return { message_id: original.id, channel, status: original.status, error: original.error };
  }

  const claim = await claimOne(svc, input.shop_id, messageId);
  if (claim.claimed === null) {
    return { message_id: messageId, channel, status: claim.status, error: claim.error };
  }
  const result = await deliverClaimed(svc, claim.claimed);
  svc.log.info("message_send_requested", {
    message_id: messageId,
    shop_id: input.shop_id,
    channel,
    template_key: input.template_key ?? null,
    ...(doc ? { [`${doc.kind}_id`]: doc.id } : {}),
    status: result.status,
  });
  return { message_id: messageId, channel, status: result.status, error: result.error };
}

// ---------------------------------------------------------------------------
// Template variables
// ---------------------------------------------------------------------------

/**
 * Refuses a template send whose placeholders would render blank, before
 * anything is queued (the database renders a missing / null variable as ''):
 *   - without a job, any placeholder that is not a CUSTOMER_TEMPLATE_VARS
 *     variable (e.g. follow_up's "your {{vehicle}}") -> `job_required`
 *     (not for quotes / invoices: the database renders them with their own
 *     variables, comms_document_vars);
 *   - a LINK_VARS placeholder whose value is blank for this customer / job /
 *     document (e.g. {{review_link}} while the shop has no review URL, or the
 *     {{quote_link}} of a draft quote) -> `missing_link`.
 * Reads the shop's own wording for the channel (service role, shop-scoped).
 * A missing or disabled template is left to the database (template_disabled).
 */
async function checkTemplateVariables(
  svc: Services,
  input: ScopedInput,
  templateKey: string,
  customerId: string,
  channel: Channel,
  document: DocumentRow | null,
): Promise<void> {
  const { data, error } = await svc.admin.from("message_templates")
    .select("subject, body, enabled")
    .eq("shop_id", input.shop_id).eq("key", templateKey).eq("channel", channel)
    .maybeSingle();
  if (error) throw new DbError("message_templates lookup", error);
  const template = data as { subject: string | null; body: string | null; enabled: boolean } | null;
  if (!template?.enabled) return;
  const names = placeholdersIn(
    `${template.body ?? ""}\n${channel === "email" ? (template.subject ?? "") : ""}`,
  );

  if (!input.job_id && !document) {
    // A marketing email gets its own {{unsubscribe_link}} from the database
    // (enqueue_customer_template, 0033), with or without a job.
    const marketingEmail = channel === "email" && MARKETING_TEMPLATE_KEYS.includes(templateKey);
    const jobOnly = names.filter((name) =>
      !CUSTOMER_TEMPLATE_VARS.has(name) && !(marketingEmail && name === "unsubscribe_link")
    );
    if (jobOnly.length > 0) {
      throw refusal("job_required", channel, undefined, { details: { variables: jobOnly } });
    }
  }

  const links = names.filter((name) => Object.hasOwn(LINK_VARS, name));
  if (links.length === 0) return;
  const { data: vars, error: varsError } = document
    ? await svc.admin.rpc("comms_document_vars", {
      p_quote_id: input.quote_id ?? null,
      p_invoice_id: input.invoice_id ?? null,
    })
    : input.job_id
    ? await svc.admin.rpc("comms_job_vars", { p_job_id: input.job_id })
    : await svc.admin.rpc("comms_customer_vars", {
      p_shop_id: input.shop_id,
      p_customer_id: customerId,
    });
  if (varsError) throw new DbError("template variables", varsError);
  const values = (vars ?? {}) as Record<string, unknown>;
  const blank = links.filter((name) => {
    const value = values[name];
    return value === null || value === undefined || String(value).trim() === "";
  });
  if (blank.length > 0) {
    throw refusal("missing_link", channel, undefined, {
      message: missingLinkMessage(blank[0] as string, document),
      details: { variables: blank },
    });
  }
}

/** What staff must do before a message with this blank link can go out. */
function missingLinkMessage(variable: string, document: DocumentRow | null): string {
  if (document && variable === "quote_link") return "Mark the quote as sent first.";
  if (document && variable === "invoice_link") {
    return document.status === "void"
      ? "This invoice is void; it can no longer be sent."
      : "Issue the invoice first.";
  }
  return LINK_VARS[variable] ?? REFUSAL_MESSAGES.missing_link("sms");
}

// ---------------------------------------------------------------------------
// Duplicate requests
// ---------------------------------------------------------------------------

/**
 * A repeat of the same send by the same staff member within this window is
 * the same request (a retry after a lost response, a double tap), not a new
 * message: it answers with the original message instead of texting or
 * emailing the customer again.
 */
export const DUPLICATE_WINDOW_MS = 5 * 60_000;

/** Statuses of a message that went out or still will (a failed/cancelled one may be re-sent). */
const LIVE_STATUSES: ReadonlySet<string> = new Set(["queued", "sending", "sent", "delivered"]);

/** Server clock (created_at) vs edge clock (the query bound). */
const DUPLICATE_CLOCK_SKEW_MS = 120_000;

interface RecentMessage {
  id: string;
  job_id: string | null;
  campaign_id: string | null;
  template_key: string | null;
  subject: string | null;
  body: string;
  /** Marketing email: its random unsubscribe token (appears in the body's link). */
  unsubscribe_token: string | null;
  status: MessageStatus;
  error: string | null;
  created_at: string;
}

/**
 * The body as sent, minus the email's own unsubscribe token: two sends of the
 * same marketing email differ only in that per-email link.
 */
function comparableBody(m: RecentMessage): string {
  return m.unsubscribe_token ? m.body.replaceAll(m.unsubscribe_token, "") : m.body;
}

/**
 * Called right after this request queued `messageId` and before anything is
 * sent. If the same caller queued an identical message (same customer,
 * channel, job, template, subject and body, as stored by the database, a
 * marketing email's per-email unsubscribe token aside) that
 * is still live and was created at most DUPLICATE_WINDOW_MS before this one,
 * the EARLIEST such message is the one to keep: this request's row is
 * withdrawn (deleted while still 'queued'; it never reached a provider) and
 * the earlier message is returned. Concurrent duplicates agree on the
 * earliest row, so exactly one of them sends. Only for sends without a
 * request_nonce (identity is then the content); a nonce makes the database
 * the judge (messages.request_nonce). A lookup failure never blocks the send
 * (logged, the message goes out).
 */
async function earlierDuplicate(
  svc: Services,
  shopId: string,
  callerId: string,
  customerId: string,
  channel: Channel,
  messageId: string,
): Promise<RecentMessage | null> {
  const since = new Date(svc.now().getTime() - DUPLICATE_WINDOW_MS - DUPLICATE_CLOCK_SKEW_MS);
  const { data, error } = await svc.admin.from("messages")
    .select(
      "id, job_id, campaign_id, template_key, subject, body, unsubscribe_token, status, error, created_at",
    )
    .eq("shop_id", shopId).eq("customer_id", customerId).eq("channel", channel)
    .eq("direction", "outbound").eq("sent_by", callerId)
    .gte("created_at", since.toISOString())
    .order("created_at", { ascending: true }).order("id", { ascending: true })
    .limit(200);
  if (error) {
    svc.log.warn("message_duplicate_check_failed", {
      message_id: messageId,
      error: new DbError("messages lookup", error),
    });
    return null;
  }
  const rows = (Array.isArray(data) ? data : []) as unknown as RecentMessage[];
  const ours = rows.find((m) => m.id === messageId);
  if (!ours) return null;
  const oursAt = Date.parse(ours.created_at);
  const first = rows.find((m) =>
    m.id === ours.id || (
      m.campaign_id === null && LIVE_STATUSES.has(m.status) &&
      m.job_id === ours.job_id && m.template_key === ours.template_key &&
      m.subject === ours.subject && comparableBody(m) === comparableBody(ours) &&
      oursAt - Date.parse(m.created_at) <= DUPLICATE_WINDOW_MS
    )
  );
  if (!first || first.id === ours.id) return null;

  const { data: removed, error: removeError } = await svc.admin.from("messages")
    .delete()
    .eq("shop_id", shopId).eq("id", ours.id).eq("status", "queued")
    .select("id");
  if (removeError || !Array.isArray(removed) || removed.length !== 1) {
    // Already claimed by the cron worker (or the delete failed): it goes out.
    svc.log.warn("message_duplicate_not_withdrawn", {
      message_id: ours.id,
      duplicate_of: first.id,
      ...(removeError ? { error: new DbError("messages delete", removeError) } : {}),
    });
    return null;
  }
  return first;
}

/** Queues the message with the right RPC; returns its id or a 422 refusal. */
async function queue(
  svc: Services,
  req: Request,
  input: ScopedInput,
  callerId: string,
  customerId: string,
  channel: Channel,
): Promise<string> {
  const nonce = input.request_nonce ?? null;
  const refused = async (error: { code?: string | null }, operation: string) => {
    const mapped = rpcRefusal(operation, error);
    if (mapped instanceof HttpError && mapped.code === "unprocessable") {
      return refusal(
        await diagnose(
          svc,
          input.shop_id,
          customerId,
          channel,
          input.template_key,
          input.job_id,
        ),
        channel,
        error,
      );
    }
    return mapped;
  };

  if (input.template_key === undefined) {
    // Free-form: manager+ (checked again by queue_message as the caller).
    const user = userClient(req, { env: svc.env, fetch: svc.deps.fetch });
    const { data, error } = await user.rpc("queue_message", {
      p_shop_id: input.shop_id,
      p_customer_id: customerId,
      p_channel: channel,
      p_subject: channel === "email" ? (input.subject ?? null) : null,
      p_body: input.body ?? "",
      p_job_id: input.job_id ?? null,
      p_request_nonce: nonce,
    });
    if (error) throw await refused(error, "queue_message");
    const id = (data as { id?: unknown } | null)?.id;
    if (typeof id !== "string") throw new DbError("queue_message", { message: "no row returned" });
    return id;
  }

  let data: unknown;
  let error: { code?: string | null; message?: string } | null;
  let operation: string;
  if (input.quote_id !== undefined || input.invoice_id !== undefined) {
    // As the caller: the RPC re-checks that they manage the document's shop
    // and renders the quote_sent / invoice_sent template with the document's
    // link, amount and balance (0090).
    operation = "enqueue_document_message";
    const user = userClient(req, { env: svc.env, fetch: svc.deps.fetch });
    ({ data, error } = await user.rpc(operation, {
      p_quote_id: input.quote_id ?? null,
      p_invoice_id: input.invoice_id ?? null,
      p_channel: channel,
      p_request_nonce: nonce,
    }));
    if (error?.code === "55000") {
      // The wording needs customer links and the platform has no app URL.
      throw refusal("missing_link", channel, error, {
        message:
          "Customer links are not set up on this platform yet, so this message cannot be sent.",
      });
    }
  } else if (input.job_id) {
    // As the caller: the RPC re-checks role, assignment and technician keys.
    operation = "enqueue_template_message";
    const user = userClient(req, { env: svc.env, fetch: svc.deps.fetch });
    ({ data, error } = await user.rpc(operation, {
      p_job_id: input.job_id,
      p_key: input.template_key,
      p_channel: channel,
      p_request_nonce: nonce,
    }));
  } else {
    // Customer-level template (no job; CUSTOMER_TEMPLATE_KEYS only, checked
    // in send): only enqueue_customer_template exists for this, and it is
    // service-role only. The caller was verified as manager+ of
    // input.shop_id above and the RPC scopes the customer to that shop.
    operation = "enqueue_customer_template";
    ({ data, error } = await svc.admin.rpc(operation, {
      p_shop_id: input.shop_id,
      p_customer_id: customerId,
      p_key: input.template_key,
      p_channel: channel,
      p_sent_by: callerId,
      p_request_nonce: nonce,
    }));
  }
  if (error) throw await refused(error, operation);
  if (typeof data === "string" && data !== "") return data;
  // null: the database queued nothing (opted out, no address, template off...).
  throw refusal(
    await diagnose(svc, input.shop_id, customerId, channel, input.template_key, input.job_id),
    channel,
  );
}
