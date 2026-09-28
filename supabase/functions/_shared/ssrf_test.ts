import { assertEquals } from "@std/assert";
import {
  checkOutboundUrl,
  checkResolvedAddresses,
  isBlockedAddress,
  parseIPv4,
  parseIPv6,
} from "./ssrf.ts";

Deno.test("ssrf: address parsing", () => {
  assertEquals(parseIPv4("192.168.1.10"), [192, 168, 1, 10]);
  assertEquals(parseIPv4("256.1.1.1"), null);
  assertEquals(parseIPv4("1.2.3"), null);
  assertEquals(parseIPv6("::1"), [0, 0, 0, 0, 0, 0, 0, 1]);
  assertEquals(parseIPv6("2001:db8::8a2e:370:7334"), [
    0x2001,
    0xdb8,
    0,
    0,
    0,
    0x8a2e,
    0x370,
    0x7334,
  ]);
  assertEquals(parseIPv6("::ffff:127.0.0.1"), [0, 0, 0, 0, 0, 0xffff, 0x7f00, 1]);
  assertEquals(parseIPv6("fe80::1%eth0"), [0xfe80, 0, 0, 0, 0, 0, 0, 1]);
  assertEquals(parseIPv6("1:2:3:4:5:6:7:8:9"), null);
  assertEquals(parseIPv6("1::2::3"), null);
  assertEquals(parseIPv6("example.com"), null);
});

Deno.test("ssrf: private, loopback, link-local, CGNAT, multicast and reserved are blocked", () => {
  for (
    const ip of [
      "0.0.0.0",
      "10.1.2.3",
      "100.64.0.1",
      "100.127.255.255",
      "127.0.0.1",
      "169.254.169.254",
      "172.16.0.1",
      "172.31.255.255",
      "192.168.0.1",
      "192.0.2.5",
      "198.18.0.1",
      "224.0.0.1",
      "255.255.255.255",
      "::",
      "::1",
      "::ffff:10.0.0.1",
      "::ffff:169.254.169.254",
      "64:ff9b::7f00:1",
      "2002:c0a8:0101::1",
      "fc00::1",
      "fd12:3456::1",
      "fe80::1",
      "ff02::1",
      "2001:db8::1",
      "[::1]",
      "not an ip",
    ]
  ) {
    assertEquals(isBlockedAddress(ip), true, ip);
  }
  for (const ip of ["8.8.8.8", "1.1.1.1", "100.128.0.1", "172.32.0.1", "2606:4700::1111"]) {
    assertEquals(isBlockedAddress(ip), false, ip);
  }
});

Deno.test("ssrf: static URL rules mirror the database (https host names only)", () => {
  for (
    const url of [
      "https://hooks.zapier.com/hooks/catch/1/abc/",
      "https://example.com:443/x",
      // the database stores any port, so deliveries must not refuse one
      "https://hooks.example.com:8443/in",
      "https://sub.example.co.uk/path?x=1",
      "https://Example.COM./x",
    ]
  ) {
    assertEquals(checkOutboundUrl(url), { ok: true }, url);
  }
  for (
    const url of [
      "http://example.com/x",
      "https://user:pass@example.com/",
      "https://127.0.0.1:8443/",
      "https://localhost:8080/",
      "https://box.localdomain/",
      "https://127.0.0.1/",
      "https://0x7f000001/",
      "https://2130706433/",
      "https://0177.0.0.1/",
      "https://127.1/",
      "https://[::1]/",
      "https://[fe80::1]/",
      "https://localhost/",
      "https://api.localhost/",
      "https://printer.local/",
      "https://metadata.google.internal/",
      "https://nas.lan/",
      "https://router.home/",
      "https://intranet/",
      "https://0xa.example.com/",
      "not a url",
    ]
  ) {
    assertEquals(checkOutboundUrl(url).ok, false, url);
  }
});

Deno.test("ssrf: resolved addresses must all be public", async () => {
  const resolver = (answers: Record<string, string[]>) => (host: string) =>
    Promise.resolve(answers[host] ?? []);
  assertEquals(
    await checkResolvedAddresses(
      "https://ok.example.com/",
      resolver({ "ok.example.com": ["93.184.216.34", "2606:2800:220:1::1"] }),
    ),
    { ok: true },
  );
  assertEquals(
    (await checkResolvedAddresses(
      "https://rebind.example.com/",
      resolver({ "rebind.example.com": ["93.184.216.34", "169.254.169.254"] }),
    ))?.ok,
    false,
  );
  assertEquals(
    await checkResolvedAddresses("https://nx.example.com/", resolver({})),
    { ok: false, reason: "the host name does not resolve" },
  );
  // A runtime without DNS gives no verdict (the static rules still apply).
  assertEquals(
    await checkResolvedAddresses("https://x.example.com/", () => Promise.reject(new Error("no"))),
    null,
  );
});
