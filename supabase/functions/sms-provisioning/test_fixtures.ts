/** A FakeSupabase + fake Twilio (numbers, messaging, Trust Hub) for sms-provisioning tests. */
import { jsonResponse } from "../_shared/testing/fake_fetch.ts";
import { FakeRpcError, FakeSupabase, type Row } from "../_shared/testing/fake_supabase.ts";
import { type MemoryLogger, memoryLogger } from "../_shared/testing/logger.ts";
import { jsonRequest } from "../_shared/testing/requests.ts";
import { makeHandler } from "./index.ts";

export const SHOP = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
export const CA_SHOP = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
export const UK_SHOP = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";
export const OWNER = "10000000-0000-4000-8000-000000000001";
export const ADMIN = "10000000-0000-4000-8000-000000000002";
export const MANAGER = "10000000-0000-4000-8000-000000000003";
export const CRON_SECRET = "fake-cron-secret-0123456789abcdef";
export const API = "https://api.twilio.com/2010-04-01/Accounts/AC00000000000000000000000000000000";
export const MSG = "https://messaging.twilio.com/v1";
export const HUB = "https://trusthub.twilio.com/v1";
export const PRIMARY_PROFILE = `BU${"f".repeat(32)}`;

let counter = 0;
export function sid(prefix: string): string {
  counter += 1;
  return `${prefix}${counter.toString(16).padStart(32, "0")}`;
}

export interface FixtureOptions {
  env?: Record<string, string | undefined>;
  numbers?: Row[];
  /** Wall clock handed to the handler (edit windows). */
  now?: Date;
}

export interface Fixture {
  db: FakeSupabase;
  handler: (req: Request) => Promise<Response>;
  rpc: Record<string, Record<string, unknown>[]>;
  log: MemoryLogger;
  provisionedOf: (shopId: string) => Row | undefined;
}

