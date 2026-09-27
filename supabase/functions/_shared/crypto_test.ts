import { assert, assertEquals, assertMatch, assertNotEquals, assertThrows } from "@std/assert";
import { hmacBase64, hmacHex, randomToken, sha256Hex, timingSafeEqual } from "./crypto.ts";

Deno.test("crypto: timingSafeEqual", () => {
  assertEquals(timingSafeEqual("abc", "abc"), true);
  assertEquals(timingSafeEqual("abc", "abd"), false);
  assertEquals(timingSafeEqual("abc", "abcd"), false);
  assertEquals(timingSafeEqual("abcd", "abc"), false);
  assertEquals(timingSafeEqual("", ""), true);
  assertEquals(timingSafeEqual("", "a"), false);
  assertEquals(timingSafeEqual(new Uint8Array([1, 2]), new Uint8Array([1, 2])), true);
  assertEquals(timingSafeEqual(new Uint8Array([1, 2]), "\u0001\u0002"), true);
  // A prefix plus a NUL byte must not compare equal to the prefix.
  assertEquals(timingSafeEqual("abc\u0000", "abc"), false);
});

Deno.test("crypto: HMAC test vectors (RFC 2202 / RFC 4231 case 2)", async () => {
  assertEquals(
    await hmacHex("SHA-1", "Jefe", "what do ya want for nothing?"),
    "effcdf6ae5eb2fa2d27416d5f184df9c259a7c79",
  );
  assertEquals(
    await hmacHex("SHA-256", "Jefe", "what do ya want for nothing?"),
    "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
  );
  assertEquals(
    await hmacBase64("SHA-1", "Jefe", "what do ya want for nothing?"),
    "7/zfauXrL6LSdBbV8YTfnCWafHk=",
  );
});

Deno.test("crypto: sha256Hex", async () => {
  assertEquals(
    await sha256Hex("abc"),
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
  );
});

Deno.test("crypto: randomToken is url-safe, sized and unique", () => {
  const a = randomToken();
  assertMatch(a, /^[A-Za-z0-9_-]{43}$/);
  assertNotEquals(a, randomToken());
  assert(randomToken(16).length >= 22);
  assertThrows(() => randomToken(8), RangeError);
});

Deno.test("crypto: hex / base64 / base64url encoders", async () => {
  const { toBase64, toBase64Url, toHex } = await import("./crypto.ts");
  const bytes = new Uint8Array([0, 1, 254, 255, 62, 63]);
  assertEquals(toHex(bytes), "0001feff3e3f");
  assertEquals(toBase64(bytes), "AAH+/z4/");
  assertEquals(toBase64Url(bytes), "AAH-_z4_");
  assertEquals(toBase64(new TextEncoder().encode("f")), "Zg==");
  assertEquals(toBase64Url(new TextEncoder().encode("f")), "Zg");
  const big = new Uint8Array(100_000).fill(65);
  assertEquals(atob(toBase64(big)).length, 100_000);
});
