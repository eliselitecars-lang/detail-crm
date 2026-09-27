/**
 * `send` — a staff member messages a customer, then the message is delivered
 * immediately through the same pipeline as the cron sender.
 *
 *   owner/admin/manager  free-form `body` (queue_message) or `template_key`
 *                        (enqueue_template_message for a job, or the
 *                        customer-level template when no job is given)
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
import { uuid } from "../_shared/schemas.ts";
import { userClient } from "../_shared/supabase.ts";
import { type Channel, claimOne, deliverClaimed, type MessageStatus } from "./deliver.ts";
import { DbError, rpcRefusal, type Services } from "./lib.ts";

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

export const SMS_MAX_LENGTH = 1600;
export const EMAIL_MAX_LENGTH = 50_000;
export const SUBJECT_MAX_LENGTH = 500;

export const sendInput = z.object({
  /** Optional: derived from the job/customer when omitted. */
  shop_id: uuid.optional(),
  customer_id: uuid.optional(),
  job_id: uuid.optional(),
  channel: z.enum(["sms", "email"]),
  template_key: z.enum(SENDABLE_TEMPLATE_KEYS).optional(),
  subject: z.string().max(SUBJECT_MAX_LENGTH).optional(),
  body: z.string().max(EMAIL_MAX_LENGTH).optional(),
}).strict().superRefine((input, ctx) => {
  const issue = (path: string, message: string) =>
    ctx.addIssue({ code: "custom", path: [path], message });
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
  | "empty_message"
  | "job_customer_mismatch"
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
  empty_message: () => "The template produced an empty message.",
  job_customer_mismatch: () => "The job belongs to a different customer.",
  not_sendable: () => "This message cannot be sent.",
};

export function refusal(reason: RefusalReason, channel: Channel, cause?: unknown): HttpError {
  return new HttpError("unprocessable", REFUSAL_MESSAGES[reason](channel), {
    details: { reason },
    cause,
  });
}

/** Works out why a message was refused / not queued (service-role reads, shop-scoped). */
async function diagnose(
  svc: Services,
  shopId: string,
  customerId: string,
  channel: Channel,
  templateKey?: string,
): Promise<RefusalReason> {
  const { admin } = svc;
  const { data: customer, error } = await admin.from("customers")
    .select("phone, email, sms_opted_out_at, email_opted_out_at")
    .eq("shop_id", shopId).eq("id", customerId).maybeSingle();
  if (error) throw new DbError("customers lookup", error);
  const row = customer as
    | {
      phone: string | null;
      email: string | null;
      sms_opted_out_at: string | null;
      email_opted_out_at: string | null;
    }
    | null;
  if (!row) return "not_sendable";
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

/**
 * The shop the message is for: the job's shop, else the customer's shop
 * (service-role lookup by id). Missing rows are `not_found`.
 */
async function deriveShopId(svc: Services, input: SendInput): Promise<string> {
  const [table, id, label] = input.job_id
    ? ["jobs", input.job_id, "Job"] as const
    : ["customers", input.customer_id, "Customer"] as const;
  if (!id) throw errors.badRequest("customer_id or job_id is required.");
  const { data, error } = await svc.admin.from(table).select("shop_id").eq("id", id).maybeSingle();
  if (error) throw new DbError(`${table} lookup`, error);
  const shopId = (data as { shop_id?: unknown } | null)?.shop_id;
  if (typeof shopId !== "string") throw errors.notFound(`${label} not found.`);
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
  if (!membership) throw errors.notFound(input.job_id ? "Job not found." : "Customer not found.");
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

  if (!isManager) {
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

  let job: JobRow | null = null;
  if (input.job_id) {
    job = await loadJob(svc, input.shop_id, input.job_id);
    if (input.customer_id && input.customer_id !== job.customer_id) {
      throw refusal("job_customer_mismatch", channel);
    }
  }
  const customerId = input.customer_id ?? job?.customer_id;
  if (!customerId) throw errors.badRequest("customer_id or job_id is required.");

  const messageId = await queue(svc, req, input, caller.id, customerId, channel);

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
    status: result.status,
  });
  return { message_id: messageId, channel, status: result.status, error: result.error };
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
  const refused = async (error: { code?: string | null }, operation: string) => {
    const mapped = rpcRefusal(operation, error);
    if (mapped instanceof HttpError && mapped.code === "unprocessable") {
      return refusal(
        await diagnose(svc, input.shop_id, customerId, channel, input.template_key),
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
    });
    if (error) throw await refused(error, "queue_message");
    const id = (data as { id?: unknown } | null)?.id;
    if (typeof id !== "string") throw new DbError("queue_message", { message: "no row returned" });
    return id;
  }

  let data: unknown;
  let error: { code?: string | null; message?: string } | null;
  let operation: string;
  if (input.job_id) {
    // As the caller: the RPC re-checks role, assignment and technician keys.
    operation = "enqueue_template_message";
    const user = userClient(req, { env: svc.env, fetch: svc.deps.fetch });
    ({ data, error } = await user.rpc(operation, {
      p_job_id: input.job_id,
      p_key: input.template_key,
      p_channel: channel,
    }));
  } else {
    // Customer-level template (no job): only enqueue_customer_template
    // exists for this, and it is service-role only. The caller was verified
    // as manager+ of input.shop_id above and the RPC scopes the customer to
    // that shop.
    operation = "enqueue_customer_template";
    ({ data, error } = await svc.admin.rpc(operation, {
      p_shop_id: input.shop_id,
      p_customer_id: customerId,
      p_key: input.template_key,
      p_channel: channel,
      p_sent_by: callerId,
    }));
  }
  if (error) throw await refused(error, operation);
  if (typeof data === "string" && data !== "") return data;
  // null: the database queued nothing (opted out, no address, template off...).
  throw refusal(
    await diagnose(svc, input.shop_id, customerId, channel, input.template_key),
    channel,
  );
}
