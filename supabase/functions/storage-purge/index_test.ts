import { assertEquals } from "@std/assert";
import type { ErrorBody } from "../_shared/http.ts";
import { jsonResponse } from "../_shared/testing/fake_fetch.ts";
import { FakeRpcError, FakeSupabase } from "../_shared/testing/fake_supabase.ts";
import { memoryLogger } from "../_shared/testing/logger.ts";
import { jsonRequest, responseJson } from "../_shared/testing/requests.ts";
import { makeHandler, MAX_BATCHES, type PurgeRunSummary, TIME_BUDGET_MS } from "./index.ts";

const CRON_SECRET = "fake-cron-secret-0123456789abcdef";
const SHOP = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const JOB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const STORAGE_DELETE = "https://fake-project.supabase.co/storage/v1/object/:bucket";

interface Claimed {
  request_id: number;
  bucket_id: string;
  object_name: string;
}

interface Setup {
  /** Successive claim_storage_purge answers (then empty). */
  batches: Claimed[][];
  /** Buckets whose remove call fails. */
  failBuckets?: string[];
  clock?: () => number;
}

function setup(options: Setup) {
  const queue = [...options.batches];
  const claims: Record<string, unknown>[] = [];
  const finishes: Record<string, unknown>[] = [];
  const db = new FakeSupabase({
    rpc: {
      claim_storage_purge: (args) => {
        claims.push(args);
        return queue.shift() ?? [];
      },
      finish_storage_purge: (args) => {
        finishes.push(args);
        return (args.p_request_ids as unknown[]).length;
      },
    },
  });
  const removed: { bucket: string; prefixes: string[]; auth: string | null }[] = [];
  db.http.on("DELETE", STORAGE_DELETE, (req, match) => {
    const bucket = match.params.bucket ?? "";
    const prefixes = (match.call.json as { prefixes: string[] }).prefixes;
    removed.push({ bucket, prefixes, auth: req.headers.get("authorization") });
    if (options.failBuckets?.includes(bucket)) {
      return jsonResponse(
        { statusCode: "503", error: "Unavailable", message: "backend down" },
        503,
      );
    }
    return jsonResponse(prefixes.map((name) => ({ name, bucket_id: bucket })));
  });
  const log = memoryLogger();
  const handler = makeHandler({
    env: db.env(),
    fetch: db.http.fetch,
    logger: log.logger,
    clock: options.clock,
  });
  return { db, handler, claims, finishes, removed, log };
}

const cron = (body: Record<string, unknown> = {}, secret: string | null = CRON_SECRET) =>
  jsonRequest("storage-purge", { action: "purge", ...body }, {
    headers: secret === null ? {} : { "x-cron-secret": secret },
  });

Deno.test("purge: rejects a missing or wrong cron secret before touching the queue", async () => {
  const { db, handler, removed } = setup({ batches: [] });
  for (const secret of [null, "", "wrong-secret-0123456789abcdef", `${CRON_SECRET}x`]) {
    const res = await handler(cron({}, secret));
    assertEquals(res.status, 401);
    assertEquals((await responseJson<ErrorBody>(res)).code, "unauthorized");
  }
  assertEquals(db.requests.length, 0);
  assertEquals(removed.length, 0);
});

Deno.test("purge: validates the batch size strictly", async () => {
  const { db, handler } = setup({ batches: [] });
  for (const body of [{ limit: 0 }, { limit: 1001 }, { limit: 1.5 }, { bucket: "job-photos" }]) {
    const res = await handler(cron(body));
    assertEquals(res.status, 400);
    assertEquals((await responseJson<ErrorBody>(res)).code, "validation_failed");
  }
  assertEquals(db.requests.length, 0);
});

