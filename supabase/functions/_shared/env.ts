/**
 * Typed access to function secrets / environment. Every getter validates the
 * value and throws `EnvError` naming the variable, so a misconfigured deploy
 * fails loudly in the logs (the client only sees `server_misconfigured`).
 *
 * Values are read lazily (per call) so a function only needs the secrets for
 * the code path it actually runs, and tests can inject an `EnvSource`.
 */

export const ENV_NAMES = [
  // Provided automatically by Supabase in hosted + local edge runtime.
  "SUPABASE_URL",
  "SUPABASE_ANON_KEY",
  "SUPABASE_SERVICE_ROLE_KEY",
  // Set with `supabase secrets set`.
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
  // Optional.
  "CORS_ALLOWED_ORIGINS",
  "FUNCTIONS_PUBLIC_URL",
] as const;

export type EnvName = typeof ENV_NAMES[number];

export interface EnvSource {
  get(name: string): string | undefined;
}

/** Reads from the real process environment (requires --allow-env). */
export const denoEnvSource: EnvSource = {
  get: (name) => Deno.env.get(name),
};

/** An EnvSource backed by a plain object (tests, scripts). */
export function envFromRecord(record: Readonly<Record<string, string | undefined>>): EnvSource {
  return { get: (name) => record[name] };
}

export class EnvError extends Error {
  readonly variable: EnvName;
  readonly problem: "missing" | "invalid";

  constructor(variable: EnvName, problem: "missing" | "invalid", detail?: string) {
    super(
      problem === "missing"
        ? `Missing required environment variable ${variable}.`
        : `Invalid environment variable ${variable}${detail ? `: ${detail}` : ""}.`,
    );
    this.name = "EnvError";
    this.variable = variable;
    this.problem = problem;
  }
}

export interface SupabaseEnv {
  url: string;
  anonKey: string;
  serviceRoleKey: string;
}

export interface StripeEnv {
  secretKey: string;
  publishableKey: string;
  livemode: boolean;
}

export interface TwilioEnv {
  accountSid: string;
  authToken: string;
}

export interface ResendEnv {
  apiKey: string;
  from: string;
}

const MIN_CRON_SECRET_LENGTH = 24;

function parseHttpUrl(name: EnvName, raw: string): URL {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    throw new EnvError(name, "invalid", "not a URL");
  }
  if (url.protocol !== "https:" && url.protocol !== "http:") {
    throw new EnvError(name, "invalid", "must be an http(s) URL");
  }
  return url;
}

function stripTrailingSlash(value: string): string {
  return value.replace(/\/+$/, "");
}

export class Env {
  readonly #source: EnvSource;

  constructor(source: EnvSource = denoEnvSource) {
    this.#source = source;
  }

  /** Trimmed value, or undefined when unset/blank. */
  optional(name: EnvName): string | undefined {
    const value = this.#source.get(name)?.trim();
    return value ? value : undefined;
  }

  required(name: EnvName): string {
    const value = this.optional(name);
    if (value === undefined) throw new EnvError(name, "missing");
    return value;
  }

  supabase(): SupabaseEnv {
    const url = parseHttpUrl("SUPABASE_URL", this.required("SUPABASE_URL"));
    return {
      url: stripTrailingSlash(url.toString()),
      anonKey: this.required("SUPABASE_ANON_KEY"),
      serviceRoleKey: this.required("SUPABASE_SERVICE_ROLE_KEY"),
    };
  }

  /**
   * Public base URL of the edge functions (what Stripe/Twilio call). Defaults
   * to `${SUPABASE_URL}/functions/v1`; override with FUNCTIONS_PUBLIC_URL when
   * local dev is exposed through a tunnel.
   */
  functionsPublicUrl(): string {
    const override = this.optional("FUNCTIONS_PUBLIC_URL");
    if (override) {
      return stripTrailingSlash(parseHttpUrl("FUNCTIONS_PUBLIC_URL", override).toString());
    }
    return `${this.supabase().url}/functions/v1`;
  }

