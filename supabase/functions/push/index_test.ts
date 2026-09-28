import { assert, assertEquals } from "@std/assert";
import { APNS_HOSTS } from "../_shared/apns.ts";
import type { ErrorBody } from "../_shared/http.ts";
import { apnsTestKey } from "../_shared/testing/apns.ts";
import { jsonResponse } from "../_shared/testing/fake_fetch.ts";
import { FakeRpcError, FakeSupabase, type Row } from "../_shared/testing/fake_supabase.ts";
import { memoryLogger } from "../_shared/testing/logger.ts";
import { jsonRequest, responseJson } from "../_shared/testing/requests.ts";
import {
  type ClaimedPush,
  makeHandler,
  payloadFor,
  type QueueSummary,
  RUN_DEADLINE_MS,
} from "./index.ts";

const CRON_SECRET = "fake-cron-secret-0123456789abcdef";
const SHOP = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const USER = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const OUTSIDER = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
const JOB = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";
const TOKEN_A = "a".repeat(64);
const TOKEN_B = "b".repeat(64);
const TOKEN_C = "c".repeat(64);
const PROD_URL = `${APNS_HOSTS.production}/3/device/:token`;
const SANDBOX_URL = `${APNS_HOSTS.sandbox}/3/device/:token`;

function claimed(overrides: Partial<ClaimedPush> = {}): ClaimedPush {
  return {
    notification_id: crypto.randomUUID(),
    shop_id: SHOP,
    user_id: USER,
    kind: "job_assigned",
    title: "New job #1042",
    body: "Monday, Jun 2 at 10:00 AM - Full detail",
    job_id: JOB,
    customer_id: null,
    quote_id: null,
    invoice_id: null,
    badge: 3,
    tokens: [{ token: TOKEN_A, apns_env: "production" }],
    ...overrides,
  };
}

interface Setup {
  batches?: ClaimedPush[][];
  /** APNs answer per device token (default 200). */
  apns?: Record<string, { status: number; reason?: string }>;
  env?: Record<string, string | undefined>;
  devices?: Row[];
  clock?: () => number;
  /** Runs before each APNs answer (tests move the clock). */
  onApns?: () => void;
  /** Parallel APNs requests (default: the production value). */
  concurrency?: number;
}

async function setup(options: Setup = {}) {
  const key = await apnsTestKey();
  const queue = [...(options.batches ?? [])];
  const calls = { claims: 0, released: [] as string[], invalid: [] as Row[] };
  const db = new FakeSupabase({
    env: {
      APNS_KEY_ID: "ABC123DEFG",
      APNS_TEAM_ID: "TEAM123456",
      // stored on one line, as secrets often are
      APNS_PRIVATE_KEY: key.pem.replace(/\n/g, "\\n"),
      APNS_TOPIC: "com.example.detailcrm",
      ...options.env,
    },
    users: {
      "tok-staff": { id: USER, email: "tech@example.com" },
      "tok-outsider": { id: OUTSIDER, email: "o@example.com" },
    },
    tables: {
      shop_members: [{
        id: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
        shop_id: SHOP,
        user_id: USER,
        role: "technician",
        display_name: "Tech",
        active: true,
      }],
      device_push_tokens: options.devices ?? [],
    },
    rpc: {
      claim_push_batch: (args, ctx) => {
        if (ctx.role !== "service_role") throw new FakeRpcError("42501", "permission denied");
        calls.claims += 1;
        assertEquals(args.p_limit, 100);
        return queue.shift() ?? [];
      },
      release_push: (args) => {
        calls.released.push(String(args.p_notification_id));
        return true;
      },
      mark_push_token_invalid: (args) => {
        calls.invalid.push(args);
        return null;
      },
    },
  });
  const answer = (token: string) => {
    options.onApns?.();
    const a = options.apns?.[token];
    if (!a || a.status === 200) return new Response(null, { status: 200 });
    return jsonResponse({ reason: a.reason ?? "x" }, a.status);
  };
  db.http.on("POST", PROD_URL, (_req, match) => answer(match.params.token ?? ""));
  db.http.on("POST", SANDBOX_URL, (_req, match) => answer(match.params.token ?? ""));
  const log = memoryLogger();
  const handler = makeHandler({
    env: db.env(),
    fetch: db.http.fetch,
    logger: log.logger,
    now: () => 1_760_000_000_000,
    clock: options.clock,
    concurrency: options.concurrency,
  });
  return { db, handler, calls, log };
}

const cron = (body: Record<string, unknown> = {}, secret: string | null = CRON_SECRET) =>
  jsonRequest("push", { action: "process_queue", ...body }, {
    headers: secret === null ? {} : { "x-cron-secret": secret },
  });

const apnsCalls = (db: FakeSupabase) =>
  db.http.calls.filter((c) => c.url.hostname.endsWith("push.apple.com"));

