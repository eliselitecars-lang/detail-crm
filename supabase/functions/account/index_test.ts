import { assertEquals } from "@std/assert";
import type { ErrorBody } from "../_shared/http.ts";
import { jsonResponse } from "../_shared/testing/fake_fetch.ts";
import { FakeRpcError, FakeSupabase, type Row } from "../_shared/testing/fake_supabase.ts";
import { memoryLogger } from "../_shared/testing/logger.ts";
import { jsonRequest, preflightRequest, responseJson } from "../_shared/testing/requests.ts";
import { type DeleteAccountResponse, makeHandler, OWNS_SHOPS_MESSAGE } from "./index.ts";

const APP = "https://app.example.com";
const OWNER = "10000000-0000-4000-8000-000000000001";
const TECH = "10000000-0000-4000-8000-000000000002";
const CLIENT = "10000000-0000-4000-8000-000000000003";
const SHOP = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const OTHER_SHOP = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const ADMIN_USERS = "https://fake-project.supabase.co/auth/v1/admin/users/:id";

interface Fixture {
  db: FakeSupabase;
  handler: (req: Request) => Promise<Response>;
  deleted: string[];
}

/**
 * account_deletion_blockers (0092) as the caller: the shops they own, by
 * name. Granted to authenticated only (service_role and anon: 42501).
 */
function setup(options: { owned?: Record<string, Row[]>; deleteStatus?: number } = {}): Fixture {
  const owned = options.owned ?? {
    [OWNER]: [
      { shop_id: OTHER_SHOP, name: "B Detail" },
      { shop_id: SHOP, name: "A Shine" },
    ],
  };
  const deleted: string[] = [];
  const db = new FakeSupabase({
    users: {
      "tok-owner": { id: OWNER, email: "owner@example.com" },
      "tok-tech": { id: TECH, email: "tech@example.com" },
      "tok-client": { id: CLIENT, email: "client@example.com" },
      "tok-anon": { id: "10000000-0000-4000-8000-000000000009", is_anonymous: true },
    },
  });
  db.onRpc("account_deletion_blockers", (_args, ctx) => {
    if (ctx.role !== "authenticated" || !ctx.userId) {
      throw new FakeRpcError("42501", "permission denied");
    }
    const shops = [...(owned[ctx.userId] ?? [])].sort((a, b) =>
      String(a.name).localeCompare(String(b.name))
    );
    return { owned_shops: shops };
  });
  db.http.on("DELETE", ADMIN_USERS, (req, match) => {
    const key = req.headers.get("authorization");
    if (key !== "Bearer fake-service-role-key") {
      return jsonResponse({ code: 403, msg: "User not allowed" }, 403);
    }
    const status = options.deleteStatus ?? 200;
    if (status !== 200) {
      return jsonResponse(
        { code: status, error_code: "unexpected_failure", msg: "Database error deleting user" },
        status,
      );
    }
    deleted.push(match.params.id ?? "");
    return jsonResponse({});
  });
  const handler = makeHandler({
    env: db.env(),
    fetch: db.http.fetch,
    logger: memoryLogger().logger,
  });
  return { db, handler, deleted };
}

function deleteRequest(token: string | null, body: Record<string, unknown> = {}): Request {
  return jsonRequest("account", { action: "delete_account", ...body }, {
    ...(token ? { token } : {}),
    origin: APP,
  });
}

Deno.test("account: a member who owns no shop deletes their account (Auth admin API)", async () => {
  const { db, handler, deleted } = setup();
  const res = await handler(deleteRequest("tok-tech"));
  assertEquals(res.status, 200);
  assertEquals(res.headers.get("access-control-allow-origin"), APP);
  assertEquals(await responseJson<DeleteAccountResponse>(res), { deleted: true });
  assertEquals(deleted, [TECH]);
  // The blockers were read as the caller, never with the service role.
  const check = db.requests.find((r) => r.target === "account_deletion_blockers");
  assertEquals([check?.role, check?.userId], ["authenticated", TECH]);
});

Deno.test("account: a portal client (no membership) can delete their account", async () => {
  const { handler, deleted } = setup();
  const res = await handler(deleteRequest("tok-client"));
  assertEquals(res.status, 200);
  assertEquals(deleted, [CLIENT]);
});

Deno.test("account: an owner is refused with the shops to transfer or delete (409 owns_shops)", async () => {
  const { handler, deleted } = setup();
  const res = await handler(deleteRequest("tok-owner"));
  const body = await responseJson<ErrorBody>(res);
  assertEquals([res.status, body.code, body.error], [409, "conflict", OWNS_SHOPS_MESSAGE]);
  assertEquals(body.details, {
    reason: "owns_shops",
    shops: [
      { shop_id: SHOP, name: "A Shine" },
      { shop_id: OTHER_SHOP, name: "B Detail" },
    ],
  });
  assertEquals(deleted, []);
});

Deno.test("account: the database refusing the delete (shop owned meanwhile) is 409 owns_shops", async () => {
  // The check passes, then the user becomes an owner before GoTrue deletes.
  const owned: Record<string, Row[]> = {};
  const { db, handler } = setup({ owned, deleteStatus: 500 });
  let checks = 0;
  db.onRpc("account_deletion_blockers", () => {
    checks += 1;
    return { owned_shops: checks === 1 ? [] : [{ shop_id: SHOP, name: "A Shine" }] };
  });
  const res = await handler(deleteRequest("tok-tech"));
  const body = await responseJson<ErrorBody>(res);
  assertEquals([res.status, body.code], [409, "conflict"]);
  assertEquals(body.details, { reason: "owns_shops", shops: [{ shop_id: SHOP, name: "A Shine" }] });
});

Deno.test("account: a GoTrue failure that is not about ownership is retryable (503), a 4xx a 500", async () => {
  // auth-js reports a 5xx from GoTrue as AuthRetryableFetchError.
  const { handler, deleted } = setup({ deleteStatus: 500 });
  const res = await handler(deleteRequest("tok-tech"));
  const body = await responseJson<ErrorBody>(res);
  assertEquals([res.status, body.code], [503, "service_unavailable"]);
  assertEquals(deleted, []);
  const refused = await setup({ deleteStatus: 422 }).handler(deleteRequest("tok-tech"));
  assertEquals(
    [refused.status, (await responseJson<ErrorBody>(refused)).code],
    [500, "internal_error"],
  );
});

Deno.test("account: a user already gone in Auth counts as deleted", async () => {
  const { handler } = setup({ deleteStatus: 404 });
  const res = await handler(deleteRequest("tok-tech"));
  assertEquals([res.status, await responseJson(res)], [200, { deleted: true }]);
});

Deno.test("account: no session, an anonymous user or extra fields are refused", async () => {
  const { handler, deleted } = setup();
  const none = await handler(deleteRequest(null));
  assertEquals([none.status, (await responseJson<ErrorBody>(none)).code], [401, "unauthorized"]);
  const anon = await handler(deleteRequest("tok-anon"));
  assertEquals([anon.status, (await responseJson<ErrorBody>(anon)).code], [401, "unauthorized"]);
  const extra = await handler(deleteRequest("tok-tech", { user_id: OWNER }));
  assertEquals(
    [extra.status, (await responseJson<ErrorBody>(extra)).code],
    [400, "validation_failed"],
  );
  assertEquals(deleted, []);
});

Deno.test("account: CORS preflight from the app origin", async () => {
  const { handler } = setup();
  const res = await handler(preflightRequest("account", APP));
  assertEquals(res.status, 204);
  assertEquals(res.headers.get("access-control-allow-origin"), APP);
});
