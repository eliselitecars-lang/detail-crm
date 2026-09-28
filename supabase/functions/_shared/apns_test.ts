import { assert, assertEquals, assertMatch, assertRejects } from "@std/assert";
import {
  APNS_HOSTS,
  ApnsTokenSigner,
  pemToPkcs8,
  PROVIDER_TOKEN_TTL_MS,
  sendApns,
} from "./apns.ts";
import { toBase64 } from "./crypto.ts";
import type { ApnsEnv } from "./env.ts";
import { FakeFetch, jsonResponse } from "./testing/fake_fetch.ts";
import { apnsTestKey } from "./testing/apns.ts";

const DEVICE = "a".repeat(64);

function decodeSegment(segment: string): unknown {
  const b64 = segment.replace(/-/g, "+").replace(/_/g, "/");
  return JSON.parse(atob(b64 + "=".repeat((4 - (b64.length % 4)) % 4)));
}

function base64UrlToBytes(segment: string): Uint8Array<ArrayBuffer> {
  const b64 = segment.replace(/-/g, "+").replace(/_/g, "/");
  const binary = atob(b64 + "=".repeat((4 - (b64.length % 4)) % 4));
  return Uint8Array.from(binary, (c) => c.charCodeAt(0));
}

async function signerFixture(clock: () => number = () => 1_760_000_000_000) {
  const key = await apnsTestKey();
  const env: ApnsEnv = {
    keyId: "ABC123DEFG",
    teamId: "TEAM123456",
    privateKeyPem: key.pem,
    topic: "com.example.detailcrm",
  };
  return { env, key, signer: new ApnsTokenSigner(env, clock) };
}

Deno.test("apns: pemToPkcs8 reads the .p8 body and rejects garbage", () => {
  const der = pemToPkcs8(
    `-----BEGIN PRIVATE KEY-----\n${
      toBase64(new Uint8Array([1, 2, 3]))
    }\n-----END PRIVATE KEY-----`,
  );
  assertEquals([...der], [1, 2, 3]);
  let threw = false;
  try {
    pemToPkcs8("-----BEGIN PRIVATE KEY-----\n***\n-----END PRIVATE KEY-----");
  } catch {
    threw = true;
  }
  assert(threw);
});

Deno.test("apns: the provider token is an ES256 JWT that verifies with the key", async () => {
  const { signer, key } = await signerFixture();
  const token = await signer.token();
  const [header, claims, signature] = token.split(".");
  assert(header && claims && signature);
  assertEquals(decodeSegment(header), { alg: "ES256", kid: "ABC123DEFG" });
  assertEquals(decodeSegment(claims), { iss: "TEAM123456", iat: 1_760_000_000 });
  const raw = base64UrlToBytes(signature);
  assertEquals(raw.byteLength, 64); // JWS ES256: raw r||s, not DER
  const ok = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    key.publicKey,
    raw,
    new TextEncoder().encode(`${header}.${claims}`),
  );
  assert(ok);
});

Deno.test("apns: the provider token is cached for 50 minutes, then re-minted", async () => {
  let now = 1_760_000_000_000;
  const { signer } = await signerFixture(() => now);
  const first = await signer.token();
  now += PROVIDER_TOKEN_TTL_MS - 1;
  assertEquals(await signer.token(), first);
  now += 1;
  const second = await signer.token();
  assert(second !== first);
  signer.invalidate();
  assertEquals((await signer.token()).split(".").length, 3);
});

Deno.test("apns: a key that is not a P-256 PKCS#8 key fails clearly", async () => {
  const signer = new ApnsTokenSigner({
    keyId: "ABC123DEFG",
    teamId: "TEAM123456",
    privateKeyPem: `-----BEGIN PRIVATE KEY-----\n${
      toBase64(new Uint8Array(40))
    }\n-----END PRIVATE KEY-----`,
    topic: "com.example.app",
  });
  await assertRejects(() => signer.token(), TypeError, "could not be imported");
});

Deno.test("apns: sends to the environment's host with the provider headers", async () => {
  const { signer } = await signerFixture();
  const http = new FakeFetch();
  http.on("POST", `${APNS_HOSTS.sandbox}/3/device/:token`, () =>
    new Response(null, {
      status: 200,
      headers: { "apns-id": "11111111-2222-3333-4444-555555555555" },
    }));
  const result = await sendApns(http.fetch, signer, {
    deviceToken: DEVICE.toUpperCase(),
    environment: "sandbox",
    topic: "com.example.detailcrm",
    payload: { aps: { alert: { title: "Hi" } } },
  }, () => 1_760_000_000_000);
  assertEquals(result, { status: "sent", apnsId: "11111111-2222-3333-4444-555555555555" });
  const call = http.calls[0];
  assert(call);
  assertEquals(call.url.pathname, `/3/device/${DEVICE}`);
  assertMatch(call.headers.get("authorization") ?? "", /^bearer [\w-]+\.[\w-]+\.[\w-]+$/);
  assertEquals(call.headers.get("apns-topic"), "com.example.detailcrm");
  assertEquals(call.headers.get("apns-push-type"), "alert");
  assertEquals(call.headers.get("apns-priority"), "10");
  assertEquals(call.headers.get("apns-expiration"), String(1_760_000_000 + 3600));
  assertEquals(call.json, { aps: { alert: { title: "Hi" } } });
});

