import { assert, assertEquals } from "@std/assert";
import { emptyRequest } from "../_shared/testing/mod.ts";
import { errorOf, fixture, INVOICE, SHOP } from "./test_fixtures.ts";

Deno.test("payments: unknown action, wrong method, strict bodies", async () => {
  const f = fixture();
  assertEquals((await errorOf(await f.call({ action: "transfer" }, "owner")))[1], "unknown_action");
  assertEquals((await errorOf(await f.call({ token: "x" })))[1], "unknown_action");
  const get = await f.handler(emptyRequest("payments"));
  assertEquals([get.status, (await errorOf(get))[1]], [405, "method_not_allowed"]);
});

Deno.test("payments: CORS preflight only for the app origin", async () => {
  const f = fixture();
  const ok = await f.preflight("https://app.example.com");
  assertEquals(ok.headers.get("access-control-allow-origin"), "https://app.example.com");
  await ok.body?.cancel();
  const evil = await f.preflight("https://evil.example.com");
  assert(evil.headers.get("access-control-allow-origin") !== "https://evil.example.com");
  await evil.body?.cancel();
});

Deno.test("payments: client secrets never reach the logs", async () => {
  const f = fixture();
  const res = await f.call(
    { action: "payment_sheet", shop_id: SHOP, invoice_id: INVOICE },
    "manager",
  );
  assertEquals(res.status, 200);
  await res.body?.cancel();
  const logged = JSON.stringify(f.logs.records);
  for (const secret of ["pi_1New_secret_abc", "ek_test_secret", "sk_test_", "tok-manager"]) {
    assert(!logged.includes(secret), `logs contain ${secret}`);
  }
});
