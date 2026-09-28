import { assertEquals, assertThrows } from "@std/assert";
import { hmacHex } from "./crypto.ts";
import { computeSignature, signatureHeader, verifySignatureHeader } from "./webhook_sign.ts";

const SECRET = "whsec_0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
const BODY = '{"id":"evt_1","event":"test"}';
const T = 1_760_000_000;
// python3: hmac.new(SECRET.encode(), b"1760000000." + BODY.encode(), hashlib.sha256).hexdigest()
const KNOWN = "eb8daea4fc08e983a7bdf1c63f9989f7b3e5a1dc960a1d3d1a9876595e91bd9b";

Deno.test("webhook_sign: HMAC-SHA256 and the header match known vectors", async () => {
  assertEquals(
    await hmacHex("SHA-256", "key", "The quick brown fox jumps over the lazy dog"),
    "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8",
  );
  assertEquals(await computeSignature(SECRET, T, BODY), KNOWN);
  assertEquals(await signatureHeader(SECRET, T, BODY), `t=${T},v1=${KNOWN}`);
  assertThrows(() => computeSignature(SECRET, 1.5, BODY), RangeError);
});

Deno.test("webhook_sign: verification accepts the signature within the tolerance only", async () => {
  const header = `t=${T},v1=${KNOWN}`;
  assertEquals(await verifySignatureHeader(SECRET, header, BODY, { now: T + 10 }), true);
  assertEquals(await verifySignatureHeader(SECRET, header, BODY, { now: T + 301 }), false);
  assertEquals(await verifySignatureHeader(SECRET, header, BODY, { now: T - 301 }), false);
  assertEquals(await verifySignatureHeader(SECRET, header, `${BODY} `, { now: T }), false);
  assertEquals(await verifySignatureHeader(`${SECRET}0`, header, BODY, { now: T }), false);
  assertEquals(await verifySignatureHeader(SECRET, null, BODY, { now: T }), false);
  assertEquals(await verifySignatureHeader(SECRET, `v1=${KNOWN}`, BODY, { now: T }), false);
  assertEquals(await verifySignatureHeader(SECRET, `t=${T}`, BODY, { now: T }), false);
  // Any matching v1 entry is accepted (secret rotation on the receiver side).
  assertEquals(
    await verifySignatureHeader(SECRET, `t=${T},v1=${"0".repeat(64)},v1=${KNOWN}`, BODY, {
      now: T,
    }),
    true,
  );
});
