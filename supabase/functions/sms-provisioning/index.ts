/**
 * sms-provisioning — self-serve text-messaging numbers (P-14; state in
 * shop_sms_numbers, RPCs in migration 0089). Ships dark: every search /
 * purchase / verification action answers 422 reason `provisioning_disabled`
 * until the platform sets SMS_PROVISIONING_ENABLED=true (its Twilio account
 * must be able to buy numbers and submit toll-free verifications); 10DLC
 * registration additionally needs TWILIO_ISV_ENABLED=true (an approved
 * Twilio ISV) and TWILIO_PRIMARY_CUSTOMER_PROFILE_SID. Until then support
 * binds numbers by hand (supabase/setup/twilio.md).
 *
 * verify_jwt = false: staff actions verify the JWT and role here; the
 * status refresh is pg_cron (x-cron-secret).
 *
 *   status                        {shop_id}                          owner/admin
 *   search_numbers                {shop_id, kind, area_code?, contains?}   owner/admin
 *   purchase_number               {shop_id, phone_e164, request_nonce}     owner/admin
 *   submit_tollfree_verification  {shop_id, business}                owner/admin
 *   submit_10dlc                  {shop_id, business, campaign}      owner/admin
 *   release_number                {shop_id}                          owner
 *   refresh_status                {}                                 pg_cron
 *   release_worklist              {}                                 pg_cron / operator
 *
 * The platform pays Twilio for every number bought here, so buying one
 * (purchase_number) and registering 10DLC (submit_10dlc, carrier fees) need a
 * shop in good standing (shop_billing_standing, 0101): subscribed or comped
 * while billing is on (a lapsed shop gets 402 payment_required, a trialing or
 * past-due one 422 subscription_required; billing off: any shop). A shop that
 * gave back MAX_RECENT_RELEASES numbers in the last RELEASE_WINDOW_DAYS days
 * (sms_number_releases, 0093) cannot buy another until the oldest of them is
 * that old (429 number_churn_limit), so buy / release cannot loop.
 *
 * release_worklist works through sms_number_releases (numbers unbound from
 * their shop: a release, a deleted shop, support moving a number). It asks
 * Twilio whether the platform still rents each one: a number bought here for
 * a shop that no longer exists is released; one no longer on the account (or
 * bound to a shop again) is done, and its entry is removed once its shop is
 * gone or it is older than the release window; everything else is still
 * rented and unbound and is returned as `pending` for the operator
 * (supabase/setup/twilio.md) and logged as sms_numbers_awaiting_release.
 *
 * A number bought here gets the platform's inbound webhook
 * (messaging?action=twilio_inbound&shop_id=<shop>) - the binding the
 * messaging function checks before sending - and its own Messaging Service
 * (one per shop, so STOP stays per shop), and becomes the shop's sending
 * number (record_sms_number). Outbound texts then go through that service.
 */
import { z } from "zod";
import { createActionRouter, jsonAction } from "../_shared/actions.ts";
import { requireCronSecret, requireShopRole, requireUser, ROLES } from "../_shared/auth.ts";
import { sha256Hex } from "../_shared/crypto.ts";
import type { Env } from "../_shared/env.ts";
import { HttpError, SUBSCRIPTION_INACTIVE_MESSAGE } from "../_shared/errors.ts";
import { createHandler } from "../_shared/http.ts";
import type { Logger } from "../_shared/log.ts";
import { e164, email, requestNonce, uuid } from "../_shared/schemas.ts";
import { adminClient, type SupabaseClient } from "../_shared/supabase.ts";
import { TwilioError } from "../_shared/twilio.ts";
import { twilioInboundUrl, twilioStatusUrl } from "../_shared/twilio_urls.ts";
import {
  a2pBusinessSchema,
  a2pCampaignSchema,
  type A2pInfo,
  type A2pProgress,
  ProfileNotCompliant,
  refreshA2p,
  registerA2p,
} from "./a2p.ts";
import {
  type FormValue,
  type Json,
  MESSAGING_API,
  releasePlatformNumber,
  str,
  type TwilioClient,
  twilioClient,
} from "../_shared/twilio_api.ts";

export interface Deps {
  env?: Env;
  fetch?: typeof fetch;
  logger?: Logger;
  /** Wall clock (tests): decides whether a rejected verification's edit window is open. */
  now?: () => Date;
}

export type NumberKind = "tollfree" | "local";
export type VerificationStatus = "not_started" | "pending" | "in_review" | "approved" | "rejected";

/** NANP toll-free area codes (US and Canada). */
const TOLL_FREE_AREA_CODES = new Set(["800", "833", "844", "855", "866", "877", "888"]);
const SUPPORTED_COUNTRIES = new Set(["US", "CA"]);
const REFRESH_BATCH = 50;

/** Standing (0101 billing_state) in which a shop may buy numbers and register 10DLC. */
const PAID_STATES = new Set(["active", "comped"]);
/** A shop may give back at most this many numbers per window before buying again. */
export const MAX_RECENT_RELEASES = 2;
export const RELEASE_WINDOW_DAYS = 30;
const DAY_MS = 24 * 60 * 60 * 1000;
/** sms_number_releases entries release_worklist looks at per run (oldest first). */
export const WORKLIST_BATCH = 200;

// ---------------------------------------------------------------------------
// Inputs
// ---------------------------------------------------------------------------

