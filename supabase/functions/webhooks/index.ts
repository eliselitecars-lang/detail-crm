/**
 * webhooks — delivers shops' outbound webhooks (P-27; queue, payloads and
 * retry schedule in migration 0089). pg_cron only; verify_jwt = false.
 *
 *   deliver  {limit?}  (x-cron-secret) claim_webhook_deliveries -> one signed
 *                      POST per delivery -> mark_webhook_delivery, batch after
 *                      batch until the queue is empty or the 40 s budget is
 *                      used. Each claim is sized so that its deliveries can
 *                      all time out and still finish inside the budget
 *                      (claimLimit), so the run never outlives the cron's
 *                      60 s HTTP timeout and no claimed row is stranded.
 *
 * Each request:
 *   POST <endpoint url>
 *   Content-Type: application/json
 *   User-Agent: DetailCRM-Webhooks/1
 *   X-DetailCRM-Event: <event>
 *   X-DetailCRM-Delivery: <delivery id>      (the same on every retry)
 *   X-DetailCRM-Signature: t=<unix>,v1=<hex HMAC-SHA256(secret, t + "." + body)>
 *   body: the JSON payload stored when the event happened (the signature
 *         covers exactly the bytes sent)
 *
 * Any 2xx is success; everything else (3xx - redirects are not followed -,
 * 4xx, 5xx, a network error, or no answer within 10 s, name resolution
 * included) is a failure the
 * database retries after 1 min, 5 min, 30 min, 2 h, 6 h, 12 h and 24 h. The
 * response body is never read. Before connecting, the URL must pass the
 * SSRF guard (_shared/ssrf.ts: https host names only, and every address the
 * name resolves to must be public); a refused URL is recorded as a failure
 * with the reason.
 */
import { z } from "zod";
import { createActionRouter, jsonAction } from "../_shared/actions.ts";
import { requireCronSecret } from "../_shared/auth.ts";
import type { Env } from "../_shared/env.ts";
import { createHandler } from "../_shared/http.ts";
import type { Logger } from "../_shared/log.ts";
import {
  checkOutboundUrl,
  checkResolvedAddresses,
  denoResolver,
  type Resolver,
} from "../_shared/ssrf.ts";
import { adminClient, type SupabaseClient } from "../_shared/supabase.ts";
import { SIGNATURE_HEADER, signatureHeader } from "../_shared/webhook_sign.ts";

export interface Deps {
  env?: Env;
  /** Supabase + receivers (tests inject FakeFetch). */
  fetch?: typeof fetch;
  logger?: Logger;
  resolver?: Resolver;
  /** Monotonic milliseconds for the time budget (tests). */
  clock?: () => number;
  /** Wall-clock milliseconds for signature timestamps (tests). */
  now?: () => number;
  /** Per-request timeout (tests). */
  timeoutMs?: number;
}

export const USER_AGENT = "DetailCRM-Webhooks/1";
export const REQUEST_TIMEOUT_MS = 10_000;
export const DEFAULT_BATCH = 50;
/** Hard deadline for a run: no delivery may still be in flight after it. */
export const TIME_BUDGET_MS = 40_000;
export const MAX_BATCHES = 60;
export const CONCURRENCY = 5;
/** Allowance per delivery on top of its request timeout (mark_webhook_delivery). */
export const MARK_ALLOWANCE_MS = 2_000;

/**
 * How many deliveries to claim with `remainingMs` left: every worker must be
 * able to finish its share (at most `timeoutMs` for DNS + the POST, plus
 * the mark) before the deadline, so a batch of hanging receivers cannot
 * overrun the run. 0 = no room for another round.
 */
export function claimLimit(requested: number, remainingMs: number, timeoutMs: number): number {
  const rounds = Math.floor(remainingMs / (timeoutMs + MARK_ALLOWANCE_MS));
  return Math.max(0, Math.min(requested, CONCURRENCY * rounds));
}

export const deliverInput = z.object({
  limit: z.number().int().min(1).max(500).optional(),
}).strict();

/** A row of claim_webhook_deliveries (0089). */
export interface ClaimedDelivery {
  id: string;
  endpoint_id: string;
  url: string;
  secret: string;
  event: string;
  payload: unknown;
  attempts: number;
}

export interface DeliverSummary {
  batches: number;
  claimed: number;
  succeeded: number;
  failed: number;
  more: boolean;
}

interface Attempt {
  statusCode: number | null;
  error: string | null;
}

function dbFailure(what: string, error: { message?: string; code?: string }): Error {
  return new Error(`${what} failed: ${error.code ?? ""} ${error.message ?? ""}`.trim(), {
    cause: error,
  });
}

function short(text: string): string {
  return text.length > 300 ? `${text.slice(0, 297)}...` : text;
}

let dnsWarned = false;

/** POSTs one delivery; never throws. */
export async function attemptDelivery(
  delivery: ClaimedDelivery,
  options: {
    fetch: typeof fetch;
    resolver: Resolver;
    nowSeconds: number;
    timeoutMs: number;
    log: Logger;
  },
): Promise<Attempt> {
  const guard = checkOutboundUrl(delivery.url);
  if (!guard.ok) return { statusCode: null, error: `refused: ${guard.reason}` };

  // One deadline covers name resolution and the request together.
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), options.timeoutMs);
  const within = options.timeoutMs >= 1000
    ? `${Math.round(options.timeoutMs / 1000)} s`
    : `${options.timeoutMs} ms`;
  try {
    const aborted = new Promise<"aborted">((resolve) => {
      controller.signal.addEventListener("abort", () => resolve("aborted"), { once: true });
    });
    const resolved = await Promise.race([
      checkResolvedAddresses(delivery.url, options.resolver),
      aborted,
    ]);
    if (resolved === "aborted") {
      return { statusCode: null, error: `the host name did not resolve within ${within}` };
    }
    if (resolved && !resolved.ok) {
      return { statusCode: null, error: `refused: ${resolved.reason}` };
    }
    if (resolved === null && !dnsWarned) {
      // No DNS in this runtime: the static checks still apply. Logged once per worker.
      dnsWarned = true;
      options.log.warn("webhook_dns_check_unavailable", { delivery_id: delivery.id });
    }
    return await post(delivery, options, controller, within);
  } finally {
    clearTimeout(timer);
  }
}

