/**
 * account — the signed-in user's own account (App Store guideline 5.1.1(v):
 * an app that lets people create an account must let them delete it).
 * verify_jwt = true at the gateway; the action verifies the caller again.
 *
 *   delete_account  {}  -> account_deletion_blockers() AS THE CALLER (the
 *                   RPC is granted to authenticated only and reads
 *                   auth.uid()); a caller who still owns a shop gets
 *                   409 conflict reason `owns_shops` with the shops, since
 *                   a shop cannot be left without an owner (transfer
 *                   ownership or delete the shop first). Otherwise the auth
 *                   user is deleted with the Auth admin API (service role).
 *
 * Every role can delete their account, clients of the portal included. What
 * the user leaves behind is handled by the database cascades on auth.users:
 * shop memberships and the profile go, customers' portal links are cleared,
 * and audit columns (created_by, sent_by...) are nulled. Business records a
 * shop owns (customers, jobs, payments) are never deleted with a person's
 * account.
 */
import { z } from "zod";
import { createActionRouter, jsonAction } from "../_shared/actions.ts";
import { requireUser } from "../_shared/auth.ts";
import type { Env } from "../_shared/env.ts";
import { HttpError } from "../_shared/errors.ts";
import { createHandler } from "../_shared/http.ts";
import type { Logger } from "../_shared/log.ts";
import { adminClient, type SupabaseClient, userClient } from "../_shared/supabase.ts";

export interface Deps {
  env?: Env;
  /** Tests inject FakeSupabase's FakeFetch (PostgREST + Auth on one fetch). */
  fetch?: typeof fetch;
  logger?: Logger;
}

export const deleteAccountInput = z.object({}).strict();

export interface OwnedShop {
  shop_id: string;
  name: string;
}

export interface DeleteAccountResponse {
  deleted: true;
}

export const OWNS_SHOPS_MESSAGE = "Transfer ownership or delete these shops first.";

/** The shops the caller owns (account_deletion_blockers, 0092), as the caller. */
async function ownedShops(user: SupabaseClient): Promise<OwnedShop[]> {
  const { data, error } = await user.rpc("account_deletion_blockers");
  if (error) {
    if (error.code === "42501") {
      throw new HttpError("unauthorized", "Sign in to continue.", { cause: error });
    }
    throw new Error("account_deletion_blockers failed", { cause: error });
  }
  const shops = (data as { owned_shops?: unknown } | null)?.owned_shops;
  if (!Array.isArray(shops)) {
    throw new Error("account_deletion_blockers returned no owned_shops list");
  }
  return shops.map((shop) => {
    const row = shop as { shop_id?: unknown; name?: unknown };
    if (typeof row.shop_id !== "string" || typeof row.name !== "string") {
      throw new Error("account_deletion_blockers returned a malformed shop");
    }
    return { shop_id: row.shop_id, name: row.name };
  });
}

function ownsShops(shops: OwnedShop[], cause?: unknown): HttpError {
  return new HttpError("conflict", OWNS_SHOPS_MESSAGE, {
    details: { reason: "owns_shops", shops },
    cause,
  });
}

interface AuthAdminError {
  status?: number;
  name?: string;
  code?: string;
  message?: string;
}

/** A GoTrue error that carries the ownership guard's SQLSTATE (23514). */
function isOwnershipGuard(error: AuthAdminError): boolean {
  return [error.code, error.message].some((text) => typeof text === "string" && /23514/.test(text));
}

async function deleteAccount(
  deps: Deps,
  ctx: { req: Request; env: Env; log: Logger },
): Promise<DeleteAccountResponse> {
  const admin = adminClient({ env: deps.env, fetch: deps.fetch });
  const caller = await requireUser(ctx.req, { admin });
  const user = userClient(ctx.req, { env: deps.env, fetch: deps.fetch });

  const shops = await ownedShops(user);
  if (shops.length > 0) throw ownsShops(shops);

  const { error } = await admin.auth.admin.deleteUser(caller.id);
  if (error) {
    const authError = error as AuthAdminError;
    if (authError.status === 404) {
      // Deleted meanwhile (another device): the outcome the caller wanted.
      ctx.log.info("account_already_deleted", { user_id: caller.id });
      return { deleted: true };
    }
    // A shop became owned between the check and the delete (the database
    // refuses to delete a shop's owner): answer as the check would have.
    if (isOwnershipGuard(authError)) throw ownsShops(await ownedShops(user), error);
    const now = await ownedShops(user).catch(() => []);
    if (now.length > 0) throw ownsShops(now, error);
    if (
      authError.name === "AuthRetryableFetchError" ||
      (typeof authError.status === "number" && (authError.status === 429 || authError.status === 0))
    ) {
      throw new HttpError("service_unavailable", "Account deletion is unavailable. Try again.", {
        cause: error,
      });
    }
    throw new Error("auth admin deleteUser failed", { cause: error });
  }
  ctx.log.info("account_deleted", { user_id: caller.id });
  return { deleted: true };
}

export function makeHandler(deps: Deps = {}): (req: Request) => Promise<Response> {
  const router = createActionRouter({
    delete_account: jsonAction(deleteAccountInput, (_input, ctx) => deleteAccount(deps, ctx)),
  });
  return createHandler(
    { name: "account", env: deps.env, logger: deps.logger },
    (req, ctx) => router(req, ctx),
  );
}

if (import.meta.main) Deno.serve(makeHandler());
