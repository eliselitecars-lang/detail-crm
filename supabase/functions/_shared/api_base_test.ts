import { assertEquals, assertThrows } from "@std/assert";
import {
  apiBaseFromEnv,
  DEFAULT_RESEND_API_BASE,
  DEFAULT_STRIPE_API_BASE,
  DEFAULT_TWILIO_API_BASE,
  stripeHostOptions,
} from "./api_base.ts";
import { RESEND_API_URL } from "./resend.ts";
import { TWILIO_API_BASE } from "./twilio.ts";

const from = (record: Record<string, string>) => (name: string) => record[name];

Deno.test("api_base: unset or blank falls back to the real provider host", () => {
  assertEquals(
    apiBaseFromEnv("TWILIO_API_BASE", DEFAULT_TWILIO_API_BASE, from({})),
    DEFAULT_TWILIO_API_BASE,
  );
  assertEquals(
    apiBaseFromEnv("RESEND_API_BASE", DEFAULT_RESEND_API_BASE, from({ RESEND_API_BASE: "  " })),
    DEFAULT_RESEND_API_BASE,
  );
  assertEquals(stripeHostOptions(from({})), {});
});

Deno.test("api_base: overrides are trimmed and lose trailing slashes", () => {
  assertEquals(
    apiBaseFromEnv(
      "TWILIO_API_BASE",
      DEFAULT_TWILIO_API_BASE,
      from({ TWILIO_API_BASE: " http://host.docker.internal:12112/2010-04-01/ " }),
    ),
    "http://host.docker.internal:12112/2010-04-01",
  );
});

Deno.test("api_base: invalid overrides throw, naming the variable", () => {
  assertThrows(
    () =>
      apiBaseFromEnv("RESEND_API_BASE", DEFAULT_RESEND_API_BASE, from({ RESEND_API_BASE: "nope" })),
    Error,
    "RESEND_API_BASE",
  );
  assertThrows(
    () =>
      apiBaseFromEnv(
        "RESEND_API_BASE",
        DEFAULT_RESEND_API_BASE,
        from({ RESEND_API_BASE: "ftp://x" }),
      ),
    Error,
    "RESEND_API_BASE",
  );
  assertThrows(
    () =>
      apiBaseFromEnv(
        "TWILIO_API_BASE",
        DEFAULT_TWILIO_API_BASE,
        from({ TWILIO_API_BASE: "http://x/?a=1" }),
      ),
    Error,
    "TWILIO_API_BASE",
  );
  assertThrows(
    () => stripeHostOptions(from({ STRIPE_API_BASE: "http://localhost:12111/v1" })),
    Error,
    "path",
  );
});

Deno.test("api_base: STRIPE_API_BASE maps to Stripe SDK host/port/protocol", () => {
  assertEquals(stripeHostOptions(from({ STRIPE_API_BASE: "http://host.docker.internal:12111" })), {
    host: "host.docker.internal",
    port: 12111,
    protocol: "http",
  });
  assertEquals(stripeHostOptions(from({ STRIPE_API_BASE: "https://stripe.local" })), {
    host: "stripe.local",
    port: 443,
    protocol: "https",
  });
  assertEquals(stripeHostOptions(from({ STRIPE_API_BASE: `${DEFAULT_STRIPE_API_BASE}/` })), {});
});

Deno.test("api_base: without overrides the provider modules use the real hosts", () => {
  // The unit-test process never sets the overrides (the harness only sets them
  // for `supabase functions serve`).
  assertEquals(Deno.env.get("TWILIO_API_BASE"), undefined);
  assertEquals(Deno.env.get("RESEND_API_BASE"), undefined);
  assertEquals(TWILIO_API_BASE, "https://api.twilio.com/2010-04-01");
  assertEquals(RESEND_API_URL, "https://api.resend.com/emails");
});
