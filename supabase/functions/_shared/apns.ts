/**
 * Apple Push Notification service (APNs) over its HTTP/2 provider API with
 * token-based authentication (no certificates):
 *
 *   POST https://api.push.apple.com/3/device/<device token>          (production)
 *   POST https://api.sandbox.push.apple.com/3/device/<device token>  (development builds)
 *   authorization: bearer <provider JWT>
 *   apns-topic: <bundle id>   apns-push-type: alert   apns-priority: 10
 *   apns-expiration: <unix seconds>
 *
 * The provider JWT is ES256 over {alg: "ES256", kid: APNS_KEY_ID} /
 * {iss: APNS_TEAM_ID, iat}, signed with the .p8 auth key through WebCrypto
 * (the raw r||s signature WebCrypto produces is exactly what JWS ES256
 * wants). Apple accepts a token for up to an hour and throttles refreshes
 * more often than every 20 minutes, so it is cached for 50 minutes.
 *
 * `fetch` negotiates HTTP/2 through ALPN, which APNs requires. Every
 * request is capped (APNS_REQUEST_TIMEOUT_MS, or less when the caller's run
 * deadline is nearer): a stalled connection comes back as a "retry" instead
 * of hanging the worker with its claimed notifications.
 */
import { toBase64Url } from "./crypto.ts";
import type { ApnsEnv } from "./env.ts";
import { FetchTimeoutError, withTimeout } from "./fetch_timeout.ts";

export const APNS_HOSTS = {
  production: "https://api.push.apple.com",
  sandbox: "https://api.sandbox.push.apple.com",
} as const;

export type ApnsEnvironment = keyof typeof APNS_HOSTS;

/** Provider tokens are reused for this long (Apple: 20-60 minutes). */
export const PROVIDER_TOKEN_TTL_MS = 50 * 60 * 1000;

/** How long APNs keeps trying to reach an offline device. */
export const DEFAULT_EXPIRATION_SECONDS = 3600;

/** Cap on one APNs request, response included. */
export const APNS_REQUEST_TIMEOUT_MS = 10_000;

/** Apple's limit for a regular notification payload. */
export const MAX_PAYLOAD_BYTES = 4096;

const encoder = new TextEncoder();

/** The DER body of a PKCS#8 PEM ("-----BEGIN PRIVATE KEY-----"). */
export function pemToPkcs8(pem: string): Uint8Array<ArrayBuffer> {
  const body = pem
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\s+/g, "");
  if (body === "" || !/^[A-Za-z0-9+/]+={0,2}$/.test(body)) {
    throw new TypeError("the APNs key is not a base64 PEM");
  }
  const binary = atob(body);
  const out = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
  return out;
}

function base64UrlJson(value: unknown): string {
  return toBase64Url(encoder.encode(JSON.stringify(value)));
}

/**
 * Mints and caches the provider JWT. One signer per process: the key import
 * and signature run once per TTL, not per push.
 */
export class ApnsTokenSigner {
  readonly #env: ApnsEnv;
  readonly #clock: () => number;
  #key: Promise<CryptoKey> | undefined;
  #cached: { token: string; issuedAt: number } | undefined;

  constructor(env: ApnsEnv, clock: () => number = Date.now) {
    this.#env = env;
    this.#clock = clock;
  }

  /** True when this signer was built for the same credentials. */
  matches(env: ApnsEnv): boolean {
    return env.keyId === this.#env.keyId && env.teamId === this.#env.teamId &&
      env.privateKeyPem === this.#env.privateKeyPem;
  }

