import { assertEquals, assertRejects, assertThrows } from "@std/assert";
import {
  getMembership,
  isAssignedToJob,
  requireCronSecret,
  requireJobAccess,
  requireShopRole,
  requireUser,
  ROLES,
} from "./auth.ts";
import { HttpError } from "./errors.ts";
import { FakeSupabase } from "./testing/fake_supabase.ts";
import { jsonRequest } from "./testing/requests.ts";

const SHOP = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const OTHER_SHOP = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const JOB = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
const OTHER_JOB = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";

const users = {
  owner: "10000000-0000-4000-8000-000000000001",
  manager: "10000000-0000-4000-8000-000000000002",
  tech: "10000000-0000-4000-8000-000000000003",
  inactive: "10000000-0000-4000-8000-000000000004",
  outsider: "10000000-0000-4000-8000-000000000005",
};
const members = {
  owner: "20000000-0000-4000-8000-000000000001",
  manager: "20000000-0000-4000-8000-000000000002",
  tech: "20000000-0000-4000-8000-000000000003",
  inactive: "20000000-0000-4000-8000-000000000004",
  outsiderElsewhere: "20000000-0000-4000-8000-000000000005",
};

function member(id: string, shop: string, user: string, role: string, active = true) {
  return { id, shop_id: shop, user_id: user, role, display_name: role, active };
}

function fake(): FakeSupabase {
  return new FakeSupabase({
    users: {
      "tok-owner": { id: users.owner, email: "owner@example.com" },
      "tok-anon": { id: "30000000-0000-4000-8000-000000000001", is_anonymous: true },
    },
    tables: {
      shop_members: [
        member(members.owner, SHOP, users.owner, "owner"),
        member(members.manager, SHOP, users.manager, "manager"),
        member(members.tech, SHOP, users.tech, "technician"),
        member(members.inactive, SHOP, users.inactive, "admin", false),
        member(members.outsiderElsewhere, OTHER_SHOP, users.outsider, "owner"),
      ],
      jobs: [{ id: JOB, shop_id: SHOP }, { id: OTHER_JOB, shop_id: SHOP }],
      job_assignments: [{
        id: "40000000-0000-4000-8000-000000000001",
        shop_id: SHOP,
        job_id: JOB,
        member_id: members.tech,
      }],
    },
  });
}

async function code(promise: Promise<unknown>): Promise<string> {
  return (await assertRejects(() => promise, HttpError)).code;
}

Deno.test("requireUser: verified users pass; missing/invalid/anonymous are unauthorized", async () => {
  const db = fake();
  const admin = db.admin();
  const caller = await requireUser(jsonRequest("f", {}, { token: "tok-owner" }), { admin });
  assertEquals(caller.id, users.owner);
  assertEquals(await code(requireUser(jsonRequest("f", {}), { admin })), "unauthorized");
  assertEquals(
    await code(requireUser(jsonRequest("f", {}, { token: "bad" }), { admin })),
    "unauthorized",
  );
  assertEquals(
    await code(requireUser(jsonRequest("f", {}, { token: "tok-anon" }), { admin })),
    "unauthorized",
  );
});

Deno.test("requireShopRole: allows active members whose role is listed", async () => {
  const admin = fake().admin();
  const owner = await requireShopRole(admin, { id: users.owner }, SHOP, ROLES.adminPlus);
  assertEquals(owner, {
    id: members.owner,
    shopId: SHOP,
    userId: users.owner,
    role: "owner",
    displayName: "owner",
  });
  const manager = await requireShopRole(admin, { id: users.manager }, SHOP, ROLES.managerPlus);
  assertEquals(manager.role, "manager");
  const tech = await requireShopRole(admin, { id: users.tech }, SHOP, ROLES.anyStaff);
  assertEquals(tech.id, members.tech);
});

Deno.test("requireShopRole: denies wrong roles, inactive members and other shops", async () => {
  const admin = fake().admin();
  assertEquals(
    await code(requireShopRole(admin, { id: users.manager }, SHOP, ROLES.adminPlus)),
    "forbidden",
  );
  assertEquals(
    await code(requireShopRole(admin, { id: users.tech }, SHOP, ROLES.managerPlus)),
    "forbidden",
  );
  assertEquals(
    await code(requireShopRole(admin, { id: users.inactive }, SHOP, ROLES.anyStaff)),
    "forbidden",
  );
  // An owner of another shop has no access here.
  assertEquals(
    await code(requireShopRole(admin, { id: users.outsider }, SHOP, ROLES.anyStaff)),
    "forbidden",
  );
  assertEquals(
    await code(requireShopRole(admin, { id: users.owner }, OTHER_SHOP, ROLES.anyStaff)),
    "forbidden",
  );
});