Deno.test("push: payload carries the alert, badge, thread and deep-link ids only", () => {
  const row = claimed({ customer_id: null, quote_id: "11111111-1111-4111-8111-111111111111" });
  assertEquals(payloadFor(row), {
    aps: {
      alert: { title: "New job #1042", body: "Monday, Jun 2 at 10:00 AM - Full detail" },
      badge: 3,
      sound: "default",
      "thread-id": "job_assigned",
    },
    kind: "job_assigned",
    shop_id: SHOP,
    job_id: JOB,
    customer_id: null,
    notification_id: row.notification_id,
    quote_id: "11111111-1111-4111-8111-111111111111",
  });
  const noBody = payloadFor(claimed({ body: null }));
  assertEquals((noBody.aps as { alert: unknown }).alert, { title: "New job #1042" });
});

Deno.test("process_queue: rejects a missing or wrong cron secret before claiming", async () => {
  const { handler, calls } = await setup({ batches: [[claimed()]] });
  for (const secret of [null, "wrong-secret-0123456789abcdef"]) {
    const res = await handler(cron({}, secret));
    assertEquals(res.status, 401);
    assertEquals((await responseJson<ErrorBody>(res)).code, "unauthorized");
  }
  assertEquals(calls.claims, 0);
});

Deno.test("process_queue: pushes each claimed notification to every device", async () => {
  const a = claimed({
    tokens: [{ token: TOKEN_A, apns_env: "production" }, {
      token: TOKEN_B,
      apns_env: "sandbox",
    }],
  });
  const b = claimed({ kind: "task_due", title: "Task due", body: null, job_id: null });
  const { db, handler, calls } = await setup({ batches: [[a, b]] });
  const res = await handler(cron());
  assertEquals(res.status, 200);
  assertEquals(await responseJson<QueueSummary>(res), {
    configured: true,
    batches: 1,
    claimed: 2,
    sent: 2,
    failed: 0,
    released: 0,
    invalid_tokens: 0,
    more: false,
  });
  const sent = apnsCalls(db);
  assertEquals(sent.length, 3);
  assertEquals(sent.filter((c) => c.url.hostname === "api.sandbox.push.apple.com").length, 1);
  const first = sent.find((c) => c.url.pathname.endsWith(TOKEN_B));
  assertEquals(first?.headers.get("apns-topic"), "com.example.detailcrm");
  assertEquals(first?.headers.get("apns-collapse-id"), a.notification_id);
  assertEquals((first?.json as { aps: { badge: number } }).aps.badge, 3);
  assertEquals(calls.claims, 2); // the second claim found the queue empty
  assert(db.requests.filter((r) => r.kind === "rpc").every((r) => r.role === "service_role"));
});

Deno.test("process_queue: an invalid token is disabled; a transient failure re-queues", async () => {
  const gone = claimed({ tokens: [{ token: TOKEN_A, apns_env: "production" }] });
  const flaky = claimed({ tokens: [{ token: TOKEN_B, apns_env: "production" }] });
  const partial = claimed({
    tokens: [{ token: TOKEN_C, apns_env: "production" }, {
      token: TOKEN_B,
      apns_env: "production",
    }],
  });
  const { handler, calls } = await setup({
    batches: [[gone, flaky, partial]],
    apns: {
      [TOKEN_A]: { status: 410, reason: "Unregistered" },
      [TOKEN_B]: { status: 503, reason: "ServiceUnavailable" },
    },
  });
  const summary = await responseJson<QueueSummary>(await handler(cron()));
  assertEquals([summary.sent, summary.failed, summary.released, summary.invalid_tokens], [
    1,
    2,
    1,
    1,
  ]);
  assertEquals(calls.invalid, [{ p_token: TOKEN_A, p_reason: "APNs 410 Unregistered" }]);
  // Only the notification that reached no device is re-queued; the partial
  // success is final so the other device is never alerted twice.
  assertEquals(calls.released, [flaky.notification_id]);
});

Deno.test("process_queue: past the run deadline nothing more is sent and the rest is released", async () => {
  let now = 0;
  const first = claimed();
  const second = claimed({ tokens: [{ token: TOKEN_B, apns_env: "production" }] });
  const { db, handler, calls } = await setup({
    batches: [[first, second]],
    clock: () => now,
    // One worker, so the second push is only considered after the first
    // answer. (With several workers both may legitimately start before the
    // deadline: a request that starts in time is allowed to finish.)
    concurrency: 1,
    // the first APNs answer arrives just after the deadline
    onApns: () => {
      now = RUN_DEADLINE_MS + 1;
    },
  });
  const summary = await responseJson<QueueSummary>(await handler(cron()));
  // exactly the first push reached APNs
  const sentCalls = apnsCalls(db);
  assertEquals(sentCalls.length, 1);
  assertEquals(sentCalls[0]?.url.pathname.split("/").pop(), TOKEN_A);
  assertEquals([summary.sent, summary.failed, summary.released], [1, 1, 1]);
  // the second was never attempted: released for the next run, not stranded
  assertEquals(calls.released, [second.notification_id]);
  assertEquals(summary.more, true);
});