const text = (min: number, max: number) => z.string().trim().min(min).max(max);
const nanp = e164.regex(/^\+1[2-9]\d{2}[2-9]\d{6}$/, "must be a US or Canadian number");

export const shopInput = z.object({ shop_id: uuid }).strict();

export const searchInput = z.object({
  shop_id: uuid,
  kind: z.enum(["tollfree", "local"]),
  area_code: z.string().regex(/^[2-9]\d{2}$/, "must be a 3-digit area code").optional(),
  contains: z.string().regex(/^[0-9A-Za-z*]{1,10}$/, "digits or letters, at most 10").optional(),
}).strict();

export const purchaseInput = z.object({
  shop_id: uuid,
  phone_e164: nanp,
  request_nonce: requestNonce,
}).strict();

export const TOLLFREE_USE_CASES = [
  "TWO_FACTOR_AUTHENTICATION",
  "ACCOUNT_NOTIFICATIONS",
  "CUSTOMER_CARE",
  "CHARITY_NONPROFIT",
  "DELIVERY_NOTIFICATIONS",
  "FRAUD_ALERT_MESSAGING",
  "EVENTS",
  "HIGHER_EDUCATION",
  "K12",
  "MARKETING",
  "POLLING_AND_VOTING_NON_POLITICAL",
  "POLITICAL_ELECTION_CAMPAIGNS",
  "PUBLIC_SERVICE_ANNOUNCEMENT",
  "SECURITY_ALERT",
] as const;

export const MONTHLY_VOLUMES = [
  "10",
  "100",
  "1,000",
  "10,000",
  "100,000",
  "250,000",
  "500,000",
  "750,000",
  "1,000,000",
  "5,000,000",
  "10,000,000+",
] as const;

export const tollfreeBusinessSchema = z.object({
  legal_name: text(1, 200),
  website: z.url({ protocol: /^https?$/ }).max(500),
  address_line1: text(1, 200),
  address_line2: text(1, 200).optional(),
  city: text(1, 100),
  region: text(2, 50),
  postal_code: text(3, 12),
  country: z.enum(["US", "CA"]),
  contact_first_name: text(1, 100),
  contact_last_name: text(1, 100),
  contact_email: email,
  contact_phone: e164,
  /** Where Twilio sends verification updates (default: contact_email). */
  notification_email: email.optional(),
  use_case_categories: z.array(z.enum(TOLLFREE_USE_CASES)).min(1).max(5),
  use_case_summary: text(20, 1000),
  production_message_sample: text(20, 1000),
  opt_in_type: z.enum(["VERBAL", "WEB_FORM", "PAPER_FORM", "VIA_TEXT", "MOBILE_QR_CODE"]),
  opt_in_image_urls: z.array(z.url({ protocol: /^https?$/ }).max(500)).min(1).max(5),
  estimated_monthly_volume: z.enum(MONTHLY_VOLUMES),
  additional_information: text(1, 1000).optional(),
}).strict();

export const tollfreeInput = z.object({
  shop_id: uuid,
  business: tollfreeBusinessSchema,
  /**
   * Resubmitting after a rejection: what was fixed (Twilio's EditReason,
   * e.g. "Website fixed"). Used only when Twilio lets the rejected
   * verification be edited; a default is sent otherwise.
   */
  edit_reason: text(1, 500).optional(),
}).strict();
export const a2pInput = z.object({
  shop_id: uuid,
  business: a2pBusinessSchema,
  campaign: a2pCampaignSchema,
}).strict();
export const refreshInput = z.object({}).strict();
export const worklistInput = z.object({}).strict();

// ---------------------------------------------------------------------------
// Database helpers
// ---------------------------------------------------------------------------

/** The provisioned row of shop_sms_numbers (service role). */
export interface ProvisionedNumber {
  shop_id: string;
  phone_number: string;
  twilio_number_sid: string;
  messaging_service_sid: string | null;
  kind: NumberKind | null;
  verification_status: VerificationStatus;
  verification_sid: string | null;
  rejection_reason: string | null;
  business_info: Record<string, unknown> | null;
}

const NUMBER_COLUMNS =
  "shop_id, phone_number, twilio_number_sid, messaging_service_sid, kind, verification_status, " +
  "verification_sid, rejection_reason, business_info";

interface DbError {
  message?: string;
  code?: string;
}

function dbFailure(what: string, error: DbError): Error {
  return new Error(`${what} failed: ${error.code ?? ""} ${error.message ?? ""}`.trim(), {
    cause: error,
  });
}

async function provisioned(
  admin: SupabaseClient,
  shopId: string,
): Promise<ProvisionedNumber | null> {
  const { data, error } = await admin.from("shop_sms_numbers").select(NUMBER_COLUMNS)
    .eq("shop_id", shopId).not("twilio_number_sid", "is", null).limit(1);
  if (error) throw dbFailure("shop_sms_numbers", error);
  return ((data ?? []) as unknown as ProvisionedNumber[])[0] ?? null;
}

async function numberStatus(admin: SupabaseClient, shopId: string): Promise<Json> {
  const { data, error } = await admin.rpc("sms_provisioning_status", { p_shop_id: shopId });
  if (error) throw dbFailure("sms_provisioning_status", error);
  return (data ?? {}) as Json;
}

