import { assertEquals } from "@std/assert";
import { clientIp, parseIp } from "./client_ip.ts";

function req(headers: Record<string, string>): Request {
  return new Request("https://example.test/", { headers });
}

Deno.test("parseIp: IPv4 and IPv6 addresses only", () => {
  assertEquals(parseIp("203.0.113.7"), "203.0.113.7");
  assertEquals(parseIp(" 203.0.113.7 "), "203.0.113.7");
  assertEquals(parseIp("2001:DB8:0:0::1"), "2001:db8::1");
  assertEquals(parseIp("::ffff:203.0.113.7"), "::ffff:cb00:7107");
  for (
    const bad of [
      "",
      "256.1.1.1",
      "1.2.3",
      "example.com",
      "2001:db8::zz",
      ":::",
      "1.2.3.4/24",
      "fe80::1%eth0",
      null,
    ]
  ) {
    assertEquals(parseIp(bad), null, String(bad));
  }
});

Deno.test("clientIp: cf-connecting-ip, then x-real-ip, then the last x-forwarded-for hop", () => {
  assertEquals(
    clientIp(
      req({
        "cf-connecting-ip": "198.51.100.1",
        "x-real-ip": "198.51.100.2",
        "x-forwarded-for": "1.1.1.1, 198.51.100.3",
      }),
    ),
    "198.51.100.1",
  );
  assertEquals(
    clientIp(req({ "x-real-ip": "198.51.100.2", "x-forwarded-for": "1.1.1.1, 198.51.100.3" })),
    "198.51.100.2",
  );
  assertEquals(
    clientIp(req({ "x-forwarded-for": "1.1.1.1, 198.51.100.3" })),
    "198.51.100.3",
    "never the client-chosen first hop",
  );
  assertEquals(
    clientIp(req({ "cf-connecting-ip": "junk", "x-forwarded-for": "2001:db8::5" })),
    "2001:db8::5",
    "malformed: next source",
  );
  assertEquals(clientIp(req({})), null);
});
