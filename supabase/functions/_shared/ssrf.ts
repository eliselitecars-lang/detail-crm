/**
 * Outbound-request guard for customer-configured URLs (webhook endpoints).
 * A shop admin chooses the URL, so without a guard the platform could be
 * made to POST into its own network (cloud metadata at 169.254.169.254,
 * localhost services, private ranges).
 *
 * Two layers:
 *  1. `checkOutboundUrl` (static): https only, no credentials, a host NAME
 *     (every IP literal is refused, in any form the URL parser accepts:
 *     dotted, octal, hex, IPv6), not localhost / *.localhost / *.local /
 *     *.localdomain / *.internal / *.lan / *.home, no single-label names, no
 *     label that reads as a number. Any port is allowed, as the database's
 *     comms_webhook_url (0089) allows it: the static rules mirror that
 *     function, so an endpoint the database accepted is never refused here
 *     for a reason the admin was not shown when saving it. A port cannot
 *     reach a private network on its own: layer 2 still applies.
 *  2. `checkResolvedAddresses` (dynamic): every A/AAAA address the name
 *     resolves to must be public (not loopback, private, link-local /
 *     metadata, CGNAT, unique-local, multicast, documentation or reserved).
 *
 * Limits: the edge runtime cannot pin the resolved address for the
 * connection, so a name that changes its answer between the check and the
 * request (DNS rebinding) can still reach a private address. Payloads are
 * curated (no secrets or tokens) and responses are ignored, which bounds
 * what such a request can do.
 */

export type GuardResult = { ok: true } | { ok: false; reason: string };

const BLOCKED_SUFFIXES = [".localhost", ".local", ".localdomain", ".internal", ".lan", ".home"];

/** Strict dotted-decimal IPv4 -> 4 octets, else null. */
export function parseIPv4(value: string): number[] | null {
  const parts = value.split(".");
  if (parts.length !== 4) return null;
  const out: number[] = [];
  for (const part of parts) {
    if (!/^\d{1,3}$/.test(part)) return null;
    const n = Number(part);
    if (n > 255) return null;
    out.push(n);
  }
  return out;
}

/** IPv6 text (no brackets, optional embedded IPv4) -> 8 hextets, else null. */
export function parseIPv6(value: string): number[] | null {
  let text = value.toLowerCase();
  const zone = text.indexOf("%");
  if (zone >= 0) text = text.slice(0, zone);
  if (!/^[0-9a-f:.]+$/.test(text) || !text.includes(":")) return null;
  const lastColon = text.lastIndexOf(":");
  const last = text.slice(lastColon + 1);
  if (last.includes(".")) {
    // a.b.c.d in the last 32 bits -> two hex groups
    const v4 = parseIPv4(last);
    if (!v4) return null;
    const [o1 = 0, o2 = 0, o3 = 0, o4 = 0] = v4;
    text = `${text.slice(0, lastColon + 1)}${((o1 << 8) | o2).toString(16)}:${
      ((o3 << 8) | o4).toString(16)
    }`;
  }
  const halves = text.split("::");
  if (halves.length > 2) return null;
  const groups = (part: string): number[] | null => {
    if (part === "") return [];
    const out: number[] = [];
    for (const group of part.split(":")) {
      if (!/^[0-9a-f]{1,4}$/.test(group)) return null;
      out.push(parseInt(group, 16));
    }
    return out;
  };
  const head = groups(halves[0] ?? "");
  const tail = halves.length === 2 ? groups(halves[1] ?? "") : [];
  if (!head || !tail) return null;
  if (halves.length === 1) return head.length === 8 ? head : null;
  const missing = 8 - head.length - tail.length;
  if (missing < 1) return null;
  return [...head, ...new Array<number>(missing).fill(0), ...tail];
}

function inV4(ip: number[], base: [number, number, number, number], bits: number): boolean {
  const toInt = (o: number[]) =>
    (((o[0] ?? 0) << 24) >>> 0) + ((o[1] ?? 0) << 16) + ((o[2] ?? 0) << 8) + (o[3] ?? 0);
  if (bits === 0) return true;
  const mask = bits === 32 ? 0xffffffff : (~0 << (32 - bits)) >>> 0;
  return ((toInt(ip) & mask) >>> 0) === ((toInt(base) & mask) >>> 0);
}

const V4_BLOCKED: Array<[[number, number, number, number], number]> = [
  [[0, 0, 0, 0], 8], // "this network"
  [[10, 0, 0, 0], 8], // private
  [[100, 64, 0, 0], 10], // CGNAT
  [[127, 0, 0, 0], 8], // loopback
  [[169, 254, 0, 0], 16], // link-local, cloud metadata
  [[172, 16, 0, 0], 12], // private
  [[192, 0, 0, 0], 24], // IETF protocol assignments
  [[192, 0, 2, 0], 24], // documentation
  [[192, 88, 99, 0], 24], // 6to4 relay anycast
  [[192, 168, 0, 0], 16], // private
  [[198, 18, 0, 0], 15], // benchmarking
  [[198, 51, 100, 0], 24], // documentation
  [[203, 0, 113, 0], 24], // documentation
  [[224, 0, 0, 0], 4], // multicast
  [[240, 0, 0, 0], 4], // reserved + broadcast
];

