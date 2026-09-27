import { assertEquals, assertRejects, assertThrows } from "@std/assert";
import { z } from "zod";
import { createActionRouter, jsonAction, rawAction } from "./actions.ts";
import { HttpError } from "./errors.ts";
import { createHandler, type ErrorBody, readForm } from "./http.ts";
import { testEnv } from "./testing/env.ts";
import { memoryLogger } from "./testing/logger.ts";
import { formRequest, jsonRequest, responseJson } from "./testing/requests.ts";

interface Deps {
  greeting: string;
}

const router = createActionRouter<Deps>({
  refund: jsonAction(
    z.object({ payment_id: z.string().min(1), amount_cents: z.number().int().positive() }).strict(),
    (input, ctx) => ({ refunded: input.amount_cents, action: ctx.action, greeting: ctx.greeting }),
  ),
  small: jsonAction(z.object({ note: z.string() }).strict(), (input) => input, { maxBytes: 40 }),
  twilio_inbound: rawAction(async (req, ctx) => {
    const form = await readForm(req);
    return { body: form.get("Body"), action: ctx.action };
  }),
});

const logs = memoryLogger();
const handler = createHandler(
  { name: "actions-test", env: testEnv(), logger: logs.logger },
  (req, ctx) => router(req, ctx, { greeting: "hi" }),
);

async function errorCode(res: Response): Promise<string> {
  return (await responseJson<ErrorBody>(res)).code;
}

Deno.test("actions: JSON body selects and validates the action", async () => {
  const res = await handler(
    jsonRequest("payments", { action: "refund", payment_id: "p1", amount_cents: 500 }),
  );
  assertEquals(res.status, 200);
  assertEquals(await res.json(), { refunded: 500, action: "refund", greeting: "hi" });
});

Deno.test("actions: query string selects JSON actions too", async () => {
  const res = await handler(
    jsonRequest("payments", { payment_id: "p1", amount_cents: 1 }, { query: { action: "refund" } }),
  );
  assertEquals(res.status, 200);
  await res.body?.cancel();
});

Deno.test("actions: body action must match the query action", async () => {
  const res = await handler(
    jsonRequest("payments", { action: "small", note: "x" }, { query: { action: "refund" } }),
  );
  assertEquals(res.status, 400);
  assertEquals(await errorCode(res), "bad_request");
});

Deno.test("actions: unknown, missing and prototype-named actions are rejected", async () => {
  for (const body of [{ action: "nope" }, {}, { action: "constructor" }, { action: 7 }, []]) {
    const res = await handler(jsonRequest("payments", body));
    assertEquals(res.status, 400);
    assertEquals(await errorCode(res), "unknown_action");
  }
});

Deno.test("actions: params are validated (strict schemas reject extra keys)", async () => {
  const res = await handler(
    jsonRequest("payments", { action: "refund", payment_id: "p1", amount_cents: -1, total: 9 }),
  );
  assertEquals(res.status, 400);
  const body = await responseJson<ErrorBody>(res);
  assertEquals(body.code, "validation_failed");
});

Deno.test("actions: per-action body limits apply", async () => {
  const res = await handler(jsonRequest("payments", { action: "small", note: "x".repeat(100) }));
  assertEquals(res.status, 413);
  assertEquals(await errorCode(res), "payload_too_large");
});

Deno.test("actions: raw actions get the untouched request via ?action=", async () => {
  const res = await handler(
    formRequest("messaging", { Body: "STOP" }, { query: { action: "twilio_inbound" } }),
  );
  assertEquals(res.status, 200);
  assertEquals(await res.json(), { body: "STOP", action: "twilio_inbound" });
});

Deno.test("actions: raw actions cannot be reached through a JSON body", async () => {
  const res = await handler(jsonRequest("messaging", { action: "twilio_inbound" }));
  assertEquals(res.status, 400);
  assertEquals(await errorCode(res), "unknown_action");
});

Deno.test("actions: non-object JSON bodies are rejected for query-selected actions", async () => {
  const err = await assertRejects(
    () =>
      router(
        jsonRequest("payments", [1, 2], { query: { action: "refund" } }),
        { requestId: "r", log: logs.logger, env: testEnv() },
        { greeting: "x" },
      ),
    HttpError,
  );
  assertEquals(err.code, "validation_failed");
});

Deno.test("actions: invalid action names are rejected at definition time", () => {
  assertThrows(() => createActionRouter({ "Bad-Name": rawAction(() => null) }), Error);
});
