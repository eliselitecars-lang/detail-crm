import { assertEquals } from "@std/assert";
import { createLogger, type LogRecord, redact, REDACTED } from "./log.ts";

Deno.test("log: redacts secret-looking keys at any depth", () => {
  const out = redact({
    Authorization: "Bearer x",
    stripe: { secret_key: "sk", api_key: "k", nested: [{ public_token: "t" }] },
    card_number: "4242",
    signature: "s",
    amount_cents: 500,
  });
  assertEquals(out, {
    Authorization: REDACTED,
    stripe: { secret_key: REDACTED, api_key: REDACTED, nested: [{ public_token: REDACTED }] },
    card_number: REDACTED,
    signature: REDACTED,
    amount_cents: 500,
  });
});

Deno.test("log: errors serialize with name/message/code and cause", () => {
  const cause = Object.assign(new Error("inner"), { code: "23505" });
  const out = redact(new Error("outer", { cause })) as Record<string, unknown>;
  assertEquals(out.name, "Error");
  assertEquals(out.message, "outer");
  assertEquals((out.cause as Record<string, unknown>).code, "23505");
});

Deno.test("log: records carry level, event, time and inherited fields", () => {
  const records: LogRecord[] = [];
  const log = createLogger({ fn: "payments" }, (r) => records.push(r)).child({ request_id: "r1" });
  log.warn("slow", { ms: 900 });
  assertEquals(records.length, 1);
  const [record] = records;
  assertEquals(record?.level, "warn");
  assertEquals(record?.event, "slow");
  assertEquals(record?.fn, "payments");
  assertEquals(record?.request_id, "r1");
  assertEquals(record?.ms, 900);
  assertEquals(typeof record?.time, "string");
});

Deno.test("log: bigint and deep values are safe to serialize", () => {
  let deep: Record<string, unknown> = { v: 1 };
  for (let i = 0; i < 10; i++) deep = { next: deep };
  const out = JSON.stringify(redact({ big: 10n, deep }));
  assertEquals(out.includes('"big":"10"'), true);
  assertEquals(out.includes("[truncated]"), true);
});
