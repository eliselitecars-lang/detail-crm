/** A freshly generated APNs-style ES256 key (PKCS#8 PEM) for tests. */
import { toBase64 } from "../crypto.ts";

export interface ApnsTestKey {
  pem: string;
  publicKey: CryptoKey;
}

export async function apnsTestKey(): Promise<ApnsTestKey> {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, [
    "sign",
    "verify",
  ]);
  const der = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  const body = toBase64(der).replace(/(.{64})/g, "$1\n").trim();
  return {
    pem: `-----BEGIN PRIVATE KEY-----\n${body}\n-----END PRIVATE KEY-----`,
    publicKey: pair.publicKey,
  };
}