Deno.test("purge: removes claimed objects per bucket with the service role and reports success", async () => {
  const { db, handler, claims, finishes, removed } = setup({
    batches: [[
      { request_id: 1, bucket_id: "job-photos", object_name: `${SHOP}/${JOB}/a.jpg` },
      { request_id: 1, bucket_id: "job-photos", object_name: `${SHOP}/${JOB}/b.jpg` },
      { request_id: 2, bucket_id: "signatures", object_name: `${SHOP}/sig/customer.png` },
      { request_id: 3, bucket_id: "shop-assets", object_name: `${SHOP}/logo.png` },
    ]],
  });
  const res = await handler(cron({ limit: 250 }));
  assertEquals(res.status, 200);
  assertEquals(await responseJson<PurgeRunSummary>(res), {
    batches: 1,
    claimed: 4,
    removed: 4,
    failed_requests: 0,
    more: false,
  });
  assertEquals(claims, [{ p_limit: 250 }, { p_limit: 250 }]);
  assertEquals(removed.map((r) => [r.bucket, r.prefixes]), [
    ["job-photos", [`${SHOP}/${JOB}/a.jpg`, `${SHOP}/${JOB}/b.jpg`]],
    ["signatures", [`${SHOP}/sig/customer.png`]],
    ["shop-assets", [`${SHOP}/logo.png`]],
  ]);
  assertEquals(removed.every((r) => r.auth === "Bearer fake-service-role-key"), true);
  assertEquals(finishes, [
    { p_request_ids: [1], p_error: null },
    { p_request_ids: [2], p_error: null },
    { p_request_ids: [3], p_error: null },
  ]);
  assertEquals(db.requests.every((r) => r.role === "service_role"), true);
});

Deno.test("purge: a storage failure is reported for its requests and the run goes on", async () => {
  const { handler, finishes, log } = setup({
    batches: [
      [
        { request_id: 7, bucket_id: "signatures", object_name: `${SHOP}/sig/a.png` },
        { request_id: 8, bucket_id: "job-photos", object_name: `${SHOP}/${JOB}/x.jpg` },
      ],
      [{ request_id: 9, bucket_id: "job-photos", object_name: `${SHOP}/${JOB}/y.jpg` }],
    ],
    failBuckets: ["signatures"],
  });
  const res = await handler(cron());
  assertEquals(res.status, 200);
  assertEquals(await responseJson<PurgeRunSummary>(res), {
    batches: 2,
    claimed: 3,
    removed: 2,
    failed_requests: 1,
    more: false,
  });
  assertEquals(finishes.length, 3);
  assertEquals(finishes[0]?.p_request_ids, [7]);
  assertEquals(String(finishes[0]?.p_error).startsWith("storage remove (signatures): "), true);
  assertEquals(finishes[1], { p_request_ids: [8], p_error: null });
  assertEquals(finishes[2], { p_request_ids: [9], p_error: null });
  assertEquals(log.events("storage_purge_failed").length, 1);
});

Deno.test("purge: stops after MAX_BATCHES or the time budget and says there may be more", async () => {
  const one = (id: number): Claimed[] => [
    { request_id: id, bucket_id: "job-photos", object_name: `${SHOP}/${JOB}/${id}.jpg` },
  ];
  const endless = Array.from({ length: MAX_BATCHES + 5 }, (_, i) => one(i + 1));
  const capped = setup({ batches: endless });
  const res = await capped.handler(cron());
  const summary = await responseJson<PurgeRunSummary>(res);
  assertEquals([summary.batches, summary.more], [MAX_BATCHES, true]);
  assertEquals(capped.claims.length, MAX_BATCHES);

  let now = 0;
  const timed = setup({
    batches: endless,
    clock: () => {
      now += TIME_BUDGET_MS / 2;
      return now;
    },
  });
  const timedSummary = await responseJson<PurgeRunSummary>(await timed.handler(cron()));
  assertEquals(timedSummary.more, true);
  assertEquals(timedSummary.batches < MAX_BATCHES, true);
});

Deno.test("purge: a database error is a 500 and nothing is removed", async () => {
  const { db, handler, removed } = setup({ batches: [] });
  db.onRpc("claim_storage_purge", () => {
    throw new FakeRpcError("42501", "permission denied for function claim_storage_purge");
  });
  const res = await handler(cron());
  assertEquals(res.status, 500);
  assertEquals((await responseJson<ErrorBody>(res)).code, "internal_error");
  assertEquals(removed.length, 0);
});
