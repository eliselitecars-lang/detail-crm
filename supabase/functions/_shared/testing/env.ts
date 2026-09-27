/** Complete, syntactically valid (but fake) env for tests. */
import { Env, envFromRecord, type EnvSource } from "../env.ts";

export const TEST_ENV: Readonly<Record<string, string>> = {
  SUPABASE_URL: "https://fake-project.supabase.co",
  SUPABASE_ANON_KEY: "fake-anon-key",
  SUPABASE_SERVICE_ROLE_KEY: "fake-service-role-key",
  STRIPE_SECRET_KEY: "sk_test_FakeSecretKey000000000000",
  STRIPE_PUBLISHABLE_KEY: "pk_test_FakePublishableKey00000000",
  STRIPE_WEBHOOK_SECRET: "whsec_FakeWebhookSecret000000000000",
  PLATFORM_FEE_BPS: "0",
  TWILIO_ACCOUNT_SID: "AC00000000000000000000000000000000",
  TWILIO_AUTH_TOKEN: "fake-twilio-auth-token",
  RESEND_API_KEY: "re_FakeResendKey000000",
  EMAIL_FROM: "Detail CRM <notifications@example.com>",
  APP_BASE_URL: "https://app.example.com",
  CRON_SECRET: "fake-cron-secret-0123456789abcdef",
};

/** TEST_ENV with overrides; pass `undefined` to unset a variable. */
export function testEnvSource(overrides: Record<string, string | undefined> = {}): EnvSource {
  return envFromRecord({ ...TEST_ENV, ...overrides });
}

export function testEnv(overrides: Record<string, string | undefined> = {}): Env {
  return new Env(testEnvSource(overrides));
}
