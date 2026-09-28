import { assert, assertEquals, assertMatch } from "@std/assert";
import type { ErrorBody } from "../_shared/http.ts";
import { jsonResponse } from "../_shared/testing/fake_fetch.ts";
import { FakeRpcError, FakeSupabase } from "../_shared/testing/fake_supabase.ts";
import { memoryLogger } from "../_shared/testing/logger.ts";
import { jsonRequest, responseJson } from "../_shared/testing/requests.ts";
import { verifySignatureHeader } from "../_shared/webhook_sign.ts";
import {
  type ClaimedDelivery,
  claimLimit,
  CONCURRENCY,
  type DeliverSummary,
  makeHandler,
  MARK_ALLOWANCE_MS,
  REQUEST_TIMEOUT_MS,
  TIME_BUDGET_MS,
  USER_AGENT,
} from "./index.ts";

const CRON_SECRET = "fake-cron-secret-0123456789abcdef";
const SECRET = "whsec_" + "ab".repeat(32);
const NOW_MS = 1_760_000_000_000;

function delivery(overrides: Partial<ClaimedDelivery> = {}): ClaimedDelivery {
  return {
    id: crypto.randomUUID(),
    endpoint_id: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
    url: "https://hooks.example.com/catch/1",
    secret: SECRET,
    event: "job_completed",
    payload: {
      id: "11111111-1111-4111-8111-111111111111",
      event: "job_completed",
      created_at: "2026-06-02T15:00:00Z",
      shop: { id: "s", name: "Shine" },
      data: { job: { number: 1042, total_cents: 25000 } },
    },
    attempts: 1,
    ...overrides,
  };
}

interface Setup {
  batches: ClaimedDelivery[][];
  dns?: Record<string, string[]>;
  resolver?: (host: string) => Promise<string[]>;
  timeoutMs?: number;
  clock?: () => number;
}

function setup(options: Setup) {
  const queue = [...options.batches];
  const marks: Record<string, unknown>[] = [];
  const limits: unknown[] = [];
  let claims = 0;
  const db = new FakeSupabase({
    rpc: {
      claim_webhook_deliveries: (args, ctx) => {
        if (ctx.role !== "service_role") throw new FakeRpcError("42501", "denied");
        claims += 1;
        limits.push(args.p_limit);
        return queue.shift() ?? [];
      },
      mark_webhook_delivery: (args, ctx) => {
        if (ctx.role !== "service_role") throw new FakeRpcError("42501", "denied");
        marks.push(args);
        return null;
      },
    },
  });
  const dns = options.dns ?? {};
  const log = memoryLogger();
  const handler = makeHandler({
    env: db.env(),
    fetch: db.http.fetch,
    logger: log.logger,
    resolver: options.resolver ?? ((host) => Promise.resolve(dns[host] ?? ["93.184.216.34"])),
    now: () => NOW_MS,
    timeoutMs: options.timeoutMs,
    clock: options.clock,
  });
  return { db, handler, marks, log, limits, claims: () => claims };
}

const cron = (secret: string | null = CRON_SECRET, body: Record<string, unknown> = {}) =>
  jsonRequest("webhooks", { action: "deliver", ...body }, {
    headers: secret === null ? {} : { "x-cron-secret": secret },
  });

Deno.test("deliver: rejects a bad cron secret before claiming", async () => {
  const { handler, claims } = setup({ batches: [[delivery()]] });
  const res = await handler(cron("nope-nope-nope-nope-nope-nope"));
  assertEquals(res.status, 401);
  assertEquals((await responseJson<ErrorBody>(res)).code, "unauthorized");
  assertEquals(claims(), 0);
});

