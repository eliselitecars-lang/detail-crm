/**
 * The sender pipeline shared by `process_queue` (cron) and `send` (staff):
 *
 *   claim  claim_queued_messages(limit)  -> rows locked as 'sending'
 *          (or claimOne(id) for the message a staff member just queued)
 *   gate   campaign rows whose customer withdrew marketing consent since
 *          launch -> cancelled (the claim only re-checks hard opt-outs)
 *   send   SMS via Twilio (from = the shop's number returned by the claim,
 *          only if the platform provisioned that number for the shop, see
 *          sender.ts; StatusCallback = messaging?action=twilio_status) or
 *          email via Resend (from = EMAIL_FROM relabelled with the shop name,
 *          reply-to = shop email, idempotency key = message id; campaign
 *          mail carries RFC 8058 one-click List-Unsubscribe)
 *   mark   mark_message_result(sent | failed | queued=retry with backoff)
 *          (+ Twilio 21610 "unsubscribed" records the customer's SMS opt-out)
 *
 * A provider failure never aborts the batch: each message gets its own
 * outcome. Retry policy (the DB fails a message after 5 attempts):
 *   - Twilio: 429/5xx -> retry; a request that never got an HTTP answer is
 *     FAILED, not retried, because Twilio has no idempotency keys and the
 *     text may already be on its way (never double-send); permanent
 *     recipient errors (21610 unsubscribed, 21211 invalid...) and other 4xx
 *     -> failed.
 *   - Resend: network/429/5xx -> retry (the message-id idempotency key makes
 *     a retry of an accepted email a no-op for 24 h); other 4xx -> failed.
 *   - Missing provider configuration -> retry (fix the secret; the DB gives
 *     up after 5 attempts).
 */
import { fromWithDisplayName } from "../_shared/email.ts";
import { EnvError } from "../_shared/env.ts";
import { functionUrl } from "../_shared/links.ts";
import { ResendError, sendEmail } from "../_shared/resend.ts";
import { textToHtml } from "../_shared/templates.ts";
import { PERMANENT_RECIPIENT_ERRORS, sendSms, TwilioError } from "../_shared/twilio.ts";
import { DbError, errorText, mapWithConcurrency, type Services } from "./lib.ts";
import { recordSmsOptOut, TWILIO_UNSUBSCRIBED } from "./optout.ts";
import { checkSmsSender, withConnectionOverrides } from "./sender.ts";

export type Channel = "sms" | "email";

export type MessageStatus =
  | "queued"
  | "sending"
  | "sent"
  | "delivered"
  | "failed"
  | "received"
  | "cancelled";

/** A row returned by claim_queued_messages (status is now 'sending'). */
export interface ClaimedMessage {
  id: string;
  shop_id: string;
  channel: Channel;
  to_address: string;
  /** SMS: the shop's sending number (set by the claim). */
  from_address: string | null;
  subject: string | null;
  body: string;
  attempts: number;
  shop_name: string;
  /** The shop's email (reply-to for emails). */
  reply_to: string | null;
  customer_id: string | null;
  job_id: string | null;
  campaign_id: string | null;
  template_key: string | null;
}

export type SendOutcome =
  | { status: "sent"; providerId: string; fromAddress: string | null }
  | {
    status: "failed" | "queued";
    error: string;
    /** Twilio 21610: the recipient unsubscribed from this number (record the opt-out). */
    recipientOptedOut?: boolean;
  };

export interface DeliveryResult {
  id: string;
  /** Status recorded in the database after the attempt. */
  status: MessageStatus;
  /** What the attempt asked the database to record. */
  outcome: SendOutcome["status"];
  error: string | null;
  /** False when mark_message_result itself failed (row stays 'sending'). */
  recorded: boolean;
}

export const DEFAULT_BATCH_SIZE = 50;
export const DEFAULT_QUEUE_LIMIT = 200;
export const MAX_QUEUE_LIMIT = 1000;
export const DEFAULT_TIME_BUDGET_MS = 45_000;
export const DEFAULT_CONCURRENCY = 5;

/** Delivery status webhook, with connection overrides so Twilio retries a 5xx. */
export function twilioStatusCallbackUrl(svc: Services): string {
  return withConnectionOverrides(
    functionUrl(svc.env.functionsPublicUrl(), "messaging", { action: "twilio_status" }),
  );
}

/**
 * Campaign emails' one-click unsubscribe endpoint (RFC 8058):
 * messaging?action=unsubscribe&token=<message id>. POST unsubscribes
 * (public_unsubscribe, 0035); GET redirects to the /u/<message id> page.
 */
