import {
  assert,
  assertEquals,
  assertMatch,
  assertNotEquals,
  assertRejects,
  assertThrows,
} from "@std/assert";
import { HttpError } from "./errors.ts";
import { mapError } from "./http.ts";
import {
  createStripe,
  eventAccount,
  idempotencyKey,
  onAccount,
  STRIPE_API_VERSION,
  stripeFromEnv,
  verifyStripeWebhook,
} from "./stripe.ts";
import { testEnv } from "./testing/env.ts";
import { FakeFetch, jsonResponse } from "./testing/fake_fetch.ts";
import { signStripePayload, stripeErrorBody, stripeEvent } from "./testing/stripe.ts";

const SECRET = "whsec_test_secret_for_unit_tests";
const ACCOUNT = "acct_1TestConnected00";

function stripeWith(http: FakeFetch) {
  return createStripe("sk_test_unit", { fetch: http.fetch, maxNetworkRetries: 0 });
}

const payload = JSON.stringify(
  stripeEvent({
    id: "evt_1",
    type: "payment_intent.succeeded",
    account: ACCOUNT,
    object: { id: "pi_1", object: "payment_intent", amount: 5000, metadata: { invoice_id: "x" } },
  }),
);

Deno.test("stripe: the pinned API version matches the SDK's", async () => {
  const { default: Stripe } = await import("stripe");
  assertEquals(STRIPE_API_VERSION, Stripe.API_VERSION);
});

Deno.test("stripe webhook: a correctly signed payload verifies", async () => {
  const stripe = stripeWith(new FakeFetch());
  const header = await signStripePayload(payload, SECRET);
  const event = await verifyStripeWebhook(stripe, payload, header, SECRET);
  assertEquals(event.id, "evt_1");
  assertEquals(event.type, "payment_intent.succeeded");
  assertEquals(eventAccount(event), ACCOUNT);
});

Deno.test("stripe webhook: our signer matches the SDK's reference signer", async () => {
  const stripe = stripeWith(new FakeFetch());
  const timestamp = 1_790_000_000;
  const sdk = await stripe.webhooks.generateTestHeaderStringAsync({
    payload,
    secret: SECRET,
    timestamp,
  });
  assertEquals(await signStripePayload(payload, SECRET, timestamp), sdk);
});

async function rejectsSignature(promise: Promise<unknown>) {
  const err = await assertRejects(() => promise, HttpError);
  assertEquals(err.code, "invalid_signature");
  assertEquals(err.status, 400);
}

Deno.test("stripe webhook: tampered payload, wrong secret, stale or missing header fail", async () => {
  const stripe = stripeWith(new FakeFetch());
  const header = await signStripePayload(payload, SECRET);
  const tampered = payload.replace('"amount":5000', '"amount":1');
  assertNotEquals(tampered, payload);
  await rejectsSignature(verifyStripeWebhook(stripe, tampered, header, SECRET));
  await rejectsSignature(verifyStripeWebhook(stripe, payload, header, "whsec_other"));
  const stale = await signStripePayload(payload, SECRET, Math.floor(Date.now() / 1000) - 3600);
  await rejectsSignature(verifyStripeWebhook(stripe, payload, stale, SECRET));
  await rejectsSignature(verifyStripeWebhook(stripe, payload, null, SECRET));
  await rejectsSignature(verifyStripeWebhook(stripe, payload, "t=1,v1=deadbeef", SECRET));
});

Deno.test("stripe webhook: any matching v1 signature is accepted (secret rotation)", async () => {
  const stripe = stripeWith(new FakeFetch());
  const timestamp = Math.floor(Date.now() / 1000);
  const good = await signStripePayload(payload, SECRET, timestamp);
  const other = await signStripePayload(payload, "whsec_old", timestamp);
  const combined = `${other},v1=${good.split("v1=")[1]}`;
  const event = await verifyStripeWebhook(stripe, payload, combined, SECRET);
  assertEquals(event.id, "evt_1");
});

