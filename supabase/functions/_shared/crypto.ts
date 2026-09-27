/**
 * Small WebCrypto helpers shared by webhook verification and token/key
 * generation. Everything here is runtime-agnostic (Deno + edge runtime).
 */

const encoder = new TextEncoder();

export function toHex(bytes: Uint8Array): string {
  let out = "";
  for (const byte of bytes) out += byte.toString(16).padStart(2, "0");
  return out;
}

export function toBase64(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(binary);
}

export function toBase64Url(bytes: Uint8Array): string {
  return toBase64(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export type HmacAlgorithm = "SHA-1" | "SHA-256";

function toBytes(value: string | Uint8Array): Uint8Array<ArrayBuffer> {
  return typeof value === "string" ? encoder.encode(value) : new Uint8Array(value);
}

/**
 * Constant-time equality. The loop always runs over the longer input and the
 * length difference is folded into the result, so timing does not reveal the
 * position of the first mismatching byte.
 */
export function timingSafeEqual(a: string | Uint8Array, b: string | Uint8Array): boolean {
  const left = toBytes(a);
  const right = toBytes(b);
  const length = Math.max(left.length, right.length);
  let diff = left.length ^ right.length;
  for (let i = 0; i < length; i++) {
    diff |= (left[i] ?? 0) ^ (right[i] ?? 0);
  }
  return diff === 0;
}

export async function hmac(
  algorithm: HmacAlgorithm,
  key: string | Uint8Array,
  data: string | Uint8Array,
): Promise<Uint8Array> {
  const cryptoKey = await crypto.subtle.importKey(
    "raw",
    toBytes(key),
    { name: "HMAC", hash: algorithm },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    "HMAC",
    cryptoKey,
    toBytes(data),
  );
  return new Uint8Array(signature);
}

export async function hmacBase64(
  algorithm: HmacAlgorithm,
  key: string | Uint8Array,
  data: string | Uint8Array,
): Promise<string> {
  return toBase64(await hmac(algorithm, key, data));
}

export async function hmacHex(
  algorithm: HmacAlgorithm,
  key: string | Uint8Array,
  data: string | Uint8Array,
): Promise<string> {
  return toHex(await hmac(algorithm, key, data));
}

export async function sha256Hex(data: string | Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", toBytes(data));
  return toHex(new Uint8Array(digest));
}

/** Cryptographically random URL-safe token (default 32 bytes = 256 bits). */
export function randomToken(bytes = 32): string {
  if (!Number.isInteger(bytes) || bytes < 16 || bytes > 1024) {
    throw new RangeError("randomToken: bytes must be an integer between 16 and 1024");
  }
  return toBase64Url(crypto.getRandomValues(new Uint8Array(bytes)));
}
