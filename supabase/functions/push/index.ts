/**
 * push — APNs notifications for the staff iPhone app (P-2; queue in
 * migration 0082). verify_jwt = false: the queue action is pg_cron
 * (x-cron-secret) and the test action verifies the staff JWT itself.
 *
 *   process_queue  {limit?}     (x-cron-secret) claim_push_batch -> one APNs
 *                               request per enabled device of the recipient
 *                               -> mark_push_token_invalid (410, BadDeviceToken,
 *                               DeviceTokenNotForTopic, Unregistered) or
 *                               release_push (429 / 5xx / network, nothing
 *                               delivered) -> batch after batch until the queue
 *                               is empty or ~25 s passed. Each APNs request
 *                               is capped at 10 s and the whole run at 45 s
 *                               (RUN_DEADLINE_MS): what is not attempted by
 *                               then is released, never left claimed.
 *   send_test      {shop_id}    (any active staff member) "Test notification"
 *                               to the CALLER's own enabled devices only.
 *
 * The database decides who is pushed what (claim_push_batch: kind readable
 * by the recipient's current role, not muted, kind switched on, created
 * within the hour) and never puts money or phone numbers in the text; this
 * function only delivers. A notification is claimed once (pushed_at): a
 * worker that dies mid-batch loses those pushes (the in-app list still has
 * them) rather than ever sending one twice.
 *
 * APNs credentials (APNS_KEY_ID, APNS_TEAM_ID, APNS_PRIVATE_KEY, APNS_TOPIC)
 * are optional for the platform: while none is set the queue run is a
 * no-op ({configured: false}) and the queue is left untouched; a partial or
 * malformed set is 500 server_misconfigured (EnvError names the variable).
 */
import { z } from "zod";
import { createActionRouter, jsonAction } from "../_shared/actions.ts";
import {
  type ApnsEnvironment,
  type ApnsResult,
  ApnsTokenSigner,
  sendApns,
} from "../_shared/apns.ts";
import { requireCronSecret, requireShopRole, requireUser, ROLES } from "../_shared/auth.ts";
import type { ApnsEnv, Env } from "../_shared/env.ts";
import { HttpError } from "../_shared/errors.ts";
import { createHandler } from "../_shared/http.ts";
import type { Logger } from "../_shared/log.ts";
import { uuid } from "../_shared/schemas.ts";
import { adminClient, type SupabaseClient } from "../_shared/supabase.ts";

export interface Deps {
  env?: Env;
  fetch?: typeof fetch;
  logger?: Logger;
  /** Monotonic milliseconds for the time budget (tests). */
  clock?: () => number;
  /** Wall-clock milliseconds for provider tokens and expirations (tests). */
  now?: () => number;
  /** Parallel APNs requests (tests pin 1 for deterministic ordering). */
  concurrency?: number;
}

/** Notifications per claim (claim_push_batch caps at 500). */
export const DEFAULT_BATCH = 100;
/** Stop claiming after this long (the cron job's HTTP timeout is 60 s). */
export const TIME_BUDGET_MS = 25_000;
/**
 * Hard deadline for a run (or a test send): no APNs request runs past it,
 * and pushes not yet attempted by then are answered "retry" and re-queued
 * (release_push) instead of being stranded by a killed worker. Each request
 * is also capped at APNS_REQUEST_TIMEOUT_MS.
 */
export const RUN_DEADLINE_MS = 45_000;
/** Safety cap on claims per run. */
export const MAX_BATCHES = 50;
/** Parallel APNs requests. */
export const CONCURRENCY = 8;

const APNS_VARS = ["APNS_KEY_ID", "APNS_TEAM_ID", "APNS_PRIVATE_KEY", "APNS_TOPIC"] as const;

export const processQueueInput = z.object({
  limit: z.number().int().min(1).max(500).optional(),
}).strict();

export const sendTestInput = z.object({ shop_id: uuid }).strict();

interface DeviceToken {
  token: string;
  apns_env: ApnsEnvironment;
}

/** A row of claim_push_batch (0082). */
export interface ClaimedPush {
  notification_id: string;
  shop_id: string;
  user_id: string;
  kind: string;
  title: string;
  body: string | null;
  job_id: string | null;
  customer_id: string | null;
  quote_id: string | null;
  invoice_id: string | null;
  badge: number;
  tokens: DeviceToken[] | null;
}

export interface QueueSummary {
  configured: boolean;
  batches: number;
  claimed: number;
  sent: number;
  failed: number;
  released: number;
  invalid_tokens: number;
  more: boolean;
}

export interface SendTestResponse {
  sent: number;
  failed: number;
  invalid_tokens: number;
}

function dbFailure(what: string, error: { message?: string; code?: string }): Error {
  return new Error(`${what} failed: ${error.code ?? ""} ${error.message ?? ""}`.trim(), {
    cause: error,
  });
}

