import { assert, assertEquals } from "@std/assert";
import type { ErrorBody } from "../_shared/http.ts";
import { FakeRpcError, FakeSupabase } from "../_shared/testing/fake_supabase.ts";
import { memoryLogger } from "../_shared/testing/logger.ts";
import { emptyRequest, jsonRequest, responseJson } from "../_shared/testing/requests.ts";
import { makeHandler } from "./index.ts";

const TOKEN = "11111111-2222-4333-8444-555555555555";

const FEED = {
  shop: { name: "Shine Auto Spa", timezone: "America/Chicago" },
  member: { display_name: "Alex" },
  events: [
    {
      uid: "job-aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      starts_at: "2026-06-02T15:00:00+00:00",
      ends_at: "2026-06-02T18:00:00+00:00",
      summary: "Job #1042 - Full detail - Dana R.",
      location: "12 Oak St, Birmingham, AL 35203",
      description: "2021 Honda Civic\nFull detail",
      status: "CONFIRMED",
      updated_at: "2026-05-30T12:00:00+00:00",
    },
    {
      uid: "event-bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb-20260603T140000Z",
      starts_at: "2026-06-03T14:00:00+00:00",
      ends_at: "2026-06-03T22:00:00+00:00",
      summary: "Time off",
      location: null,
      description: null,
      status: "CONFIRMED",
      updated_at: "2026-05-01T00:00:00+00:00",
    },
    { uid: "broken", starts_at: null, ends_at: "2026-06-03T22:00:00+00:00" },
  ],
};

function setup(result: unknown = FEED) {
  const seen: Record<string, unknown>[] = [];
  const db = new FakeSupabase({
    rpc: {
      calendar_feed_events: (args, ctx) => {
        if (ctx.role !== "service_role") throw new FakeRpcError("42501", "permission denied");
        seen.push(args);
        return args.p_token === TOKEN ? result : null;
      },
    },
  });
  const log = memoryLogger();
  const handler = makeHandler({
    env: db.env(),
    fetch: db.http.fetch,
    logger: log.logger,
    now: () => new Date("2026-06-01T00:00:00Z"),
  });
  return { db, handler, seen, log };
}

const feed = (token?: string) =>
  emptyRequest("calendar-feed", token === undefined ? {} : { query: { token } });

Deno.test("calendar-feed: renders the member's events as text/calendar", async () => {
  const { handler, seen, log } = setup();
  const res = await handler(feed(TOKEN.toUpperCase()));
  assertEquals(res.status, 200);
  assertEquals(res.headers.get("content-type"), "text/calendar; charset=utf-8");
  assertEquals(res.headers.get("cache-control"), "private, max-age=300");
  assertEquals(res.headers.get("access-control-allow-origin"), null);
  const body = await res.text();
  const lines = body.replace(/\r\n /g, "").split("\r\n");
  assert(lines.includes("X-WR-CALNAME:Shine Auto Spa - Alex"));
  assert(lines.includes("UID:job-aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa@detail-crm"));
  assert(lines.includes("DTSTART:20260602T150000Z"));
  assert(lines.includes("SUMMARY:Job #1042 - Full detail - Dana R."));
  assert(lines.includes("DESCRIPTION:2021 Honda Civic\\nFull detail"));
  assert(lines.includes("SUMMARY:Time off"));
  assertEquals(lines.filter((l) => l === "BEGIN:VEVENT").length, 2);
  assertEquals(seen, [{ p_token: TOKEN }]);
  assertEquals(log.events("calendar_feed_events_skipped").length, 1);
});

Deno.test("calendar-feed: unknown or revoked token is 404; malformed is 400", async () => {
  const { handler } = setup();
  const unknown = await handler(feed("99999999-2222-4333-8444-555555555555"));
  assertEquals(unknown.status, 404);
  assertEquals((await responseJson<ErrorBody>(unknown)).code, "not_found");
  for (const token of [undefined, "", "not-a-uuid", `${TOKEN}x`]) {
    const res = await handler(feed(token));
    assertEquals(res.status, 400, String(token));
  }
});

Deno.test("calendar-feed: GET only", async () => {
  const { handler, seen } = setup();
  const res = await handler(jsonRequest("calendar-feed", {}, { query: { token: TOKEN } }));
  assertEquals(res.status, 405);
  assertEquals(seen.length, 0);
});

Deno.test("calendar-feed: a database error is a 500 without details", async () => {
  const { db, handler } = setup();
  db.onRpc("calendar_feed_events", () => {
    throw new FakeRpcError("XX000", "boom");
  });
  const res = await handler(feed(TOKEN));
  assertEquals(res.status, 500);
  assertEquals((await responseJson<ErrorBody>(res)).code, "internal_error");
});

Deno.test("calendar-feed: an empty feed is a valid calendar", async () => {
  const { handler } = setup({ shop: { name: "S", timezone: "UTC" }, member: {}, events: [] });
  const res = await handler(feed(TOKEN));
  const body = await res.text();
  assert(body.startsWith("BEGIN:VCALENDAR\r\n"));
  assert(body.endsWith("END:VCALENDAR\r\n"));
  assert(body.includes("X-WR-CALNAME:S\r\n"));
});
