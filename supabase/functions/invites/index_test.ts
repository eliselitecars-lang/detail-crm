import { assert, assertEquals } from "@std/assert";
import type { ErrorBody } from "../_shared/http.ts";
import { jsonResponse } from "../_shared/testing/fake_fetch.ts";
import { FakeRpcError, FakeSupabase, type Row } from "../_shared/testing/fake_supabase.ts";
import { memoryLogger } from "../_shared/testing/logger.ts";
import { jsonRequest, responseJson } from "../_shared/testing/requests.ts";
import { formatPhone, type InviteResponse, makeHandler } from "./index.ts";

const SHOP = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const OTHER_SHOP = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const OWNER = "10000000-0000-4000-8000-000000000001";
const ADMIN = "10000000-0000-4000-8000-000000000002";
const MANAGER = "10000000-0000-4000-8000-000000000003";
const TECH = "10000000-0000-4000-8000-000000000004";
const OUTSIDER = "10000000-0000-4000-8000-000000000005";
const RESEND_URL = "https://api.resend.com/emails";
const NOW = new Date("2026-09-27T15:00:00.000Z");
const APP = "https://app.example.com";

function member(userId: string, role: string, shopId = SHOP): Row {
  return {
    id: crypto.randomUUID(),
    shop_id: shopId,
    user_id: userId,
    role,
    display_name: role,
    active: true,
  };
}

function invite(overrides: Row = {}): Row {
  return {
    id: crypto.randomUUID(),
    shop_id: SHOP,
    email: "newtech@example.com",
    role: "technician",
    token: crypto.randomUUID(),
    invited_by: OWNER,
    expires_at: "2026-10-01T00:00:00.000Z",
    accepted_at: null,
    revoked_at: null,
    ...overrides,
  };
}

function setup(options: { invites?: Row[]; templates?: Row[] } = {}) {
  const db = new FakeSupabase({
    users: {
      "tok-owner": { id: OWNER, email: "owner@example.com" },
      "tok-admin": { id: ADMIN, email: "admin@example.com" },
      "tok-manager": { id: MANAGER, email: "manager@example.com" },
      "tok-tech": { id: TECH, email: "tech@example.com" },
      "tok-outsider": { id: OUTSIDER, email: "outsider@example.com" },
    },
    tables: {
      shop_members: [
        member(OWNER, "owner"),
        member(ADMIN, "admin"),
        member(MANAGER, "manager"),
        member(TECH, "technician"),
        member(OUTSIDER, "owner", OTHER_SHOP),
      ],
      shops: [
        { id: SHOP, name: "Shine Auto Spa", email: "hello@shine.example", phone: "+12055550100" },
        { id: OTHER_SHOP, name: "Other", email: null, phone: null },
      ],
      shop_invites: options.invites ?? [],
      message_templates: options.templates ?? [],
    },
  });
  db.onRpc("invite_member", (args, ctx) => {
    if (ctx.role !== "authenticated") throw new FakeRpcError("42501", "must be a user");
    const role = ctx.db.table("shop_members").find((m) =>
      m.user_id === ctx.userId && m.shop_id === args.p_shop_id
    )?.role;
    if (role !== "owner" && role !== "admin") {
      throw new FakeRpcError("42501", "only owners and admins can invite team members");
    }
    const email = String(args.p_email).toLowerCase();
    if (email === "owner@example.com") {
      throw new FakeRpcError("23505", `${email} is already a member of this shop`);
    }
    const rows = ctx.db.table("shop_invites").map((i) =>
      i.shop_id === args.p_shop_id && i.email === email && !i.accepted_at && !i.revoked_at
        ? { ...i, revoked_at: NOW.toISOString() }
        : i
    );
    const row = invite({
      shop_id: args.p_shop_id,
      email,
      role: args.p_role,
      invited_by: ctx.userId,
      expires_at: "2026-10-04T15:00:00.000Z",
    });
    ctx.db.seed("shop_invites", [...rows, row]);
    return row;
  });
  let sent = 0;
  db.http.on("POST", RESEND_URL, () => jsonResponse({ id: `email-${++sent}` }));
  const logs = memoryLogger();
  const handler = makeHandler({
    env: db.env(),
    fetch: db.http.fetch,
    logger: logs.logger,
    now: () => NOW,
  });
  return { db, handler, logs };
}

const sendInvite = (token: string | null, body: Record<string, unknown>) =>
  jsonRequest("invites", { action: "send_invite", shop_id: SHOP, ...body }, {
    ...(token ? { token } : {}),
    origin: APP,
  });

const resendInvite = (token: string, inviteId: string) =>
  jsonRequest("invites", { action: "resend_invite", invite_id: inviteId }, { token });

async function expectError(res: Response, status: number, code: string): Promise<ErrorBody> {
  const body = await responseJson<ErrorBody>(res);
  assertEquals([res.status, body.code], [status, code], JSON.stringify(body));
  return body;
}

