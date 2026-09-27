import { assertEquals, assertRejects } from "@std/assert";
import { HttpError } from "./errors.ts";
import {
  beginStripeEvent,
  completeStripeEvent,
  failStripeEvent,
  processStripeEventOnce,
  STRIPE_EVENT_ERROR_MAX_CHARS,
} from "./stripe_events.ts";
import { jsonResponse } from "./testing/fake_fetch.ts";
import { FakeSupabase, type Row } from "./testing/fake_supabase.ts";
import { memoryLogger } from "./testing/logger.ts";

const T1 = new Date("2026-09-01T10:00:00.000Z");
const T2 = new Date("2026-09-01T10:05:00.000Z");
const T3 = new Date("2026-09-01T10:30:00.000Z");
const EVENT = { id: "evt_1PaymentSucceeded", type: "payment_intent.succeeded" };

function fake(rows: Row[] = []): FakeSupabase {
  return new FakeSupabase({
    tables: { stripe_events: rows },
    tableOptions: {
      stripe_events: {
        primaryKey: ["id"],
        defaults: () => ({ attempts: 1, processed_at: null, error: null, account: null }),
      },
    },
  });
}

function ledger(db: FakeSupabase): Row | undefined {
  return db.table("stripe_events")[0];
}

Deno.test("stripe events: first delivery is recorded as received, not processed", async () => {
  const db = fake();
  const claim = await beginStripeEvent(db.admin(), { ...EVENT, account: "acct_123abc" }, {
    now: () => T1,
  });
  assertEquals(claim, { process: true, attempt: 1 });
  assertEquals(ledger(db), {
    id: EVENT.id,
    type: EVENT.type,
    account: "acct_123abc",
    received_at: T1.toISOString(),
    last_attempt_at: T1.toISOString(),
    attempts: 1,
    processed_at: null,
    error: null,
  });
  assertEquals(db.requests.every((r) => r.role === "service_role"), true);
});

Deno.test("stripe events: a retry after a failed attempt is processed again", async () => {
  const db = fake();
  const admin = db.admin();
  await beginStripeEvent(admin, EVENT, { now: () => T1 });
  await failStripeEvent(admin, EVENT.id, new Error("stripe lookup timed out"));
  assertEquals(ledger(db)?.error, "Error: stripe lookup timed out");
  assertEquals(ledger(db)?.processed_at, null);

  // Stripe redelivers: the insert conflicts, but processed_at is null -> run again.
  const retry = await beginStripeEvent(admin, EVENT, { now: () => T2 });
  assertEquals(retry, { process: true, attempt: 2 });
  assertEquals(ledger(db)?.attempts, 2);
  assertEquals(ledger(db)?.last_attempt_at, T2.toISOString());
  assertEquals(ledger(db)?.received_at, T1.toISOString());

  await completeStripeEvent(admin, EVENT.id, { now: () => T3 });
  assertEquals(ledger(db)?.processed_at, T3.toISOString());
  assertEquals(ledger(db)?.error, null);

  // Only now is a redelivery a duplicate.
  const dup = await beginStripeEvent(admin, EVENT, { now: () => T3 });
  assertEquals(dup, { process: false, attempt: 2 });
  assertEquals(ledger(db)?.attempts, 2);
});

Deno.test("stripe events: a failure is never recorded over a processed event", async () => {
  const db = fake([{
    id: EVENT.id,
    type: EVENT.type,
    account: null,
    received_at: T1.toISOString(),
    last_attempt_at: T1.toISOString(),
    attempts: 1,
    processed_at: T2.toISOString(),
    error: null,
  }]);
  await failStripeEvent(db.admin(), EVENT.id, "late failure");
  assertEquals(ledger(db)?.error, null);
  assertEquals(ledger(db)?.processed_at, T2.toISOString());
});

