import { assertEquals, assertThrows } from "@std/assert";
import type { Stripe } from "../_shared/stripe.ts";
import {
  cancelsAtPeriodEnd,
  chargeCard,
  chargeMethod,
  intentMethod,
  intentSavesCard,
  invoiceSubscription,
  isoFromUnix,
  isReconfirmableSheetIntent,
  membershipStatusOf,
  mergeMetadata,
  methodForStripeType,
  ownership,
  paymentIntentId,
  paymentMethodCard,
  readMetadata,
  splitTip,
  stripeMethodTypeOf,
  subscriptionPeriodEnd,
  subscriptionTerms,
  unmappedMethodType,
} from "./mapping.ts";

const SHOP = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const OTHER = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const INVOICE = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
const MEMBERSHIP = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";
const ORDER = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";

Deno.test("mapping: readMetadata parses the contract and drops malformed values", () => {
  assertEquals(
    readMetadata({
      shop_id: SHOP.toUpperCase(),
      invoice_id: INVOICE,
      kind: "deposit",
      tip_cents: "250",
    }),
    {
      shopId: SHOP,
      invoiceId: INVOICE,
      jobId: null,
      customerId: null,
      membershipId: null,
      kind: "deposit",
      giftCardOrderId: null,
      tipCents: 250,
      problems: [],
    },
  );
  const bad = readMetadata({
    shop_id: SHOP,
    job_id: "not-a-uuid",
    kind: "membership",
    tip_cents: "-5",
  });
  assertEquals(bad.jobId, null);
  assertEquals(bad.kind, "payment");
  assertEquals(bad.tipCents, 0);
  assertEquals(bad.problems.length, 3);
  assertEquals(readMetadata(null).shopId, null);
  assertEquals(readMetadata({ tip_cents: "1.5" }).tipCents, 0);
  assertEquals(readMetadata({ tip_cents: "1000000000" }).tipCents, 0);
});

Deno.test("mapping: a gift card sale carries its order (never a payment kind)", () => {
  const sale = readMetadata({ shop_id: SHOP, kind: "gift_card", gift_card_order_id: ORDER });
  assertEquals([sale.giftCardOrderId, sale.kind, sale.problems], [ORDER, "payment", []]);
  // without (or with a malformed) order id it is not a sale, and it is flagged
  const orphan = readMetadata({ shop_id: SHOP, kind: "gift_card" });
  assertEquals([orphan.giftCardOrderId, orphan.problems.length], [null, 1]);
  const malformed = readMetadata({ shop_id: SHOP, kind: "gift_card", gift_card_order_id: "x" });
  assertEquals([malformed.giftCardOrderId, malformed.problems.length], [null, 2]);
  // an order id on another kind is ignored
  assertEquals(
    readMetadata({ shop_id: SHOP, kind: "payment", gift_card_order_id: ORDER }).giftCardOrderId,
    null,
  );
  // Terminal intents: channel / source are informational, never problems
  assertEquals(
    readMetadata({ shop_id: SHOP, invoice_id: INVOICE, channel: "terminal", source: "terminal" })
      .problems,
    [],
  );
});

Deno.test("mapping: membership kind is implied by membership_id", () => {
  const md = readMetadata({ shop_id: SHOP, membership_id: MEMBERSHIP, kind: "payment" });
  assertEquals([md.kind, md.membershipId], ["membership", MEMBERSHIP]);
});

Deno.test("mapping: ownership requires this shop in every source that names one", () => {
  assertEquals(ownership(SHOP, { shop_id: SHOP }), "ours");
  assertEquals(ownership(SHOP, { shop_id: SHOP.toUpperCase() }), "ours");
  assertEquals(ownership(SHOP, {}, { shop_id: SHOP }), "ours");
  assertEquals(ownership(SHOP, null, undefined, {}), "not_crm");
  assertEquals(ownership(SHOP, { shop_id: OTHER }), "shop_mismatch");
  assertEquals(ownership(SHOP, { shop_id: SHOP }, { shop_id: OTHER }), "shop_mismatch");
  assertEquals(ownership(SHOP, { shop_id: "garbage" }), "shop_mismatch");
});

Deno.test("mapping: mergeMetadata prefers the primary source per key", () => {
  assertEquals(
    mergeMetadata({ a: "1", b: "" }, { a: "2", b: "3", c: "4" }),
    { a: "1", b: "3", c: "4" },
  );
});