Deno.test("send_invite: admin invites via the RPC as the caller and emails the link", async () => {
  const { db, handler } = setup();
  const res = await handler(
    sendInvite("tok-admin", { email: " NewTech@Example.com ", role: "technician" }),
  );
  assertEquals(res.status, 200);
  assertEquals(res.headers.get("access-control-allow-origin"), APP);
  const out = await responseJson<InviteResponse>(res);
  const stored = db.table("shop_invites")[0];
  assert(stored);
  assertEquals(out.invite, {
    id: stored.id,
    shop_id: SHOP,
    email: "newtech@example.com",
    role: "technician",
    expires_at: "2026-10-04T15:00:00.000Z",
  });
  assertEquals(out.invite_url, `${APP}/invite/${stored.token}`);
  assertEquals(out.email_sent, true);
  // The token itself is not echoed as a separate field.
  assertEquals("token" in (out.invite as Record<string, unknown>), false);

  const rpc = db.requests.find((r) => r.target === "invite_member");
  assertEquals([rpc?.role, rpc?.userId], ["authenticated", ADMIN]);

  const call = db.http.callsTo("POST", RESEND_URL)[0];
  assert(call);
  const email = call.json as Record<string, unknown>;
  assertEquals(email.from, "Shine Auto Spa <notifications@example.com>");
  assertEquals(email.to, ["newtech@example.com"]);
  assertEquals(email.reply_to, ["hello@shine.example"]);
  assertEquals(email.subject, "You are invited to join Shine Auto Spa");
  assertEquals(
    email.text,
    "Hello,\n\nYou have been invited to join the Shine Auto Spa team.\n\n" +
      `Accept your invitation here: ${APP}/invite/${stored.token}\n\n` +
      "This invitation expires in 7 days. If you were not expecting it, you can ignore this email.",
  );
  assert(String(email.html).includes(`<a href="${APP}/invite/${stored.token}">`));
  assertEquals(call.headers.get("idempotency-key"), `invite-${stored.id}`);
});

Deno.test("send_invite: uses the shop's enabled invite template", async () => {
  const { db, handler } = setup({
    templates: [{
      shop_id: SHOP,
      key: "invite",
      channel: "email",
      subject: "Join {{shop_name}} <crew>",
      body: "Hey! {{shop_name}} ({{shop_phone}}) wants you: {{invite_link}}",
      enabled: true,
    }],
  });
  const out = await responseJson<InviteResponse>(
    await handler(sendInvite("tok-owner", { email: "m@example.com", role: "manager" })),
  );
  const email = db.http.callsTo("POST", RESEND_URL)[0]?.json as Record<string, unknown>;
  assertEquals(email.subject, "Join Shine Auto Spa <crew>");
  assertEquals(email.text, `Hey! Shine Auto Spa ((205) 555-0100) wants you: ${out.invite_url}`);
});

Deno.test("send_invite: a disabled template still sends the default wording", async () => {
  const { db, handler } = setup({
    templates: [{
      shop_id: SHOP,
      key: "invite",
      channel: "email",
      subject: "Custom",
      body: "Custom {{invite_link}}",
      enabled: false,
    }],
  });
  await (await handler(sendInvite("tok-owner", { email: "m@example.com", role: "manager" }))).body
    ?.cancel();
  const email = db.http.callsTo("POST", RESEND_URL)[0]?.json as Record<string, unknown>;
  assertEquals(email.subject, "You are invited to join Shine Auto Spa");
});

Deno.test("send_invite: managers, technicians, outsiders and signed-out callers are refused", async () => {
  const { db, handler } = setup();
  const body = { email: "x@example.com", role: "technician" };
  await expectError(await handler(sendInvite("tok-manager", body)), 403, "forbidden");
  await expectError(await handler(sendInvite("tok-tech", body)), 403, "forbidden");
  await expectError(await handler(sendInvite("tok-outsider", body)), 403, "forbidden");
  await expectError(await handler(sendInvite(null, body)), 401, "unauthorized");
  assertEquals(db.requests.some((r) => r.target === "invite_member"), false);
  assertEquals(db.http.callsTo("POST", RESEND_URL).length, 0);
});

Deno.test("send_invite: the database role check is enforced too", async () => {
  const { db, handler } = setup();
  db.onRpc("invite_member", () => {
    throw new FakeRpcError("42501", "only owners and admins can invite team members");
  });
  const err = await expectError(
    await handler(sendInvite("tok-admin", { email: "x@example.com", role: "technician" })),
    403,
    "forbidden",
  );
  assertEquals(err.error, "Only owners and admins can invite team members.");
  assertEquals(db.http.callsTo("POST", RESEND_URL).length, 0);
});

Deno.test("send_invite: validation, owner role and existing members", async () => {
  const { handler } = setup();
  for (
    const body of [
      { email: "x@example.com", role: "owner" },
      { email: "not-an-email", role: "technician" },
      { email: "x@example.com", role: "technician", token: "abc" },
      { role: "technician" },
    ]
  ) {
    await expectError(await handler(sendInvite("tok-owner", body)), 400, "validation_failed");
  }
  await expectError(
    await handler(sendInvite("tok-owner", { email: "owner@example.com", role: "admin" })),
    409,
    "conflict",
  );
});