export function unsubscribeUrl(svc: Services, messageId: string): string | null {
  try {
    return functionUrl(svc.env.functionsPublicUrl(), "messaging", {
      action: "unsubscribe",
      token: messageId,
    });
  } catch {
    return null;
  }
}

/** List-Unsubscribe headers for a campaign email (none for transactional mail). */
export function unsubscribeHeaders(svc: Services, msg: ClaimedMessage): Record<string, string> {
  if (!msg.campaign_id) return {};
  const url = unsubscribeUrl(svc, msg.id);
  if (!url) return {};
  return {
    "List-Unsubscribe": `<${url}>`,
    "List-Unsubscribe-Post": "List-Unsubscribe=One-Click",
  };
}

/** Sends one claimed message through its provider. Never throws. */
export async function sendClaimed(svc: Services, msg: ClaimedMessage): Promise<SendOutcome> {
  try {
    if (msg.channel === "sms") {
      if (!msg.from_address) {
        return { status: "failed", error: "text messaging is not set up for this shop" };
      }
      // shops.sms_from_number is tenant-editable: only send from a number
      // the platform provisioned for this shop (sender.ts).
      const sender = await checkSmsSender(svc, msg.shop_id, msg.from_address);
      if (!sender.ok) {
        return { status: sender.retry ? "queued" : "failed", error: sender.reason };
      }
      const sent = await sendSms(svc.env.twilio(), {
        to: msg.to_address,
        from: msg.from_address,
        body: msg.body,
        statusCallback: twilioStatusCallbackUrl(svc),
      }, svc.fetch);
      return { status: "sent", providerId: sent.sid, fromAddress: msg.from_address };
    }

    const resend = svc.env.resend();
    const headers = unsubscribeHeaders(svc, msg);
    const from = fromWithDisplayName(resend.from, msg.shop_name);
    const sent = await sendEmail(resend.apiKey, {
      from,
      to: msg.to_address,
      subject: msg.subject?.trim() || msg.shop_name,
      text: msg.body,
      html: textToHtml(msg.body),
      replyTo: msg.reply_to ?? undefined,
      idempotencyKey: `message-${msg.id}`,
      tags: [{ name: "message_id", value: msg.id }, { name: "shop_id", value: msg.shop_id }],
      headers,
    }, svc.fetch);
    return { status: "sent", providerId: sent.id, fromAddress: from };
  } catch (err) {
    return classifyFailure(err, msg.channel);
  }
}

/** Maps a send failure to failed (permanent) or queued (retry later). */
export function classifyFailure(err: unknown, channel: Channel): SendOutcome {
  if (err instanceof EnvError) {
    return {
      status: "queued",
      error: `the ${channel === "sms" ? "SMS" : "email"} provider is not configured`,
    };
  }
  if (err instanceof TwilioError) {
    const code = err.providerCode;
    const detail = errorText(`Twilio${code ? ` ${code}` : ""}: ${err.message}`);
    if (code === TWILIO_UNSUBSCRIBED) {
      return { status: "failed", error: detail, recipientOptedOut: true };
    }
    if (code && PERMANENT_RECIPIENT_ERRORS.has(code)) return { status: "failed", error: detail };
    if (err.httpStatus === null) {
      return {
        status: "failed",
        error: "the SMS provider could not be reached; the text may not have been sent",
      };
    }
    if (err.httpStatus === 429 || err.httpStatus >= 500) return { status: "queued", error: detail };
    return { status: "failed", error: detail };
  }
  if (err instanceof ResendError) {
    const detail = errorText(
      `Resend${err.providerCode ? ` ${err.providerCode}` : ""}: ${err.message}`,
    );
    if (err.httpStatus === null || err.httpStatus === 429 || err.httpStatus >= 500) {
      return { status: "queued", error: detail };
    }
    return { status: "failed", error: detail };
  }
  if (err instanceof TypeError) {
    // sendSms/sendEmail input checks: a bad address can never succeed.
    return { status: "failed", error: "invalid recipient or sender address" };
  }
  return { status: "queued", error: "unexpected error while sending" };
}

interface MarkedRow {
  id: string;
  status: MessageStatus;
  error: string | null;
}

export async function markResult(
  svc: Services,
  id: string,
  outcome: SendOutcome,
): Promise<MarkedRow> {
  const args = outcome.status === "sent"
    ? {
      p_id: id,
      p_status: "sent",
      p_provider_id: outcome.providerId,
      p_from_address: outcome.fromAddress,
    }
    : { p_id: id, p_status: outcome.status, p_error: outcome.error };
  const { data, error } = await svc.admin.rpc("mark_message_result", args);
  if (error) throw new DbError("mark_message_result", error);
  const row = data as MarkedRow | null;
  if (!row || typeof row.status !== "string") {
    throw new DbError("mark_message_result", { message: "no row returned" });
  }
  return row;
}

