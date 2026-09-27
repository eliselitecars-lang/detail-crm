import { assertEquals, assertMatch } from "@std/assert";
import { isStripeAccountId, isUuid, requestIdFor } from "./ids.ts";

Deno.test("ids: isUuid / isStripeAccountId", () => {
  assertEquals(isUuid("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"), true);
  assertEquals(isUuid("AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"), true);
  assertEquals(isUuid("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa"), false);
  assertEquals(isUuid(42), false);
  assertEquals(isStripeAccountId("acct_1ABCdef234"), true);
  assertEquals(isStripeAccountId("acct_"), false);
});

Deno.test("ids: requestIdFor", () => {
  const mk = (id?: string) =>
    new Request("https://x.example", id ? { headers: { "x-request-id": id } } : {});
  assertEquals(requestIdFor(mk("abcdefgh")), "abcdefgh");
  assertMatch(requestIdFor(mk("short")), /^[0-9a-f-]{36}$/);
  assertMatch(requestIdFor(mk()), /^[0-9a-f-]{36}$/);
});
