/**
 * Server-side authorization for edge functions (SPEC §3 capability matrix).
 * Lookups use the service-role client and always filter by `active = true`
 * (inactive members have no role, matching SQL `shop_role_of`).
 */
import { timingSafeEqual } from "./crypto.ts";
import { errors, HttpError } from "./errors.ts";
import { isUuid } from "./ids.ts";
import { type Caller, getCaller, type SupabaseClient } from "./supabase.ts";

export const SHOP_ROLES = ["owner", "admin", "manager", "technician"] as const;
export type ShopRole = typeof SHOP_ROLES[number];

/** Role sets used across functions (mirror SQL is_shop_admin / is_shop_manager). */
export const ROLES = {
  anyStaff: SHOP_ROLES,
  managerPlus: ["owner", "admin", "manager"],
  adminPlus: ["owner", "admin"],
  owner: ["owner"],
} as const satisfies Record<string, readonly ShopRole[]>;

export interface Membership {
  /** shop_members.id (what job_assignments.member_id references). */
  id: string;
  shopId: string;
  userId: string;
  role: ShopRole;
  displayName: string;
}

/** Verified caller or `unauthorized`. Anonymous auth users are rejected. */
export async function requireUser(
  req: Request,
  options: { admin: SupabaseClient },
): Promise<Caller> {
  const caller = await getCaller(req, options);
  if (!caller || caller.isAnonymous) throw errors.unauthorized();
  return caller;
}

function dbFailure(what: string, cause: unknown): Error {
  return new Error(`${what} lookup failed`, { cause });
}

/** The caller's active membership in `shopId`, or null. */
export async function getMembership(
  admin: SupabaseClient,
  shopId: string,
  userId: string,
): Promise<Membership | null> {
  if (!isUuid(shopId) || !isUuid(userId)) return null;
  const { data, error } = await admin
    .from("shop_members")
    .select("id, shop_id, user_id, role, display_name")
    .eq("shop_id", shopId)
    .eq("user_id", userId)
    .eq("active", true)
    .maybeSingle();
  if (error) throw dbFailure("shop_members", error);
  if (!data) return null;
  const row = data as {
    id: string;
    shop_id: string;
    user_id: string;
    role: string;
    display_name: string;
  };
  if (!(SHOP_ROLES as readonly string[]).includes(row.role)) {
    throw new Error(`Unexpected shop role "${row.role}"`);
  }
  return {
    id: row.id,
    shopId: row.shop_id,
    userId: row.user_id,
    role: row.role as ShopRole,
    displayName: row.display_name,
  };
}

/**
 * Requires the caller to be an active member of `shopId` with one of
 * `roles`. Non-members get the same `forbidden` as a wrong role, so shop
 * existence is not revealed.
 */
export async function requireShopRole(
  admin: SupabaseClient,
  caller: Pick<Caller, "id">,
  shopId: string,
  roles: readonly ShopRole[],
): Promise<Membership> {
  if (!isUuid(shopId)) {
    throw new HttpError("validation_failed", "Some fields are missing or invalid.", {
      details: { issues: [{ path: "shop_id", message: "must be a UUID" }] },
    });
  }
  const membership = await getMembership(admin, shopId, caller.id);
  if (!membership) throw errors.forbidden("You do not have access to this shop.");
  if (!roles.includes(membership.role)) {
    throw errors.forbidden("Your role does not allow this action.");
  }
  return membership;
}

export function hasRole(membership: Pick<Membership, "role">, roles: readonly ShopRole[]): boolean {
  return roles.includes(membership.role);
}

/** Is `memberId` assigned to job `jobId` in `shopId`? */
export async function isAssignedToJob(
  admin: SupabaseClient,
  shopId: string,
  jobId: string,
  memberId: string,
): Promise<boolean> {
  if (!isUuid(shopId) || !isUuid(jobId) || !isUuid(memberId)) return false;
  const { data, error } = await admin
    .from("job_assignments")
    .select("id")
    .eq("shop_id", shopId)
    .eq("job_id", jobId)
    .eq("member_id", memberId)
    .limit(1);
  if (error) throw dbFailure("job_assignments", error);
  return Array.isArray(data) && data.length > 0;
}

/**
 * Job-level access: roles in `fullAccess` (default manager+) may act on any
 * job of the shop; everyone else must be assigned to it. Verifies the job
 * belongs to the membership's shop (`not_found` otherwise).
 */
export async function requireJobAccess(
  admin: SupabaseClient,
  membership: Membership,
  jobId: string,
  fullAccess: readonly ShopRole[] = ROLES.managerPlus,
): Promise<void> {
  if (!isUuid(jobId)) throw errors.notFound("Job not found.");
  const { data, error } = await admin
    .from("jobs")
    .select("id")
    .eq("shop_id", membership.shopId)
    .eq("id", jobId)
    .maybeSingle();
  if (error) throw dbFailure("jobs", error);
  if (!data) throw errors.notFound("Job not found.");
  if (hasRole(membership, fullAccess)) return;
  if (!(await isAssignedToJob(admin, membership.shopId, jobId, membership.id))) {
    throw errors.forbidden("You are not assigned to this job.");
  }
}

export const CRON_SECRET_HEADER = "x-cron-secret";

/** Guards cron/internal endpoints with a shared secret (constant-time compare). */
export function requireCronSecret(req: Request, expected: string): void {
  const provided = req.headers.get(CRON_SECRET_HEADER);
  if (!provided || !timingSafeEqual(provided, expected)) {
    throw new HttpError("unauthorized", "Invalid cron credentials.");
  }
}