/** Sends a claimed message and records the result. Never throws. */
export async function deliverClaimed(svc: Services, msg: ClaimedMessage): Promise<DeliveryResult> {
  const outcome = await sendClaimed(svc, msg);
  const fields = { message_id: msg.id, shop_id: msg.shop_id, channel: msg.channel };
  if (outcome.status === "sent") svc.log.info("message_sent", fields);
  else {
    svc.log.warn("message_not_sent", { ...fields, outcome: outcome.status, reason: outcome.error });
    if (outcome.recipientOptedOut && msg.channel === "sms") {
      try {
        await recordSmsOptOut(svc, msg.shop_id, msg.to_address);
      } catch (err) {
        svc.log.error("sms_opt_out_record_failed", { ...fields, error: err });
      }
    }
  }
  return await recordOutcome(svc, msg, outcome);
}

/** Records an attempt's outcome (mark_message_result, retried once). Never throws. */
async function recordOutcome(
  svc: Services,
  msg: ClaimedMessage,
  outcome: SendOutcome,
): Promise<DeliveryResult> {
  const fields = { message_id: msg.id, shop_id: msg.shop_id, channel: msg.channel };
  // A lost result after a real send must not turn into a resend, so the mark
  // is retried once; if it still fails the row stays 'sending' and the
  // claim's stuck-send sweep fails it after 15 minutes (never re-sent).
  for (let attempt = 1; attempt <= 2; attempt++) {
    try {
      const row = await markResult(svc, msg.id, outcome);
      return {
        id: msg.id,
        status: row.status,
        outcome: outcome.status,
        error: row.error ?? null,
        recorded: true,
      };
    } catch (err) {
      svc.log.error("mark_message_result_failed", { ...fields, attempt, error: err });
    }
  }
  return {
    id: msg.id,
    status: "sending",
    outcome: outcome.status,
    error: outcome.status === "sent" ? null : outcome.error,
    recorded: false,
  };
}

export async function claimQueued(svc: Services, limit: number): Promise<ClaimedMessage[]> {
  const { data, error } = await svc.admin.rpc("claim_queued_messages", { p_limit: limit });
  if (error) throw new DbError("claim_queued_messages", error);
  return (Array.isArray(data) ? data : []) as ClaimedMessage[];
}

export interface QueueRunSummary {
  batches: number;
  claimed: number;
  sent: number;
  failed: number;
  retried: number;
  /** Campaign messages cancelled because marketing consent was withdrawn after launch. */
  cancelled: number;
  /** Results that could not be recorded (rows left 'sending' for the sweep). */
  unrecorded: number;
  /** True when the run stopped at its limit/time budget with work possibly left. */
  more: boolean;
}

/**
 * Drains the queue in bounded batches until it is empty, `limit` messages
 * were claimed, or the time budget is spent (the next cron run continues;
 * concurrent runs are safe because the claim skips locked rows).
 */
export async function processQueue(
  svc: Services,
  options: { limit: number; batchSize?: number; timeBudgetMs?: number; concurrency?: number },
): Promise<QueueRunSummary> {
  const batchSize = Math.max(1, Math.min(options.batchSize ?? DEFAULT_BATCH_SIZE, options.limit));
  const deadline = Date.now() + (options.timeBudgetMs ?? DEFAULT_TIME_BUDGET_MS);
  const concurrency = options.concurrency ?? DEFAULT_CONCURRENCY;
  const summary: QueueRunSummary = {
    batches: 0,
    claimed: 0,
    sent: 0,
    failed: 0,
    retried: 0,
    cancelled: 0,
    unrecorded: 0,
    more: false,
  };

  while (summary.claimed < options.limit) {
    if (Date.now() >= deadline) {
      summary.more = true;
      break;
    }
    const want = Math.min(batchSize, options.limit - summary.claimed);
    const batch = await claimQueued(svc, want);
    summary.batches += 1;
    summary.claimed += batch.length;
    const gate = await gateCampaignConsent(svc, batch);
    summary.cancelled += gate.cancelled;
    const results = await mapWithConcurrency(
      gate.messages,
      concurrency,
      (item) =>
        item.retry
          ? recordOutcome(svc, item.msg, { status: "queued", error: item.retry })
          : deliverClaimed(svc, item.msg),
    );
    for (const result of results) {
      if (!result.recorded) summary.unrecorded += 1;
      else if (result.outcome === "sent") summary.sent += 1;
      else if (result.status === "queued") summary.retried += 1;
      else summary.failed += 1;
    }
    if (batch.length < want) break;
    if (summary.claimed >= options.limit) summary.more = true;
  }
  return summary;
}

