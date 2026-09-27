/**
 * invites — email staff invitations (SPEC §3 team management, §5).
 * verify_jwt = true at the gateway; every action also verifies the caller
 * and requires owner/admin of the invite's shop.
 *
 *   send_invite    { shop_id, email, role }  -> invite_member RPC as the
 *                  caller (RLS/role checks apply), then emails
 *                  APP_BASE_URL/invite/<token> via Resend
 *   resend_invite  { invite_id }             -> re-emails a pending invite
 *                  issued within REUSE_WINDOW_MS; an older (or expired) one
 *                  is re-issued (new token, a full 7 days)
 *
 * Every invite email says the link lasts 7 days, so an email only ever
 * carries a link with (almost) all of its INVITE_TTL_MS left: an invite is
 * reused only while it is "fresh" (issued within REUSE_WINDOW_MS, judged by
 * its expires_at), otherwise a new one is issued (invite_member revokes the
 * email's pending invite before inserting the new one).
 *
 * Retries and double submits never invalidate a link already emailed: when
 * a fresh pending invite for the same shop, email and role exists (an
 * earlier or concurrent identical request) it is reused and re-emailed with
 * the same link. A concurrent request that loses the race to insert (unique
 * pending-invite index, 23505) reuses the winner's invite. Every invite
 * email is keyed per invite and minute (inviteEmailKey), so a double submit
 * also sends one email. A different role, or an invite older than the
 * reuse window, issues a new link.
 *
 * The email uses the shop's `invite` email template when enabled (else the
 * default wording) and is sent from EMAIL_FROM relabelled with the shop
 * name, reply-to the shop email. A failed email does not undo the invite:
 * the response says `email_sent: false` and carries `invite_url` so the
 * admin can share the link another way or resend.
 */
import { z } from "zod";
import { createActionRouter, jsonAction } from "../_shared/actions.ts";
import { requireShopRole, requireUser, ROLES } from "../_shared/auth.ts";
import { fromWithDisplayName } from "../_shared/email.ts";
import type { Env } from "../_shared/env.ts";
import { errors, HttpError } from "../_shared/errors.ts";
import { PROVIDER_TIMEOUT_MS, withTimeout } from "../_shared/fetch_timeout.ts";
import { createHandler } from "../_shared/http.ts";
import { links } from "../_shared/links.ts";
import type { Logger } from "../_shared/log.ts";
import { sendEmail } from "../_shared/resend.ts";
import { email, uuid } from "../_shared/schemas.ts";
import { adminClient, type SupabaseClient, userClient } from "../_shared/supabase.ts";
import { renderTemplate, textToHtml } from "../_shared/templates.ts";

export interface Deps {
  env?: Env;
  fetch?: typeof fetch;
  logger?: Logger;
  now?: () => Date;
  /** Cap on the Resend request (default PROVIDER_TIMEOUT_MS); a stall reports email_sent: false. */
  providerTimeoutMs?: number;
}

/** Roles an invite may grant (ownership moves only via transfer_ownership). */
export const INVITE_ROLES = ["admin", "manager", "technician"] as const;
export type InviteRole = typeof INVITE_ROLES[number];

export const sendInviteInput = z.object({
  shop_id: uuid,
  email: z.string().trim().max(320).pipe(email),
  role: z.enum(INVITE_ROLES),
}).strict();

export const resendInviteInput = z.object({ invite_id: uuid }).strict();

/** Same wording as the SQL seed (0032 default_message_templates, key 'invite'). */
export const DEFAULT_INVITE_TEMPLATE = {
  subject: "You are invited to join {{shop_name}}",
  body: "Hello,\n\nYou have been invited to join the {{shop_name}} team.\n\n" +
    "Accept your invitation here: {{invite_link}}\n\n" +
    "This invitation expires in 7 days. If you were not expecting it, you can ignore this email.",
} as const;

interface InviteRow {
  id: string;
  shop_id: string;
  email: string;
  role: InviteRole;
  token: string;
  expires_at: string;
  accepted_at: string | null;
  revoked_at: string | null;
}

