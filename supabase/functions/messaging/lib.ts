/**
 * Dependencies and small helpers shared by the messaging actions.
 */
import type { ActionContext } from "../_shared/actions.ts";
import type { Env } from "../_shared/env.ts";
import { PROVIDER_TIMEOUT_MS, withTimeout } from "../_shared/fetch_timeout.ts";
import { HttpError } from "../_shared/errors.ts";
import type { Logger } from "../_shared/log.ts";
import { adminClient, type SupabaseClient } from "../_shared/supabase.ts";
import type { SenderCheck } from "./sender.ts";

export interface Deps {
  env?: Env;
  /** One fetch for Supabase + Twilio + Resend (tests inject FakeSupabase's FakeFetch). */
  fetch?: typeof fetch;
  logger?: Logger;
  /** Clock (tests pin it). */
  now?: () => Date;
  /** Wall-clock budget for one process_queue run (default 45 s). */
  queueTimeBudgetMs?: number;
  /** Messages delivered in parallel within a batch (default 5). */
  concurrency?: number;
  /**
   * Cap on one Twilio/Resend HTTP exchange, response body included
   * (default PROVIDER_TIMEOUT_MS). A provider that accepts the connection and
   * then stalls must fail that one attempt, not hang the whole claimed batch.
   */
  providerTimeoutMs?: number;
}

/** Per-request services every action receives. */
export interface Services {
  admin: SupabaseClient;
  env: Env;
  log: Logger;
  /** For provider calls (Twilio, Resend): capped per request (withTimeout). */
  fetch: typeof fetch;
  now: () => Date;
  /** Only for actions that act as the caller (userClient); deps.fetch has no time cap. */
  deps: Deps;
  /** Per-request memo of SMS sender provisioning checks (sender.ts). */
  senderChecks: Map<string, Promise<SenderCheck>>;
}

export function services(deps: Deps, ctx: ActionContext): Services {
  return {
    admin: adminClient({ env: deps.env, fetch: deps.fetch }),
    env: ctx.env,
    log: ctx.log,
    // Provider calls only (Twilio, Resend); the Supabase clients use deps.fetch.
    fetch: withTimeout(
      deps.fetch ?? globalThis.fetch,
      deps.providerTimeoutMs ?? PROVIDER_TIMEOUT_MS,
    ),
    now: deps.now ?? (() => new Date()),
    deps,
    senderChecks: new Map(),
  };
}

export interface PgError {
  code?: string | null;
  message?: string | null;
  details?: string | null;
  hint?: string | null;
}

/** An unexpected database failure (-> 500; the PostgREST error is only logged). */
export class DbError extends Error {
  readonly code: string | null;

  constructor(operation: string, error: PgError) {
    super(`${operation} failed${error.code ? ` (${error.code})` : ""}: ${error.message ?? ""}`);
    this.name = "DbError";
    this.code = error.code ?? null;
  }
}

/**
 * Maps a refused staff RPC to a stable HttpError. The SQL message is only
 * logged (as the cause); clients get our generic wording and branch on code.
 */
export function rpcRefusal(operation: string, error: PgError): Error {
  switch (error.code) {
    case "42501":
      return new HttpError("forbidden", "Your role does not allow this message.", { cause: error });
    case "P0002":
    case "PT404": // public RPCs' not-found (0042 convention)
      return new HttpError("not_found", "The customer or job was not found.", { cause: error });
    case "22P02":
    case "22023":
    case "23514":
    case "55000":
      return new HttpError("unprocessable", "This message cannot be sent.", { cause: error });
    default:
      return new DbError(operation, error);
  }
}

/** Runs `fn` over `items` with at most `limit` in flight; results keep input order. */
export async function mapWithConcurrency<T, R>(
  items: readonly T[],
  limit: number,
  fn: (item: T) => Promise<R>,
): Promise<R[]> {
  const results = new Array<R>(items.length);
  let next = 0;
  const worker = async () => {
    while (next < items.length) {
      const index = next++;
      results[index] = await fn(items[index] as T);
    }
  };
  await Promise.all(Array.from({ length: Math.max(1, Math.min(limit, items.length)) }, worker));
  return results;
}

/** Trims and caps a provider/diagnostic text stored in messages.error. */
export function errorText(text: string, max = 500): string {
  const clean = text.replace(/\s+/g, " ").trim();
  return clean.length > max ? `${clean.slice(0, max - 1)}…` : clean;
}