Deno.test("mapping: splitTip bounds the metadata tip by the charged total", () => {
  assertEquals(splitTip(11_000, 1_000), {
    amountCents: 10_000,
    tipCents: 1_000,
    tipIgnored: false,
  });
  assertEquals(splitTip(5_000, 0), { amountCents: 5_000, tipCents: 0, tipIgnored: false });
  // a tip equal to or above what was charged is ignored: all of it is amount
  assertEquals(splitTip(5_000, 5_000), { amountCents: 5_000, tipCents: 0, tipIgnored: true });
  assertEquals(splitTip(5_000, 9_000), { amountCents: 5_000, tipCents: 0, tipIgnored: true });
  assertThrows(() => splitTip(0, 0), RangeError);
  assertThrows(() => splitTip(1.5, 0), RangeError);
});

Deno.test("mapping: subscription statuses map onto membership statuses", () => {
  const cases: Array<[string, string | null]> = [
    ["incomplete", "incomplete"],
    ["active", "active"],
    ["trialing", "active"],
    ["past_due", "past_due"],
    ["unpaid", "past_due"],
    ["paused", "past_due"],
    ["canceled", "cancelled"],
    ["incomplete_expired", "cancelled"],
    ["something_new", null],
  ];
  for (const [stripe, ours] of cases) assertEquals(membershipStatusOf(stripe), ours, stripe);
});

Deno.test("mapping: subscription period end is the latest item period", () => {
  const sub = {
    status: "active",
    cancel_at_period_end: false,
    cancel_at: null,
    items: {
      data: [{ current_period_end: 1_800_000_000 }, { current_period_end: 1_800_086_400 }],
    },
  } as unknown as Stripe.Subscription;
  assertEquals(subscriptionPeriodEnd(sub), 1_800_086_400);
  assertEquals(cancelsAtPeriodEnd(sub), false);
  assertEquals(
    cancelsAtPeriodEnd({ ...sub, cancel_at: 1_800_086_400 } as Stripe.Subscription),
    true,
  );
  assertEquals(
    cancelsAtPeriodEnd(
      { ...sub, status: "canceled", cancel_at_period_end: true } as Stripe.Subscription,
    ),
    false,
  );
  assertEquals(
    subscriptionPeriodEnd({ items: { data: [] } } as unknown as Stripe.Subscription),
    null,
  );
});

Deno.test("mapping: subscriptionTerms is the single item's price × quantity", () => {
  const sub = (item: Record<string, unknown>, more: Record<string, unknown>[] = []) =>
    ({ items: { data: [item, ...more] } }) as unknown as Stripe.Subscription;
  const item = (price: Record<string, unknown>, quantity: unknown = 1) => ({
    quantity,
    price: {
      id: "price_1Gold",
      unit_amount: 5000,
      recurring: { interval: "month", interval_count: 1 },
      ...price,
    },
  });
  assertEquals(subscriptionTerms(sub(item({}))), {
    priceId: "price_1Gold",
    amountCents: 5000,
    interval: "month",
    intervalCount: 1,
  });
  assertEquals(subscriptionTerms(sub(item({}, 2)))?.amountCents, 10000);
  assertEquals(
    subscriptionTerms(sub(item({ recurring: { interval: "year", interval_count: 1 } })))?.interval,
    "year",
  );
  // not representable: left alone (null)
  assertEquals(subscriptionTerms(sub(item({}), [item({})])), null);
  assertEquals(subscriptionTerms({ items: { data: [] } } as unknown as Stripe.Subscription), null);
  assertEquals(subscriptionTerms(sub(item({ unit_amount: null }))), null);
  assertEquals(subscriptionTerms(sub(item({ unit_amount: 12.5 }))), null);
  assertEquals(
    subscriptionTerms(sub(item({ recurring: { interval: "week", interval_count: 2 } }))),
    { priceId: "price_1Gold", amountCents: 5000, interval: "week", intervalCount: 2 },
  );
  assertEquals(
    subscriptionTerms(sub(item({ recurring: { interval: "week", interval_count: 13 } }))),
    null,
  );
  assertEquals(
    subscriptionTerms(sub(item({ recurring: { interval: "day", interval_count: 1 } }))),
    null,
  );
  assertEquals(
    subscriptionTerms(sub(item({ recurring: { interval: "year", interval_count: 4 } }))),
    null,
  );
  assertEquals(
    subscriptionTerms(sub(item({ recurring: { interval: "month", interval_count: 37 } }))),
    null,
  );
  assertEquals(subscriptionTerms(sub(item({ id: "plan_legacy" }))), null);
  assertEquals(subscriptionTerms(sub(item({}, 0))), null);
});