async function recordNumber(
  admin: SupabaseClient,
  shopId: string,
  phone: string,
  numberSid: string,
  serviceSid: string | null,
  kind: NumberKind,
): Promise<void> {
  const { error } = await admin.rpc("record_sms_number", {
    p_shop_id: shopId,
    p_phone_e164: phone,
    p_number_sid: numberSid,
    p_messaging_service_sid: serviceSid,
    p_kind: kind,
  });
  if (!error) return;
  if (error.code === "23505") {
    throw new HttpError("conflict", "This shop already has a text messaging number.", {
      details: { reason: "already_has_number" },
      cause: error,
    });
  }
  throw dbFailure("record_sms_number", error);
}

async function saveVerification(
  admin: SupabaseClient,
  shopId: string,
  status: VerificationStatus,
  sid: string | null,
  reason: string | null,
  businessInfo: Record<string, unknown> | null,
): Promise<void> {
  const { error } = await admin.rpc("set_sms_verification", {
    p_shop_id: shopId,
    p_status: status,
    p_verification_sid: sid,
    p_rejection_reason: reason,
    p_business_info: businessInfo,
  });
  if (error) throw dbFailure("set_sms_verification", error);
}

async function shopCountry(admin: SupabaseClient, shopId: string): Promise<string> {
  const { data, error } = await admin.from("shops").select("country").eq("id", shopId)
    .maybeSingle();
  if (error) throw dbFailure("shops", error);
  const country = (data as { country?: string } | null)?.country ?? "";
  if (!SUPPORTED_COUNTRIES.has(country)) {
    throw new HttpError(
      "unprocessable",
      "Self-serve text numbers are available for shops in the United States and Canada.",
      { details: { reason: "unsupported_country" } },
    );
  }
  return country;
}

// ---------------------------------------------------------------------------
// Rules
// ---------------------------------------------------------------------------

function requireEnabled(env: Env): void {
  if (!env.smsProvisioningEnabled()) {
    throw new HttpError(
      "unprocessable",
      "Self-serve text numbers are not available yet. Contact support to connect a number.",
      { details: { reason: "provisioning_disabled" } },
    );
  }
}

/**
 * The platform pays for what comes next (a number's rent, 10DLC fees): only a
 * shop in good standing may start it. Billing off: shop_billing_standing
 * reads `active` for every shop.
 */
async function requirePaidStanding(admin: SupabaseClient, shopId: string): Promise<void> {
  const { data, error } = await admin.rpc("shop_billing_standing", { p_shop_id: shopId });
  if (error) throw dbFailure("shop_billing_standing", error);
  const row = (Array.isArray(data) ? data[0] : data) as { state?: unknown } | null;
  const state = typeof row?.state === "string" ? row.state : "lapsed";
  if (PAID_STATES.has(state)) return;
  if (state === "lapsed") {
    throw new HttpError("payment_required", SUBSCRIPTION_INACTIVE_MESSAGE, {
      details: { reason: "subscription_inactive" },
    });
  }
  throw new HttpError(
    "unprocessable",
    state === "past_due"
      ? "The shop's last subscription payment did not go through. Update the payment method in Settings > Billing, then try again."
      : "Self-serve text numbers are available once the shop's subscription is paid. Contact support to connect a number during the trial.",
    { details: { reason: "subscription_required", state } },
  );
}

/**
 * Buy / release / buy again must not loop: each purchase is a number the
 * platform pays for. At most MAX_RECENT_RELEASES give-backs (logged in
 * sms_number_releases by 0093) within RELEASE_WINDOW_DAYS days.
 */
async function requireNoRecentChurn(
  admin: SupabaseClient,
  shopId: string,
  now: Date,
): Promise<void> {
  const since = new Date(now.getTime() - RELEASE_WINDOW_DAYS * DAY_MS).toISOString();
  const { data, error } = await admin.from("sms_number_releases").select("released_at")
    .eq("shop_id", shopId).gte("released_at", since)
    .order("released_at", { ascending: true }).limit(MAX_RECENT_RELEASES);
  if (error) throw dbFailure("sms_number_releases", error);
  const recent = (data ?? []) as { released_at: string }[];
  if (recent.length < MAX_RECENT_RELEASES) return;
  const oldest = Date.parse(recent[0]?.released_at ?? "");
  const retryAt = Number.isNaN(oldest)
    ? null
    : new Date(oldest + RELEASE_WINDOW_DAYS * DAY_MS).toISOString();
  throw new HttpError(
    "rate_limited",
    `This shop gave back ${MAX_RECENT_RELEASES} text numbers in the last ${RELEASE_WINDOW_DAYS} days. ` +
      "Contact support to get another number sooner.",
    { details: { reason: "number_churn_limit", retry_at: retryAt } },
  );
}

export function numberKind(phone: string): NumberKind {
  return TOLL_FREE_AREA_CODES.has(phone.slice(2, 5)) ? "tollfree" : "local";
}

function requireNumber(row: ProvisionedNumber | null): ProvisionedNumber {
  if (!row) {
    throw new HttpError("unprocessable", "Get a text messaging number first.", {
      details: { reason: "no_number" },
    });
  }
  return row;
}

function requireResubmittable(row: ProvisionedNumber): void {
  if (row.verification_status === "approved") {
    throw new HttpError("conflict", "This number is already approved for texting.", {
      details: { reason: "already_approved" },
    });
  }
  if (row.verification_status === "pending" || row.verification_status === "in_review") {
    throw new HttpError("conflict", "A verification for this number is already under review.", {
      details: { reason: "verification_in_progress" },
    });
  }
}

