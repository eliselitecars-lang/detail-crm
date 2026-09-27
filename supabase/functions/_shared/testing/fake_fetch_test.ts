import { assertEquals, assertRejects } from "@std/assert";
import { FakeFetch, jsonResponse } from "./fake_fetch.ts";

Deno.test("FakeFetch: routes by method + pattern, captures params and bodies", async () => {
  const http = new FakeFetch();
  http.on("POST", "https://api.example.com/v1/items/:id", (_req, { params, call }) => ({
    id: params.id,
    echoed: call.json,
  }));
  const res = await http.fetch("https://api.example.com/v1/items/42?expand=a", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ a: 1 }),
  });
  assertEquals(await res.json(), { id: "42", echoed: { a: 1 } });
  assertEquals(http.calls.length, 1);
  assertEquals(http.callsTo("POST", "https://api.example.com/v1/items/:id").length, 1);
  assertEquals(http.calls[0]?.url.searchParams.get("expand"), "a");
});

Deno.test("FakeFetch: later routes win; once() routes expire", async () => {
  const http = new FakeFetch();
  http.on("GET", "https://api.example.com/x", () => jsonResponse({ v: "default" }));
  http.once("GET", "https://api.example.com/x", () => jsonResponse({ v: "first" }, 201));
  const first = await http.fetch("https://api.example.com/x");
  assertEquals([first.status, await first.json()], [201, { v: "first" }]);
  const second = await http.fetch("https://api.example.com/x");
  assertEquals(await second.json(), { v: "default" });
});

Deno.test("FakeFetch: form bodies are parsed", async () => {
  const http = new FakeFetch();
  http.on("POST", "https://api.example.com/form", () => ({}));
  await (await http.fetch("https://api.example.com/form", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: "To=%2B1205&Body=hi+there",
  })).body?.cancel();
  assertEquals(http.calls[0]?.form.get("Body"), "hi there");
  assertEquals(http.calls[0]?.form.get("To"), "+1205");
});

Deno.test("FakeFetch: unmatched requests reject and are recorded", async () => {
  const http = new FakeFetch();
  http.on("GET", "https://api.example.com/a", () => ({}));
  await assertRejects(
    () => http.fetch("https://api.example.com/b", { method: "GET" }),
    TypeError,
    "no route for GET https://api.example.com/b",
  );
  await assertRejects(() => http.fetch("https://api.example.com/a", { method: "POST" }), TypeError);
  assertEquals(http.unmatched.length, 2);
});

Deno.test("FakeFetch: explicit query patterns and ports", async () => {
  const http = new FakeFetch();
  http.on("GET", "http://localhost:54321/q?mode=a", () => ({ ok: "a" }));
  assertEquals(await (await http.fetch("http://localhost:54321/q?mode=a")).json(), { ok: "a" });
  await assertRejects(() => http.fetch("http://localhost:54321/q?mode=b"), TypeError);
  await assertRejects(() => http.fetch("http://localhost:9999/q?mode=a"), TypeError);
});