Deno.test("process_queue: a payload/topic error is final (not re-queued, token kept)", async () => {
  const bad = claimed();
  const { handler, calls, log } = await setup({
    batches: [[bad]],
    apns: { [TOKEN_A]: { status: 400, reason: "BadTopic" } },
  });
  const summary = await responseJson<QueueSummary>(await handler(cron()));
  assertEquals([summary.sent, summary.failed, summary.released], [0, 1, 0]);
  assertEquals(calls.invalid.length, 0);
  assertEquals(calls.released.length, 0);
  assertEquals(log.events("push_not_delivered").length, 1);
});

Deno.test("process_queue: without APNs credentials the queue is left untouched", async () => {
  const { handler, calls } = await setup({
    batches: [[claimed()]],
    env: {
      APNS_KEY_ID: undefined,
      APNS_TEAM_ID: undefined,
      APNS_PRIVATE_KEY: undefined,
      APNS_TOPIC: undefined,
    },
  });
  const summary = await responseJson<QueueSummary>(await handler(cron()));
  assertEquals(summary.configured, false);
  assertEquals(calls.claims, 0);
});

Deno.test("process_queue: a partial APNs configuration is server_misconfigured before claiming", async () => {
  const { handler, calls } = await setup({
    batches: [[claimed()]],
    env: { APNS_TOPIC: undefined },
  });
  const res = await handler(cron());
  assertEquals(res.status, 500);
  assertEquals((await responseJson<ErrorBody>(res)).code, "server_misconfigured");
  assertEquals(calls.claims, 0);
});

Deno.test("process_queue: validates the limit strictly", async () => {
  const { handler } = await setup();
  for (const body of [{ limit: 0 }, { limit: 501 }, { extra: true }]) {
    const res = await handler(cron(body));
    assertEquals(res.status, 400);
  }
});

const testPush = (token: string | undefined, body: Record<string, unknown> = { shop_id: SHOP }) =>
  jsonRequest("push", { action: "send_test", ...body }, token ? { token } : {});

const device = (token: string, extra: Row = {}): Row => ({
  id: crypto.randomUUID(),
  user_id: USER,
  token,
  apns_env: "production",
  disabled_at: null,
  last_seen_at: "2026-09-01T00:00:00Z",
  ...extra,
});

Deno.test("send_test: pushes to the caller's own enabled devices only", async () => {
  const { db, handler } = await setup({
    devices: [
      device(TOKEN_A),
      device(TOKEN_B, { disabled_at: "2026-09-02T00:00:00Z" }),
      device(TOKEN_C, { user_id: OUTSIDER }),
    ],
  });
  const res = await handler(testPush("tok-staff"));
  assertEquals(res.status, 200);
  assertEquals(await responseJson(res), { sent: 1, failed: 0, invalid_tokens: 0 });
  const sent = apnsCalls(db);
  assertEquals(sent.map((c) => c.url.pathname), [`/3/device/${TOKEN_A}`]);
  const payload = sent[0]?.json as { aps: { alert: { title: string } }; shop_id: string };
  assertEquals(payload.aps.alert.title, "Test notification");
  assertEquals(payload.shop_id, SHOP);
});

Deno.test("send_test: auth, membership and device errors", async () => {
  const { handler } = await setup({ devices: [] });
  assertEquals((await handler(testPush(undefined))).status, 401);
  const outsider = await handler(testPush("tok-outsider"));
  assertEquals(outsider.status, 403);
  const none = await handler(testPush("tok-staff"));
  assertEquals(none.status, 422);
  assertEquals((await responseJson<ErrorBody>(none)).details, { reason: "no_devices" });
  assertEquals((await handler(testPush("tok-staff", { shop_id: "nope" }))).status, 400);
});

Deno.test("send_test: an unregistered device is disabled and reported as no_devices", async () => {
  const { handler, calls } = await setup({
    devices: [device(TOKEN_A)],
    apns: { [TOKEN_A]: { status: 410, reason: "Unregistered" } },
  });
  const res = await handler(testPush("tok-staff"));
  assertEquals(res.status, 422);
  assertEquals(calls.invalid.length, 1);
});

Deno.test("send_test: APNs down is a 502", async () => {
  const { handler } = await setup({
    devices: [device(TOKEN_A)],
    apns: { [TOKEN_A]: { status: 503, reason: "ServiceUnavailable" } },
  });
  const res = await handler(testPush("tok-staff"));
  assertEquals(res.status, 502);
  assertEquals((await responseJson<ErrorBody>(res)).code, "upstream_error");
});
