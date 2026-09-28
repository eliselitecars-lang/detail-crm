import { assertEquals } from "@std/assert";
import {
  isPlanProduct,
  PLAN_FLAG_KEY,
  planFromPrice,
  type PlanMetadata,
  planMetadata,
  type SkippedPrice,
} from "./billing_plans.ts";
import type { Stripe } from "./stripe.ts";

const PRODUCT = { id: "prod_1Studio", name: "  Studio ", description: " For one location " };
const META: PlanMetadata = { maxMembers: 5, features: ["online_booking"], sort: 1, warnings: [] };

function price(overrides: Record<string, unknown> = {}): Stripe.Price {
  return {
    id: "price_1Monthly",
    object: "price",
    type: "recurring",
    billing_scheme: "per_unit",
    unit_amount: 4_900,
    currency: "USD",
    recurring: { interval: "month", interval_count: 1, usage_type: "licensed", meter: null },
    ...overrides,
  } as unknown as Stripe.Price;
}

Deno.test("isPlanProduct: only metadata detailcrm_plan = true (trimmed, any case)", () => {
  assertEquals(PLAN_FLAG_KEY, "detailcrm_plan");
  assertEquals(isPlanProduct({ metadata: { detailcrm_plan: "true" } }), true);
  assertEquals(isPlanProduct({ metadata: { detailcrm_plan: " TRUE " } }), true);
  assertEquals(isPlanProduct({ metadata: { detailcrm_plan: "yes" } }), false);
  assertEquals(isPlanProduct({ metadata: { detailcrm_plan: "false" } }), false);
  assertEquals(isPlanProduct({ metadata: { other: "true" } }), false);
  assertEquals(isPlanProduct({ metadata: {} }), false);
  assertEquals(isPlanProduct({}), false);
});

Deno.test("planMetadata: valid values are used", () => {
  assertEquals(
    planMetadata("prod_1", {
      max_members: " 10 ",
      features: "Online_Booking, sms , ,sms,reports",
      sort: "-3",
    }),
    { maxMembers: 10, features: ["online_booking", "sms", "reports"], sort: -3, warnings: [] },
  );
  // absent keys: unlimited members, no features, sort 0, and no warnings
  assertEquals(planMetadata("prod_1", {}), {
    maxMembers: null,
    features: [],
    sort: 0,
    warnings: [],
  });
  assertEquals(planMetadata("prod_1", null).maxMembers, null);
});

Deno.test("planMetadata: invalid values are ignored with a warning naming the key", () => {
  for (const bad of ["0", "-1", "five", "2.5", "99999999999", "1e3"]) {
    const meta = planMetadata("prod_1", { max_members: bad });
    assertEquals(meta.maxMembers, null, bad);
    assertEquals(meta.warnings.map((w) => [w.product_id, w.key]), [["prod_1", "max_members"]], bad);
  }
  const features = planMetadata("prod_1", { features: "sms,bad key!,ok_2,-x" });
  assertEquals(features.features, ["sms", "ok_2"]);
  assertEquals(features.warnings.map((w) => w.key), ["features", "features"]);
  for (const bad of ["first", "1.5", "3000000000"]) {
    const sort = planMetadata("prod_1", { sort: bad });
    assertEquals([sort.sort, sort.warnings.map((w) => w.key)], [0, ["sort"]], bad);
  }
});

Deno.test("planFromPrice: a licensed per-unit monthly or yearly price becomes a plan", () => {
  assertEquals(planFromPrice(PRODUCT, price(), META), {
    plan: {
      stripePriceId: "price_1Monthly",
      stripeProductId: "prod_1Studio",
      name: "Studio",
      description: "For one location",
      amountCents: 4_900,
      currency: "usd",
      interval: "month",
      intervalCount: 1,
      maxMembers: 5,
      features: ["online_booking"],
      sort: 1,
    },
  });
  const yearly = planFromPrice(
    { id: "prod_1Studio", name: "Studio", description: "" },
    price({
      id: "price_1Yearly",
      unit_amount: 0,
      recurring: { interval: "year", interval_count: 2, usage_type: "licensed", meter: null },
    }),
    META,
  );
  assertEquals("plan" in yearly && yearly.plan.interval, "year");
  assertEquals("plan" in yearly && yearly.plan.intervalCount, 2);
  assertEquals("plan" in yearly && yearly.plan.amountCents, 0); // a free plan is allowed
  assertEquals("plan" in yearly && yearly.plan.description, null);
});

Deno.test("planFromPrice: prices the database cannot bill as a plan are skipped with a reason", () => {
  const cases: Array<[Record<string, unknown>, SkippedPrice["reason"]]> = [
    [{ id: "nope" }, "invalid_price_id"],
    [{ type: "one_time", recurring: null }, "not_recurring"],
    [{
      recurring: { interval: "month", interval_count: 1, usage_type: "metered", meter: null },
    }, "metered_price"],
    [{
      recurring: { interval: "month", interval_count: 1, usage_type: "licensed", meter: "mtr_1" },
    }, "metered_price"],
    [{ billing_scheme: "tiered", unit_amount: null }, "tiered_price"],
    [{ unit_amount: null }, "no_fixed_amount"],
    [{ unit_amount: 10.5 }, "no_fixed_amount"],
    [{
      recurring: { interval: "week", interval_count: 1, usage_type: "licensed", meter: null },
    }, "unsupported_interval"],
    [{
      recurring: { interval: "day", interval_count: 1, usage_type: "licensed", meter: null },
    }, "unsupported_interval"],
    [{
      recurring: { interval: "month", interval_count: 0, usage_type: "licensed", meter: null },
    }, "invalid_interval_count"],
    [{ currency: "us dollars" }, "invalid_currency"],
  ];
  for (const [overrides, reason] of cases) {
    assertEquals(planFromPrice(PRODUCT, price(overrides), META), { skip: reason }, reason);
  }
});
