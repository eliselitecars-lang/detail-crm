/**
 * US A2P 10DLC registration for a shop's local number, as an ISV
 * (TWILIO_ISV_ENABLED): a secondary Trust Hub customer profile for the shop
 * (business details, authorized representative, address, the ISV's primary
 * profile), an A2P messaging trust product, a brand registration, and -
 * once the brand is approved (refresh_status) - a campaign on the shop's own
 * Messaging Service.
 *
 * Every Twilio resource id is saved (business_info.twilio) as soon as it is
 * created, so a submission interrupted by a network error resumes where it
 * stopped instead of creating duplicates. A profile Twilio evaluates as
 * non-compliant is abandoned (the next submission starts afresh with the
 * corrected details).
 */
import { z } from "zod";
import { e164, email } from "../_shared/schemas.ts";
import {
  A2P_MESSAGING_PROFILE_POLICY,
  type Json,
  MESSAGING_API,
  SECONDARY_CUSTOMER_PROFILE_POLICY,
  str,
  TRUSTHUB_API,
  type TwilioClient,
} from "../_shared/twilio_api.ts";

const text = (min: number, max: number) => z.string().trim().min(min).max(max);
const httpsUrl = z.url({ protocol: /^https?$/ }).max(500);

export const BUSINESS_TYPES = [
  "Sole Proprietorship",
  "Partnership",
  "Corporation",
  "Co-operative",
  "Limited Liability Corporation",
  "Non-profit Corporation",
] as const;

export const BUSINESS_INDUSTRIES = [
  "AUTOMOTIVE",
  "AGRICULTURE",
  "BANKING",
  "CONSUMER",
  "EDUCATION",
  "ELECTRONICS",
  "ENERGY",
  "ENGINEERING",
  "FAST_MOVING_CONSUMER_GOODS",
  "FINANCIAL",
  "FINTECH",
  "FOOD_AND_BEVERAGE",
  "GOVERNMENT",
  "HEALTHCARE",
  "HOSPITALITY",
  "INSURANCE",
  "JEWELRY",
  "LEGAL",
  "MANUFACTURING",
  "MEDIA",
  "NOT_FOR_PROFIT",
  "OIL_AND_GAS",
  "ONLINE",
  "PROFESSIONAL_SERVICES",
  "RAW_MATERIALS",
  "REAL_ESTATE",
  "RELIGION",
  "RETAIL",
  "TECHNOLOGY",
  "TELECOMMUNICATIONS",
  "TRANSPORTATION",
  "TRAVEL",
] as const;

export const a2pBusinessSchema = z.object({
  legal_name: text(1, 200),
  business_type: z.enum(BUSINESS_TYPES),
  industry: z.enum(BUSINESS_INDUSTRIES),
  /** EIN (US) or CBN (Canada business number). */
  registration_identifier: z.enum(["EIN", "CBN"]),
  registration_number: text(2, 40),
  website: httpsUrl,
  regions_of_operation: z.array(
    z.enum(["USA_AND_CANADA", "AFRICA", "ASIA", "EUROPE", "LATIN_AMERICA"]),
  ).min(1).max(5),
  company_type: z.enum(["private", "public", "non-profit", "government"]),
  stock_exchange: text(1, 20).optional(),
  stock_ticker: text(1, 10).optional(),
  address_line1: text(1, 200),
  address_line2: text(1, 200).optional(),
  city: text(1, 100),
  region: text(2, 50),
  postal_code: text(3, 12),
  country: z.enum(["US", "CA"]),
  /** Where Twilio sends profile review updates. */
  email,
  representative: z.object({
    first_name: text(1, 100),
    last_name: text(1, 100),
    email,
    phone: e164,
    business_title: text(1, 100),
    job_position: z.enum(["Director", "GM", "VP", "CEO", "CFO", "General Counsel", "Other"]),
  }).strict(),
}).strict().refine(
  (b) =>
    b.company_type !== "public" || (b.stock_exchange !== undefined && b.stock_ticker !== undefined),
  { message: "public companies need stock_exchange and stock_ticker", path: ["stock_ticker"] },
);