Deno.test("requireShopRole: rejects malformed shop ids without querying", async () => {
  const db = fake();
  const err = await assertRejects(
    () => requireShopRole(db.admin(), { id: users.owner }, "not-a-uuid", ROLES.anyStaff),
    HttpError,
  );
  assertEquals(err.code, "validation_failed");
  assertEquals(db.requests.length, 0);
});

Deno.test("requireShopRole: lookups use the service role and filter active", async () => {
  const db = fake();
  await requireShopRole(db.admin(), { id: users.owner }, SHOP, ROLES.owner);
  const call = db.http.calls.at(-1);
  assertEquals(db.requests.at(-1)?.role, "service_role");
  assertEquals(call?.url.searchParams.get("active"), "eq.true");
  assertEquals(call?.url.searchParams.get("shop_id"), `eq.${SHOP}`);
  assertEquals(call?.url.searchParams.get("user_id"), `eq.${users.owner}`);
});

Deno.test("getMembership: database errors are raised, not treated as 'no access'", async () => {
  const db = fake();
  db.http.on(
    "GET",
    `${db.url}/rest/v1/shop_members`,
    () =>
      new Response(JSON.stringify({ code: "57014", message: "canceling statement" }), {
        status: 500,
        headers: { "content-type": "application/json" },
      }),
  );
  await assertRejects(
    () => getMembership(db.admin(), SHOP, users.owner),
    Error,
    "shop_members lookup failed",
  );
});

Deno.test("isAssignedToJob / requireJobAccess: technician only on assigned jobs", async () => {
  const admin = fake().admin();
  assertEquals(await isAssignedToJob(admin, SHOP, JOB, members.tech), true);
  assertEquals(await isAssignedToJob(admin, SHOP, OTHER_JOB, members.tech), false);
  assertEquals(await isAssignedToJob(admin, OTHER_SHOP, JOB, members.tech), false);
  assertEquals(await isAssignedToJob(admin, SHOP, "bad", members.tech), false);

  const tech = await requireShopRole(admin, { id: users.tech }, SHOP, ROLES.anyStaff);
  await requireJobAccess(admin, tech, JOB);
  assertEquals(await code(requireJobAccess(admin, tech, OTHER_JOB)), "forbidden");

  const manager = await requireShopRole(admin, { id: users.manager }, SHOP, ROLES.anyStaff);
  await requireJobAccess(admin, manager, OTHER_JOB);
  // Narrower full-access set: managers then need an assignment too.
  assertEquals(
    await code(requireJobAccess(admin, manager, OTHER_JOB, ROLES.adminPlus)),
    "forbidden",
  );
});

Deno.test("requireJobAccess: jobs of other shops or unknown ids are not_found", async () => {
  const db = fake();
  db.seed("jobs", [...db.table("jobs"), {
    id: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
    shop_id: OTHER_SHOP,
  }]);
  const admin = db.admin();
  const owner = await requireShopRole(admin, { id: users.owner }, SHOP, ROLES.anyStaff);
  assertEquals(
    await code(requireJobAccess(admin, owner, "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee")),
    "not_found",
  );
  assertEquals(await code(requireJobAccess(admin, owner, "nope")), "not_found");
});

Deno.test("requireCronSecret: constant-time check of x-cron-secret", () => {
  const secret = "fake-cron-secret-0123456789abcdef";
  requireCronSecret(jsonRequest("f", {}, { headers: { "x-cron-secret": secret } }), secret);
  const cases: Record<string, string>[] = [{}, { "x-cron-secret": "wrong" }, {
    "x-cron-secret": `${secret}x`,
  }];
  for (const headers of cases) {
    const err = assertThrows(
      () => requireCronSecret(jsonRequest("f", {}, { headers }), secret),
      HttpError,
    );
    assertEquals(err.code, "unauthorized");
  }
});