  #importKey(): Promise<CryptoKey> {
    this.#key ??= crypto.subtle.importKey(
      "pkcs8",
      pemToPkcs8(this.#env.privateKeyPem),
      { name: "ECDSA", namedCurve: "P-256" },
      false,
      ["sign"],
    ).catch((err) => {
      this.#key = undefined;
      throw new TypeError("the APNs key could not be imported (expected an ES256 .p8 key)", {
        cause: err,
      });
    });
    return this.#key;
  }

  /** A provider token, reused until it is PROVIDER_TOKEN_TTL_MS old. */
  async token(): Promise<string> {
    const now = this.#clock();
    if (this.#cached && now - this.#cached.issuedAt < PROVIDER_TOKEN_TTL_MS) {
      return this.#cached.token;
    }
    const key = await this.#importKey();
    const header = base64UrlJson({ alg: "ES256", kid: this.#env.keyId });
    const claims = base64UrlJson({ iss: this.#env.teamId, iat: Math.floor(now / 1000) });
    const signingInput = `${header}.${claims}`;
    const signature = await crypto.subtle.sign(
      { name: "ECDSA", hash: "SHA-256" },
      key,
      encoder.encode(signingInput),
    );
    const token = `${signingInput}.${toBase64Url(new Uint8Array(signature))}`;
    this.#cached = { token, issuedAt: now };
    return token;
  }

  /** Drops the cached token (APNs answered ExpiredProviderToken). */
  invalidate(): void {
    this.#cached = undefined;
  }
}

export interface ApnsRequest {
  /** Hex device token (as registered by the app). */
  deviceToken: string;
  environment: ApnsEnvironment;
  topic: string;
  payload: Record<string, unknown>;
  /** Unix seconds after which APNs stops trying (default now + 1 h). */
  expiration?: number;
  /** 10 = immediate (alerts), 5 = power-considerate. */
  priority?: 5 | 10;
  collapseId?: string;
}

export type ApnsResult =
  /** Accepted by APNs. */
  | { status: "sent"; apnsId: string | null }
  /** The token is no longer valid for this app: stop using it. */
  | { status: "invalid_token"; reason: string; httpStatus: number }
  /** Transient (network, throttling, APNs outage, provider token): try again later. */
  | { status: "retry"; reason: string; httpStatus: number | null }
  /** Permanent for this notification (payload/topic problems): do not retry. */
  | { status: "failed"; reason: string; httpStatus: number };

/** APNs 400 reasons that mean the device token itself is unusable. */
export const INVALID_TOKEN_REASONS: ReadonlySet<string> = new Set([
  "BadDeviceToken",
  "DeviceTokenNotForTopic",
  "Unregistered",
]);

/** 403 reasons about the provider token (credentials), never about the device. */
const PROVIDER_TOKEN_REASONS: ReadonlySet<string> = new Set([
  "ExpiredProviderToken",
  "InvalidProviderToken",
  "MissingProviderToken",
]);

const HEX_TOKEN = /^[0-9a-fA-F]{64,200}$/;

async function reasonOf(response: Response): Promise<string> {
  const body = await response.json().catch(() => null) as { reason?: unknown } | null;
  return typeof body?.reason === "string" ? body.reason : `HTTP ${response.status}`;
}

export interface ApnsTransport {
  /** Cap on each request (default APNS_REQUEST_TIMEOUT_MS). */
  timeoutMs?: number;
  /**
   * Milliseconds left before the caller's own deadline; a request never
   * runs past it, and none starts once it is reached (answered "retry").
   */
  remainingMs?: () => number;
}

/**
 * Sends one notification to one device. Never throws for provider answers,
 * network errors or timeouts; they come back classified (see ApnsResult). An
 * ExpiredProviderToken answer refreshes the provider token and retries once.
 */
export async function sendApns(
  fetchFn: typeof fetch,
  signer: ApnsTokenSigner,
  request: ApnsRequest,
  now: () => number = Date.now,
  transport: ApnsTransport = {},
): Promise<ApnsResult> {
  if (!HEX_TOKEN.test(request.deviceToken)) {
    return { status: "invalid_token", reason: "malformed device token", httpStatus: 400 };
  }
  const body = JSON.stringify(request.payload);
  if (encoder.encode(body).byteLength > MAX_PAYLOAD_BYTES) {
    return { status: "failed", reason: "PayloadTooLarge", httpStatus: 413 };
  }
  const url = `${APNS_HOSTS[request.environment]}/3/device/${request.deviceToken.toLowerCase()}`;
  const expiration = request.expiration ??
    Math.floor(now() / 1000) + DEFAULT_EXPIRATION_SECONDS;

  for (let attempt = 1; attempt <= 2; attempt++) {
    let jwt: string;
    try {
      jwt = await signer.token();
    } catch (err) {
      return {
        status: "retry",
        reason: err instanceof Error ? err.message : "provider token unavailable",
        httpStatus: null,
      };
    }
    const headers: Record<string, string> = {
      authorization: `bearer ${jwt}`,
      "apns-topic": request.topic,
      "apns-push-type": "alert",
      "apns-priority": String(request.priority ?? 10),
      "apns-expiration": String(expiration),
      "content-type": "application/json",
    };
    if (request.collapseId) headers["apns-collapse-id"] = request.collapseId.slice(0, 64);

    const limit = Math.min(
      transport.timeoutMs ?? APNS_REQUEST_TIMEOUT_MS,
      transport.remainingMs?.() ?? Infinity,
    );
    if (!(limit >= 1)) {
      return { status: "retry", reason: "the run's time budget is used up", httpStatus: null };
    }
    let response: Response;
    try {
      response = await withTimeout(fetchFn, Math.floor(limit))(url, {
        method: "POST",
        headers,
        body,
      });
    } catch (err) {
      if (err instanceof FetchTimeoutError) {
        return {
          status: "retry",
          reason: `timeout: no answer from APNs within ${err.timeoutMs} ms`,
          httpStatus: null,
        };
      }
      return {
        status: "retry",
        reason: err instanceof Error ? `network: ${err.message}` : "network error",
        httpStatus: null,
      };
    }

    if (response.status === 200) {
      await response.body?.cancel();
      return { status: "sent", apnsId: response.headers.get("apns-id") };
    }
    const reason = await reasonOf(response);
    if (response.status === 410 || (response.status === 400 && INVALID_TOKEN_REASONS.has(reason))) {
      return { status: "invalid_token", reason, httpStatus: response.status };
    }
    if (response.status === 403 && reason === "ExpiredProviderToken" && attempt === 1) {
      signer.invalidate();
      continue;
    }
    if (response.status === 403 && PROVIDER_TOKEN_REASONS.has(reason)) {
      return { status: "retry", reason, httpStatus: response.status };
    }
    if (response.status === 429 || response.status >= 500) {
      return { status: "retry", reason, httpStatus: response.status };
    }
    return { status: "failed", reason, httpStatus: response.status };
  }
  return { status: "retry", reason: "ExpiredProviderToken", httpStatus: 403 };
}
