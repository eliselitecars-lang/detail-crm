/**
 * Shop subscription plans (platform billing, docs/BILLING.md). The operator
 * defines plans as Products + Prices in the PLATFORM Stripe account (never a
 * shop's connected account); this module mirrors them into platform_plans
 * through the service-role RPCs billing_upsert_plan and
 * billing_deactivate_plans_except (migration 0101). Nothing about a plan is
 * hard-coded here:
 *
 *  - a Product is a plan when its metadata `detailcrm_plan` is "true";
 *  - each of its ACTIVE RECURRING Prices becomes one plan row (a monthly and a
 *    yearly Price are two rows with the Product's name);
 *  - name / description come from the Product; amount / currency / interval
 *    from the Price;
 *  - max_members, features and sort come from Product metadata and are
 *    validated (an invalid value is ignored with a warning: max_members ->
 *    null = unlimited, features -> the valid keys only, sort -> 0);
 *  - every plan row whose Price was not listed is deactivated (archived
 *    Products/Prices, a removed flag, a Price that can no longer be billed).
 *
 * Used by `billing` (sync_plans: pg_cron + the deploy) and `billing-webhook`
 * (product.* / price.* events). Deactivation runs only after the whole Stripe
 * listing succeeded, so a Stripe failure part-way never deactivates plans.
 */
import type { SupabaseClient } from "@supabase/supabase-js";
import type { Logger } from "./log.ts";
import type { Stripe } from "./stripe.ts";

/** Product metadata key marking a Product as a Detail CRM plan (value "true"). */
export const PLAN_FLAG_KEY = "detailcrm_plan";

/** Product metadata keys read for a plan. */
export const PLAN_METADATA_KEYS = {
  maxMembers: "max_members",
  features: "features",
  sort: "sort",
} as const;

/** platform_plans.interval check: month | year. */
export type PlanInterval = "month" | "year";

/** One plan row as billing_upsert_plan receives it. */
export interface PlanInput {
  stripePriceId: string;
  stripeProductId: string;
  name: string;
  description: string | null;
  amountCents: number;
  currency: string;
  interval: PlanInterval;
  intervalCount: number;
  /** null = unlimited (counts active members + pending invites). */
  maxMembers: number | null;
  features: string[];
  sort: number;
}

/** A Price (or a whole Product: price_id null) that was not synced, and why. */
export interface SkippedPrice {
  product_id: string;
  price_id: string | null;
  reason:
    | "missing_name"
    | "invalid_price_id"
    | "not_recurring"
    | "metered_price"
    | "tiered_price"
    | "no_fixed_amount"
    | "unsupported_interval"
    | "invalid_interval_count"
    | "invalid_currency";
}

/** A Product metadata value that was ignored, and what was used instead. */
export interface MetadataWarning {
  product_id: string;
  key: string;
  reason: string;
}

export interface PlanMetadata {
  maxMembers: number | null;
  features: string[];
  sort: number;
  warnings: MetadataWarning[];
}

export interface SyncResult {
  /** Plan rows written (one per synced Price). */
  upserted: number;
  /** Plan rows turned inactive because their Price is no longer listed. */
  deactivated: number;
  skipped: SkippedPrice[];
  warnings: MetadataWarning[];
}

const INT4_MAX = 2_147_483_647;
const INT4_MIN = -2_147_483_648;
const PRICE_ID = /^price_[A-Za-z0-9]+$/;
const PRODUCT_ID = /^prod_[A-Za-z0-9]+$/;
const FEATURE_KEY = /^[a-z0-9][a-z0-9_-]{0,63}$/;
const CURRENCY = /^[a-z]{3}$/;

type Metadata = Readonly<Record<string, string>> | null | undefined;

/** Whether a Product is marked as a Detail CRM plan (`detailcrm_plan: "true"`). */
export function isPlanProduct(product: { metadata?: Metadata }): boolean {
  return product.metadata?.[PLAN_FLAG_KEY]?.trim().toLowerCase() === "true";
}

/** max_members / features / sort from Product metadata, validated. */
export function planMetadata(productId: string, metadata: Metadata): PlanMetadata {
  const warnings: MetadataWarning[] = [];
  const warn = (key: string, reason: string) =>
    warnings.push({ product_id: productId, key, reason });

  let maxMembers: number | null = null;
  const rawMax = metadata?.[PLAN_METADATA_KEYS.maxMembers]?.trim() ?? "";
  if (rawMax !== "") {
    const n = /^\d+$/.test(rawMax) ? Number(rawMax) : NaN;
    if (Number.isSafeInteger(n) && n >= 1 && n <= INT4_MAX) maxMembers = n;
    else warn(PLAN_METADATA_KEYS.maxMembers, "not a positive whole number: treated as unlimited");
  }

  const features: string[] = [];
  const rawFeatures = metadata?.[PLAN_METADATA_KEYS.features] ?? "";
  for (const part of rawFeatures.split(",")) {
    const key = part.trim().toLowerCase();
    if (key === "") continue;
    if (!FEATURE_KEY.test(key)) {
      warn(
        PLAN_METADATA_KEYS.features,
        `"${part.trim().slice(0, 40)}" is not a feature key: left out`,
      );
      continue;
    }
    if (!features.includes(key)) features.push(key);
  }

  let sort = 0;
  const rawSort = metadata?.[PLAN_METADATA_KEYS.sort]?.trim() ?? "";
  if (rawSort !== "") {
    const n = /^-?\d+$/.test(rawSort) ? Number(rawSort) : NaN;
    if (Number.isSafeInteger(n) && n >= INT4_MIN && n <= INT4_MAX) sort = n;
    else warn(PLAN_METADATA_KEYS.sort, "not a whole number: 0 used");
  }

  return { maxMembers, features, sort, warnings };
}