/** The APNs payload for a claimed notification (deep-link ids at the top level). */
export function payloadFor(row: ClaimedPush): Record<string, unknown> {
  const alert: Record<string, string> = { title: row.title };
  if (row.body) alert.body = row.body;
  const payload: Record<string, unknown> = {
    aps: {
      alert,
      badge: Math.max(0, Math.trunc(row.badge ?? 0)),
      sound: "default",
      "thread-id": row.kind,
    },
    kind: row.kind,
    shop_id: row.shop_id,
    job_id: row.job_id,
    customer_id: row.customer_id,
    notification_id: row.notification_id,
  };
  if (row.quote_id) payload.quote_id = row.quote_id;
  if (row.invoice_id) payload.invoice_id = row.invoice_id;
  return payload;
}

async function mapLimit<T, R>(
  items: readonly T[],
  limit: number,
  fn: (item: T) => Promise<R>,
): Promise<R[]> {
  const out: R[] = new Array(items.length);
  let next = 0;
  const workers = Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (next < items.length) {
      const index = next++;
      out[index] = await fn(items[index] as T);
    }
  });
  await Promise.all(workers);
  return out;
}

interface Pusher {
  fetch: typeof fetch;
  signer: ApnsTokenSigner;
  topic: string;
  now: () => number;
  /** Milliseconds left before RUN_DEADLINE_MS. */
  remainingMs: () => number;
  /** Parallel APNs requests. */
  concurrency: number;
}

let sharedSigner: ApnsTokenSigner | undefined;

function signerFor(apns: ApnsEnv, now: () => number, shared: boolean): ApnsTokenSigner {
  if (!shared) return new ApnsTokenSigner(apns, now);
  if (!sharedSigner || !sharedSigner.matches(apns)) sharedSigner = new ApnsTokenSigner(apns, now);
  return sharedSigner;
}

async function markInvalid(admin: SupabaseClient, token: string, reason: string): Promise<void> {
  const { error } = await admin.rpc("mark_push_token_invalid", {
    p_token: token,
    p_reason: reason,
  });
  if (error) throw dbFailure("mark_push_token_invalid", error);
}

interface NotificationOutcome {
  delivered: boolean;
  released: boolean;
  invalidTokens: number;
}

async function pushOne(
  admin: SupabaseClient,
  pusher: Pusher,
  row: ClaimedPush,
  log: Logger,
): Promise<NotificationOutcome> {
  const tokens = Array.isArray(row.tokens) ? row.tokens : [];
  const payload = payloadFor(row);
  const results: ApnsResult[] = [];
  for (const device of tokens) {
    results.push(
      await sendApns(
        pusher.fetch,
        pusher.signer,
        {
          deviceToken: device.token,
          environment: device.apns_env === "sandbox" ? "sandbox" : "production",
          topic: pusher.topic,
          payload,
          collapseId: row.notification_id,
        },
        pusher.now,
        { remainingMs: pusher.remainingMs },
      ),
    );
  }
  let invalidTokens = 0;
  for (const [index, result] of results.entries()) {
    const device = tokens[index];
    if (result.status === "invalid_token" && device) {
      await markInvalid(admin, device.token, `APNs ${result.httpStatus} ${result.reason}`);
      invalidTokens += 1;
    } else if (result.status === "failed" || result.status === "retry") {
      log.warn("push_not_delivered", {
        notification_id: row.notification_id,
        outcome: result.status,
        http_status: result.httpStatus,
        reason: result.reason,
      });
    }
  }
  const delivered = results.some((r) => r.status === "sent");
  // Re-queue only when no device got it and a device may still get it later;
  // a partial success is final (a retry would alert the other devices twice).
  let released = false;
  if (!delivered && results.some((r) => r.status === "retry")) {
    const { data, error } = await admin.rpc("release_push", {
      p_notification_id: row.notification_id,
    });
    if (error) throw dbFailure("release_push", error);
    released = data === true;
  }
  return { delivered, released, invalidTokens };
}

export async function runQueue(
  admin: SupabaseClient,
  pusher: Pusher,
  limit: number,
  log: Logger,
  clock: () => number,
): Promise<QueueSummary> {
  const started = clock();
  const summary: QueueSummary = {
    configured: true,
    batches: 0,
    claimed: 0,
    sent: 0,
    failed: 0,
    released: 0,
    invalid_tokens: 0,
    more: false,
  };
  while (true) {
    if (summary.batches >= MAX_BATCHES || clock() - started >= TIME_BUDGET_MS) {
      summary.more = true;
      break;
    }
    const { data, error } = await admin.rpc("claim_push_batch", { p_limit: limit });
    if (error) throw dbFailure("claim_push_batch", error);
    const rows = (Array.isArray(data) ? data : []) as ClaimedPush[];
    // An empty claim ends the run. (Rows the claim settled without a push -
    // stale, muted, no device - are not returned, so a short batch is not
    // the end of the queue.)
    if (rows.length === 0) break;
    summary.batches += 1;
    summary.claimed += rows.length;
    const outcomes = await mapLimit(
      rows,
      pusher.concurrency,
      (row) => pushOne(admin, pusher, row, log),
    );
    for (const outcome of outcomes) {
      if (outcome.delivered) summary.sent += 1;
      else summary.failed += 1;
      if (outcome.released) summary.released += 1;
      summary.invalid_tokens += outcome.invalidTokens;
    }
  }
  log.info("push_queue_run", { ...summary });
  return summary;
}