Deno.test("mapping: card details come only from brand/last4/expiry", () => {
  const charge = {
    payment_method_details: {
      type: "card",
      card: { brand: "Visa", last4: "4242", exp_month: 12, exp_year: 2030, fingerprint: "x" },
    },
  } as unknown as Stripe.Charge;
  assertEquals(chargeCard(charge), {
    method: "card",
    brand: "visa",
    last4: "4242",
    expMonth: 12,
    expYear: 2030,
  });
  const present = {
    payment_method_details: {
      type: "card_present",
      card_present: { brand: "mastercard", last4: "0005" },
    },
  } as unknown as Stripe.Charge;
  assertEquals(chargeCard(present)?.method, "card_present");
  assertEquals(
    chargeCard({ payment_method_details: { type: "us_bank_account" } } as unknown as Stripe.Charge),
    null,
  );
  assertEquals(
    chargeCard({
      payment_method_details: { type: "card", card: { brand: "visa", last4: "42" } },
    } as unknown as Stripe.Charge)?.last4,
    null,
  );
  assertEquals(paymentMethodCard({ type: "link" } as unknown as Stripe.PaymentMethod), null);
});

Deno.test("mapping: in-person-only intents are card_present", () => {
  assertEquals(intentMethod({ payment_method_types: ["card_present"] }), "card_present");
  assertEquals(
    intentMethod({ payment_method_types: ["card_present", "interac_present"] }),
    "card_present",
  );
  assertEquals(intentMethod({ payment_method_types: ["card", "link"] }), "card");
  assertEquals(intentMethod({ payment_method_types: ["card", "card_present"] }), "card");
  assertEquals(intentMethod({ payment_method_types: [] }), "card");
});

Deno.test("mapping: an intent's method follows the chosen or only payment method type", () => {
  // a Checkout intent with dynamic methods is a card until the customer chooses
  assertEquals(
    intentMethod({ payment_method_types: ["card", "us_bank_account", "affirm"] }),
    "card",
  );
  assertEquals(intentMethod({ payment_method_types: ["us_bank_account"] }), "ach_debit");
  assertEquals(intentMethod({ payment_method_types: ["klarna"] }), "bnpl");
  assertEquals(
    intentMethod({
      payment_method_types: ["card", "us_bank_account"],
      payment_method: { id: "pm_1", type: "us_bank_account" } as unknown as Stripe.PaymentMethod,
    }),
    "ach_debit",
  );
  assertEquals(
    intentMethod({
      payment_method_types: ["card", "affirm"],
      payment_method: { id: "pm_1", type: "affirm" } as unknown as Stripe.PaymentMethod,
    }),
    "bnpl",
  );
  // an unexpanded payment method id says nothing
  assertEquals(
    intentMethod({ payment_method_types: ["card", "us_bank_account"], payment_method: "pm_1" }),
    "card",
  );
});

Deno.test("mapping: Stripe payment method types map onto payment methods (P-31)", () => {
  for (const type of ["card", "link", "apple_pay", "google_pay"]) {
    assertEquals(methodForStripeType(type), "card", type);
  }
  assertEquals(methodForStripeType("card_present"), "card_present");
  assertEquals(methodForStripeType("interac_present"), "card_present");
  assertEquals(methodForStripeType("us_bank_account"), "ach_debit");
  for (const type of ["affirm", "klarna", "afterpay_clearpay", "zip"]) {
    assertEquals(methodForStripeType(type), "bnpl", type);
  }
  assertEquals(methodForStripeType("cashapp"), null);
  assertEquals(methodForStripeType(null), null);

  const withType = (type: string, extra: Record<string, unknown> = {}) =>
    ({ payment_method_details: { type, ...extra } }) as unknown as Stripe.Charge;
  assertEquals(
    chargeMethod(withType("us_bank_account", { us_bank_account: { last4: "6789" } })),
    { method: "ach_debit", brand: null, last4: "6789" },
  );
  assertEquals(chargeMethod(withType("klarna")), { method: "bnpl", brand: null, last4: null });
  assertEquals(
    chargeMethod(withType("card", { card: { brand: "visa", last4: "4242" } })),
    { method: "card", brand: "visa", last4: "4242" },
  );
  assertEquals(chargeMethod(withType("link")), { method: "card", brand: null, last4: null });
  assertEquals(chargeMethod(withType("cashapp")), null);
  assertEquals(chargeMethod(null), null);

  // stripe_method_type: charge first, then the expanded payment method, then the only type
  assertEquals(stripeMethodTypeOf(withType("affirm")), "affirm");
  assertEquals(
    stripeMethodTypeOf(null, {
      payment_method: { type: "us_bank_account" } as unknown as Stripe.PaymentMethod,
      payment_method_types: ["card", "us_bank_account"],
    }),
    "us_bank_account",
  );
  assertEquals(
    stripeMethodTypeOf(null, { payment_method: "pm_1", payment_method_types: ["card_present"] }),
    "card_present",
  );
  assertEquals(
    stripeMethodTypeOf(null, { payment_method: null, payment_method_types: ["card", "klarna"] }),
    null,
  );
  assertEquals(stripeMethodTypeOf(withType("Weird Type!")), null);
});