  stripe(): StripeEnv {
    const secretKey = this.required("STRIPE_SECRET_KEY");
    const publishableKey = this.required("STRIPE_PUBLISHABLE_KEY");
    const secretMode = /^(sk|rk)_(test|live)_[A-Za-z0-9]+$/.exec(secretKey)?.[2];
    if (!secretMode) {
      throw new EnvError("STRIPE_SECRET_KEY", "invalid", "expected sk_test_/sk_live_/rk_ key");
    }
    const publishableMode = /^pk_(test|live)_[A-Za-z0-9]+$/.exec(publishableKey)?.[1];
    if (!publishableMode) {
      throw new EnvError("STRIPE_PUBLISHABLE_KEY", "invalid", "expected pk_test_/pk_live_ key");
    }
    if (secretMode !== publishableMode) {
      throw new EnvError(
        "STRIPE_PUBLISHABLE_KEY",
        "invalid",
        `publishable key is ${publishableMode} but secret key is ${secretMode}`,
      );
    }
    return { secretKey, publishableKey, livemode: secretMode === "live" };
  }

  stripeWebhookSecret(): string {
    const secret = this.required("STRIPE_WEBHOOK_SECRET");
    if (!/^whsec_[A-Za-z0-9+/=_-]+$/.test(secret)) {
      throw new EnvError("STRIPE_WEBHOOK_SECRET", "invalid", "expected whsec_ secret");
    }
    return secret;
  }

  /** Platform application fee in basis points (0–10000). Unset = 0. */
  platformFeeBps(): number {
    const raw = this.optional("PLATFORM_FEE_BPS");
    if (raw === undefined) return 0;
    if (!/^\d+$/.test(raw)) {
      throw new EnvError("PLATFORM_FEE_BPS", "invalid", "must be a whole number of basis points");
    }
    const bps = Number(raw);
    if (bps > 10_000) throw new EnvError("PLATFORM_FEE_BPS", "invalid", "must be at most 10000");
    return bps;
  }

  twilio(): TwilioEnv {
    const accountSid = this.required("TWILIO_ACCOUNT_SID");
    if (!/^AC[0-9a-fA-F]{32}$/.test(accountSid)) {
      throw new EnvError("TWILIO_ACCOUNT_SID", "invalid", "expected AC followed by 32 hex chars");
    }
    return { accountSid, authToken: this.required("TWILIO_AUTH_TOKEN") };
  }

  resend(): ResendEnv {
    const apiKey = this.required("RESEND_API_KEY");
    if (!apiKey.startsWith("re_")) {
      throw new EnvError("RESEND_API_KEY", "invalid", "expected re_ key");
    }
    const from = this.required("EMAIL_FROM");
    // "Name <addr@domain>" or "addr@domain"
    if (!/^([^<>]+<[^\s<>@]+@[^\s<>@]+\.[^\s<>@]+>|[^\s<>@]+@[^\s<>@]+\.[^\s<>@]+)$/.test(from)) {
      throw new EnvError("EMAIL_FROM", "invalid", 'expected "Name <user@domain>" or an address');
    }
    return { apiKey, from };
  }

  /** Web app origin + path base, without trailing slash (links in SMS/email). */
  appBaseUrl(): string {
    const url = parseHttpUrl("APP_BASE_URL", this.required("APP_BASE_URL"));
    if (url.search || url.hash) {
      throw new EnvError("APP_BASE_URL", "invalid", "must not contain a query or fragment");
    }
    return stripTrailingSlash(url.toString());
  }

  cronSecret(): string {
    const secret = this.required("CRON_SECRET");
    if (secret.length < MIN_CRON_SECRET_LENGTH) {
      throw new EnvError(
        "CRON_SECRET",
        "invalid",
        `must be at least ${MIN_CRON_SECRET_LENGTH} characters`,
      );
    }
    return secret;
  }

  /** Extra browser origins allowed by CORS (comma-separated exact origins). */
  corsExtraOrigins(): string[] {
    const raw = this.optional("CORS_ALLOWED_ORIGINS");
    if (!raw) return [];
    return raw.split(",").map((part) => part.trim()).filter(Boolean).map((part) => {
      const url = parseHttpUrl("CORS_ALLOWED_ORIGINS", part);
      if (url.pathname !== "/" || url.search || url.hash) {
        throw new EnvError("CORS_ALLOWED_ORIGINS", "invalid", `"${part}" is not a bare origin`);
      }
      return url.origin;
    });
  }
}

/** Process-wide Env reading Deno.env. */
export const env: Env = new Env();