export const a2pCampaignSchema = z.object({
  use_case: z.enum(["MIXED", "CUSTOMER_CARE", "ACCOUNT_NOTIFICATION", "MARKETING", "LOW_VOLUME"]),
  description: text(40, 2048),
  message_flow: text(40, 2048),
  message_samples: z.array(text(20, 1024)).min(2).max(5),
  has_embedded_links: z.boolean(),
  has_embedded_phone: z.boolean(),
  opt_in_message: text(20, 320).optional(),
  opt_out_message: text(20, 320).optional(),
  help_message: text(20, 320).optional(),
}).strict();

export type A2pBusiness = z.output<typeof a2pBusinessSchema>;
export type A2pCampaign = z.output<typeof a2pCampaignSchema>;

/** Twilio resources created so far (business_info.twilio). */
export interface A2pProgress {
  customer_profile_sid?: string;
  assigned_to_profile?: string[];
  business_end_user_sid?: string;
  representative_end_user_sid?: string;
  address_sid?: string;
  address_document_sid?: string;
  customer_profile_submitted?: boolean;
  trust_product_sid?: string;
  assigned_to_trust_product?: string[];
  a2p_end_user_sid?: string;
  trust_product_submitted?: boolean;
  brand_sid?: string;
  brand_approved?: boolean;
  campaign_sid?: string;
}

export interface A2pInfo {
  kind: "10dlc";
  business: A2pBusiness;
  campaign: A2pCampaign;
  twilio: A2pProgress;
}

export class ProfileNotCompliant extends Error {
  readonly issues: unknown;
  constructor(what: string, issues: unknown) {
    super(`${what} was evaluated as non-compliant`);
    this.name = "ProfileNotCompliant";
    this.issues = issues;
  }
}

interface Steps {
  client: TwilioClient;
  primaryProfileSid: string;
  shopId: string;
  messagingServiceSid: string;
  /** Persists progress after each created resource. */
  save(info: A2pInfo): Promise<void>;
}

function sidOf(json: Json, what: string): string {
  const sid = str(json.sid);
  if (!sid) throw new Error(`Twilio returned no sid for ${what}`);
  return sid;
}

/** Twilio evaluation results: only the failed requirements, trimmed. */
function failedRequirements(evaluation: Json): unknown[] {
  const results = Array.isArray(evaluation.results) ? evaluation.results as Json[] : [];
  return results
    .filter((r) => r.passed === false)
    .map((r) => ({
      requirement: str(r.requirement_friendly_name) ?? str(r.requirement_name),
      fields: Array.isArray(r.fields)
        ? (r.fields as Json[]).filter((f) => f.passed === false).map((f) =>
          str(f.friendly_name) ?? str(f.object_field)
        )
        : [],
    }))
    .slice(0, 20);
}

async function assign(
  steps: Steps,
  info: A2pInfo,
  bundleUrl: string,
  listKey: "assigned_to_profile" | "assigned_to_trust_product",
  objectSid: string,
): Promise<void> {
  const done = info.twilio[listKey] ?? [];
  if (done.includes(objectSid)) return;
  await steps.client.request("POST", `${bundleUrl}/EntityAssignments`, { ObjectSid: objectSid });
  info.twilio[listKey] = [...done, objectSid];
  await steps.save(info);
}

async function evaluate(
  steps: Steps,
  bundleUrl: string,
  policySid: string,
  what: string,
): Promise<void> {
  const evaluation = await steps.client.request("POST", `${bundleUrl}/Evaluations`, {
    PolicySid: policySid,
  });
  if (str(evaluation.status) !== "compliant") {
    throw new ProfileNotCompliant(what, failedRequirements(evaluation));
  }
}

/**
 * Runs (or resumes) the registration up to the brand; creates the campaign
 * too when the brand is already approved. Returns the status to record.
 */