/**
 * Runs Twilio calls made with the admin's details and turns Twilio's 4xx
 * answers about those details (an invalid website or postal code, an
 * unreachable opt-in image, an address Twilio cannot validate, a bad EIN)
 * into 422 `twilio_rejected_details` with Twilio's own message and code:
 * retrying cannot fix them, the admin has to correct the form. 401/403
 * (platform credentials), 404 (a stale sid) and 429 stay upstream errors
 * (502 "try again"), as do 5xx and network failures.
 */
export async function withTwilioValidation<T>(work: () => Promise<T>): Promise<T> {
  try {
    return await work();
  } catch (err) {
    if (err instanceof TwilioError && isDetailsError(err)) {
      const message = err.message.length > 300 ? `${err.message.slice(0, 297)}...` : err.message;
      throw new HttpError(
        "unprocessable",
        `Twilio did not accept these details: ${message}. Correct them and submit again.`,
        {
          details: {
            reason: "twilio_rejected_details",
            twilio_code: err.providerCode,
            twilio_message: message,
          },
          cause: err,
        },
      );
    }
    throw err;
  }
}

function isDetailsError(err: TwilioError): boolean {
  const status = err.httpStatus;
  return status !== null && status >= 400 && status < 500 &&
    ![401, 403, 404, 429].includes(status);
}

/** Twilio toll-free verification status -> ours. */
export function tollfreeStatus(twilio: string | null): VerificationStatus {
  switch (twilio) {
    case "TWILIO_APPROVED":
      return "approved";
    case "TWILIO_REJECTED":
      return "rejected";
    case "IN_REVIEW":
      return "in_review";
    default:
      return "pending";
  }
}

// ---------------------------------------------------------------------------
// Actions
// ---------------------------------------------------------------------------

interface StaffContext {
  admin: SupabaseClient;
  env: Env;
  log: Logger;
}

async function staff(
  deps: Deps,
  ctx: { req: Request; env: Env; log: Logger },
  shopId: string,
  roles: readonly ("owner" | "admin" | "manager" | "technician")[] = ROLES.adminPlus,
): Promise<StaffContext> {
  const admin = adminClient({ env: deps.env, fetch: deps.fetch });
  const caller = await requireUser(ctx.req, { admin });
  await requireShopRole(admin, caller, shopId, roles);
  return { admin, env: ctx.env, log: ctx.log };
}

function client(deps: Deps, env: Env): TwilioClient {
  return twilioClient(env.twilio(), deps.fetch ?? fetch);
}

async function statusResponse(s: StaffContext, shopId: string): Promise<Json> {
  return {
    enabled: s.env.smsProvisioningEnabled(),
    isv_enabled: s.env.twilioIsvEnabled(),
    number: await numberStatus(s.admin, shopId),
  };
}

async function searchNumbers(
  deps: Deps,
  s: StaffContext,
  input: z.output<typeof searchInput>,
): Promise<Json> {
  const country = await shopCountry(s.admin, input.shop_id);
  const twilio = client(deps, s.env);
  const params = new URLSearchParams({ SmsEnabled: "true", PageSize: "20" });
  if (input.area_code) params.set("AreaCode", input.area_code);
  if (input.contains) params.set("Contains", input.contains);
  const path = `AvailablePhoneNumbers/${country}/${
    input.kind === "tollfree" ? "TollFree" : "Local"
  }.json`;
  const result = await withTwilioValidation(() =>
    twilio.request("GET", `${twilio.account(path)}?${params}`)
  );
  const list = Array.isArray(result.available_phone_numbers)
    ? result.available_phone_numbers as Json[]
    : [];
  return {
    numbers: list.slice(0, 20).flatMap((n) => {
      const phone = str(n.phone_number);
      if (!phone || !/^\+1\d{10}$/.test(phone)) return [];
      return [{ phone_e164: phone, locality: str(n.locality), region: str(n.region) }];
    }),
  };
}