Deno.test("deliver: POSTs the stored payload with a verifiable signature", async () => {
  const d = delivery();
  const { db, handler, marks } = setup({ batches: [[d]] });
  db.http.on("POST", "https://hooks.example.com/catch/1", () => new Response("ok"));
  const res = await handler(cron());
  assertEquals(res.status, 200);
  assertEquals(await responseJson<DeliverSummary>(res), {
    batches: 1,
    claimed: 1,
    succeeded: 1,
    failed: 0,
    more: false,
  });
  const call = db.http.callsTo("POST", "https://hooks.example.com/catch/1")[0];
  assert(call);
  assertEquals(call.bodyText, JSON.stringify(d.payload));
  assertEquals(call.headers.get("content-type"), "application/json");
  assertEquals(call.headers.get("user-agent"), USER_AGENT);
  assertEquals(call.headers.get("x-detailcrm-event"), "job_completed");
  assertEquals(call.headers.get("x-detailcrm-delivery"), d.id);
  const signature = call.headers.get("x-detailcrm-signature");
  assertMatch(signature ?? "", /^t=1760000000,v1=[0-9a-f]{64}$/);
  assert(
    await verifySignatureHeader(SECRET, signature, call.bodyText, { now: NOW_MS / 1000 }),
  );
  assertEquals(marks, [{ p_id: d.id, p_status_code: 200, p_error: null }]);
});

Deno.test("deliver: non-2xx, redirects and network errors are failures with reasons", async () => {
  const server = delivery({ url: "https://a.example.com/500" });
  const redirect = delivery({ url: "https://a.example.com/301" });
  const down = delivery({ url: "https://down.example.com/x" });
  const { db, handler, marks, log } = setup({ batches: [[server, redirect, down]] });
  db.http.on("POST", "https://a.example.com/500", () => jsonResponse({ no: true }, 500));
  db.http.on(
    "POST",
    "https://a.example.com/301",
    () => new Response(null, { status: 301, headers: { location: "http://169.254.169.254/" } }),
  );
  db.http.on("POST", "https://down.example.com/x", () => {
    throw new TypeError("connection refused");
  });
  const summary = await responseJson<DeliverSummary>(await handler(cron()));
  assertEquals([summary.succeeded, summary.failed], [0, 3]);
  const byId = Object.fromEntries(marks.map((m) => [m.p_id, m]));
  assertEquals(byId[server.id], { p_id: server.id, p_status_code: 500, p_error: "HTTP 500" });
  assertEquals(byId[redirect.id], {
    p_id: redirect.id,
    p_status_code: 301,
    p_error: "redirects are not followed (HTTP 301)",
  });
  assertEquals(byId[down.id]?.p_status_code, null);
  assertMatch(String(byId[down.id]?.p_error), /^request failed: connection refused/);
  // The redirect target was never requested.
  assertEquals(db.http.calls.some((c) => c.url.hostname === "169.254.169.254"), false);
  assertEquals(log.events("webhook_delivery_failed").length, 3);
});

Deno.test("deliver: a receiver that does not answer in time is a failure", async () => {
  const slow = delivery({ url: "https://slow.example.com/x" });
  const { db, handler, marks } = setup({ batches: [[slow]], timeoutMs: 20 });
  db.http.on("POST", "https://slow.example.com/x", (req) =>
    new Promise((_, reject) => {
      req.signal.addEventListener("abort", () => reject(new DOMException("aborted", "AbortError")));
    }));
  await (await handler(cron())).body?.cancel();
  assertEquals(marks, [{
    p_id: slow.id,
    p_status_code: null,
    p_error: "no response within 20 ms",
  }]);
});

Deno.test("deliver: the SSRF guard refuses private targets without connecting", async () => {
  const literal = delivery({ url: "https://127.0.0.1/hook" });
  const internal = delivery({ url: "https://metadata.google.internal/x" });
  const rebinding = delivery({ url: "https://evil.example.com/x" });
  const { db, handler, marks } = setup({
    batches: [[literal, internal, rebinding]],
    dns: { "evil.example.com": ["10.0.0.5"] },
  });
  const summary = await responseJson<DeliverSummary>(await handler(cron()));
  assertEquals(summary.failed, 3);
  assertEquals(db.http.calls.filter((c) => !c.url.hostname.startsWith("fake-project")).length, 0);
  for (const m of marks) {
    assertEquals(m.p_status_code, null);
    assertMatch(String(m.p_error), /^refused: /);
  }
});