export async function registerA2p(
  steps: Steps,
  info: A2pInfo,
): Promise<{ status: "pending" | "in_review"; sid: string }> {
  const { client } = steps;
  const b = info.business;
  const p = info.twilio;
  const friendly = `dcrm-${steps.shopId}`;

  if (!p.brand_sid) {
    // 1. secondary customer profile
    if (!p.customer_profile_sid) {
      p.customer_profile_sid = sidOf(
        await client.request("POST", `${TRUSTHUB_API}/CustomerProfiles`, {
          FriendlyName: friendly,
          Email: b.email,
          PolicySid: SECONDARY_CUSTOMER_PROFILE_POLICY,
        }),
        "the customer profile",
      );
      await steps.save(info);
    }
    const profileUrl = `${TRUSTHUB_API}/CustomerProfiles/${p.customer_profile_sid}`;
    if (!p.customer_profile_submitted) {
      if (!p.business_end_user_sid) {
        p.business_end_user_sid = sidOf(
          await client.request("POST", `${TRUSTHUB_API}/EndUsers`, {
            FriendlyName: `${friendly}-business`,
            Type: "customer_profile_business_information",
            Attributes: JSON.stringify({
              business_name: b.legal_name,
              business_identity: "direct_customer",
              business_industry: b.industry,
              business_registration_identifier: b.registration_identifier,
              business_registration_number: b.registration_number,
              business_regions_of_operation: b.regions_of_operation.join(","),
              business_type: b.business_type,
              social_media_profile_urls: "",
              website_url: b.website,
            }),
          }),
          "the business information",
        );
        await steps.save(info);
      }
      await assign(steps, info, profileUrl, "assigned_to_profile", p.business_end_user_sid);

      if (!p.representative_end_user_sid) {
        const r = b.representative;
        p.representative_end_user_sid = sidOf(
          await client.request("POST", `${TRUSTHUB_API}/EndUsers`, {
            FriendlyName: `${friendly}-representative`,
            Type: "authorized_representative_1",
            Attributes: JSON.stringify({
              business_title: r.business_title,
              email: r.email,
              first_name: r.first_name,
              job_position: r.job_position,
              last_name: r.last_name,
              phone_number: r.phone,
            }),
          }),
          "the authorized representative",
        );
        await steps.save(info);
      }
      await assign(steps, info, profileUrl, "assigned_to_profile", p.representative_end_user_sid);

      if (!p.address_sid) {
        p.address_sid = sidOf(
          await client.request("POST", client.account("Addresses.json"), {
            CustomerName: b.legal_name,
            Street: b.address_line1,
            StreetSecondary: b.address_line2,
            City: b.city,
            Region: b.region,
            PostalCode: b.postal_code,
            IsoCountry: b.country,
            FriendlyName: friendly,
          }),
          "the address",
        );
        await steps.save(info);
      }
      if (!p.address_document_sid) {
        p.address_document_sid = sidOf(
          await client.request("POST", `${TRUSTHUB_API}/SupportingDocuments`, {
            FriendlyName: `${friendly}-address`,
            Type: "customer_profile_address",
            Attributes: JSON.stringify({ address_sids: p.address_sid }),
          }),
          "the address document",
        );
        await steps.save(info);
      }
      await assign(steps, info, profileUrl, "assigned_to_profile", p.address_document_sid);
      await assign(steps, info, profileUrl, "assigned_to_profile", steps.primaryProfileSid);
      await evaluate(steps, profileUrl, SECONDARY_CUSTOMER_PROFILE_POLICY, "The business profile");
      await client.request("POST", profileUrl, { Status: "pending-review" });
      p.customer_profile_submitted = true;
      await steps.save(info);
    }

    // 2. A2P messaging profile (trust product)
    if (!p.trust_product_sid) {
      p.trust_product_sid = sidOf(
        await client.request("POST", `${TRUSTHUB_API}/TrustProducts`, {
          FriendlyName: `${friendly}-a2p`,
          Email: b.email,
          PolicySid: A2P_MESSAGING_PROFILE_POLICY,
        }),
        "the messaging profile",
      );
      await steps.save(info);
    }
    const productUrl = `${TRUSTHUB_API}/TrustProducts/${p.trust_product_sid}`;
    if (!p.trust_product_submitted) {
      if (!p.a2p_end_user_sid) {
        p.a2p_end_user_sid = sidOf(
          await client.request("POST", `${TRUSTHUB_API}/EndUsers`, {
            FriendlyName: `${friendly}-a2p-info`,
            Type: "us_a2p_messaging_profile_information",
            Attributes: JSON.stringify({
              company_type: b.company_type,
              ...(b.company_type === "public"
                ? { stock_exchange: b.stock_exchange, stock_ticker: b.stock_ticker }
                : {}),
            }),
          }),
          "the messaging profile information",
        );
        await steps.save(info);
      }
      await assign(steps, info, productUrl, "assigned_to_trust_product", p.a2p_end_user_sid);
      await assign(steps, info, productUrl, "assigned_to_trust_product", p.customer_profile_sid);
      await evaluate(steps, productUrl, A2P_MESSAGING_PROFILE_POLICY, "The messaging profile");
      await client.request("POST", productUrl, { Status: "pending-review" });
      p.trust_product_submitted = true;
      await steps.save(info);
    }

    // 3. brand
    const brand = await client.request("POST", `${MESSAGING_API}/a2p/BrandRegistrations`, {
      CustomerProfileBundleSid: p.customer_profile_sid,
      A2PProfileBundleSid: p.trust_product_sid,
    });
    p.brand_sid = sidOf(brand, "the brand");
    p.brand_approved = str(brand.status) === "APPROVED";
    await steps.save(info);
  }

  if (!p.brand_approved) return { status: "pending", sid: p.brand_sid };
  return { status: "in_review", sid: await createCampaign(steps, info) };
}

