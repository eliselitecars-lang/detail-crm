/**
 * The visitor's IP address of an incoming request, for the public forms'
 * per-connection abuse limits (migration 0110: membership_join_prepare and
 * gift_card_order_prepare take it as p_client_ip, because the payments
 * function calls them as service_role and the database would otherwise see
 * only this function's own request).
 *
 * The same sources, in the same order, as the database's form_signer_ip()
 * (migration 0020) — never a value the client chose:
 *   1. cf-connecting-ip — set (overwritten) by the edge network in front of
 *      the Supabase gateway;
 *   2. x-real-ip        — set by the gateway from the peer it accepted;
 *   3. the RIGHT-most x-forwarded-for hop — the one the last trusted proxy
 *      appended (earlier hops are whatever the client sent).
 * A header that is present but not a plain IPv4 / IPv6 address is skipped;
 * null when there is none (the database then applies only its per-shop
 * limit).
 */

const IPV4 = /^(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}$/;

/** The address in canonical text form, or null when `value` is not an IP address. */
export function parseIp(value: string | null | undefined): string | null {
  const text = (value ?? "").trim();
  if (!text || text.length > 45) return null;
  if (IPV4.test(text)) return text;
  if (!/^[0-9A-Fa-f:.]+$/.test(text) || !text.includes(":")) return null;
  try {
    // the URL parser validates (and canonicalises) IPv6 literals
    const host = new URL(`http://[${text}]/`).hostname;
    return host.startsWith("[") && host.endsWith("]") ? host.slice(1, -1) : null;
  } catch {
    return null;
  }
}

export function clientIp(req: Request): string | null {
  const forwarded = (req.headers.get("x-forwarded-for") ?? "").split(",");
  const candidates = [
    req.headers.get("cf-connecting-ip"),
    req.headers.get("x-real-ip"),
    forwarded[forwarded.length - 1],
  ];
  for (const candidate of candidates) {
    const ip = parseIp(candidate);
    if (ip) return ip;
  }
  return null;
}
