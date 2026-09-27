import { assertEquals, assertInstanceOf, assertRejects, assertThrows } from "@std/assert";
import { ResendError, sendEmail } from "./resend.ts";
import { FetchTimeoutError, withTimeout } from "./fetch_timeout.ts";

const never = () => new Promise<Response>(() => {});

Deno.test("withTimeout: a request that never answers rejects on time and is aborted", async () => {
  let seen: AbortSignal | undefined;
  const fetchFn = withTimeout((_input, init) => {
    seen = init?.signal ?? undefined;
    return never();
  }, 20);
  const started = Date.now();
  const error = await assertRejects(() => fetchFn("https://api.example.com/x"), FetchTimeoutError);
  assertEquals(error.timeoutMs, 20);
  assertEquals(seen?.aborted, true);
  assertEquals(Date.now() - started < 1000, true);
});

Deno.test("withTimeout: a body that stalls after the headers is bounded too", async () => {
  const fetchFn = withTimeout(() =>
    Promise.resolve(
      new Response(new ReadableStream({ start() {/* never enqueues or closes */} }), {
        status: 200,
      }),
    ), 20);
  await assertRejects(() => fetchFn("https://api.example.com/x"), FetchTimeoutError);
});

Deno.test("withTimeout: a prompt answer passes through unchanged", async () => {
  const fetchFn = withTimeout(() =>
    Promise.resolve(
      new Response(JSON.stringify({ id: "1" }), {
        status: 201,
        headers: { "content-type": "application/json" },
      }),
    ), 1000);
  const res = await fetchFn("https://api.example.com/x", { method: "POST" });
  assertEquals([res.status, res.headers.get("content-type")], [201, "application/json"]);
  assertEquals(await res.json(), { id: "1" });
  const empty = await withTimeout(() => Promise.resolve(new Response(null, { status: 204 })), 1000)(
    "https://api.example.com/x",
  );
  assertEquals(empty.status, 204);
});

Deno.test("withTimeout: the caller's own signal still aborts", async () => {
  const controller = new AbortController();
  const fetchFn = withTimeout((_input, init) =>
    new Promise<Response>((_resolve, reject) => {
      init?.signal?.addEventListener("abort", () => reject(init.signal?.reason));
    }), 1000);
  const pending = fetchFn("https://api.example.com/x", { signal: controller.signal });
  controller.abort(new Error("caller gave up"));
  await assertRejects(() => pending, Error, "caller gave up");
});

Deno.test("withTimeout: rejects a nonsensical cap", () => {
  assertThrows(() => withTimeout(fetch, 0), RangeError);
  assertThrows(() => withTimeout(fetch, Number.NaN), RangeError);
});

Deno.test("withTimeout: a stalled Resend call becomes a transport ResendError", async () => {
  const error = await assertRejects(() =>
    sendEmail("re_test", {
      from: "Shop <n@example.com>",
      to: "a@example.com",
      subject: "Hi",
      text: "Hello",
    }, withTimeout(never, 20))
  );
  assertInstanceOf(error, ResendError);
  assertEquals(error.httpStatus, null);
});