/** Creates the campaign on the shop's Messaging Service (brand approved). */
export async function createCampaign(steps: Steps, info: A2pInfo): Promise<string> {
  const p = info.twilio;
  if (p.campaign_sid) return p.campaign_sid;
  const c = info.campaign;
  const campaign = await steps.client.request(
    "POST",
    `${MESSAGING_API}/Services/${steps.messagingServiceSid}/Compliance/Usa2p`,
    {
      BrandRegistrationSid: p.brand_sid,
      Description: c.description,
      MessageFlow: c.message_flow,
      MessageSamples: c.message_samples,
      UsAppToPersonUsecase: c.use_case,
      HasEmbeddedLinks: c.has_embedded_links,
      HasEmbeddedPhone: c.has_embedded_phone,
      OptInMessage: c.opt_in_message,
      OptOutMessage: c.opt_out_message,
      HelpMessage: c.help_message,
    },
  );
  p.campaign_sid = sidOf(campaign, "the campaign");
  await steps.save(info);
  return p.campaign_sid;
}

export type Verdict =
  | { status: "pending" | "in_review" | "approved"; sid: string; reason: null }
  | { status: "rejected"; sid: string; reason: string };

function errorsText(json: Json, fallback: string): string {
  const list = Array.isArray(json.errors) ? json.errors as Json[] : [];
  const parts = list.map((e) => str(e.description) ?? str(e.message) ?? str(e.error_code))
    .filter((v): v is string => v !== null);
  return (str(json.failure_reason) ?? parts.join("; ")) || fallback;
}

/**
 * Polls a 10DLC registration: brand (pending -> approved: the campaign is
 * created; failed: rejected), then campaign (verified: approved; failed:
 * rejected). Mutates `info.twilio` (brand_approved, campaign_sid).
 */
export async function refreshA2p(steps: Steps, info: A2pInfo): Promise<Verdict> {
  const p = info.twilio;
  if (!p.brand_sid) {
    return {
      status: "rejected",
      sid: "",
      reason: "the registration was not completed; submit it again",
    };
  }
  if (!p.brand_approved) {
    const brand = await steps.client.request(
      "GET",
      `${MESSAGING_API}/a2p/BrandRegistrations/${p.brand_sid}`,
    );
    const status = str(brand.status);
    if (status === "FAILED" || status === "DELETED" || status === "SUSPENDED") {
      return {
        status: "rejected",
        sid: p.brand_sid,
        reason: errorsText(brand, "the brand registration failed"),
      };
    }
    if (status !== "APPROVED") return { status: "pending", sid: p.brand_sid, reason: null };
    p.brand_approved = true;
    await steps.save(info);
  }
  if (!p.campaign_sid) {
    return { status: "in_review", sid: await createCampaign(steps, info), reason: null };
  }
  const campaign = await steps.client.request(
    "GET",
    `${MESSAGING_API}/Services/${steps.messagingServiceSid}/Compliance/Usa2p/${p.campaign_sid}`,
  );
  const status = str(campaign.campaign_status);
  if (status === "VERIFIED") return { status: "approved", sid: p.campaign_sid, reason: null };
  if (status === "FAILED" || status === "SUSPENDED") {
    return {
      status: "rejected",
      sid: p.campaign_sid,
      reason: errorsText(campaign, "the campaign was not approved"),
    };
  }
  return { status: "in_review", sid: p.campaign_sid, reason: null };
}
