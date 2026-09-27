/**
 * Stripe webhook idempotency on the `stripe_events` ledger (migration 0011).
 *
 * A ledger row means "received", NOT "processed": `processed_at` is set only
 * after the handler finished. Stripe retries every non-2xx delivery, so a
 * conflict on insert is a retry of an event we may never have finished (the
 * first attempt failed or timed out). Only a non-null `processed_at` makes a
 * delivery a duplicate that is acknowledged without re-running the handler.
 *
 *   const outcome = await processStripeEventOnce(admin, event, async () => {
 *     // ... idempotent handler (safe to re-run after a partial failure) ...
 *   }, { log: ctx.log });
 *   return json({ received: true, duplicate: outcome === "duplicate" });
 *
 * Handlers must still be idempotent: two deliveries of one event can overlap,
 * and a handler can fail after some of its writes landed.
 */
import type { SupabaseClient } from "@supabase/supabase-js";
import { HttpError } from "./errors.ts";
import { isStripeAccountId } from "./ids.ts";
import type { Logger } from "./log.ts";

const TABLE = "stripe_events";
const EVENT_ID = /^evt_[A-Za-z0-9]+$/;
/** `stripe_events.error` check constraint (char_length <= 5000). */
export const STRIPE_EVENT_ERROR_MAX_CHARS = 5000;
/** `stripe_events.type` check constraint (char_length between 1 and 100). */
const TYPE_MAX_CHARS = 100;
/** Optimistic-update retries when concurrent deliveries race on one row. */
const CLAIM_ATTEMPTS = 3;

export interface StripeEventRef {
  id: string;
  type: string;
  /** Connected account for Connect events (`event.account`). */
  account?: string | null;
}

export type StripeEventClaim =
  /** First delivery, or a retry of an event that was never marked processed. */
  | { process: true; attempt: number }
  /** Already processed: acknowledge (2xx) without running the handler again. */
  | { process: false; attempt: number };

export interface StripeEventOptions {
  /** Clock for `last_attempt_at` / `processed_at` (tests). */
  now?: () => Date;
}

interface LedgerRow {
  attempts: number;
  processed_at: string | null;
}

function nowIso(options: StripeEventOptions): string {
  return (options.now?.() ?? new Date()).toISOString();
}

function assertEventId(id: string): void {
  if (!EVENT_ID.test(id)) {
    throw new HttpError("bad_request", "Unexpected Stripe event id.");
  }
}

function truncateChars(text: string, max: number): string {
  const chars = Array.from(text);
  return chars.length <= max ? text : chars.slice(0, max).join("");
}

function errorText(error: unknown): string {
  const text = error instanceof Error
    ? `${error.name}: ${error.message}`
    : typeof error === "string"
    ? error
    : "Unknown error";
  return truncateChars(text || "Unknown error", STRIPE_EVENT_ERROR_MAX_CHARS);
}

/**
 * Records a delivery and decides whether to run the handler. A new event is
 * inserted with `attempts = 1`; a redelivery of an unprocessed event bumps
 * `attempts`/`last_attempt_at` and is processed again; a redelivery of a
 * processed event is reported as `process: false`.
 */
export async function beginStripeEvent(
  admin: SupabaseClient,
  event: StripeEventRef,
  options: StripeEventOptions = {},
): Promise<StripeEventClaim> {
  assertEventId(event.id);
  const account = typeof event.account === "string" && isStripeAccountId(event.account)
    ? event.account
    : null;
  const at = nowIso(options);

  const inserted = await admin.from(TABLE).upsert(
    {
      id: event.id,
      type: truncateChars(event.type || "unknown", TYPE_MAX_CHARS),
      account,
      received_at: at,
      last_attempt_at: at,
    },
    { onConflict: "id", ignoreDuplicates: true },
  ).select("id");
  if (inserted.error) {
    throw new Error("Could not record the Stripe event.", { cause: inserted.error });
  }
  if ((inserted.data ?? []).length > 0) return { process: true, attempt: 1 };

  // Conflict: the event was received before. Retry it unless it finished.
  for (let i = 0; i < CLAIM_ATTEMPTS; i++) {
    const existing = await admin.from(TABLE).select("attempts, processed_at").eq("id", event.id)
      .maybeSingle<LedgerRow>();
    if (existing.error) {
      throw new Error("Could not read the Stripe event ledger.", { cause: existing.error });
    }
    const row = existing.data;
    if (!row) {
      throw new Error(`Stripe event ${event.id} conflicted on insert but is not in the ledger.`);
    }
    if (row.processed_at !== null) return { process: false, attempt: row.attempts };

    const bumped = await admin.from(TABLE)
      .update({ attempts: row.attempts + 1, last_attempt_at: at })
      .eq("id", event.id)
      .eq("attempts", row.attempts)
      .is("processed_at", null)
      .select("attempts");
    if (bumped.error) {
      throw new Error("Could not record the Stripe event retry.", { cause: bumped.error });
    }
    if ((bumped.data ?? []).length > 0) return { process: true, attempt: row.attempts + 1 };
    // Another delivery changed the row between our read and update: re-read.
  }
  // Non-2xx, so Stripe delivers again later instead of the event being lost.
  throw new HttpError(
    "conflict",
    "This Stripe event is being processed by another delivery. Retry later.",
  );
}

/** Marks the event processed (clears any earlier failure). */
export async function completeStripeEvent(
  admin: SupabaseClient,
  eventId: string,
  options: StripeEventOptions = {},
): Promise<void> {
  assertEventId(eventId);
  const { error } = await admin.from(TABLE)
    .update({ processed_at: nowIso(options), error: null })
    .eq("id", eventId);
  if (error) throw new Error("Could not mark the Stripe event processed.", { cause: error });
}

/**
 * Records why an attempt failed and leaves `processed_at` null so the next
 * Stripe retry processes it again. Never touches an already processed event.
 */
export async function failStripeEvent(
  admin: SupabaseClient,
  eventId: string,
  failure: unknown,
): Promise<void> {
  assertEventId(eventId);
  const { error } = await admin.from(TABLE)
    .update({ error: errorText(failure) })
    .eq("id", eventId)
    .is("processed_at", null);
  if (error) throw new Error("Could not record the Stripe event failure.", { cause: error });
}

export type StripeEventOutcome = "processed" | "duplicate";

/**
 * begin -> handler -> complete. On a handler error the failure is recorded
 * and the ORIGINAL error is rethrown, so the webhook answers non-2xx and
 * Stripe retries; the retry runs the handler again because `processed_at`
 * is still null.
 */
export async function processStripeEventOnce(
  admin: SupabaseClient,
  event: StripeEventRef,
  handler: (claim: { attempt: number }) => Promise<void>,
  options: StripeEventOptions & { log?: Logger } = {},
): Promise<StripeEventOutcome> {
  const claim = await beginStripeEvent(admin, event, options);
  if (!claim.process) {
    options.log?.info("stripe_event_duplicate", { event_id: event.id, type: event.type });
    return "duplicate";
  }
  try {
    await handler({ attempt: claim.attempt });
  } catch (failure) {
    try {
      await failStripeEvent(admin, event.id, failure);
    } catch (recordError) {
      options.log?.error("stripe_event_failure_not_recorded", {
        event_id: event.id,
        error: recordError instanceof Error ? recordError.message : String(recordError),
      });
    }
    throw failure;
  }
  await completeStripeEvent(admin, event.id, options);
  return "processed";
}
