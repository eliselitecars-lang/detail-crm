import { assert, assertEquals } from "@std/assert";
import type { ErrorBody } from "../_shared/http.ts";
import { jsonResponse } from "../_shared/testing/fake_fetch.ts";
import { FakeRpcError, FakeSupabase, type Row } from "../_shared/testing/fake_supabase.ts";
import { memoryLogger } from "../_shared/testing/logger.ts";
import { jsonRequest, responseJson } from "../_shared/testing/requests.ts";
import {
  carriesInviteLink,
  formatPhone,
  INVITE_EMAIL_INTERVAL_MS,
  INVITE_TTL_MS,
  inviteEmailKey,
  type InviteResponse,
  INVITES_PER_DAY,
  isFreshInvite,
  makeHandler,
  REUSE_WINDOW_MS,
} from "./index.ts";

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
const ISSUED_5_MIN_AGO = "2026-10-04T14:55:00.000Z";
/** Issued 6 days 23 hours 50 minutes before NOW: expires 10 minutes from NOW. */
const EXPIRING_SOON = "2026-09-27T15:10:00.000Z";

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
    // Issued 5 minutes before NOW: still within the reuse window.
    expires_at: ISSUED_5_MIN_AGO,
    accepted_at: null,
    revoked_at: null,
    ...overrides,
  };
}