Deno.test("stripe events: failure text is bounded to the column limit", async () => {
  const db = fake();
  await beginStripeEvent(db.admin(), EVENT);
  await failStripeEvent(db.admin(), EVENT.id, new Error("\u{1F697}".repeat(6000)));
  const stored = String(ledger(db)?.error);
  assertEquals(Array.from(stored).length, STRIPE_EVENT_ERROR_MAX_CHARS);
});

Deno.test("stripe events: processStripeEventOnce re-runs a failed event until it succeeds", async () => {
  const db = fake();
  const admin = db.admin();
  const { logger } = memoryLogger();
  const attempts: number[] = [];
  let fail = true;
  const handler = ({ attempt }: { attempt: number }) => {
    attempts.push(attempt);
    if (fail) return Promise.reject(new Error("database unavailable"));
    return Promise.resolve();
  };

  await assertRejects(
    () => processStripeEventOnce(admin, EVENT, handler, { log: logger }),
    Error,
    "database unavailable",
  );
  assertEquals(ledger(db)?.processed_at, null);
  assertEquals(ledger(db)?.error, "Error: database unavailable");

  fail = false;
  assertEquals(await processStripeEventOnce(admin, EVENT, handler, { log: logger }), "processed");
  assertEquals(await processStripeEventOnce(admin, EVENT, handler, { log: logger }), "duplicate");
  assertEquals(attempts, [1, 2]);
  assertEquals(ledger(db)?.error, null);
  assertEquals(typeof ledger(db)?.processed_at, "string");
});

Deno.test("stripe events: the handler's own error is rethrown even if recording it fails", async () => {
  const db = fake();
  const admin = db.admin();
  const { logger, records } = memoryLogger();
  // First delivery: the insert is a POST; the only PATCH is recording the failure.
  db.http.on(
    "PATCH",
    `${db.url}/rest/v1/stripe_events`,
    () =>
      jsonResponse(
        { code: "08006", message: "connection failure", details: null, hint: null },
        503,
      ),
  );
  const err = await assertRejects(
    () =>
      processStripeEventOnce(
        admin,
        EVENT,
        () => Promise.reject(new HttpError("unprocessable", "Unknown invoice.")),
        { log: logger },
      ),
    HttpError,
  );
  assertEquals(err.code, "unprocessable");
  assertEquals(records.some((r) => r.event === "stripe_event_failure_not_recorded"), true);
});

Deno.test("stripe events: ledger errors surface (non-2xx) instead of acknowledging", async () => {
  const db = fake();
  db.http.on(
    "POST",
    `${db.url}/rest/v1/stripe_events`,
    () =>
      jsonResponse(
        { code: "08006", message: "connection failure", details: null, hint: null },
        503,
      ),
  );
  await assertRejects(() => beginStripeEvent(db.admin(), EVENT), Error, "record the Stripe event");
});

Deno.test("stripe events: malformed event ids are rejected before touching the ledger", async () => {
  const db = fake();
  const err = await assertRejects(
    () => beginStripeEvent(db.admin(), { id: "evt_bad id", type: "x" }),
    HttpError,
  );
  assertEquals(err.code, "bad_request");
  assertEquals(db.requests.length, 0);
});

Deno.test("stripe events: non-Connect account values are stored as null", async () => {
  const db = fake();
  await beginStripeEvent(db.admin(), { ...EVENT, account: "not-an-account" });
  assertEquals(ledger(db)?.account, null);
});

Deno.test("stripe events: a retry that keeps losing the optimistic race answers 409 (Stripe retries)", async () => {
  const db = fake();
  const admin = db.admin();
  await beginStripeEvent(admin, EVENT);
  // Every bump matches no row, as if another delivery changed `attempts` each time.
  db.http.on("PATCH", `${db.url}/rest/v1/stripe_events`, () => jsonResponse([], 200));
  const err = await assertRejects(() => beginStripeEvent(admin, EVENT), HttpError);
  assertEquals(err.code, "conflict");
  assertEquals(err.status, 409);
  assertEquals(ledger(db)?.attempts, 1);
});