export function fixture(options: FixtureOptions = {}): Fixture {
  const member = (id: string, userId: string, role: string, shopId = SHOP): Row => ({
    id,
    shop_id: shopId,
    user_id: userId,
    role,
    display_name: role,
    active: true,
  });
  const rpc: Record<string, Record<string, unknown>[]> = {
    record_sms_number: [],
    set_sms_verification: [],
    release_sms_number: [],
  };
  const db = new FakeSupabase({
    env: {
      SMS_PROVISIONING_ENABLED: "true",
      ...options.env,
    },
    users: {
      "tok-owner": { id: OWNER, email: "o@example.com" },
      "tok-admin": { id: ADMIN, email: "a@example.com" },
      "tok-manager": { id: MANAGER, email: "m@example.com" },
    },
    tables: {
      shop_members: [
        member("20000000-0000-4000-8000-000000000001", OWNER, "owner"),
        member("20000000-0000-4000-8000-000000000002", ADMIN, "admin"),
        member("20000000-0000-4000-8000-000000000003", MANAGER, "manager"),
        member("20000000-0000-4000-8000-000000000004", OWNER, "owner", CA_SHOP),
        member("20000000-0000-4000-8000-000000000005", OWNER, "owner", UK_SHOP),
      ],
      shops: [
        { id: SHOP, country: "US", sms_from_number: null },
        { id: CA_SHOP, country: "CA", sms_from_number: null },
        { id: UK_SHOP, country: "GB", sms_from_number: null },
      ],
      shop_sms_numbers: options.numbers ?? [],
    },
    tableOptions: { shop_sms_numbers: { primaryKey: ["phone_number"] } },
  });

  const numbersOf = (shopId: string) =>
    db.table("shop_sms_numbers").filter((n) => n.shop_id === shopId);
  const provisionedOf = (shopId: string) => numbersOf(shopId).find((n) => n.twilio_number_sid);

  db.onRpc("sms_provisioning_status", (args, ctx) => {
    if (ctx.role !== "service_role") throw new FakeRpcError("42501", "denied");
    const row = provisionedOf(String(args.p_shop_id)) ?? numbersOf(String(args.p_shop_id))[0];
    return {
      number: row?.phone_number ?? null,
      kind: row?.kind ?? null,
      verification_status: row?.verification_status ?? null,
      rejection_reason: row?.rejection_reason ?? null,
      provisioned: Boolean(row?.twilio_number_sid),
    };
  });
  db.onRpc("record_sms_number", (args, ctx) => {
    if (ctx.role !== "service_role") throw new FakeRpcError("42501", "denied");
    rpc.record_sms_number?.push(args);
    const shopId = String(args.p_shop_id);
    const phone = String(args.p_phone_e164);
    const other = provisionedOf(shopId);
    if (other && other.phone_number !== phone) {
      throw new FakeRpcError("23505", "this shop already has a provisioned number", {
        status: 409,
      });
    }
    const rows = db.table("shop_sms_numbers").filter((n) => n.phone_number !== phone);
    const current = db.table("shop_sms_numbers").find((n) => n.phone_number === phone);
    rows.push({
      phone_number: phone,
      shop_id: shopId,
      twilio_number_sid: args.p_number_sid,
      messaging_service_sid: args.p_messaging_service_sid ?? current?.messaging_service_sid ?? null,
      kind: args.p_kind,
      verification_status: current?.verification_status ?? "not_started",
      verification_sid: current?.verification_sid ?? null,
      rejection_reason: null,
      business_info: current?.business_info ?? {},
      last_checked_at: null,
    });
    db.seed("shop_sms_numbers", rows);
    db.seed(
      "shops",
      db.table("shops").map((s) => s.id === shopId ? { ...s, sms_from_number: phone } : s),
    );
    return rows.at(-1);
  });
  db.onRpc("set_sms_verification", (args, ctx) => {
    if (ctx.role !== "service_role") throw new FakeRpcError("42501", "denied");
    rpc.set_sms_verification?.push(structuredClone(args));
    const row = provisionedOf(String(args.p_shop_id));
    if (!row) throw new FakeRpcError("P0002", "this shop has no provisioned number");
    const next = {
      ...row,
      verification_status: args.p_status,
      verification_sid: args.p_verification_sid ?? row.verification_sid,
      rejection_reason: args.p_status === "rejected" ? args.p_rejection_reason ?? null : null,
      business_info: args.p_business_info ?? row.business_info,
      last_checked_at: "2026-09-27T00:00:00Z",
    };
    db.seed(
      "shop_sms_numbers",
      db.table("shop_sms_numbers").map((n) => n.phone_number === row.phone_number ? next : n),
    );
    return next;
  });
  db.onRpc("release_sms_number", (args, ctx) => {
    if (ctx.role !== "service_role") throw new FakeRpcError("42501", "denied");
    rpc.release_sms_number?.push(args);
    db.seed(
      "shop_sms_numbers",
      db.table("shop_sms_numbers").filter((n) =>
        !(n.shop_id === args.p_shop_id && n.twilio_number_sid)
      ),
    );
    return null;
  });

  const log = memoryLogger();
  const now = options.now;
  const handler = makeHandler({
    env: db.env(),
    fetch: db.http.fetch,
    logger: log.logger,
    ...(now ? { now: () => now } : {}),
  });
  return { db, handler, rpc, log, provisionedOf };
}

export const call = (action: string, body: Record<string, unknown>, token?: string): Request =>
  jsonRequest("sms-provisioning", { action, ...body }, {
    origin: "https://app.example.com",
    ...(token ? { token } : {}),
  });

export const cron = (secret: string = CRON_SECRET): Request =>
  jsonRequest("sms-provisioning", { action: "refresh_status" }, {
    headers: { "x-cron-secret": secret },
  });

/** Twilio-style resource answer. */
export const created = (body: Row, status = 201): Response => jsonResponse(body, status);

export const twilioError = (status: number, code: number, message: string): Response =>
  jsonResponse({ code, message, status }, status);