Deno.test("stripe: calls on a connected account send Stripe-Account, idempotency and version", async () => {
  const http = new FakeFetch();
  http.on("POST", "https://api.stripe.com/v1/payment_intents", (_req, { call }) =>
    jsonResponse({
      id: "pi_123",
      object: "payment_intent",
      amount: Number(call.form.get("amount")),
      currency: call.form.get("currency"),
      status: "requires_payment_method",
    }));
  const stripe = stripeWith(http);
  const key = await idempotencyKey("payment_sheet", "invoice-1", 5000, "nonce-1");
  const intent = await stripe.paymentIntents.create(
    {
      amount: 5000,
      currency: "usd",
      application_fee_amount: 150,
      metadata: { invoice_id: "invoice-1" },
    },
    onAccount(ACCOUNT, { idempotencyKey: key }),
  );
  assertEquals(intent.id, "pi_123");
  const call = http.calls[0];
  assert(call);
  assertEquals(call.headers.get("stripe-account"), ACCOUNT);
  assertEquals(call.headers.get("idempotency-key"), key);
  assertEquals(call.headers.get("stripe-version"), STRIPE_API_VERSION);
  assertEquals(call.headers.get("authorization"), "Bearer sk_test_unit");
  assertEquals(call.form.get("amount"), "5000");
  assertEquals(call.form.get("application_fee_amount"), "150");
  assertEquals(call.form.get("metadata[invoice_id]"), "invoice-1");
});

Deno.test("stripe: SDK card errors map to payment_failed via the handler mapping", async () => {
  const http = new FakeFetch();
  http.on("POST", "https://api.stripe.com/v1/payment_intents", () =>
    jsonResponse(
      stripeErrorBody("card_error", "Your card was declined.", {
        code: "card_declined",
        decline_code: "generic_decline",
      }),
      402,
    ));
  const stripe = stripeWith(http);
  const err = await assertRejects(() =>
    stripe.paymentIntents.create(
      { amount: 5000, currency: "usd", confirm: true },
      onAccount(ACCOUNT),
    )
  );
  const { httpError } = mapError(err);
  assertEquals(httpError.code, "payment_failed");
  assertEquals(httpError.status, 402);
  assertEquals(httpError.message, "Your card was declined.");
  assertEquals(httpError.details, {
    stripe_code: "card_declined",
    decline_code: "generic_decline",
  });
});

Deno.test("stripe: invalid-request errors map to a generic upstream_error", async () => {
  const http = new FakeFetch();
  http.on(
    "POST",
    "https://api.stripe.com/v1/refunds",
    () => jsonResponse(stripeErrorBody("invalid_request_error", "No such charge: 'ch_x'"), 400),
  );
  const err = await assertRejects(() => stripeWith(http).refunds.create({ charge: "ch_x" }));
  const { httpError } = mapError(err);
  assertEquals(httpError.code, "upstream_error");
  assert(!httpError.message.includes("ch_x"));
});

Deno.test("stripe: onAccount validates the account id", () => {
  assertEquals(onAccount(ACCOUNT), { stripeAccount: ACCOUNT });
  for (const bad of ["", "acct_", "cus_123456", "acct_12 34"]) {
    assertThrows(() => onAccount(bad), Error, "invalid Stripe connected account id");
  }
});

Deno.test("stripe: idempotency keys are deterministic, scoped and collision-safe", async () => {
  const a = await idempotencyKey("refund", "pay_1", 500);
  assertEquals(a, await idempotencyKey("refund", "pay_1", 500));
  assertMatch(a, /^dcrm:refund:[0-9a-f]{64}$/);
  assertNotEquals(a, await idempotencyKey("refund", "pay_1", 501));
  assertNotEquals(a, await idempotencyKey("charge", "pay_1", 500));
  assertNotEquals(await idempotencyKey("x", "ab", "c"), await idempotencyKey("x", "a", "bc"));
  assert(a.length <= 255);
  await assertRejects(() => idempotencyKey("Bad Scope", "x"), Error);
  await assertRejects(() => idempotencyKey("scope"), Error);
  await assertRejects(() => idempotencyKey("scope", Number.NaN), Error);
});

Deno.test("stripe: stripeFromEnv requires a valid key pair", () => {
  const stripe = stripeFromEnv(testEnv(), { maxNetworkRetries: 0 });
  assert(stripe.paymentIntents);
  assertThrows(
    () => stripeFromEnv(testEnv({ STRIPE_SECRET_KEY: undefined })),
    Error,
    "STRIPE_SECRET_KEY",
  );
});

Deno.test("stripe: eventAccount ignores platform events", () => {
  assertEquals(eventAccount({ account: undefined }), null);
  assertEquals(eventAccount({ account: "not-an-account" }), null);
});