async function purchaseNumber(
  deps: Deps,
  s: StaffContext,
  input: z.output<typeof purchaseInput>,
): Promise<Json> {
  const existing = await provisioned(s.admin, input.shop_id);
  if (existing && existing.phone_number !== input.phone_e164) {
    throw new HttpError("conflict", "This shop already has a text messaging number.", {
      details: { reason: "already_has_number" },
    });
  }
  const country = await shopCountry(s.admin, input.shop_id);
  const twilio = client(deps, s.env);
  const functionsUrl = s.env.functionsPublicUrl();
  const inboundUrl = twilioInboundUrl(functionsUrl, input.shop_id);
  const kind = numberKind(input.phone_e164);
  let numberSid = existing?.twilio_number_sid ?? null;

  if (!existing) {
    // A new number is rented by the platform: only for a shop that pays.
    await requirePaidStanding(s.admin, input.shop_id);
    // Idempotent on the nonce: a retry finds the number it already bought.
    const friendlyName = `dcrm-${input.shop_id}-${
      (await sha256Hex(input.request_nonce)).slice(0, 16)
    }`;
    const found = await twilio.request(
      "GET",
      `${twilio.account("IncomingPhoneNumbers.json")}?${new URLSearchParams({
        FriendlyName: friendlyName,
        PageSize: "20",
      })}`,
    );
    const owned =
      (Array.isArray(found.incoming_phone_numbers) ? found.incoming_phone_numbers as Json[] : [])
        .find((n) => str(n.phone_number) === input.phone_e164);
    if (owned) {
      numberSid = str(owned.sid);
    } else {
      await requireNoRecentChurn(s.admin, input.shop_id, deps.now?.() ?? new Date());
      try {
        const bought = await twilio.request("POST", twilio.account("IncomingPhoneNumbers.json"), {
          PhoneNumber: input.phone_e164,
          FriendlyName: friendlyName,
          SmsUrl: inboundUrl,
          SmsMethod: "POST",
        });
        numberSid = str(bought.sid);
      } catch (err) {
        if (
          err instanceof TwilioError && ["21421", "21422", "21452"].includes(err.providerCode ?? "")
        ) {
          throw new HttpError(
            "conflict",
            "That number is no longer available. Search again and pick another one.",
            { details: { reason: "number_unavailable" }, cause: err },
          );
        }
        throw err;
      }
    }
    if (!numberSid) throw new Error("Twilio returned no phone number sid");
    s.log.info("sms_number_bought", { shop_id: input.shop_id, country, kind });
    try {
      await recordNumber(s.admin, input.shop_id, input.phone_e164, numberSid, null, kind);
    } catch (err) {
      // Bought but cannot be bound to this shop (a concurrent purchase won):
      // give the number back instead of paying for an orphan.
      if (err instanceof HttpError && err.status === 409) {
        await twilio.requestOrNull(
          "DELETE",
          twilio.account(`IncomingPhoneNumbers/${numberSid}.json`),
        )
          .catch((cause) =>
            s.log.error("sms_number_release_failed", { shop_id: input.shop_id, error: cause })
          );
      }
      throw err;
    }
  }

  if (!existing?.messaging_service_sid) {
    // One Messaging Service per shop: STOP and compliance stay per shop.
    const service = await twilio.request("POST", `${MESSAGING_API}/Services`, {
      FriendlyName: `dcrm-shop-${input.shop_id}`,
      InboundRequestUrl: inboundUrl,
      InboundMethod: "POST",
      StatusCallback: twilioStatusUrl(functionsUrl),
      UseInboundWebhookOnNumber: true,
    });
    const serviceSid = str(service.sid);
    if (!serviceSid) throw new Error("Twilio returned no messaging service sid");
    try {
      await twilio.request("POST", `${MESSAGING_API}/Services/${serviceSid}/PhoneNumbers`, {
        PhoneNumberSid: numberSid,
      });
    } catch (err) {
      await twilio.requestOrNull("DELETE", `${MESSAGING_API}/Services/${serviceSid}`)
        .catch(() => undefined);
      throw err;
    }
    await recordNumber(
      s.admin,
      input.shop_id,
      input.phone_e164,
      numberSid as string,
      serviceSid,
      kind,
    );
  }
  return { number: await numberStatus(s.admin, input.shop_id) };
}

async function submitTollfree(
  deps: Deps,
  s: StaffContext,
  input: z.output<typeof tollfreeInput>,
): Promise<Json> {
  const row = requireNumber(await provisioned(s.admin, input.shop_id));
  if (row.kind !== "tollfree") {
    throw new HttpError("unprocessable", "Toll-free verification is only for toll-free numbers.", {
      details: { reason: "not_tollfree" },
    });
  }
  requireResubmittable(row);
  const b = input.business;
  const form = {
    BusinessName: b.legal_name,
    BusinessWebsite: b.website,
    NotificationEmail: b.notification_email ?? b.contact_email,
    UseCaseCategories: b.use_case_categories,
    UseCaseSummary: b.use_case_summary,
    ProductionMessageSample: b.production_message_sample,
    OptInImageUrls: b.opt_in_image_urls,
    OptInType: b.opt_in_type,
    MessageVolume: b.estimated_monthly_volume,
    BusinessStreetAddress: b.address_line1,
    BusinessStreetAddress2: b.address_line2,
    BusinessCity: b.city,
    BusinessStateProvinceRegion: b.region,
    BusinessPostalCode: b.postal_code,
    BusinessCountry: b.country,
    BusinessContactFirstName: b.contact_first_name,
    BusinessContactLastName: b.contact_last_name,
    BusinessContactEmail: b.contact_email,
    BusinessContactPhone: b.contact_phone,
    AdditionalInformation: b.additional_information,
    ExternalReferenceId: input.shop_id,
  };
  const twilio = client(deps, s.env);
  const verification = await withTwilioValidation(async () => {
    const create = () =>
      twilio.request("POST", `${MESSAGING_API}/Tollfree/Verifications`, {
        ...form,
        TollfreePhoneNumberSid: row.twilio_number_sid,
      });
    if (row.verification_status !== "rejected" || !row.verification_sid) return await create();
    return await resubmitRejected(twilio, s, row, row.verification_sid, {
      form,
      editReason: input.edit_reason ?? DEFAULT_EDIT_REASON,
      now: deps.now?.() ?? new Date(),
      create,
    });
  });
  const sid = str(verification.sid);
  if (!sid) throw new Error("Twilio returned no verification sid");
  const status = tollfreeStatus(str(verification.status));
  await saveVerification(
    s.admin,
    input.shop_id,
    status,
    sid,
    status === "rejected"
      ? str(verification.rejection_reason) ?? "the verification was rejected"
      : null,
    { kind: "tollfree", business: b },
  );
  return { number: await numberStatus(s.admin, input.shop_id) };
}