// ---------------------------------------------------------------------------
// Campaign consent gate
// ---------------------------------------------------------------------------

export const CONSENT_WITHDRAWN = "the recipient withdrew marketing consent before sending";
export const CONSENT_UNVERIFIED = "marketing consent could not be verified; will retry";

interface GatedMessage {
  msg: ClaimedMessage;
  /** Set when the message must not be sent now: the retry reason. */
  retry?: string;
}

/**
 * launch_campaign only queues customers who opted in (sms_opt_in /
 * email_opt_in) at launch, and a scheduled campaign is sent later;
 * claim_queued_messages re-checks only the hard opt-out stamps. So a
 * customer whose marketing opt-in was withdrawn in between (e.g. staff
 * unticked it, transactional texts still allowed) must be dropped here:
 * those campaign rows are cancelled, never sent. If consent cannot be read
 * the rows are put back in the queue (retry), never sent unverified.
 */
async function gateCampaignConsent(
  svc: Services,
  batch: ClaimedMessage[],
): Promise<{ messages: GatedMessage[]; cancelled: number }> {
  const campaign = batch.filter((m) => m.campaign_id !== null);
  if (campaign.length === 0) return { messages: batch.map((msg) => ({ msg })), cancelled: 0 };

  const unverified = (ids: Set<string>) => ({
    messages: batch.map((msg) => ids.has(msg.id) ? { msg, retry: CONSENT_UNVERIFIED } : { msg }),
    cancelled: 0,
  });
  const campaignIds = new Set(campaign.map((m) => m.id));

  const customerIds = [
    ...new Set(campaign.map((m) => m.customer_id).filter((id): id is string => id !== null)),
  ];
  const consent = new Map<
    string,
    { shop_id: string; sms_opt_in: boolean; email_opt_in: boolean }
  >();
  if (customerIds.length > 0) {
    const { data, error } = await svc.admin.from("customers")
      .select("id, shop_id, sms_opt_in, email_opt_in").in("id", customerIds);
    if (error) {
      svc.log.error("campaign_consent_lookup_failed", { error: new DbError("customers", error) });
      return unverified(campaignIds);
    }
    for (const row of (data ?? []) as Array<Record<string, unknown>>) {
      consent.set(String(row.id), {
        shop_id: String(row.shop_id),
        sms_opt_in: row.sms_opt_in === true,
        email_opt_in: row.email_opt_in === true,
      });
    }
  }

  const withdrawn = campaign.filter((m) => {
    const row = m.customer_id ? consent.get(m.customer_id) : undefined;
    if (!row || row.shop_id !== m.shop_id) return true;
    return m.channel === "sms" ? !row.sms_opt_in : !row.email_opt_in;
  });
  if (withdrawn.length === 0) return { messages: batch.map((msg) => ({ msg })), cancelled: 0 };

  const withdrawnIds = new Set(withdrawn.map((m) => m.id));
  const { data: updated, error: cancelError } = await svc.admin.from("messages")
    .update({ status: "cancelled", error: CONSENT_WITHDRAWN })
    .in("id", [...withdrawnIds]).eq("status", "sending").select("id");
  if (cancelError) {
    svc.log.error("campaign_consent_cancel_failed", {
      error: new DbError("messages cancel", cancelError),
    });
    return unverified(withdrawnIds);
  }
  const cancelled = Array.isArray(updated) ? updated.length : 0;
  for (const msg of withdrawn) {
    svc.log.info("message_cancelled", {
      message_id: msg.id,
      shop_id: msg.shop_id,
      channel: msg.channel,
      reason: "marketing_consent_withdrawn",
    });
  }
  return {
    messages: batch.filter((m) => !withdrawnIds.has(m.id)).map((msg) => ({ msg })),
    cancelled,
  };
}

// ---------------------------------------------------------------------------
// claimOne — the single message a staff member just queued
// ---------------------------------------------------------------------------

interface MessageRow {
  id: string;
  shop_id: string;
  customer_id: string | null;
  job_id: string | null;
  campaign_id: string | null;
  template_key: string | null;
  direction: string;
  channel: Channel;
  to_address: string;
  from_address: string | null;
  subject: string | null;
  body: string;
  attempts: number;
  status: MessageStatus;
  send_after: string;
}

const MESSAGE_COLUMNS =
  "id, shop_id, customer_id, job_id, campaign_id, template_key, direction, channel, to_address, " +
  "from_address, subject, body, attempts, status, send_after";

