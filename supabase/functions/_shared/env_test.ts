import { assertEquals, assertThrows } from "@std/assert";
import { denoEnvSource, Env, ENV_NAMES, EnvError, envFromRecord } from "./env.ts";
import { TEST_ENV, testEnv } from "./testing/env.ts";

function envError(fn: () => unknown, variable: string, problem: "missing" | "invalid"): EnvError {
  const err = assertThrows(fn, EnvError);
  assertEquals(err.variable, variable);
  assertEquals(err.problem, problem);
  return err;
}

Deno.test("env: required throws a clear EnvError naming the variable", () => {
  const env = new Env(envFromRecord({}));
  const err = envError(() => env.required("STRIPE_SECRET_KEY"), "STRIPE_SECRET_KEY", "missing");
  assertEquals(err.message, "Missing required environment variable STRIPE_SECRET_KEY.");
});

Deno.test("env: blank values count as missing and values are trimmed", () => {
  const env = new Env(
    envFromRecord({ EMAIL_FROM: "   ", APP_BASE_URL: "  https://a.example.com/ " }),
  );
  envError(() => env.required("EMAIL_FROM"), "EMAIL_FROM", "missing");
  assertEquals(env.optional("EMAIL_FROM"), undefined);
  assertEquals(env.appBaseUrl(), "https://a.example.com");
});

Deno.test("env: the full test env validates", () => {
  const env = testEnv();
  assertEquals(env.supabase(), {
    url: TEST_ENV.SUPABASE_URL,
    anonKey: TEST_ENV.SUPABASE_ANON_KEY,
    serviceRoleKey: TEST_ENV.SUPABASE_SERVICE_ROLE_KEY,
  });
  assertEquals(env.stripe().livemode, false);
  assertEquals(env.stripeWebhookSecret(), TEST_ENV.STRIPE_WEBHOOK_SECRET);
  assertEquals(env.platformFeeBps(), 0);
  assertEquals(env.twilio().accountSid, TEST_ENV.TWILIO_ACCOUNT_SID);
  assertEquals(env.resend().from, TEST_ENV.EMAIL_FROM);
  assertEquals(env.cronSecret(), TEST_ENV.CRON_SECRET);
  assertEquals(env.functionsPublicUrl(), "https://fake-project.supabase.co/functions/v1");
  assertEquals(env.corsExtraOrigins(), []);
});

Deno.test("env: SUPABASE_URL must be an http(s) URL", () => {
  envError(() => testEnv({ SUPABASE_URL: "not a url" }).supabase(), "SUPABASE_URL", "invalid");
  envError(
    () => testEnv({ SUPABASE_URL: "ftp://x.example" }).supabase(),
    "SUPABASE_URL",
    "invalid",
  );
  envError(
    () => testEnv({ SUPABASE_SERVICE_ROLE_KEY: undefined }).supabase(),
    "SUPABASE_SERVICE_ROLE_KEY",
    "missing",
  );
});

Deno.test("env: Stripe keys are format-checked and must share a mode", () => {
  envError(
    () => testEnv({ STRIPE_SECRET_KEY: "pk_test_abc" }).stripe(),
    "STRIPE_SECRET_KEY",
    "invalid",
  );
  envError(
    () => testEnv({ STRIPE_PUBLISHABLE_KEY: "sk_test_abc" }).stripe(),
    "STRIPE_PUBLISHABLE_KEY",
    "invalid",
  );
  envError(
    () => testEnv({ STRIPE_PUBLISHABLE_KEY: "pk_live_abc" }).stripe(),
    "STRIPE_PUBLISHABLE_KEY",
    "invalid",
  );
  const live = testEnv({ STRIPE_SECRET_KEY: "rk_live_abc", STRIPE_PUBLISHABLE_KEY: "pk_live_abc" });
  assertEquals(live.stripe().livemode, true);
  envError(
    () => testEnv({ STRIPE_WEBHOOK_SECRET: "secret" }).stripeWebhookSecret(),
    "STRIPE_WEBHOOK_SECRET",
    "invalid",
  );
});

