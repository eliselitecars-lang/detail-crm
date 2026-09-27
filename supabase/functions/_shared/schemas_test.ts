import { assertEquals } from "@std/assert";
import {
  e164,
  email,
  nonNegativeCents,
  positiveCents,
  publicToken,
  requestNonce,
  uuid,
} from "./schemas.ts";

Deno.test("schemas: common validators", () => {
  assertEquals(uuid.safeParse("00000000-0000-0000-0000-000000000001").success, true);
  assertEquals(uuid.safeParse("not-a-uuid").success, false);
  assertEquals(positiveCents.safeParse(1).success, true);
  assertEquals(positiveCents.safeParse(0).success, false);
  assertEquals(positiveCents.safeParse(1.5).success, false);
  assertEquals(positiveCents.safeParse(100_000_000).success, false);
  assertEquals(nonNegativeCents.safeParse(0).success, true);
  assertEquals(nonNegativeCents.safeParse(-1).success, false);
  assertEquals(e164.safeParse("+12055550123").success, true);
  assertEquals(e164.safeParse("205-555-0123").success, false);
  assertEquals(email.safeParse("a@example.com").success, true);
  assertEquals(email.safeParse("nope").success, false);
  assertEquals(publicToken.safeParse("5f0c7d2e-8b1a-4c3d-9e4f-0a1b2c3d4e5f").success, true);
  assertEquals(publicToken.safeParse("5F0C7D2E-8B1A-4C3D-9E4F-0A1B2C3D4E5F").success, true);
  // Link tokens are uuid columns: anything else must fail here, not as a 22P02 in Postgres.
  assertEquals(publicToken.safeParse("AAAAAAAAAAAAAAAA").success, false);
  assertEquals(publicToken.safeParse("5f0c7d2e-8b1a-4c3d-9e4f-0a1b2c3d4e5").success, false);
  assertEquals(publicToken.safeParse("5f0c7d2e8b1a4c3d9e4f0a1b2c3d4e5f").success, false);
  assertEquals(publicToken.safeParse("short").success, false);
  assertEquals(publicToken.safeParse("abcdefghijklmnop/..").success, false);
  assertEquals(publicToken.safeParse(42).success, false);
  assertEquals(requestNonce.safeParse("nonce-123").success, true);
  assertEquals(requestNonce.safeParse("x").success, false);
});