/**
 * send_after is stamped by the database clock (now()) while this check uses
 * the edge clock; a message queued "now" must not be deferred by skew.
 */
const CLOCK_SKEW_TOLERANCE_MS = 120_000;

export type ClaimOneResult =
  | { claimed: ClaimedMessage }
  | { claimed: null; status: MessageStatus; error: string | null };

async function loadMessage(svc: Services, shopId: string, id: string): Promise<MessageRow> {
  const { data, error } = await svc.admin.from("messages").select(MESSAGE_COLUMNS)
    .eq("shop_id", shopId).eq("id", id).maybeSingle();
  if (error) throw new DbError("messages lookup", error);
  if (!data) throw new DbError("messages lookup", { message: "queued message not found" });
  return data as unknown as MessageRow;
}

async function settle(
  svc: Services,
  msg: MessageRow,
  status: "cancelled" | "failed",
  reason: string,
): Promise<ClaimOneResult> {
  const { data, error } = await svc.admin.from("messages")
    .update({ status, error: reason })
    .eq("shop_id", msg.shop_id).eq("id", msg.id).eq("status", "queued")
    .select("id");
  if (error) throw new DbError("messages settle", error);
  if (Array.isArray(data) && data.length === 1) return { claimed: null, status, error: reason };
  const current = await loadMessage(svc, msg.shop_id, msg.id);
  return { claimed: null, status: current.status, error: null };
}

/**
 * Claims ONE queued message for immediate delivery with the same rules as
 * claim_queued_messages (opted out -> cancelled; SMS without a shop number
 * -> failed; else 'sending', attempts + 1, from = shop number). The update
 * is a compare-and-set on (status = 'queued', attempts), so if the cron
 * worker claimed the row first this returns its current status instead and
 * the message is sent exactly once.
 */
export async function claimOne(
  svc: Services,
  shopId: string,
  messageId: string,
): Promise<ClaimOneResult> {
  const msg = await loadMessage(svc, shopId, messageId);
  const now = svc.now();
  if (
    msg.direction !== "outbound" || msg.status !== "queued" ||
    Date.parse(msg.send_after) > now.getTime() + CLOCK_SKEW_TOLERANCE_MS
  ) {
    return { claimed: null, status: msg.status, error: null };
  }

  const { data: shop, error: shopError } = await svc.admin.from("shops")
    .select("name, email, sms_from_number").eq("id", shopId).single();
  if (shopError) throw new DbError("shops lookup", shopError);
  const shopRow = shop as { name: string; email: string | null; sms_from_number: string | null };

  let optedOut = false;
  if (msg.customer_id) {
    const { data: customer, error: customerError } = await svc.admin.from("customers")
      .select("sms_opted_out_at, email_opted_out_at")
      .eq("shop_id", shopId).eq("id", msg.customer_id).maybeSingle();
    if (customerError) throw new DbError("customers lookup", customerError);
    const row = customer as
      | { sms_opted_out_at: string | null; email_opted_out_at: string | null }
      | null;
    const stamp = msg.channel === "sms" ? row?.sms_opted_out_at : row?.email_opted_out_at;
    optedOut = stamp !== null && stamp !== undefined;
  }
  if (optedOut) {
    return await settle(svc, msg, "cancelled", "the recipient opted out before sending");
  }
  if (msg.channel === "sms" && !shopRow.sms_from_number) {
    return await settle(svc, msg, "failed", "text messaging is not set up for this shop");
  }

  const fromAddress = msg.channel === "sms" ? shopRow.sms_from_number : msg.from_address;
  const { data: updated, error: updateError } = await svc.admin.from("messages")
    .update({
      status: "sending",
      attempts: msg.attempts + 1,
      claimed_at: now.toISOString(),
      from_address: fromAddress,
    })
    .eq("shop_id", shopId).eq("id", msg.id).eq("status", "queued").eq("attempts", msg.attempts)
    .select("id");
  if (updateError) throw new DbError("messages claim", updateError);
  if (!Array.isArray(updated) || updated.length !== 1) {
    const current = await loadMessage(svc, shopId, msg.id);
    return { claimed: null, status: current.status, error: null };
  }

  return {
    claimed: {
      id: msg.id,
      shop_id: msg.shop_id,
      channel: msg.channel,
      to_address: msg.to_address,
      from_address: fromAddress,
      subject: msg.subject,
      body: msg.body,
      attempts: msg.attempts + 1,
      shop_name: shopRow.name,
      reply_to: shopRow.email,
      customer_id: msg.customer_id,
      job_id: msg.job_id,
      campaign_id: msg.campaign_id,
      template_key: msg.template_key,
    },
  };
}