Deno.test("mapping: a card saved for later is asked for on the intent or its card options", () => {
  assertEquals(
    intentSavesCard({ setup_future_usage: "off_session", payment_method_options: null }),
    true,
  );
  assertEquals(
    intentSavesCard({
      setup_future_usage: null,
      payment_method_options: { card: { setup_future_usage: "off_session" } },
    } as unknown as Stripe.PaymentIntent),
    true,
  );
  assertEquals(
    intentSavesCard({
      setup_future_usage: null,
      payment_method_options: { card: { request_three_d_secure: "automatic" } },
    } as unknown as Stripe.PaymentIntent),
    false,
  );
  assertEquals(intentSavesCard({ setup_future_usage: null, payment_method_options: null }), false);
});

Deno.test("mapping: ids and timestamps are validated", () => {
  assertEquals(paymentIntentId("pi_123"), "pi_123");
  assertEquals(paymentIntentId({ id: "pi_456" }), "pi_456");
  assertEquals(paymentIntentId("pi_1; drop"), null);
  assertEquals(paymentIntentId(null), null);
  assertEquals(isoFromUnix(1_800_000_000), "2027-01-15T08:00:00.000Z");
  assertEquals(isoFromUnix(null), null);
  const invoice = {
    parent: {
      type: "subscription_details",
      subscription_details: { subscription: "sub_1", metadata: { shop_id: SHOP } },
    },
  } as unknown as Stripe.Invoice;
  assertEquals(invoiceSubscription(invoice), {
    subscriptionId: "sub_1",
    metadata: { shop_id: SHOP },
  });
  assertEquals(
    invoiceSubscription({ parent: null } as unknown as Stripe.Invoice).subscriptionId,
    null,
  );
});

Deno.test("mapping: unmappedMethodType flags only types the CRM has no method for", () => {
  const withType = (type: string) =>
    ({ payment_method_details: { type } }) as unknown as Stripe.Charge;
  assertEquals(unmappedMethodType(withType("card")), null);
  assertEquals(unmappedMethodType(withType("card_present")), null);
  assertEquals(unmappedMethodType(withType("interac_present")), null);
  assertEquals(unmappedMethodType(withType("us_bank_account")), null);
  assertEquals(unmappedMethodType(withType("klarna")), null);
  assertEquals(unmappedMethodType(withType("link")), null);
  assertEquals(unmappedMethodType(withType("cashapp")), "cashapp");
  assertEquals(unmappedMethodType(withType("Weird Type!")), "other");
  assertEquals(unmappedMethodType(null), null);
  assertEquals(unmappedMethodType({} as Stripe.Charge), null);
});

Deno.test("mapping: isReconfirmableSheetIntent — only unconfirmed sheet / Terminal intents", () => {
  const pi = (status: string, source?: string) =>
    ({ status, metadata: source ? { source } : {} }) as unknown as Stripe.PaymentIntent;
  assertEquals(isReconfirmableSheetIntent(pi("requires_payment_method", "payment_sheet")), true);
  assertEquals(isReconfirmableSheetIntent(pi("requires_action", "payment_sheet")), true);
  assertEquals(isReconfirmableSheetIntent(pi("requires_confirmation", "payment_sheet")), true);
  assertEquals(isReconfirmableSheetIntent(pi("canceled", "payment_sheet")), false);
  assertEquals(isReconfirmableSheetIntent(pi("processing", "payment_sheet")), false);
  assertEquals(
    isReconfirmableSheetIntent(pi("requires_payment_method", "invoice_checkout")),
    false,
  );
  assertEquals(
    isReconfirmableSheetIntent(pi("requires_payment_method", "charge_saved_card")),
    false,
  );
  assertEquals(isReconfirmableSheetIntent(pi("requires_payment_method")), false);
  // Terminal / Tap to Pay: a declined tap can be retried on the same intent
  assertEquals(isReconfirmableSheetIntent(pi("requires_payment_method", "terminal")), true);
  assertEquals(isReconfirmableSheetIntent(pi("succeeded", "terminal")), false);
});