type PriceLike = Pick<
  Stripe.Price,
  "id" | "type" | "recurring" | "billing_scheme" | "unit_amount" | "currency"
>;

/** The plan row for one Price of a plan Product, or why it cannot be one. */
export function planFromPrice(
  product: { id: string; name: string; description?: string | null },
  price: PriceLike,
  metadata: PlanMetadata,
): { plan: PlanInput } | { skip: SkippedPrice["reason"] } {
  if (typeof price.id !== "string" || !PRICE_ID.test(price.id)) return { skip: "invalid_price_id" };
  const recurring = price.recurring;
  if (price.type !== "recurring" || !recurring) return { skip: "not_recurring" };
  if (recurring.usage_type === "metered" || (recurring as { meter?: unknown }).meter) {
    return { skip: "metered_price" };
  }
  if (price.billing_scheme !== "per_unit") return { skip: "tiered_price" };
  const amount = price.unit_amount;
  // null: customer-chosen amount, or a fractional-cent unit_amount_decimal.
  if (typeof amount !== "number" || !Number.isSafeInteger(amount) || amount < 0) {
    return { skip: "no_fixed_amount" };
  }
  const rawInterval: string = recurring.interval;
  if (rawInterval !== "month" && rawInterval !== "year") return { skip: "unsupported_interval" };
  const interval: PlanInterval = rawInterval;
  const count = recurring.interval_count ?? 1;
  if (!Number.isSafeInteger(count) || count < 1 || count > INT4_MAX) {
    return { skip: "invalid_interval_count" };
  }
  const currency = typeof price.currency === "string" ? price.currency.trim().toLowerCase() : "";
  if (!CURRENCY.test(currency)) return { skip: "invalid_currency" };
  const description = product.description?.trim() || null;
  return {
    plan: {
      stripePriceId: price.id,
      stripeProductId: product.id,
      name: product.name.trim(),
      description,
      amountCents: amount,
      currency,
      interval,
      intervalCount: count,
      maxMembers: metadata.maxMembers,
      features: metadata.features,
      sort: metadata.sort,
    },
  };
}

export interface SyncDeps {
  /** Platform Stripe client (no connected account). */
  stripe: Stripe;
  /** Service-role client (the RPCs are service_role only). */
  admin: SupabaseClient;
  log?: Logger;
}

/** Reads the plan Products/Prices from Stripe and mirrors them into platform_plans. */
export async function syncPlans({ stripe, admin, log }: SyncDeps): Promise<SyncResult> {
  const plans: PlanInput[] = [];
  const skipped: SkippedPrice[] = [];
  const warnings: MetadataWarning[] = [];

  for await (const product of stripe.products.list({ active: true, limit: 100 })) {
    if (!isPlanProduct(product) || !PRODUCT_ID.test(product.id)) continue;
    if (typeof product.name !== "string" || product.name.trim() === "") {
      skipped.push({ product_id: product.id, price_id: null, reason: "missing_name" });
      continue;
    }
    const metadata = planMetadata(product.id, product.metadata);
    warnings.push(...metadata.warnings);
    for await (
      const price of stripe.prices.list({
        product: product.id,
        active: true,
        type: "recurring",
        limit: 100,
      })
    ) {
      const result = planFromPrice(product, price, metadata);
      if ("skip" in result) {
        skipped.push({ product_id: product.id, price_id: price.id ?? null, reason: result.skip });
      } else if (!plans.some((p) => p.stripePriceId === result.plan.stripePriceId)) {
        plans.push(result.plan);
      }
    }
  }

  for (const plan of plans) {
    const { error } = await admin.rpc("billing_upsert_plan", {
      p_stripe_price_id: plan.stripePriceId,
      p_stripe_product_id: plan.stripeProductId,
      p_name: plan.name,
      p_description: plan.description,
      p_amount_cents: plan.amountCents,
      p_currency: plan.currency,
      p_interval: plan.interval,
      p_interval_count: plan.intervalCount,
      p_max_members: plan.maxMembers,
      p_features: plan.features,
      p_sort: plan.sort,
      p_active: true,
    });
    if (error) {
      throw new Error(`billing_upsert_plan failed for ${plan.stripePriceId}`, { cause: error });
    }
  }

  const { data, error } = await admin.rpc("billing_deactivate_plans_except", {
    p_active_price_ids: plans.map((p) => p.stripePriceId),
  });
  if (error) throw new Error("billing_deactivate_plans_except failed", { cause: error });
  const deactivated = typeof data === "number" && Number.isFinite(data) ? data : 0;

  const result: SyncResult = { upserted: plans.length, deactivated, skipped, warnings };
  log?.info("billing_plans_synced", {
    upserted: result.upserted,
    deactivated: result.deactivated,
    skipped: skipped.length,
    warnings: warnings.length,
  });
  for (const s of skipped) log?.warn("billing_plan_price_skipped", { ...s });
  for (const w of warnings) log?.warn("billing_plan_metadata_ignored", { ...w });
  return result;
}