Deno.test("apns: answers are classified (invalid token, retry, failed)", async () => {
  const { signer } = await signerFixture();
  const cases: Array<[number, string, string]> = [
    [410, "Unregistered", "invalid_token"],
    [400, "BadDeviceToken", "invalid_token"],
    [400, "DeviceTokenNotForTopic", "invalid_token"],
    [400, "BadTopic", "failed"],
    [413, "PayloadTooLarge", "failed"],
    [403, "InvalidProviderToken", "retry"],
    [429, "TooManyRequests", "retry"],
    [500, "InternalServerError", "retry"],
    [503, "ServiceUnavailable", "retry"],
  ];
  for (const [status, reason, expected] of cases) {
    const http = new FakeFetch();
    http.on(
      "POST",
      `${APNS_HOSTS.production}/3/device/:token`,
      () => jsonResponse({ reason }, status),
    );
    const result = await sendApns(http.fetch, signer, {
      deviceToken: DEVICE,
      environment: "production",
      topic: "com.example.detailcrm",
      payload: {},
    });
    assertEquals(result.status, expected, `${status} ${reason}`);
    if (result.status !== "sent") assertEquals(result.reason, reason);
  }
});

Deno.test("apns: a network error is a retry; a malformed token never reaches APNs", async () => {
  const { signer } = await signerFixture();
  const http = new FakeFetch();
  http.on("POST", `${APNS_HOSTS.production}/3/device/:token`, () => {
    throw new TypeError("connection reset");
  });
  const net = await sendApns(http.fetch, signer, {
    deviceToken: DEVICE,
    environment: "production",
    topic: "t.t",
    payload: {},
  });
  assertEquals(net.status, "retry");
  const bad = await sendApns(http.fetch, signer, {
    deviceToken: "not-hex",
    environment: "production",
    topic: "t.t",
    payload: {},
  });
  assertEquals(bad.status, "invalid_token");
  assertEquals(http.calls.length, 1);
});

Deno.test("apns: a stalled request times out as a retry; none starts past the caller's deadline", async () => {
  const { signer } = await signerFixture();
  const http = new FakeFetch();
  http.on(
    "POST",
    `${APNS_HOSTS.production}/3/device/:token`,
    () => new Promise<Response>(() => {}),
  );
  const request = {
    deviceToken: DEVICE,
    environment: "production" as const,
    topic: "t.t",
    payload: {},
  };
  const started = performance.now();
  const hung = await sendApns(http.fetch, signer, request, Date.now, { timeoutMs: 30 });
  assert(performance.now() - started < 5_000);
  assertEquals(hung, {
    status: "retry",
    reason: "timeout: no answer from APNs within 30 ms",
    httpStatus: null,
  });
  // the nearer run deadline wins over the per-request cap
  const near = await sendApns(http.fetch, signer, request, Date.now, {
    timeoutMs: 60_000,
    remainingMs: () => 25,
  });
  assertEquals(near.status, "retry");
  assertEquals((near as { reason: string }).reason, "timeout: no answer from APNs within 25 ms");
  const calls = http.calls.length;
  const late = await sendApns(http.fetch, signer, request, Date.now, { remainingMs: () => 0 });
  assertEquals(late, {
    status: "retry",
    reason: "the run's time budget is used up",
    httpStatus: null,
  });
  assertEquals(http.calls.length, calls);
});

Deno.test("apns: ExpiredProviderToken re-mints the token and retries once", async () => {
  let now = 1_760_000_000_000;
  const { signer } = await signerFixture(() => now);
  const http = new FakeFetch();
  let calls = 0;
  http.on("POST", `${APNS_HOSTS.production}/3/device/:token`, () => {
    calls += 1;
    now += 1000;
    return calls === 1
      ? jsonResponse({ reason: "ExpiredProviderToken" }, 403)
      : new Response(null, { status: 200 });
  });
  const result = await sendApns(http.fetch, signer, {
    deviceToken: DEVICE,
    environment: "production",
    topic: "t.t",
    payload: {},
  });
  assertEquals(result.status, "sent");
  assertEquals(calls, 2);
  const [first, second] = http.calls.map((c) => c.headers.get("authorization"));
  assert(first !== second);
});

Deno.test("apns: an oversized payload is refused before sending", async () => {
  const { signer } = await signerFixture();
  const http = new FakeFetch();
  const result = await sendApns(http.fetch, signer, {
    deviceToken: DEVICE,
    environment: "production",
    topic: "t.t",
    payload: { big: "x".repeat(5000) },
  });
  assertEquals(result.status, "failed");
  assertEquals(http.calls.length, 0);
});