const INVITE_COLUMNS = "id, shop_id, email, role, token, expires_at, accepted_at, revoked_at";

export interface InviteResponse {
  invite: { id: string; shop_id: string; email: string; role: InviteRole; expires_at: string };
  invite_url: string;
  email_sent: boolean;
  /** resend_invite only: true when the invite was replaced by a new one (expired or not fresh). */
  reissued?: boolean;
}

function dbFailure(operation: string, cause: unknown): Error {
  return new Error(`${operation} failed`, { cause });
}

/** invite_member refusals -> stable codes (SQL text is only logged). */
function inviteRefusal(error: { code?: string | null }): Error {
  switch (error.code) {
    case "42501":
      return new HttpError("forbidden", "Only owners and admins can invite team members.", {
        cause: error,
      });
    case "23505":
      return new HttpError("conflict", "This person is already a member of the shop.", {
        cause: error,
      });
    case "22023":
    case "23514":
      return new HttpError("unprocessable", "This invite cannot be created.", { cause: error });
    default:
      return dbFailure("invite_member", error);
  }
}

/** NANP E.164 -> "(205) 555-0101" (same as SQL format_phone); others unchanged. */
export function formatPhone(e164: string | null): string | null {
  if (!e164) return null;
  const match = /^\+1([2-9]\d{2})([2-9]\d{2})(\d{4})$/.exec(e164);
  return match ? `(${match[1]}) ${match[2]}-${match[3]}` : e164;
}

interface ShopRow {
  id: string;
  name: string;
  email: string | null;
  phone: string | null;
}

async function loadShop(admin: SupabaseClient, shopId: string): Promise<ShopRow> {
  const { data, error } = await admin.from("shops").select("id, name, email, phone")
    .eq("id", shopId).single();
  if (error) throw dbFailure("shops lookup", error);
  return data as ShopRow;
}

async function inviteTemplate(
  admin: SupabaseClient,
  shopId: string,
): Promise<{ subject: string; body: string }> {
  const { data, error } = await admin.from("message_templates").select("subject, body, enabled")
    .eq("shop_id", shopId).eq("key", "invite").eq("channel", "email").maybeSingle();
  if (error) throw dbFailure("message_templates lookup", error);
  const row = data as { subject: string | null; body: string; enabled: boolean } | null;
  // Disabling the invite template cannot disable invites; use the default wording.
  if (!row?.enabled || !row.subject?.trim() || !row.body.trim()) return DEFAULT_INVITE_TEMPLATE;
  return { subject: row.subject, body: row.body };
}

export interface InviteEmail {
  from: string;
  to: string;
  subject: string;
  text: string;
  html: string;
  replyTo?: string;
}

export function buildInviteEmail(
  env: Env,
  shop: ShopRow,
  template: { subject: string; body: string },
  invite: Pick<InviteRow, "email">,
  inviteUrl: string,
): InviteEmail {
  const vars = {
    shop_name: shop.name,
    shop_phone: formatPhone(shop.phone),
    invite_link: inviteUrl,
  };
  const text = renderTemplate(template.body, vars).trim();
  const subject =
    renderTemplate(template.subject, vars).replace(/\s+/g, " ").trim().slice(0, 200) ||
    shop.name;
  return {
    from: fromWithDisplayName(env.resend().from, shop.name),
    to: invite.email,
    subject,
    text,
    html: textToHtml(text),
    replyTo: shop.email ?? undefined,
  };
}

/**
 * Resend idempotency key for an invite email: one per invite per minute, so a
 * double submit / retry sends one email while a deliberate resend a minute
 * later goes out again.
 */
export function inviteEmailKey(inviteId: string, at: Date): string {
  return `invite-${inviteId}-resend-${Math.floor(at.getTime() / 60_000)}`;
}

/** Invite lifetime: shop_invites.expires_at default (0002), and what the email promises. */
export const INVITE_TTL_MS = 7 * 24 * 60 * 60_000;