const DEFAULT_EDIT_REASON = "Corrected the business details flagged in the review.";

/**
 * Resubmits after a rejection. Twilio lets a rejected verification be
 * edited only while its `edit_allowed` is true and before its
 * `edit_expiration`; some rejection reasons are never editable. Otherwise
 * the old verification is deleted and a new one submitted for the number.
 * A verification Twilio no longer has is simply submitted anew, and one
 * Twilio has meanwhile moved on from 'rejected' is recorded as it is now
 * (409, nothing is resubmitted).
 */
async function resubmitRejected(
  twilio: TwilioClient,
  s: StaffContext,
  row: ProvisionedNumber,
  verificationSid: string,
  options: {
    form: Record<string, FormValue>;
    editReason: string;
    now: Date;
    create: () => Promise<Json>;
  },
): Promise<Json> {
  const url = `${MESSAGING_API}/Tollfree/Verifications/${verificationSid}`;
  const current = await twilio.requestOrNull("GET", url);
  if (current === null) {
    s.log.info("sms_tollfree_resubmitted", { shop_id: row.shop_id, mode: "new_missing" });
    return await options.create();
  }
  const status = tollfreeStatus(str(current.status));
  if (status !== "rejected") {
    await saveVerification(s.admin, row.shop_id, status, verificationSid, null, row.business_info);
    requireResubmittable({ ...row, verification_status: status });
    // "pending"/"in_review"/"approved" all throw above; kept for the type checker.
    return current;
  }
  const expiration = str(current.edit_expiration);
  const expiresAt = expiration === null ? null : Date.parse(expiration);
  const editable = current.edit_allowed === true &&
    (expiresAt === null || Number.isNaN(expiresAt) || expiresAt > options.now.getTime());
  if (editable) {
    s.log.info("sms_tollfree_resubmitted", { shop_id: row.shop_id, mode: "edit" });
    return await twilio.request("POST", url, { ...options.form, EditReason: options.editReason });
  }
  // Not editable (this rejection reason, or the edit window has passed):
  // Twilio takes a new verification once the old one is deleted.
  await twilio.requestOrNull("DELETE", url);
  s.log.info("sms_tollfree_resubmitted", { shop_id: row.shop_id, mode: "new_after_delete" });
  return await options.create();
}

function a2pInfoOf(row: ProvisionedNumber): A2pInfo | null {
  const info = row.business_info as Partial<A2pInfo> | null;
  return info?.kind === "10dlc" && info.twilio && typeof info.twilio === "object"
    ? info as A2pInfo
    : null;
}

async function submitA2p(
  deps: Deps,
  s: StaffContext,
  input: z.output<typeof a2pInput>,
): Promise<Json> {
  if (!s.env.twilioIsvEnabled()) {
    throw new HttpError(
      "unprocessable",
      "Local (10DLC) number registration is not available yet. Use a toll-free number or contact support.",
      { details: { reason: "isv_required" } },
    );
  }
  const primaryProfileSid = s.env.twilioPrimaryCustomerProfileSid();
  // Brand and campaign registration carry carrier fees the platform pays.
  await requirePaidStanding(s.admin, input.shop_id);
  const row = requireNumber(await provisioned(s.admin, input.shop_id));
  if (row.kind !== "local" || !row.messaging_service_sid) {
    throw new HttpError("unprocessable", "10DLC registration is only for local numbers.", {
      details: { reason: "not_local" },
    });
  }
  requireResubmittable(row);
  // Resume an interrupted submission; after a rejection keep only an
  // approved brand (a new campaign is enough) and otherwise start afresh.
  const previous = a2pInfoOf(row)?.twilio ?? {};
  let progress: A2pProgress = previous;
  if (row.verification_status === "rejected") {
    progress = previous.brand_approved && previous.brand_sid
      ? {
        customer_profile_sid: previous.customer_profile_sid,
        trust_product_sid: previous.trust_product_sid,
        customer_profile_submitted: true,
        trust_product_submitted: true,
        brand_sid: previous.brand_sid,
        brand_approved: true,
      }
      : {};
  }
  const info: A2pInfo = {
    kind: "10dlc",
    business: input.business,
    campaign: input.campaign,
    twilio: { ...progress },
  };
  const steps = {
    client: client(deps, s.env),
    primaryProfileSid,
    shopId: input.shop_id,
    messagingServiceSid: row.messaging_service_sid,
    save: (next: A2pInfo) =>
      saveVerification(s.admin, input.shop_id, "not_started", null, null, { ...next }),
  };
  await steps.save(info);
  try {
    const result = await withTwilioValidation(() => registerA2p(steps, info));
    await saveVerification(s.admin, input.shop_id, result.status, result.sid, null, { ...info });
  } catch (err) {
    if (err instanceof ProfileNotCompliant) {
      // Abandon the non-compliant profile: the corrected details start afresh.
      await saveVerification(s.admin, input.shop_id, "not_started", null, null, {
        ...info,
        twilio: {},
      });
      throw new HttpError(
        "unprocessable",
        `${err.message}. Check the highlighted details and try again.`,
        {
          details: { reason: "profile_incomplete", issues: err.issues },
          cause: err,
        },
      );
    }
    throw err;
  }
  return { number: await numberStatus(s.admin, input.shop_id) };
}