function apnsConfigured(env: Env): boolean {
  return APNS_VARS.some((name) => env.optional(name) !== undefined);
}

export function makeHandler(deps: Deps = {}): (req: Request) => Promise<Response> {
  const clock = deps.clock ?? (() => performance.now());
  const now = deps.now ?? Date.now;
  const injected = deps.env !== undefined || deps.fetch !== undefined;
  const pusherFor = (env: Env): Pusher => {
    const apns = env.apns();
    const deadline = clock() + RUN_DEADLINE_MS;
    return {
      fetch: deps.fetch ?? fetch,
      signer: signerFor(apns, now, !injected),
      topic: apns.topic,
      now,
      remainingMs: () => deadline - clock(),
      concurrency: deps.concurrency ?? CONCURRENCY,
    };
  };

  const router = createActionRouter({
    process_queue: jsonAction(processQueueInput, async (input, ctx): Promise<QueueSummary> => {
      requireCronSecret(ctx.req, ctx.env.cronSecret());
      if (!apnsConfigured(ctx.env)) {
        // Push is optional: leave the queue alone until APNs is configured.
        return {
          configured: false,
          batches: 0,
          claimed: 0,
          sent: 0,
          failed: 0,
          released: 0,
          invalid_tokens: 0,
          more: false,
        };
      }
      const pusher = pusherFor(ctx.env); // before claiming: a bad secret claims nothing
      const admin = adminClient({ env: deps.env, fetch: deps.fetch });
      return await runQueue(admin, pusher, input.limit ?? DEFAULT_BATCH, ctx.log, clock);
    }),

    send_test: jsonAction(sendTestInput, async (input, ctx): Promise<SendTestResponse> => {
      const admin = adminClient({ env: deps.env, fetch: deps.fetch });
      const caller = await requireUser(ctx.req, { admin });
      await requireShopRole(admin, caller, input.shop_id, ROLES.anyStaff);
      const pusher = pusherFor(ctx.env);
      const { data, error } = await admin
        .from("device_push_tokens")
        .select("token, apns_env")
        .eq("user_id", caller.id)
        .is("disabled_at", null)
        .order("last_seen_at", { ascending: false })
        .limit(25);
      if (error) throw dbFailure("device_push_tokens", error);
      const devices = (data ?? []) as DeviceToken[];
      if (devices.length === 0) {
        throw new HttpError(
          "unprocessable",
          "Turn on notifications in the iPhone app first, then try again.",
          { details: { reason: "no_devices" } },
        );
      }
      const payload = {
        aps: {
          alert: {
            title: "Test notification",
            body: "Notifications from your shop will appear like this.",
          },
          sound: "default",
          "thread-id": "general",
        },
        kind: "general",
        shop_id: input.shop_id,
      };
      const results = await mapLimit(
        devices,
        CONCURRENCY,
        (device) =>
          sendApns(
            pusher.fetch,
            pusher.signer,
            {
              deviceToken: device.token,
              environment: device.apns_env === "sandbox" ? "sandbox" : "production",
              topic: pusher.topic,
              payload,
            },
            now,
            { remainingMs: pusher.remainingMs },
          ),
      );
      const response: SendTestResponse = { sent: 0, failed: 0, invalid_tokens: 0 };
      for (const [index, result] of results.entries()) {
        const device = devices[index];
        if (result.status === "sent") response.sent += 1;
        else if (result.status === "invalid_token" && device) {
          await markInvalid(admin, device.token, `APNs ${result.httpStatus} ${result.reason}`);
          response.invalid_tokens += 1;
        } else {
          response.failed += 1;
          ctx.log.warn("push_test_not_delivered", {
            outcome: result.status,
            http_status: result.httpStatus,
            reason: result.reason,
          });
        }
      }
      if (response.sent === 0 && response.failed === 0) {
        throw new HttpError(
          "unprocessable",
          "This device is no longer registered for notifications. Reopen the iPhone app and try again.",
          { details: { reason: "no_devices" } },
        );
      }
      if (response.sent === 0) {
        throw new HttpError(
          "upstream_error",
          "Apple's push service did not accept the test notification. Try again shortly.",
        );
      }
      return response;
    }),
  });

  return createHandler(
    { name: "push", env: deps.env, logger: deps.logger },
    (req, ctx) => router(req, ctx),
  );
}

if (import.meta.main) Deno.serve(makeHandler());