Deno.test("env: PLATFORM_FEE_BPS defaults to 0 and must be 0..10000", () => {
  assertEquals(testEnv({ PLATFORM_FEE_BPS: undefined }).platformFeeBps(), 0);
  assertEquals(testEnv({ PLATFORM_FEE_BPS: "250" }).platformFeeBps(), 250);
  assertEquals(testEnv({ PLATFORM_FEE_BPS: "10000" }).platformFeeBps(), 10_000);
  for (const bad of ["-1", "2.5", "abc", "10001"]) {
    envError(
      () => testEnv({ PLATFORM_FEE_BPS: bad }).platformFeeBps(),
      "PLATFORM_FEE_BPS",
      "invalid",
    );
  }
});

Deno.test("env: Twilio, Resend, email sender and cron secret validation", () => {
  envError(
    () => testEnv({ TWILIO_ACCOUNT_SID: "AC123" }).twilio(),
    "TWILIO_ACCOUNT_SID",
    "invalid",
  );
  envError(
    () => testEnv({ TWILIO_AUTH_TOKEN: undefined }).twilio(),
    "TWILIO_AUTH_TOKEN",
    "missing",
  );
  envError(() => testEnv({ RESEND_API_KEY: "key_123" }).resend(), "RESEND_API_KEY", "invalid");
  envError(() => testEnv({ EMAIL_FROM: "Detail CRM" }).resend(), "EMAIL_FROM", "invalid");
  assertEquals(testEnv({ EMAIL_FROM: "hi@example.com" }).resend().from, "hi@example.com");
  envError(() => testEnv({ CRON_SECRET: "short" }).cronSecret(), "CRON_SECRET", "invalid");
});

Deno.test("env: APP_BASE_URL keeps a path base but rejects query/fragment", () => {
  assertEquals(
    testEnv({ APP_BASE_URL: "https://crm.example.com/app/" }).appBaseUrl(),
    "https://crm.example.com/app",
  );
  envError(
    () => testEnv({ APP_BASE_URL: "https://x.example.com/?a=1" }).appBaseUrl(),
    "APP_BASE_URL",
    "invalid",
  );
});

Deno.test("env: CORS_ALLOWED_ORIGINS parses bare origins only", () => {
  const env = testEnv({
    CORS_ALLOWED_ORIGINS: "http://localhost:5173, https://staging.example.com/",
  });
  assertEquals(env.corsExtraOrigins(), ["http://localhost:5173", "https://staging.example.com"]);
  envError(
    () => testEnv({ CORS_ALLOWED_ORIGINS: "https://x.example.com/path" }).corsExtraOrigins(),
    "CORS_ALLOWED_ORIGINS",
    "invalid",
  );
});

Deno.test("env: FUNCTIONS_PUBLIC_URL overrides the derived functions URL", () => {
  const env = testEnv({ FUNCTIONS_PUBLIC_URL: "https://tunnel.example.com/functions/v1/" });
  assertEquals(env.functionsPublicUrl(), "https://tunnel.example.com/functions/v1");
});

Deno.test("env: the default source reads Deno.env", () => {
  const name = "DETAIL_CRM_ENV_TEST_PROBE";
  Deno.env.set(name, "probe");
  try {
    assertEquals(denoEnvSource.get(name), "probe");
  } finally {
    Deno.env.delete(name);
  }
});

Deno.test("env: ENV_NAMES lists every SPEC secret", () => {
  for (
    const name of [
      "STRIPE_SECRET_KEY",
      "STRIPE_WEBHOOK_SECRET",
      "STRIPE_PUBLISHABLE_KEY",
      "PLATFORM_FEE_BPS",
      "TWILIO_ACCOUNT_SID",
      "TWILIO_AUTH_TOKEN",
      "RESEND_API_KEY",
      "EMAIL_FROM",
      "APP_BASE_URL",
      "CRON_SECRET",
    ]
  ) {
    assertEquals((ENV_NAMES as readonly string[]).includes(name), true, name);
  }
});