async function releaseNumber(deps: Deps, s: StaffContext, shopId: string): Promise<Json> {
  const row = await provisioned(s.admin, shopId);
  if (!row) return { released: false, number: await numberStatus(s.admin, shopId) };
  // The number is gone first; an empty service costs nothing (logged only).
  await releasePlatformNumber(
    client(deps, s.env),
    row,
    (err) => s.log.warn("sms_service_delete_failed", { shop_id: shopId, error: err }),
  );
  const { error } = await s.admin.rpc("release_sms_number", { p_shop_id: shopId });
  if (error) throw dbFailure("release_sms_number", error);
  s.log.info("sms_number_released", { shop_id: shopId });
  return { released: true, number: await numberStatus(s.admin, shopId) };
}

export interface RefreshSummary {
  enabled: boolean;
  checked: number;
  updated: number;
  failed: number;
}

async function refreshStatuses(deps: Deps, env: Env, log: Logger): Promise<RefreshSummary> {
  const summary: RefreshSummary = {
    enabled: env.smsProvisioningEnabled(),
    checked: 0,
    updated: 0,
    failed: 0,
  };
  if (!summary.enabled) return summary;
  const admin = adminClient({ env: deps.env, fetch: deps.fetch });
  const { data, error } = await admin.from("shop_sms_numbers").select(NUMBER_COLUMNS)
    .not("twilio_number_sid", "is", null)
    .in("verification_status", ["pending", "in_review"])
    .order("last_checked_at", { ascending: true, nullsFirst: true })
    .limit(REFRESH_BATCH);
  if (error) throw dbFailure("shop_sms_numbers", error);
  const rows = (data ?? []) as unknown as ProvisionedNumber[];
  if (rows.length === 0) return summary;
  const twilio = client(deps, env);
  for (const row of rows) {
    summary.checked += 1;
    try {
      let status: VerificationStatus;
      let sid: string | null = row.verification_sid;
      let reason: string | null = null;
      let info: Record<string, unknown> | null = null;
      const a2p = a2pInfoOf(row);
      if (row.kind === "local" && a2p && row.messaging_service_sid) {
        const verdict = await refreshA2p({
          client: twilio,
          primaryProfileSid: "",
          shopId: row.shop_id,
          messagingServiceSid: row.messaging_service_sid,
          save: (next) =>
            saveVerification(admin, row.shop_id, row.verification_status, null, null, { ...next }),
        }, a2p);
        status = verdict.status;
        sid = verdict.sid || sid;
        reason = verdict.reason;
        info = { ...a2p };
      } else if (row.verification_sid) {
        const verification = await twilio.request(
          "GET",
          `${MESSAGING_API}/Tollfree/Verifications/${row.verification_sid}`,
        );
        status = tollfreeStatus(str(verification.status));
        reason = status === "rejected"
          ? str(verification.rejection_reason) ?? "the verification was rejected"
          : null;
      } else {
        continue;
      }
      await saveVerification(admin, row.shop_id, status, sid, reason, info);
      if (status !== row.verification_status) summary.updated += 1;
    } catch (err) {
      summary.failed += 1;
      log.warn("sms_status_refresh_failed", { shop_id: row.shop_id, error: err });
    }
  }
  log.info("sms_status_refreshed", { ...summary });
  return summary;
}

/** One sms_number_releases entry (0093; service role only). */
interface ReleaseEntry {
  id: string;
  phone_number: string;
  shop_id: string;
  shop_name: string | null;
  released_at: string;
}

/** A number the platform still rents although no shop uses it. */
export interface PendingRelease {
  phone_number: string;
  twilio_number_sid: string | null;
  shop_id: string;
  shop_name: string | null;
  shop_deleted: boolean;
  released_at: string;
}

export interface WorklistSummary {
  /** Entries looked at. */
  checked: number;
  /** Still rented and unbound: release (or re-assign) them in Twilio. */
  pending: PendingRelease[];
  /** Numbers of deleted shops this run gave back to Twilio. */
  released: number;
  /** Entries removed (done, and their shop is gone or the window has passed). */
  pruned: number;
  failed: number;
}

