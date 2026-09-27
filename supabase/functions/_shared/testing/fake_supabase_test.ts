import { assert, assertEquals, assertMatch } from "@std/assert";
import { FakeRpcError, FakeSupabase } from "./fake_supabase.ts";

function fake(): FakeSupabase {
  return new FakeSupabase({
    users: { "tok-a": { id: "u-a", email: "a@example.com" } },
    tables: {
      customers: [
        {
          id: "c1",
          shop_id: "s1",
          first_name: "Ana",
          tags: ["vip", "fleet"],
          visits: 3,
          archived_at: null,
          sms_opt_in: true,
        },
        {
          id: "c2",
          shop_id: "s1",
          first_name: "Ben",
          tags: [],
          visits: 10,
          archived_at: "2026-01-01",
          sms_opt_in: false,
        },
        {
          id: "c3",
          shop_id: "s2",
          first_name: "Cy",
          tags: ["vip"],
          visits: null,
          archived_at: null,
          sms_opt_in: true,
        },
      ],
      stripe_events: [],
    },
    tableOptions: { stripe_events: { primaryKey: ["id"] } },
  });
}

Deno.test("fake-supabase: select with filters, order, limit, columns and aliases", async () => {
  const db = fake().admin();
  const { data, error } = await db.from("customers").select("id, name:first_name")
    .eq("shop_id", "s1").is("archived_at", null).order("first_name", { ascending: false });
  assertEquals(error, null);
  assertEquals(data, [{ id: "c1", name: "Ana" }]);

  const many = await db.from("customers").select("id").in("id", ["c1", "c3"]).order("id");
  assertEquals(many.data, [{ id: "c1" }, { id: "c3" }]);

  const cmp = await db.from("customers").select("id").gte("visits", 3).lt("visits", 10);
  assertEquals(cmp.data, [{ id: "c1" }]);

  const neq = await db.from("customers").select("id").neq("shop_id", "s1");
  assertEquals(neq.data, [{ id: "c3" }]);

  const tags = await db.from("customers").select("id").contains("tags", ["vip"]).order("id");
  assertEquals(tags.data, [{ id: "c1" }, { id: "c3" }]);

  const like = await db.from("customers").select("id").ilike("first_name", "a%");
  assertEquals(like.data, [{ id: "c1" }]);

  const paged = await db.from("customers").select("id").order("id").range(1, 1);
  assertEquals(paged.data, [{ id: "c2" }]);

  const nullsLast = await db.from("customers").select("id").order("visits");
  assertEquals(nullsLast.data, [{ id: "c1" }, { id: "c2" }, { id: "c3" }]);

  const booleans = await db.from("customers").select("id").eq("sms_opt_in", false);
  assertEquals(booleans.data, [{ id: "c2" }]);
});

Deno.test("fake-supabase: single / maybeSingle / count", async () => {
  const db = fake().admin();
  const one = await db.from("customers").select("id").eq("id", "c1").single();
  assertEquals(one.data, { id: "c1" });
  const none = await db.from("customers").select("id").eq("id", "zz").maybeSingle();
  assertEquals([none.data, none.error], [null, null]);
  const noneSingle = await db.from("customers").select("id").eq("id", "zz").single();
  assertEquals(noneSingle.error?.code, "PGRST116");
  const many = await db.from("customers").select("id").eq("shop_id", "s1").maybeSingle();
  assertEquals(many.error?.code, "PGRST116");
  const counted = await db.from("customers").select("id", { count: "exact", head: true }).eq(
    "shop_id",
    "s1",
  );
  assertEquals(counted.count, 2);
});

Deno.test("fake-supabase: insert, unique violations, upsert, update, delete", async () => {
  const fs = fake();
  const db = fs.admin();
  const inserted = await db.from("stripe_events").insert({ id: "evt_1", type: "x" }).select()
    .single();
  assertEquals(inserted.data, { id: "evt_1", type: "x" });
  const dup = await db.from("stripe_events").insert({ id: "evt_1", type: "x" });
  assertEquals(dup.error?.code, "23505");
  const ignored = await db.from("stripe_events").upsert({ id: "evt_1", type: "y" }, {
    ignoreDuplicates: true,
  });
  assertEquals(ignored.error, null);
  assertEquals(fs.table("stripe_events"), [{ id: "evt_1", type: "x" }]);
  await db.from("stripe_events").upsert({ id: "evt_1", type: "z" });
  assertEquals(fs.table("stripe_events"), [{ id: "evt_1", type: "z" }]);

  const created = await db.from("customers").insert({ shop_id: "s1", first_name: "Dee" }).select(
    "id",
  ).single();
  assertMatch(String((created.data as { id: string }).id), /^[0-9a-f-]{36}$/);

  const updated = await db.from("customers").update({ sms_opt_in: false }).eq("id", "c1").select(
    "id, sms_opt_in",
  );
  assertEquals(updated.data, [{ id: "c1", sms_opt_in: false }]);
  const minimal = await db.from("customers").update({ visits: 4 }).eq("id", "c1");
  assertEquals([minimal.error, minimal.status], [null, 204]);

  const deleted = await db.from("customers").delete().eq("shop_id", "s2").select("id");
  assertEquals(deleted.data, [{ id: "c3" }]);
  assertEquals(fs.table("customers").length, 3);
});

Deno.test("fake-supabase: rpc handlers, errors and caller role", async () => {
  const fs = fake();
  fs.onRpc("next_document_number", (args, ctx) => ({ args, role: ctx.role, user: ctx.userId }));
  fs.onRpc("fails", () => {
    throw new FakeRpcError("P0001", "Invoice already paid", { status: 400 });
  });
  const ok = await fs.admin().rpc("next_document_number", { p_shop_id: "s1", p_kind: "invoice" });
  assertEquals(ok.data, {
    args: { p_shop_id: "s1", p_kind: "invoice" },
    role: "service_role",
    user: null,
  });
  const asUser = await fs.asUser("tok-a").rpc("next_document_number", {});
  assertEquals((asUser.data as { role: string; user: string }).role, "authenticated");
  assertEquals((asUser.data as { role: string; user: string }).user, "u-a");
  const failed = await fs.admin().rpc("fails");
  assertEquals([failed.error?.code, failed.error?.message], ["P0001", "Invoice already paid"]);
  const missing = await fs.admin().rpc("nope");
  assertEquals(missing.error?.code, "PGRST202");
});

Deno.test("fake-supabase: unknown tables and unsupported syntax fail loudly", async () => {
  const db = fake().admin();
  const unknown = await db.from("nope").select("*");
  assertEquals(unknown.error?.code, "PGRST205");
  const embedded = await db.from("customers").select("id, vehicles(id)");
  assert(embedded.error?.message.includes("fake-supabase: unsupported"));
  const or = await db.from("customers").select("id").or("id.eq.c1,id.eq.c2");
  assert(or.error?.message.includes("fake-supabase: unsupported"));
});

Deno.test("fake-supabase: rows are isolated copies", async () => {
  const fs = fake();
  const { data } = await fs.admin().from("customers").select("*").eq("id", "c1").single();
  (data as { tags: string[] }).tags.push("mutated");
  assertEquals(fs.table("customers")[0]?.tags, ["vip", "fleet"]);
});

Deno.test("fake-supabase: requests with an unknown apikey are rejected", async () => {
  const fs = fake();
  const res = await fs.http.fetch(`${fs.url}/rest/v1/customers`, { headers: { apikey: "nope" } });
  assertEquals(res.status, 401);
  await res.body?.cancel();
});
