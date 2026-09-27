/**
 * storage-purge — removes the stored files of deleted shops, jobs,
 * inspections and form submissions (SPEC §4.6; queue and RPCs in migration
 * 0025_field_ops_storage.sql). pg_cron only; verify_jwt = false.
 *
 *   purge  { limit? }  (x-cron-secret) claim_storage_purge -> Storage API
 *                      remove (service role) -> finish_storage_purge, batch
 *                      after batch until the queue is empty, MAX_BATCHES
 *                      ran or the time budget is spent.
 *
 * Deleting rows never deletes files: the database queues the folders and
 * objects of deleted rows (customer photos and signature images are PII)
 * and this worker removes them through the Storage API, which deletes the
 * stored file along with its storage.objects row (a plain SQL delete would
 * leave the file behind and is refused by Supabase). Objects still
 * referenced by a live row are never handed out by the claim.
 *
 * A failed removal is reported with finish_storage_purge(ids, error): the
 * request keeps its error and is retried after 15 minutes. If this worker
 * dies between claim and finish, the 10-minute lease expires and the next
 * run picks the request up again; removing an already removed object is a
 * no-op, so every step is safe to repeat.
 */
import { z } from "zod";
import { createActionRouter, jsonAction } from "../_shared/actions.ts";
import { requireCronSecret } from "../_shared/auth.ts";
import type { Env } from "../_shared/env.ts";
import { createHandler } from "../_shared/http.ts";
import type { Logger } from "../_shared/log.ts";
import { adminClient, type SupabaseClient } from "../_shared/supabase.ts";

export interface Deps {
  env?: Env;
  fetch?: typeof fetch;
  logger?: Logger;
  /** Monotonic milliseconds for the time budget (tests). */
  clock?: () => number;
}

/** Claims per run (each at most `limit` objects). */
export const MAX_BATCHES = 20;
/** Stop claiming new batches after this long (the cron job's HTTP timeout is 60 s). */
export const TIME_BUDGET_MS = 40_000;
/** The Storage API removes at most 1000 objects per call. */
export const REMOVE_CHUNK = 1000;

export const purgeInput = z.object({
  limit: z.number().int().min(1).max(1000).optional(),
}).strict();

interface ClaimedObject {
  request_id: number;
  bucket_id: string;
  object_name: string;
}

export interface PurgeRunSummary {
  batches: number;
  claimed: number;
  removed: number;
  failed_requests: number;
  more: boolean;
}

function dbFailure(what: string, error: { message?: string; code?: string }): Error {
  return new Error(`${what} failed: ${error.code ?? ""} ${error.message ?? ""}`.trim(), {
    cause: error,
  });
}

async function finish(
  admin: SupabaseClient,
  requestIds: number[],
  failure: string | null,
): Promise<void> {
  const { error } = await admin.rpc("finish_storage_purge", {
    p_request_ids: requestIds,
    p_error: failure,
  });
  if (error) throw dbFailure("finish_storage_purge", error);
}

/** One claim -> remove -> finish round. Returns null when nothing was due. */
async function purgeBatch(
  admin: SupabaseClient,
  limit: number,
  log: Logger,
): Promise<{ claimed: number; removed: number; failed: number } | null> {
  const { data, error } = await admin.rpc("claim_storage_purge", { p_limit: limit });
  if (error) throw dbFailure("claim_storage_purge", error);
  const rows = (data ?? []) as ClaimedObject[];
  if (rows.length === 0) return null;

  // a request lives in one bucket; group names and request ids per bucket
  const byBucket = new Map<string, { names: string[]; requests: Set<number> }>();
  for (const row of rows) {
    const entry = byBucket.get(row.bucket_id) ?? { names: [], requests: new Set<number>() };
    entry.names.push(row.object_name);
    entry.requests.add(row.request_id);
    byBucket.set(row.bucket_id, entry);
  }

  let removed = 0;
  let failed = 0;
  for (const [bucket, { names, requests }] of byBucket) {
    const ids = [...requests];
    let failure: string | null = null;
    for (let i = 0; i < names.length && failure === null; i += REMOVE_CHUNK) {
      const chunk = names.slice(i, i + REMOVE_CHUNK);
      const result = await admin.storage.from(bucket).remove(chunk);
      if (result.error) {
        failure = `storage remove (${bucket}): ${result.error.message}`.slice(0, 2000);
      } else {
        removed += result.data?.length ?? 0;
      }
    }
    if (failure !== null) {
      failed += ids.length;
      log.warn("storage_purge_failed", { bucket, requests: ids.length, error: failure });
    }
    await finish(admin, ids, failure);
  }
  return { claimed: rows.length, removed, failed };
}

export async function runPurge(
  admin: SupabaseClient,
  limit: number,
  log: Logger,
  clock: () => number,
): Promise<PurgeRunSummary> {
  const started = clock();
  const summary: PurgeRunSummary = {
    batches: 0,
    claimed: 0,
    removed: 0,
    failed_requests: 0,
    more: false,
  };
  while (true) {
    if (summary.batches >= MAX_BATCHES || clock() - started >= TIME_BUDGET_MS) {
      summary.more = true;
      break;
    }
    const batch = await purgeBatch(admin, limit, log);
    if (batch === null) break;
    summary.batches += 1;
    summary.claimed += batch.claimed;
    summary.removed += batch.removed;
    summary.failed_requests += batch.failed;
  }
  log.info("storage_purge_run", { ...summary });
  return summary;
}

export function makeHandler(deps: Deps = {}): (req: Request) => Promise<Response> {
  const clock = deps.clock ?? (() => performance.now());
  const router = createActionRouter({
    purge: jsonAction(purgeInput, async (input, ctx) => {
      requireCronSecret(ctx.req, ctx.env.cronSecret());
      const admin = adminClient({ env: deps.env, fetch: deps.fetch });
      return await runPurge(admin, input.limit ?? 500, ctx.log, clock);
    }),
  });
  return createHandler(
    { name: "storage-purge", env: deps.env, logger: deps.logger, cors: false },
    (req, ctx) => router(req, ctx),
  );
}

if (import.meta.main) Deno.serve(makeHandler());