async function releaseWorklist(deps: Deps, env: Env, log: Logger): Promise<WorklistSummary> {
  const summary: WorklistSummary = { checked: 0, pending: [], released: 0, pruned: 0, failed: 0 };
  const admin = adminClient({ env: deps.env, fetch: deps.fetch });
  const { data, error } = await admin.from("sms_number_releases")
    .select("id, phone_number, shop_id, shop_name, released_at")
    .order("released_at", { ascending: true }).limit(WORKLIST_BATCH);
  if (error) throw dbFailure("sms_number_releases", error);
  const entries = (data ?? []) as unknown as ReleaseEntry[];
  if (entries.length === 0) return summary;

  const byPhone = new Map<string, ReleaseEntry[]>();
  for (const entry of entries) {
    byPhone.set(entry.phone_number, [...(byPhone.get(entry.phone_number) ?? []), entry]);
  }
  const bound = await admin.from("shop_sms_numbers").select("phone_number")
    .in("phone_number", [...byPhone.keys()]);
  if (bound.error) throw dbFailure("shop_sms_numbers", bound.error);
  const boundPhones = new Set(
    ((bound.data ?? []) as { phone_number: string }[]).map((r) => r.phone_number),
  );
  const shops = await admin.from("shops").select("id")
    .in("id", [...new Set(entries.map((e) => e.shop_id))]);
  if (shops.error) throw dbFailure("shops", shops.error);
  const liveShops = new Set(((shops.data ?? []) as { id: string }[]).map((r) => r.id));

  const now = (deps.now?.() ?? new Date()).getTime();
  const windowStart = now - RELEASE_WINDOW_DAYS * DAY_MS;
  // Kept while it still counts toward its (existing) shop's release limit.
  const prunable = (e: ReleaseEntry) =>
    !liveShops.has(e.shop_id) || Date.parse(e.released_at) < windowStart;
  const prune: string[] = [];
  const twilio = client(deps, env);

  for (const [phone, list] of byPhone) {
    summary.checked += list.length;
    const latest = list[list.length - 1] as ReleaseEntry;
    try {
      let done = boundPhones.has(phone); // in use by a shop again
      if (!done) {
        const found = await twilio.request(
          "GET",
          `${twilio.account("IncomingPhoneNumbers.json")}?${new URLSearchParams({
            PhoneNumber: phone,
            PageSize: "20",
          })}`,
        );
        const owned = (Array.isArray(found.incoming_phone_numbers)
          ? found.incoming_phone_numbers as Json[]
          : []).find((n) =>
            str(n.phone_number) === phone
          );
        const numberSid = owned ? str(owned.sid) : null;
        const shopGone = !liveShops.has(latest.shop_id);
        if (!owned) {
          done = true; // no longer rented by the platform
        } else if (
          numberSid && shopGone &&
          (str(owned.friendly_name) ?? "").startsWith(`dcrm-${latest.shop_id}-`)
        ) {
          // Bought by purchase_number for a shop that no longer exists.
          await twilio.requestOrNull(
            "DELETE",
            twilio.account(`IncomingPhoneNumbers/${numberSid}.json`),
          );
          summary.released += 1;
          log.info("sms_number_released", { shop_id: latest.shop_id, source: "worklist" });
          done = true;
        } else {
          summary.pending.push({
            phone_number: phone,
            twilio_number_sid: numberSid,
            shop_id: latest.shop_id,
            shop_name: latest.shop_name,
            shop_deleted: shopGone,
            released_at: latest.released_at,
          });
        }
      }
      if (done) prune.push(...list.filter(prunable).map((e) => e.id));
    } catch (err) {
      summary.failed += 1;
      log.warn("sms_release_check_failed", { shop_id: latest.shop_id, error: err });
    }
  }

  if (prune.length > 0) {
    const removed = await admin.from("sms_number_releases").delete().in("id", prune);
    if (removed.error) throw dbFailure("sms_number_releases delete", removed.error);
    summary.pruned = prune.length;
  }
  if (summary.pending.length > 0) {
    log.warn("sms_numbers_awaiting_release", { count: summary.pending.length });
  }
  log.info("sms_release_worklist", {
    checked: summary.checked,
    pending: summary.pending.length,
    released: summary.released,
    pruned: summary.pruned,
    failed: summary.failed,
  });
  return summary;
}

export function makeHandler(deps: Deps = {}): (req: Request) => Promise<Response> {
  const router = createActionRouter({
    status: jsonAction(shopInput, async (input, ctx) => {
      const s = await staff(deps, ctx, input.shop_id);
      return await statusResponse(s, input.shop_id);
    }),
    search_numbers: jsonAction(searchInput, async (input, ctx) => {
      const s = await staff(deps, ctx, input.shop_id);
      requireEnabled(ctx.env);
      return await searchNumbers(deps, s, input);
    }),
    purchase_number: jsonAction(purchaseInput, async (input, ctx) => {
      const s = await staff(deps, ctx, input.shop_id);
      requireEnabled(ctx.env);
      return await purchaseNumber(deps, s, input);
    }),
    submit_tollfree_verification: jsonAction(tollfreeInput, async (input, ctx) => {
      const s = await staff(deps, ctx, input.shop_id);
      requireEnabled(ctx.env);
      return await submitTollfree(deps, s, input);
    }, { maxBytes: 64 * 1024 }),
    submit_10dlc: jsonAction(a2pInput, async (input, ctx) => {
      const s = await staff(deps, ctx, input.shop_id);
      requireEnabled(ctx.env);
      return await submitA2p(deps, s, input);
    }, { maxBytes: 64 * 1024 }),
    release_number: jsonAction(shopInput, async (input, ctx) => {
      // Not gated: a shop can always give back a number it no longer wants.
      const s = await staff(deps, ctx, input.shop_id, ROLES.owner);
      return await releaseNumber(deps, s, input.shop_id);
    }),
    refresh_status: jsonAction(refreshInput, async (_input, ctx) => {
      requireCronSecret(ctx.req, ctx.env.cronSecret());
      return await refreshStatuses(deps, ctx.env, ctx.log);
    }),
    release_worklist: jsonAction(worklistInput, async (_input, ctx) => {
      requireCronSecret(ctx.req, ctx.env.cronSecret());
      return await releaseWorklist(deps, ctx.env, ctx.log);
    }),
  });
  return createHandler(
    { name: "sms-provisioning", env: deps.env, logger: deps.logger },
    (req, ctx) => router(req, ctx),
  );
}

if (import.meta.main) Deno.serve(makeHandler());
