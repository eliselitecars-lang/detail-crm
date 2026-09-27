/**
 * Stripe (Connect, direct charges). The platform key creates objects ON the
 * shop's connected account by passing `{ stripeAccount }` per request — see
 * `onAccount`. Card data never touches our servers or database; we only store
 * Stripe ids, brand and last4.
 */
import Stripe from "stripe";
import { sha256Hex } from "./crypto.ts";
import { type Env, env as defaultEnv } from "./env.ts";
import { HttpError } from "./errors.ts";
import { isStripeAccountId } from "./ids.ts";

export { Stripe };

/**
 * Pinned API version. Changing it changes webhook payload shapes, so bump it
 * together with the SDK, review the Stripe changelog, and update the Connect
 * webhook endpoint's version in the Dashboard at the same time.
 */
export const STRIPE_API_VERSION = "2026-08-26.dahlia" as const;

export interface StripeFactoryOptions {
  /** Injected fetch (tests). */
  fetch?: typeof fetch;
  /** Default 2; tests pass 0 so fake failures surface immediately. */
  maxNetworkRetries?: number;
  timeoutMs?: number;
}

export function createStripe(secretKey: string, options: StripeFactoryOptions = {}): Stripe {
  return new Stripe(secretKey, {
    apiVersion: STRIPE_API_VERSION,
    httpClient: Stripe.createFetchHttpClient(options.fetch),
    maxNetworkRetries: options.maxNetworkRetries ?? 2,
    timeout: options.timeoutMs ?? 20_000,
    telemetry: false,
    appInfo: { name: "Detail CRM" },
  });
}

let sharedStripe: Stripe | undefined;

/** Stripe client from STRIPE_SECRET_KEY (cached for the process env). */
export function stripeFromEnv(env: Env = defaultEnv, options: StripeFactoryOptions = {}): Stripe {
  const custom = env !== defaultEnv ||
    Object.values(options).some((value) => value !== undefined);
  if (!custom && sharedStripe) return sharedStripe;
  const client = createStripe(env.stripe().secretKey, options);
  if (!custom) sharedStripe = client;
  return client;
}

/**
 * Request options that run a call on a shop's connected account, e.g.
 * `stripe.paymentIntents.create(params, onAccount(acct, { idempotencyKey }))`.
 */
export function onAccount(
  accountId: string,
  options: { idempotencyKey?: string } = {},
): Stripe.RequestOptions {
  if (!isStripeAccountId(accountId)) {
    throw new Error("onAccount: invalid Stripe connected account id");
  }
  return {
    stripeAccount: accountId,
    ...(options.idempotencyKey ? { idempotencyKey: options.idempotencyKey } : {}),
  };
}

/** Stripe allows idempotency keys up to 255 characters. */
const MAX_IDEMPOTENCY_KEY_LENGTH = 255;

/**
 * Deterministic idempotency key: `dcrm:<scope>:<sha256(parts)>`. Include
 * everything that makes the operation unique — e.g. invoice id, amount and a
 * client-supplied request nonce for user-initiated charges — so a retry of the
 * same request reuses the key while a genuinely new charge does not.
 */
export async function idempotencyKey(
  scope: string,
  ...parts: ReadonlyArray<string | number>
): Promise<string> {
  if (!/^[a-z][a-z0-9_.-]{0,63}$/.test(scope)) {
    throw new Error("idempotencyKey: scope must be a short lowercase identifier");
  }
  if (parts.length === 0) throw new Error("idempotencyKey: at least one part is required");
  const encoded = parts.map((part) => {
    if (typeof part === "number" && !Number.isFinite(part)) {
      throw new Error("idempotencyKey: numeric parts must be finite");
    }
    const text = String(part);
    // Length-prefix each part so ("ab","c") and ("a","bc") never collide.
    return `${text.length}:${text}`;
  });
  const key = `dcrm:${scope}:${await sha256Hex(encoded.join("|"))}`;
  if (key.length > MAX_IDEMPOTENCY_KEY_LENGTH) throw new Error("idempotencyKey: key too long");
  return key;
}

export const stripeCryptoProvider: Stripe.CryptoProvider = Stripe.createSubtleCryptoProvider();

/** Default signature tolerance (seconds) — Stripe's recommended 5 minutes. */
export const WEBHOOK_TOLERANCE_SECONDS = 300;

/**
 * Verifies a Stripe webhook signature over the RAW request body and returns
 * the parsed event. Throws `invalid_signature` (400) on any failure so Stripe
 * surfaces the problem in the Dashboard; the reason is only logged.
 */
export async function verifyStripeWebhook(
  stripe: Stripe,
  rawBody: string,
  signatureHeader: string | null,
  secret: string,
  toleranceSeconds = WEBHOOK_TOLERANCE_SECONDS,
): Promise<Stripe.Event> {
  if (!signatureHeader) {
    throw new HttpError("invalid_signature", "Missing Stripe-Signature header.");
  }
  try {
    return await stripe.webhooks.constructEventAsync(
      rawBody,
      signatureHeader,
      secret,
      toleranceSeconds,
      stripeCryptoProvider,
    );
  } catch (cause) {
    throw new HttpError("invalid_signature", "Invalid Stripe signature.", { cause });
  }
}

/** The connected account an event belongs to (Connect events), if any. */
export function eventAccount(event: Pick<Stripe.Event, "account">): string | null {
  return typeof event.account === "string" && isStripeAccountId(event.account)
    ? event.account
    : null;
}