Deno.test("send_invite: an email failure keeps the invite and returns the link", async () => {
  const { db, handler, logs } = setup();
  db.http.on("POST", RESEND_URL, () => jsonResponse({ name: "internal", message: "down" }, 500));
  const res = await handler(sendInvite("tok-owner", { email: "x@example.com", role: "manager" }));
  assertEquals(res.status, 200);
  const out = await responseJson<InviteResponse>(res);
  assertEquals(out.email_sent, false);
  assertEquals(db.table("shop_invites").length, 1);
  assertEquals(out.invite_url.startsWith(`${APP}/invite/`), true);
  assertEquals(logs.events("invite_email_failed").length, 1);
});

Deno.test("send_invite: a missing APP_BASE_URL fails before an invite is created", async () => {
  const db = new FakeSupabase({
    users: { "tok-owner": { id: OWNER } },
    tables: { shop_members: [member(OWNER, "owner")], shop_invites: [] },
  });
  db.onRpc("invite_member", () => {
    throw new Error("must not be called");
  });
  const handler = makeHandler({
    env: db.env({ APP_BASE_URL: undefined }),
    fetch: db.http.fetch,
    logger: memoryLogger().logger,
    // (CORS policy also derives from APP_BASE_URL, so this fails up front.)
  });
  const res = await handler(
    jsonRequest("invites", {
      action: "send_invite",
      shop_id: SHOP,
      email: "x@example.com",
      role: "manager",
    }, { token: "tok-owner" }),
  );
  await expectError(res, 500, "server_misconfigured");
  assertEquals(db.requests.some((r) => r.target === "invite_member"), false);
});

Deno.test("resend_invite: re-emails a pending invite with the same link", async () => {
  const pending = invite();
  const { db, handler } = setup({ invites: [pending] });
  const out = await responseJson<InviteResponse>(
    await handler(resendInvite("tok-admin", String(pending.id))),
  );
  assertEquals(out.reissued, false);
  assertEquals(out.invite.id, pending.id);
  assertEquals(out.invite_url, `${APP}/invite/${pending.token}`);
  assertEquals(out.email_sent, true);
  const call = db.http.callsTo("POST", RESEND_URL)[0];
  assertEquals((call?.json as { to: string[] }).to, ["newtech@example.com"]);
  assertEquals(
    call?.headers.get("idempotency-key"),
    `invite-${pending.id}-resend-${Math.floor(NOW.getTime() / 60_000)}`,
  );
  assertEquals(db.requests.some((r) => r.target === "invite_member"), false);
});

Deno.test("resend_invite: an expired invite is re-issued with a new token", async () => {
  const expired = invite({ expires_at: "2026-09-20T00:00:00.000Z", role: "manager" });
  const { db, handler } = setup({ invites: [expired] });
  const out = await responseJson<InviteResponse>(
    await handler(resendInvite("tok-owner", String(expired.id))),
  );
  assertEquals(out.reissued, true);
  assert(out.invite.id !== expired.id);
  assertEquals(out.invite.role, "manager");
  const rows = db.table("shop_invites");
  assertEquals(rows.find((r) => r.id === expired.id)?.revoked_at, NOW.toISOString());
  const fresh = rows.find((r) => r.id === out.invite.id);
  assertEquals(out.invite_url, `${APP}/invite/${fresh?.token}`);
});

Deno.test("resend_invite: accepted, revoked, unknown and foreign invites", async () => {
  const accepted = invite({ accepted_at: "2026-09-25T00:00:00Z" });
  const revoked = invite({ revoked_at: "2026-09-25T00:00:00Z" });
  const foreign = invite({ shop_id: OTHER_SHOP });
  const pending = invite();
  const { db, handler } = setup({ invites: [accepted, revoked, foreign, pending] });
  await expectError(await handler(resendInvite("tok-owner", String(accepted.id))), 409, "conflict");
  await expectError(await handler(resendInvite("tok-owner", String(revoked.id))), 410, "gone");
  await expectError(
    await handler(resendInvite("tok-owner", crypto.randomUUID())),
    404,
    "not_found",
  );
  await expectError(await handler(resendInvite("tok-owner", String(foreign.id))), 403, "forbidden");
  await expectError(
    await handler(resendInvite("tok-manager", String(pending.id))),
    403,
    "forbidden",
  );
  assertEquals(db.http.callsTo("POST", RESEND_URL).length, 0);
});

Deno.test("formatPhone mirrors SQL format_phone", () => {
  assertEquals(formatPhone("+12055550101"), "(205) 555-0101");
  assertEquals(formatPhone("+442071234567"), "+442071234567");
  assertEquals(formatPhone(null), null);
});