async function post(
  delivery: ClaimedDelivery,
  options: { fetch: typeof fetch; nowSeconds: number },
  controller: AbortController,
  within: string,
): Promise<Attempt> {
  const body = JSON.stringify(delivery.payload ?? {});
  try {
    const response = await options.fetch(delivery.url, {
      method: "POST",
      redirect: "manual",
      signal: controller.signal,
      headers: {
        "Content-Type": "application/json",
        "User-Agent": USER_AGENT,
        "X-DetailCRM-Event": delivery.event,
        "X-DetailCRM-Delivery": delivery.id,
        [SIGNATURE_HEADER]: await signatureHeader(delivery.secret, options.nowSeconds, body),
      },
      body,
    });
    // The body is never read (it could be arbitrarily large).
    await response.body?.cancel().catch(() => undefined);
    const status = response.status;
    if (status >= 200 && status < 300) return { statusCode: status, error: null };
    if (status >= 300 && status < 400) {
      return { statusCode: status, error: `redirects are not followed (HTTP ${status})` };
    }
    return { statusCode: status, error: `HTTP ${status}` };
  } catch (err) {
    if (controller.signal.aborted) {
      return { statusCode: null, error: `no response within ${within}` };
    }
    return {
      statusCode: null,
      error: short(`request failed: ${err instanceof Error ? err.message : String(err)}`),
    };
  }
}

async function mark(admin: SupabaseClient, id: string, attempt: Attempt): Promise<void> {
  const { error } = await admin.rpc("mark_webhook_delivery", {
    p_id: id,
    p_status_code: attempt.statusCode,
    p_error: attempt.error,
  });
  if (error) throw dbFailure("mark_webhook_delivery", error);
}

async function mapLimit<T, R>(
  items: readonly T[],
  limit: number,
  fn: (item: T) => Promise<R>,
): Promise<R[]> {
  const out: R[] = new Array(items.length);
  let next = 0;
  await Promise.all(
    Array.from({ length: Math.min(limit, items.length) }, async () => {
      while (next < items.length) {
        const index = next++;
        out[index] = await fn(items[index] as T);
      }
    }),
  );
  return out;
}

export function makeHandler(deps: Deps = {}): (req: Request) => Promise<Response> {
  const clock = deps.clock ?? (() => performance.now());
  const now = deps.now ?? Date.now;
  const router = createActionRouter({
    deliver: jsonAction(deliverInput, async (input, ctx): Promise<DeliverSummary> => {
      requireCronSecret(ctx.req, ctx.env.cronSecret());
      const admin = adminClient({ env: deps.env, fetch: deps.fetch });
      const requested = input.limit ?? DEFAULT_BATCH;
      const timeoutMs = deps.timeoutMs ?? REQUEST_TIMEOUT_MS;
      const started = clock();
      const summary: DeliverSummary = {
        batches: 0,
        claimed: 0,
        succeeded: 0,
        failed: 0,
        more: false,
      };
      while (true) {
        const limit = claimLimit(requested, TIME_BUDGET_MS - (clock() - started), timeoutMs);
        if (summary.batches >= MAX_BATCHES || limit === 0) {
          summary.more = true;
          break;
        }
        const { data, error } = await admin.rpc("claim_webhook_deliveries", { p_limit: limit });
        if (error) throw dbFailure("claim_webhook_deliveries", error);
        const rows = (Array.isArray(data) ? data : []) as ClaimedDelivery[];
        if (rows.length === 0) break;
        summary.batches += 1;
        summary.claimed += rows.length;
        const outcomes = await mapLimit(rows, CONCURRENCY, async (delivery) => {
          const attempt = await attemptDelivery(delivery, {
            fetch: deps.fetch ?? fetch,
            resolver: deps.resolver ?? denoResolver,
            nowSeconds: Math.floor(now() / 1000),
            timeoutMs,
            log: ctx.log,
          });
          if (attempt.error !== null) {
            ctx.log.warn("webhook_delivery_failed", {
              delivery_id: delivery.id,
              endpoint_id: delivery.endpoint_id,
              attempt: delivery.attempts,
              status_code: attempt.statusCode,
              reason: attempt.error,
            });
          }
          try {
            await mark(admin, delivery.id, attempt);
          } catch (err) {
            // The row stays 'delivering'; the claim re-queues it after 10 min.
            ctx.log.error("webhook_mark_failed", { delivery_id: delivery.id, error: err });
          }
          return attempt.error === null;
        });
        for (const ok of outcomes) {
          if (ok) summary.succeeded += 1;
          else summary.failed += 1;
        }
      }
      ctx.log.info("webhooks_delivered", { ...summary });
      return summary;
    }),
  });
  return createHandler(
    { name: "webhooks", env: deps.env, logger: deps.logger, cors: false },
    (req, ctx) => router(req, ctx),
  );
}

if (import.meta.main) Deno.serve(makeHandler());