/**
 * How long after it was issued an invite is reused instead of re-issued:
 * covers retries and double submits, and keeps "expires in 7 days" true.
 */
export const REUSE_WINDOW_MS = 15 * 60_000;

/** Pending and issued within REUSE_WINDOW_MS (at least TTL - window left). */
export function isFreshInvite(invite: Pick<InviteRow, "expires_at">, at: Date): boolean {
  const left = Date.parse(invite.expires_at) - at.getTime();
  return Number.isFinite(left) && left >= INVITE_TTL_MS - REUSE_WINDOW_MS;
}

/** The shop's pending, unexpired invite for this (lower-cased) email, if any (service role). */
async function pendingInvite(
  admin: SupabaseClient,
  shopId: string,
  address: string,
  at: Date,
): Promise<InviteRow | null> {
  const { data, error } = await admin.from("shop_invites").select(INVITE_COLUMNS)
    .eq("shop_id", shopId).eq("email", address.trim().toLowerCase())
    .is("accepted_at", null).is("revoked_at", null)
    .gt("expires_at", at.toISOString())
    .order("created_at", { ascending: false }).limit(1);
  if (error) throw dbFailure("shop_invites lookup", error);
  return (Array.isArray(data) ? data[0] as InviteRow | undefined : undefined) ?? null;
}