function blockedV4(ip: number[]): boolean {
  return V4_BLOCKED.some(([base, bits]) => inV4(ip, base, bits));
}

function blockedV6(h: number[]): boolean {
  const [a = 0, b = 0, c = 0, d = 0, e = 0, f = 0, g = 0, last = 0] = h;
  const embeddedV4 = (hi: number, lo: number) => [hi >> 8, hi & 0xff, lo >> 8, lo & 0xff];
  if (h.every((x) => x === 0)) return true; // ::
  if (a === 0 && b === 0 && c === 0 && d === 0 && e === 0 && f === 0 && g === 0 && last === 1) {
    return true; // ::1
  }
  // IPv4-mapped ::ffff:a.b.c.d and IPv4-compatible ::a.b.c.d
  if (a === 0 && b === 0 && c === 0 && d === 0 && e === 0 && (f === 0xffff || f === 0)) {
    return blockedV4(embeddedV4(g, last));
  }
  if (a === 0x64 && b === 0xff9b) return blockedV4(embeddedV4(g, last)); // NAT64
  if (a === 0x2002) return blockedV4(embeddedV4(b, c)); // 6to4
  if (a === 0x0100 && b === 0 && c === 0 && d === 0) return true; // discard 100::/64
  if (a === 0x2001 && b === 0x0db8) return true; // documentation
  if (a === 0x2001 && b < 0x0200) return true; // IETF protocol assignments (Teredo etc.)
  if ((a & 0xfe00) === 0xfc00) return true; // unique-local fc00::/7
  if ((a & 0xffc0) === 0xfe80) return true; // link-local fe80::/10
  if ((a & 0xffc0) === 0xfec0) return true; // site-local fec0::/10
  if ((a & 0xff00) === 0xff00) return true; // multicast
  return false;
}

/** True for an IP address (v4 or v6 text) the platform must never call. */
export function isBlockedAddress(address: string): boolean {
  const text = address.replace(/^\[|\]$/g, "");
  const v4 = parseIPv4(text);
  if (v4) return blockedV4(v4);
  const v6 = parseIPv6(text);
  if (v6) return blockedV6(v6);
  return true; // not an address we understand: refuse
}

/** Static checks of a customer-configured URL (see the module header). */
export function checkOutboundUrl(raw: string): GuardResult {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    return { ok: false, reason: "the URL is not valid" };
  }
  if (url.protocol !== "https:") return { ok: false, reason: "the URL must use https" };
  if (url.username || url.password) {
    return { ok: false, reason: "the URL must not contain a user name or password" };
  }
  const host = url.hostname.toLowerCase().replace(/\.$/, "");
  if (host.startsWith("[") || parseIPv4(host) || parseIPv6(host)) {
    return { ok: false, reason: "the URL must use a host name, not an IP address" };
  }
  if (host === "localhost" || BLOCKED_SUFFIXES.some((suffix) => host.endsWith(suffix))) {
    return { ok: false, reason: "the URL must use a public host name" };
  }
  const labels = host.split(".");
  if (labels.length < 2 || labels.some((label) => label === "")) {
    return { ok: false, reason: "the URL must use a public host name" };
  }
  if (
    /^\d+$/.test(labels[labels.length - 1] ?? "") ||
    labels.some((label) => /^0x[0-9a-f]*$/i.test(label))
  ) {
    return { ok: false, reason: "the URL must use a host name, not an IP address" };
  }
  return { ok: true };
}

/** Resolves a name to its A and AAAA addresses. Throws when resolution is unavailable. */
export type Resolver = (hostname: string) => Promise<string[]>;

/** Deno.resolveDns-based resolver (A + AAAA). Unsupported runtimes throw. */
export const denoResolver: Resolver = async (hostname: string): Promise<string[]> => {
  const lookups = await Promise.allSettled([
    Deno.resolveDns(hostname, "A"),
    Deno.resolveDns(hostname, "AAAA"),
  ]);
  const addresses: string[] = [];
  for (const lookup of lookups) {
    if (lookup.status === "fulfilled") addresses.push(...lookup.value);
    // NXDOMAIN / no record of that type: not an address; anything else
    // (no DNS in this runtime, permission, timeout) is "cannot tell"
    else if (!(lookup.reason instanceof Deno.errors.NotFound)) throw lookup.reason;
  }
  return addresses;
};

/**
 * Checks what the URL's host resolves to. Returns null (no verdict) when
 * the runtime cannot resolve names, so callers fall back to the static
 * check alone.
 */
export async function checkResolvedAddresses(
  raw: string,
  resolver: Resolver,
): Promise<GuardResult | null> {
  const host = new URL(raw).hostname.replace(/\.$/, "");
  let addresses: string[];
  try {
    addresses = await resolver(host);
  } catch {
    return null;
  }
  if (addresses.length === 0) return { ok: false, reason: "the host name does not resolve" };
  if (addresses.some(isBlockedAddress)) {
    return { ok: false, reason: "the host name resolves to a private or reserved address" };
  }
  return { ok: true };
}