function setup(
  options: { invites?: Row[]; templates?: Row[]; providerTimeoutMs?: number } = {},
) {
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
      created_at: NOW.toISOString(),
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
    providerTimeoutMs: options.providerTimeoutMs,
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
  assertEquals(call.headers.get("idempotency-key"), inviteEmailKey(String(stored.id), NOW));
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

Deno.test("send_invite: the plan's seat limit (PT402) is 402 payment_required, reason seat_limit", async () => {
  const { db, handler } = setup();
  for (const n of [1, 5]) {
    const sentence = `This shop's plan allows ${n} team member${n === 1 ? "" : "s"}.`;
    db.onRpc("invite_member", () => {
      throw new FakeRpcError("PT402", sentence, { status: 402 });
    });
    const err = await expectError(
      await handler(sendInvite("tok-admin", { email: "x@example.com", role: "technician" })),
      402,
      "payment_required",
    );
    // The database's own sentence, verbatim.
    assertEquals([err.error, err.details], [sentence, { reason: "seat_limit" }]);
  }
  // An inactive subscription refuses the same way, with its own reason.
  const inactive =
    "This shop's subscription is inactive, so new records can't be created right now.";
  db.onRpc("invite_member", () => {
    throw new FakeRpcError("PT402", inactive, { status: 402 });
  });
  const paused = await expectError(
    await handler(sendInvite("tok-owner", { email: "y@example.com", role: "manager" })),
    402,
    "payment_required",
  );
  assertEquals([paused.error, paused.details], [inactive, { reason: "subscription_inactive" }]);
  assertEquals(db.table("shop_invites").length, 0);
  assertEquals(db.http.callsTo("POST", RESEND_URL).length, 0);
});

Deno.test("resend_invite: re-issuing an expired invite past the seat limit is 402 seat_limit", async () => {
  const expired = invite({ expires_at: "2026-09-20T15:00:00.000Z" });
  const { db, handler } = setup({ invites: [expired] });
  db.onRpc("invite_member", () => {
    throw new FakeRpcError("PT402", "This shop's plan allows 2 team members.", { status: 402 });
  });
  const err = await expectError(
    await handler(resendInvite("tok-admin", String(expired.id))),
    402,
    "payment_required",
  );
  assertEquals(err.details, { reason: "seat_limit" });
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

Deno.test("send_invite: a stalled Resend call times out instead of hanging the request", async () => {
  const { db, handler, logs } = setup({ providerTimeoutMs: 20 });
  db.http.on("POST", RESEND_URL, () => new Promise<Response>(() => {}));
  const res = await handler(sendInvite("tok-owner", { email: "x@example.com", role: "manager" }));
  assertEquals(res.status, 200);
  const out = await responseJson<InviteResponse>(res);
  assertEquals(out.email_sent, false);
  assertEquals(db.table("shop_invites").length, 1);
  assertEquals(logs.events("invite_email_failed").length, 1);
});

Deno.test("send_invite: a retried / double-submitted invite reuses the first link and emails once", async () => {
  const { db, handler, logs } = setup();
  const body = { email: "x@example.com", role: "manager" };
  const first = await responseJson<InviteResponse>(await handler(sendInvite("tok-owner", body)));
  const second = await responseJson<InviteResponse>(
    await handler(sendInvite("tok-owner", { ...body, email: "X@Example.com" })),
  );
  assertEquals(second.invite.id, first.invite.id);
  assertEquals(second.invite_url, first.invite_url);
  assertEquals([first.email_sent, second.email_sent], [true, true]);
  // The first link is still pending (not revoked), and it is the only invite.
  const rows = db.table("shop_invites");
  assertEquals(rows.length, 1);
  assertEquals(rows[0]?.revoked_at, null);
  assertEquals(db.requests.filter((r) => r.target === "invite_member").length, 1);
  // Both emails carry the same link and the same Resend key (Resend dedupes).
  const calls = db.http.callsTo("POST", RESEND_URL);
  assertEquals(calls.length, 2);
  assertEquals(
    calls.map((c) => c.headers.get("idempotency-key")),
    [inviteEmailKey(first.invite.id, NOW), inviteEmailKey(first.invite.id, NOW)],
  );
  assertEquals(calls.map((c) => c.json), [calls[0]?.json, calls[0]?.json]);
  assertEquals(logs.events("invite_reused").length, 1);
});

Deno.test("send_invite: an existing pending invite is reused; a new role or an expired one re-issues", async () => {
  const pending = invite({ email: "x@example.com", role: "manager" });
  const expired = invite({ email: "y@example.com", expires_at: "2026-09-20T00:00:00.000Z" });
  const { db, handler } = setup({ invites: [pending, expired] });

  const same = await responseJson<InviteResponse>(
    await handler(sendInvite("tok-owner", { email: "x@example.com", role: "manager" })),
  );
  assertEquals(same.invite.id, pending.id);
  assertEquals(same.invite_url, `${APP}/invite/${pending.token}`);
  assertEquals(db.requests.some((r) => r.target === "invite_member"), false);

  const promoted = await responseJson<InviteResponse>(
    await handler(sendInvite("tok-owner", { email: "x@example.com", role: "admin" })),
  );
  assert(promoted.invite.id !== pending.id);
  assertEquals(promoted.invite.role, "admin");
  assertEquals(
    db.table("shop_invites").find((r) => r.id === pending.id)?.revoked_at,
    NOW.toISOString(),
  );

  const renewed = await responseJson<InviteResponse>(
    await handler(sendInvite("tok-owner", { email: "y@example.com", role: "technician" })),
  );
  assert(renewed.invite.id !== expired.id);
  assertEquals(db.requests.filter((r) => r.target === "invite_member").length, 2);
});

Deno.test("send_invite: losing the insert race to an identical request reuses the winner's invite", async () => {
  const { db, handler } = setup();
  const winner = invite({ email: "x@example.com", role: "manager" });
  db.onRpc("invite_member", (_args, ctx) => {
    // A concurrent identical request committed first: the one-pending-invite index refuses ours.
    ctx.db.seed("shop_invites", [winner]);
    throw new FakeRpcError("23505", "duplicate key value violates unique constraint");
  });
  const out = await responseJson<InviteResponse>(
    await handler(sendInvite("tok-owner", { email: "x@example.com", role: "manager" })),
  );
  assertEquals(out.invite.id, winner.id);
  assertEquals(out.invite_url, `${APP}/invite/${winner.token}`);
  assertEquals(db.table("shop_invites")[0]?.revoked_at, null);
  assertEquals(
    db.http.callsTo("POST", RESEND_URL)[0]?.headers.get("idempotency-key"),
    inviteEmailKey(String(winner.id), NOW),
  );
});

Deno.test("send_invite: a race lost to a different role is a conflict, not a revoke", async () => {
  const { db, handler } = setup();
  db.onRpc("invite_member", (_args, ctx) => {
    ctx.db.seed("shop_invites", [invite({ email: "x@example.com", role: "admin" })]);
    throw new FakeRpcError("23505", "duplicate key value violates unique constraint");
  });
  await expectError(
    await handler(sendInvite("tok-owner", { email: "x@example.com", role: "manager" })),
    409,
    "conflict",
  );
  assertEquals(db.http.callsTo("POST", RESEND_URL).length, 0);
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
    `invite-${pending.id}-email-${Math.floor(NOW.getTime() / (5 * 60_000))}`,
  );
  assertEquals(call?.headers.get("idempotency-key"), inviteEmailKey(String(pending.id), NOW));
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

Deno.test("resend_invite: a concurrent re-issue of the same expired invite reuses the new link", async () => {
  const expired = invite({ expires_at: "2026-09-20T00:00:00.000Z", role: "manager" });
  const { db, handler } = setup({ invites: [expired] });
  const winner = invite({ role: "manager", expires_at: "2026-10-04T15:00:00.000Z" });
  db.onRpc("invite_member", (_args, ctx) => {
    // The other click's invite_member committed first (revoked the expired row, inserted its own).
    ctx.db.seed("shop_invites", [
      ...ctx.db.table("shop_invites").map((r) =>
        r.id === expired.id ? { ...r, revoked_at: NOW.toISOString() } : r
      ),
      winner,
    ]);
    throw new FakeRpcError("23505", "duplicate key value violates unique constraint");
  });
  const out = await responseJson<InviteResponse>(
    await handler(resendInvite("tok-owner", String(expired.id))),
  );
  assertEquals(out.reissued, true);
  assertEquals(out.invite.id, winner.id);
  assertEquals(out.invite_url, `${APP}/invite/${winner.token}`);
  assertEquals(db.table("shop_invites").find((r) => r.id === winner.id)?.revoked_at, null);
  assertEquals(
    db.http.callsTo("POST", RESEND_URL)[0]?.headers.get("idempotency-key"),
    inviteEmailKey(String(winner.id), NOW),
  );
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

Deno.test("send_invite: an invite about to lapse is re-issued with a full 7 days, not re-sent", async () => {
  const old = invite({ email: "x@example.com", role: "manager", expires_at: EXPIRING_SOON });
  const { db, handler, logs } = setup({ invites: [old] });
  const out = await responseJson<InviteResponse>(
    await handler(sendInvite("tok-owner", { email: "x@example.com", role: "manager" })),
  );
  assert(out.invite.id !== old.id);
  assertEquals(out.invite.expires_at, "2026-10-04T15:00:00.000Z");
  const rows = db.table("shop_invites");
  assertEquals(rows.find((r) => r.id === old.id)?.revoked_at, NOW.toISOString());
  const fresh = rows.find((r) => r.id === out.invite.id);
  assertEquals(out.invite_url, `${APP}/invite/${fresh?.token}`);
  const email = db.http.callsTo("POST", RESEND_URL)[0]?.json as { text: string };
  assert(email.text.includes(`${APP}/invite/${fresh?.token}`));
  assert(!email.text.includes(String(old.token)));
  assertEquals(logs.events("invite_reused").length, 0);
});

Deno.test("send_invite: a race lost to an old pending invite is not reused", async () => {
  const { db, handler } = setup();
  db.onRpc("invite_member", (_args, ctx) => {
    ctx.db.seed("shop_invites", [
      invite({ email: "x@example.com", role: "manager", expires_at: EXPIRING_SOON }),
    ]);
    throw new FakeRpcError("23505", "x@example.com is already a member of this shop");
  });
  await expectError(
    await handler(sendInvite("tok-owner", { email: "x@example.com", role: "manager" })),
    409,
    "conflict",
  );
  assertEquals(db.http.callsTo("POST", RESEND_URL).length, 0);
});

Deno.test("resend_invite: an invite past the reuse window is re-issued; the old link is revoked", async () => {
  const old = invite({ role: "admin", expires_at: EXPIRING_SOON });
  const { db, handler } = setup({ invites: [old] });
  const out = await responseJson<InviteResponse>(
    await handler(resendInvite("tok-owner", String(old.id))),
  );
  assertEquals(out.reissued, true);
  assert(out.invite.id !== old.id);
  assertEquals([out.invite.role, out.invite.expires_at], ["admin", "2026-10-04T15:00:00.000Z"]);
  assertEquals(
    db.table("shop_invites").find((r) => r.id === old.id)?.revoked_at,
    NOW.toISOString(),
  );
  assertEquals(db.requests.filter((r) => r.target === "invite_member").length, 1);
});

Deno.test("isFreshInvite: only invites issued within the reuse window", () => {
  const issuedAt = (msAgo: number) => ({
    expires_at: new Date(NOW.getTime() - msAgo + INVITE_TTL_MS).toISOString(),
  });
  assertEquals(isFreshInvite(issuedAt(0), NOW), true);
  assertEquals(isFreshInvite(issuedAt(REUSE_WINDOW_MS), NOW), true);
  assertEquals(isFreshInvite(issuedAt(REUSE_WINDOW_MS + 1), NOW), false);
  assertEquals(isFreshInvite({ expires_at: EXPIRING_SOON }, NOW), false);
  assertEquals(isFreshInvite({ expires_at: "not a date" }, NOW), false);
});

Deno.test("formatPhone mirrors SQL format_phone", () => {
  assertEquals(formatPhone("+12055550101"), "(205) 555-0101");
  assertEquals(formatPhone("+442071234567"), "+442071234567");
  assertEquals(formatPhone(null), null);
});

// ---------------------------------------------------------------------------
// the platform's sending address is not an open relay
// ---------------------------------------------------------------------------

Deno.test("send_invite: a custom template without {{invite_link}} sends the default wording", async () => {
  const { db, handler } = setup({
    templates: [{
      shop_id: SHOP,
      key: "invite",
      channel: "email",
      subject: "Your account is locked",
      body: "Your account is suspended. Verify now at https://evil.example/login",
      enabled: true,
    }],
  });
  const out = await responseJson<InviteResponse>(
    await handler(sendInvite("tok-owner", { email: "victim@example.com", role: "technician" })),
  );
  const email = db.http.callsTo("POST", RESEND_URL)[0]?.json as Record<string, unknown>;
  assertEquals(email.subject, "You are invited to join Shine Auto Spa");
  assert(!String(email.text).includes("evil.example"));
  assert(String(email.text).includes(out.invite_url));
});

Deno.test("carriesInviteLink: the link placeholder, spaces allowed", () => {
  assertEquals(carriesInviteLink("Join: {{invite_link}}"), true);
  assertEquals(carriesInviteLink("Join: {{ invite_link }}"), true);
  assertEquals(carriesInviteLink("Join us at {{shop_name}}"), false);
  assertEquals(carriesInviteLink("invite_link"), false);
});

function recentInvites(count: number, overrides: Row = {}): Row[] {
  return Array.from({ length: count }, (_, i) =>
    invite({
      email: `person${i}@example.com`,
      // revoked / accepted rows count too: re-inviting does not reset the cap
      ...(i % 3 === 0 ? { revoked_at: NOW.toISOString() } : {}),
      created_at: new Date(NOW.getTime() - (23 * 60 - i) * 60_000).toISOString(),
      ...overrides,
    }));
}

Deno.test("send_invite: a shop that issued the day's invites is 429 rate_limited; nothing is created or emailed", async () => {
  const { db, handler } = setup({ invites: recentInvites(INVITES_PER_DAY) });
  const res = await handler(
    sendInvite("tok-owner", { email: "one-more@example.com", role: "technician" }),
  );
  const body = await expectError(res, 429, "rate_limited");
  assertEquals((body.details as Record<string, unknown>).reason, "invite_limit");
  // the oldest counted invite (23 h old) leaves the window in an hour
  assertEquals(res.headers.get("retry-after"), "3600");
  assertEquals(db.requests.filter((r) => r.target === "invite_member").length, 0);
  assertEquals(db.http.callsTo("POST", RESEND_URL).length, 0);
  assertEquals(db.table("shop_invites").length, INVITES_PER_DAY);
});

Deno.test("send_invite: invites older than 24 hours and other shops' invites do not count", async () => {
  const old = recentInvites(INVITES_PER_DAY, {
    created_at: new Date(NOW.getTime() - 25 * 60 * 60_000).toISOString(),
  });
  const elsewhere = recentInvites(INVITES_PER_DAY, { shop_id: OTHER_SHOP });
  const { handler } = setup({
    invites: [...old, ...elsewhere, ...recentInvites(INVITES_PER_DAY - 1)],
  });
  const res = await handler(
    sendInvite("tok-owner", { email: "last@example.com", role: "manager" }),
  );
  assertEquals(res.status, 200);
  assertEquals((await responseJson<InviteResponse>(res)).email_sent, true);
});

Deno.test("resend_invite: re-issuing a stale invite counts toward the daily cap", async () => {
  const stale = invite({
    email: "late@example.com",
    expires_at: EXPIRING_SOON,
    created_at: new Date(NOW.getTime() - 25 * 60 * 60_000).toISOString(),
  });
  const { db, handler } = setup({ invites: [stale, ...recentInvites(INVITES_PER_DAY)] });
  await expectError(
    await handler(resendInvite("tok-owner", String(stale.id))),
    429,
    "rate_limited",
  );
  assertEquals(db.http.callsTo("POST", RESEND_URL).length, 0);
});

Deno.test("resend_invite: repeated resends of a fresh invite share one email per interval", async () => {
  const pending = invite();
  const { db, handler } = setup({ invites: [pending] });
  for (let i = 0; i < 3; i++) {
    const res = await handler(resendInvite("tok-owner", String(pending.id)));
    assertEquals(res.status, 200);
    await res.body?.cancel();
  }
  const keys = db.http.callsTo("POST", RESEND_URL).map((c) => c.headers.get("idempotency-key"));
  assertEquals(new Set(keys).size, 1);
});

Deno.test("inviteEmailKey: one key per invite per INVITE_EMAIL_INTERVAL_MS", () => {
  const start = new Date(
    Math.floor(NOW.getTime() / INVITE_EMAIL_INTERVAL_MS) * INVITE_EMAIL_INTERVAL_MS,
  );
  const later = new Date(start.getTime() + INVITE_EMAIL_INTERVAL_MS - 1);
  const next = new Date(start.getTime() + INVITE_EMAIL_INTERVAL_MS);
  assertEquals(inviteEmailKey("i1", start), inviteEmailKey("i1", later));
  assert(inviteEmailKey("i1", start) !== inviteEmailKey("i1", next));
  assert(inviteEmailKey("i1", start) !== inviteEmailKey("i2", start));
});
