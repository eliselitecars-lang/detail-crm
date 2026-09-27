/**
 * Email sender helpers shared by the messaging and invites functions.
 *
 * Every email goes out from the platform's verified Resend domain
 * (EMAIL_FROM) but shows the shop's name, so customers and invitees see who
 * is writing to them: `EMAIL_FROM = "Detail CRM <notify@example.com>"` and
 * shop "Joe's Detailing, LLC" -> `"Joe's Detailing, LLC" <notify@example.com>`.
 */

const BARE_ADDRESS = /^[^\s<>@]+@[^\s<>@]+\.[^\s<>@]+$/;
const NAMED_ADDRESS = /^[^<>]*<([^\s<>@]+@[^\s<>@]+\.[^\s<>@]+)>$/;
/** RFC 5322 atext plus spaces: a display name made only of these needs no quotes. */
const PLAIN_PHRASE = /^[A-Za-z0-9!#$%&'*+\-/=?^_`{|}~ ]+$/;
export const MAX_DISPLAY_NAME_LENGTH = 70;

/** The bare address of `"Name <addr>"` or `addr`; null when neither form matches. */
export function emailAddressOf(from: string): string | null {
  const trimmed = from.trim();
  if (BARE_ADDRESS.test(trimmed)) return trimmed;
  return NAMED_ADDRESS.exec(trimmed)?.[1] ?? null;
}

/**
 * A display name safe to put in a From header: control characters, angle
 * brackets, quotes and backslashes removed, whitespace collapsed, length
 * capped. Empty when nothing printable remains.
 */
export function sanitizeDisplayName(name: string): string {
  // deno-lint-ignore no-control-regex
  const cleaned = name.replace(/[\u0000-\u001f\u007f<>"\\]/g, " ").replace(/\s+/g, " ").trim();
  return cleaned.slice(0, MAX_DISPLAY_NAME_LENGTH).trim();
}

/**
 * `from` (EMAIL_FROM) re-labelled with `displayName`. Falls back to `from`
 * unchanged when the name is empty after sanitizing or `from` is not a
 * recognizable address.
 */
export function fromWithDisplayName(from: string, displayName: string | null | undefined): string {
  const address = emailAddressOf(from);
  const name = sanitizeDisplayName(displayName ?? "");
  if (!address || name === "") return from.trim();
  return PLAIN_PHRASE.test(name) ? `${name} <${address}>` : `"${name}" <${address}>`;
}