Deno.test("deliver: drains batches until the queue is empty", async () => {
  const batches = [[delivery(), delivery()], [delivery()]];
  const { db, handler, claims, limits } = setup({ batches });
  db.http.on(
    "POST",
    "https://hooks.example.com/catch/1",
    () => new Response(null, { status: 204 }),
  );
  const summary = await responseJson<DeliverSummary>(await handler(cron()));
  assertEquals([summary.batches, summary.claimed, summary.succeeded], [2, 3, 3]);
  assertEquals(claims(), 3);
  // With 10 s per delivery, a claim is sized so every worker can time out
  // in the budget: floor(40 / 12) = 3 rounds of 5.
  assertEquals(limits[0], 15);
});

Deno.test("deliver: claimLimit keeps every claimed delivery inside the time budget", () => {
  const round = REQUEST_TIMEOUT_MS + MARK_ALLOWANCE_MS;
  assertEquals(claimLimit(50, TIME_BUDGET_MS, REQUEST_TIMEOUT_MS), 15);
  assertEquals(claimLimit(4, TIME_BUDGET_MS, REQUEST_TIMEOUT_MS), 4);
  assertEquals(claimLimit(50, round, REQUEST_TIMEOUT_MS), CONCURRENCY);
  assertEquals(claimLimit(50, round - 1, REQUEST_TIMEOUT_MS), 0);
  assertEquals(claimLimit(50, -5, REQUEST_TIMEOUT_MS), 0);
  assertEquals(
    claimLimit(500, TIME_BUDGET_MS, 20),
    CONCURRENCY * Math.floor(TIME_BUDGET_MS / (20 + MARK_ALLOWANCE_MS)),
  );
  // worst case: every claimed delivery hangs until its timeout
  for (let remaining = 0; remaining <= TIME_BUDGET_MS; remaining += 997) {
    const limit = claimLimit(50, remaining, REQUEST_TIMEOUT_MS);
    assert(Math.ceil(limit / CONCURRENCY) * round <= remaining, `${remaining}: ${limit}`);
  }
});

Deno.test("deliver: stops claiming when the rest of the budget cannot fit a round", async () => {
  let now = 0;
  const batches = [[delivery()], [delivery()], [delivery()]];
  const { db, handler, limits } = setup({ batches, clock: () => now });
  db.http.on("POST", "https://hooks.example.com/catch/1", () => {
    now += 15_000; // each delivery takes 15 s of the budget
    return new Response(null, { status: 204 });
  });
  const summary = await responseJson<DeliverSummary>(await handler(cron()));
  // 0 s: 15 fit; 15 s: 25 s left -> 10; 30 s: 10 s left < one 12 s round -> stop
  assertEquals(limits, [15, 10]);
  assertEquals([summary.batches, summary.claimed, summary.more], [2, 2, true]);
});

Deno.test("deliver: name resolution shares the request deadline", async () => {
  const d = delivery({ url: "https://slow-dns.example.com/x" });
  const { db, handler, marks } = setup({
    batches: [[d]],
    timeoutMs: 20,
    resolver: () => new Promise<string[]>(() => {}),
  });
  await (await handler(cron())).body?.cancel();
  assertEquals(marks, [{
    p_id: d.id,
    p_status_code: null,
    p_error: "the host name did not resolve within 20 ms",
  }]);
  assertEquals(db.http.callsTo("POST", "https://slow-dns.example.com/x").length, 0);
});

Deno.test("deliver: a non-standard port on a public host name is delivered (the database accepts it)", async () => {
  const d = delivery({ url: "https://hooks.example.com:8443/in" });
  const { db, handler, marks } = setup({ batches: [[d]] });
  db.http.on("POST", "https://hooks.example.com:8443/in", () => new Response("ok"));
  await (await handler(cron())).body?.cancel();
  assertEquals(marks, [{ p_id: d.id, p_status_code: 200, p_error: null }]);
});

Deno.test("deliver: a failed mark is logged and the run goes on", async () => {
  const { db, handler, log } = setup({ batches: [[delivery()]] });
  db.http.on("POST", "https://hooks.example.com/catch/1", () => new Response("ok"));
  db.onRpc("mark_webhook_delivery", () => {
    throw new FakeRpcError("XX000", "db down");
  });
  const res = await handler(cron());
  assertEquals(res.status, 200);
  assertEquals(log.events("webhook_mark_failed").length, 1);
});