Deno.test("env: APNs credentials are validated and one-line PEMs accepted", () => {
  const pem =
    "-----BEGIN PRIVATE KEY-----\nMIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQg\n-----END PRIVATE KEY-----";
  const good = {
    APNS_KEY_ID: "ABC123DEFG",
    APNS_TEAM_ID: "TEAM123456",
    APNS_PRIVATE_KEY: pem.replace(/\n/g, "\\n"),
    APNS_TOPIC: "com.example.detailcrm",
  };
  assertEquals(testEnv(good).apns(), {
    keyId: "ABC123DEFG",
    teamId: "TEAM123456",
    privateKeyPem: pem,
    topic: "com.example.detailcrm",
  });
  envError(() => testEnv({ ...good, APNS_KEY_ID: undefined }).apns(), "APNS_KEY_ID", "missing");
  envError(() => testEnv({ ...good, APNS_TEAM_ID: "x" }).apns(), "APNS_TEAM_ID", "invalid");
  envError(
    () => testEnv({ ...good, APNS_PRIVATE_KEY: "nope" }).apns(),
    "APNS_PRIVATE_KEY",
    "invalid",
  );
  envError(() => testEnv({ ...good, APNS_TOPIC: "nodots" }).apns(), "APNS_TOPIC", "invalid");
});

Deno.test("env: feature flags are on only for 'true'; the ISV profile sid is checked", () => {
  assertEquals(testEnv().smsProvisioningEnabled(), false);
  assertEquals(testEnv({ SMS_PROVISIONING_ENABLED: "TRUE" }).smsProvisioningEnabled(), true);
  assertEquals(testEnv({ SMS_PROVISIONING_ENABLED: "1" }).smsProvisioningEnabled(), false);
  assertEquals(testEnv({ TWILIO_ISV_ENABLED: "true" }).twilioIsvEnabled(), true);
  const sid = `BU${"a".repeat(32)}`;
  assertEquals(
    testEnv({ TWILIO_PRIMARY_CUSTOMER_PROFILE_SID: sid }).twilioPrimaryCustomerProfileSid(),
    sid,
  );
  envError(
    () => testEnv({ TWILIO_PRIMARY_CUSTOMER_PROFILE_SID: "BU1" }).twilioPrimaryCustomerProfileSid(),
    "TWILIO_PRIMARY_CUSTOMER_PROFILE_SID",
    "invalid",
  );
});

Deno.test("env: the public API origin follows FUNCTIONS_PUBLIC_URL", () => {
  assertEquals(testEnv().publicSupabaseUrl(), "https://fake-project.supabase.co");
  assertEquals(
    testEnv({ FUNCTIONS_PUBLIC_URL: "http://127.0.0.1:54321/functions/v1/" }).publicSupabaseUrl(),
    "http://127.0.0.1:54321",
  );
  assertEquals(
    testEnv({ FUNCTIONS_PUBLIC_URL: "https://tunnel.example.com/custom" }).publicSupabaseUrl(),
    "https://fake-project.supabase.co",
  );
});

Deno.test("env: the billing webhook secret is its own whsec_ value, required only when used", () => {
  assertEquals((ENV_NAMES as readonly string[]).includes("STRIPE_BILLING_WEBHOOK_SECRET"), true);
  assertEquals(
    testEnv({ STRIPE_BILLING_WEBHOOK_SECRET: "whsec_Billing0123" }).stripeBillingWebhookSecret(),
    "whsec_Billing0123",
  );
  const missing = assertThrows(() => testEnv().stripeBillingWebhookSecret(), EnvError);
  assertEquals([missing.variable, missing.problem], ["STRIPE_BILLING_WEBHOOK_SECRET", "missing"]);
  const invalid = assertThrows(
    () => testEnv({ STRIPE_BILLING_WEBHOOK_SECRET: "sk_test_nope" }).stripeBillingWebhookSecret(),
    EnvError,
  );
  assertEquals(invalid.problem, "invalid");
  // The Connect secret is untouched by it.
  assertEquals(testEnv().stripeWebhookSecret(), TEST_ENV.STRIPE_WEBHOOK_SECRET);
});

Deno.test("env: BILLING_AUTOMATIC_TAX is off unless exactly true", () => {
  assertEquals(testEnv().billingAutomaticTax(), false);
  assertEquals(testEnv({ BILLING_AUTOMATIC_TAX: "TRUE" }).billingAutomaticTax(), true);
  assertEquals(testEnv({ BILLING_AUTOMATIC_TAX: "yes" }).billingAutomaticTax(), false);
});