export function makeHandler(deps: Deps = {}): (req: Request) => Promise<Response> {
  const now = deps.now ?? (() => new Date());

  async function emailInvite(
    env: Env,
    log: Logger,
    admin: SupabaseClient,
    invite: InviteRow,
    idempotencyKey: string,
  ): Promise<{ inviteUrl: string; sent: boolean }> {
    const inviteUrl = links.invite(env.appBaseUrl(), invite.token);
    const shop = await loadShop(admin, invite.shop_id);
    const template = await inviteTemplate(admin, invite.shop_id);
    try {
      const message = buildInviteEmail(env, shop, template, invite, inviteUrl);
      await sendEmail(
        env.resend().apiKey,
        {
          ...message,
          idempotencyKey,
          tags: [{ name: "invite_id", value: invite.id }, {
            name: "shop_id",
            value: invite.shop_id,
          }],
        },
        withTimeout(deps.fetch ?? globalThis.fetch, deps.providerTimeoutMs ?? PROVIDER_TIMEOUT_MS),
      );
      log.info("invite_emailed", { invite_id: invite.id, shop_id: invite.shop_id });
      return { inviteUrl, sent: true };
    } catch (err) {
      log.error("invite_email_failed", {
        invite_id: invite.id,
        shop_id: invite.shop_id,
        error: err,
      });
      return { inviteUrl, sent: false };
    }
  }

  async function createInvite(
    req: Request,
    env: Env,
    shopId: string,
    address: string,
    role: InviteRole,
  ): Promise<InviteRow> {
    // As the caller, so invite_member's own admin check (and RLS) applies.
    const user = userClient(req, { env, fetch: deps.fetch });
    const { data, error } = await user.rpc("invite_member", {
      p_shop_id: shopId,
      p_email: address,
      p_role: role,
    });
    if (error) throw inviteRefusal(error);
    const invite = data as InviteRow | null;
    if (!invite?.id || !invite.token) throw dbFailure("invite_member", "no row returned");
    return invite;
  }

  /**
   * The invite to email for (shop, email, role): the existing pending, fresh
   * (isFreshInvite) one with that role (reused: its link stays valid), else a
   * new one from invite_member (which revokes an older pending invite). A
   * concurrent identical request that inserted first makes invite_member
   * fail on the one-pending-invite index (23505, which also means "already a
   * member"); if a matching fresh pending invite now exists it is reused,
   * otherwise the conflict stands.
   */
  async function issueInvite(
    req: Request,
    env: Env,
    admin: SupabaseClient,
    shopId: string,
    address: string,
    role: InviteRole,
  ): Promise<{ invite: InviteRow; reused: boolean }> {
    const existing = await pendingInvite(admin, shopId, address, now());
    if (existing && existing.role === role && isFreshInvite(existing, now())) {
      return { invite: existing, reused: true };
    }
    try {
      return { invite: await createInvite(req, env, shopId, address, role), reused: false };
    } catch (err) {
      if (!(err instanceof HttpError) || err.code !== "conflict") throw err;
      const winner = await pendingInvite(admin, shopId, address, now());
      if (!winner || !isFreshInvite(winner, now())) throw err;
      if (winner.role !== role) {
        throw errors.conflict(
          "This person was just invited with another role. Refresh and try again.",
        );
      }
      return { invite: winner, reused: true };
    }
  }

  const respond = (
    invite: InviteRow,
    result: { inviteUrl: string; sent: boolean },
    reissued?: boolean,
  ): InviteResponse => ({
    invite: {
      id: invite.id,
      shop_id: invite.shop_id,
      email: invite.email,
      role: invite.role,
      expires_at: invite.expires_at,
    },
    invite_url: result.inviteUrl,
    email_sent: result.sent,
    ...(reissued === undefined ? {} : { reissued }),
  });

  const router = createActionRouter({
    send_invite: jsonAction(sendInviteInput, async (input, ctx): Promise<InviteResponse> => {
      const admin = adminClient({ env: deps.env, fetch: deps.fetch });
      const caller = await requireUser(ctx.req, { admin });
      await requireShopRole(admin, caller, input.shop_id, ROLES.adminPlus);
      ctx.env.appBaseUrl(); // fail fast (server_misconfigured) before creating the invite
      const { invite, reused } = await issueInvite(
        ctx.req,
        ctx.env,
        admin,
        input.shop_id,
        input.email,
        input.role,
      );
      if (reused) ctx.log.info("invite_reused", { invite_id: invite.id, shop_id: invite.shop_id });
      const result = await emailInvite(
        ctx.env,
        ctx.log,
        admin,
        invite,
        inviteEmailKey(invite.id, now()),
      );
      return respond(invite, result);
    }),

    resend_invite: jsonAction(resendInviteInput, async (input, ctx): Promise<InviteResponse> => {
      const admin = adminClient({ env: deps.env, fetch: deps.fetch });
      const caller = await requireUser(ctx.req, { admin });
      const { data, error } = await admin.from("shop_invites").select(INVITE_COLUMNS)
        .eq("id", input.invite_id).maybeSingle();
      if (error) throw dbFailure("shop_invites lookup", error);
      if (!data) throw errors.notFound("Invite not found.");
      const invite = data as InviteRow;
      await requireShopRole(admin, caller, invite.shop_id, ROLES.adminPlus);
      if (invite.accepted_at) throw errors.conflict("This invite was already accepted.");
      if (invite.revoked_at) throw errors.gone("This invite was revoked.");

      if (!isFreshInvite(invite, now())) {
        // Expired, or issued too long ago for the email's "expires in 7
        // days" to hold: issue a fresh invite (invite_member revokes the old
        // one), or reuse the one a concurrent resend of this invite just
        // issued.
        const { invite: fresh } = await issueInvite(
          ctx.req,
          ctx.env,
          admin,
          invite.shop_id,
          invite.email,
          invite.role,
        );
        const result = await emailInvite(
          ctx.env,
          ctx.log,
          admin,
          fresh,
          inviteEmailKey(fresh.id, now()),
        );
        return respond(fresh, result, true);
      }
      // Same link again; the per-minute key absorbs double clicks and retries.
      const result = await emailInvite(
        ctx.env,
        ctx.log,
        admin,
        invite,
        inviteEmailKey(invite.id, now()),
      );
      return respond(invite, result, false);
    }),
  });

  return createHandler(
    { name: "invites", env: deps.env, logger: deps.logger },
    (req, ctx) => router(req, ctx),
  );
}

if (import.meta.main) Deno.serve(makeHandler());
