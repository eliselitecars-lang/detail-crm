/**
 * iCalendar (RFC 5545) rendering for subscribed calendar feeds.
 *
 *  - Lines end with CRLF and are folded at 75 octets (UTF-8 bytes, never
 *    inside a multi-byte character); continuation lines start with a space.
 *  - TEXT values escape backslash, semicolon, comma and newlines
 *    (`\\`, `\;`, `\,`, `\n`); other control characters are dropped.
 *  - Every instant is written in UTC ("Z" form), so no VTIMEZONE block is
 *    needed and DST transitions cannot shift an event.
 */

export const PRODID = "-//Detail CRM//Calendar//EN";
export const UID_DOMAIN = "detail-crm";

export type IcsStatus = "CONFIRMED" | "TENTATIVE" | "CANCELLED";

export interface IcsEvent {
  /** Stable per event; `@detail-crm` is appended. */
  uid: string;
  start: Date;
  end: Date;
  summary: string;
  location?: string | null;
  description?: string | null;
  status?: IcsStatus;
  /** LAST-MODIFIED. */
  updatedAt?: Date | null;
}

export interface IcsCalendar {
  /** X-WR-CALNAME (the name calendar apps show). */
  name: string;
  /** X-WR-TIMEZONE hint (IANA), e.g. America/Chicago. */
  timezone?: string | null;
  /** How often clients should refresh (minutes; default 60). */
  refreshMinutes?: number;
  events: readonly IcsEvent[];
}

const encoder = new TextEncoder();
const MAX_LINE_OCTETS = 75;

// deno-lint-ignore no-control-regex
const CONTROL = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/g;

/** Escapes a TEXT value (RFC 5545 section 3.3.11). */
export function escapeText(value: string): string {
  return value
    .replace(CONTROL, "")
    .replace(/\\/g, "\\\\")
    .replace(/;/g, "\\;")
    .replace(/,/g, "\\,")
    .replace(/\r\n|\r|\n/g, "\\n");
}

/** Folds one content line at 75 octets (section 3.1). Returns it with CRLFs. */
export function foldLine(line: string): string {
  if (encoder.encode(line).byteLength <= MAX_LINE_OCTETS) return `${line}\r\n`;
  const parts: string[] = [];
  let current = "";
  let currentBytes = 0;
  // Continuation lines carry a leading space, which counts toward their 75.
  let limit = MAX_LINE_OCTETS;
  for (const char of line) {
    const size = encoder.encode(char).byteLength;
    if (currentBytes + size > limit) {
      parts.push(current);
      current = "";
      currentBytes = 0;
      limit = MAX_LINE_OCTETS - 1;
    }
    current += char;
    currentBytes += size;
  }
  parts.push(current);
  return parts.map((part, index) => (index === 0 ? part : ` ${part}`)).join("\r\n") + "\r\n";
}

/** UTC DATE-TIME, e.g. 20260602T150000Z. */
export function formatUtc(date: Date): string {
  if (Number.isNaN(date.getTime())) throw new RangeError("invalid date");
  const pad = (n: number, width = 2) => String(n).padStart(width, "0");
  return `${pad(date.getUTCFullYear(), 4)}${pad(date.getUTCMonth() + 1)}${pad(date.getUTCDate())}T${
    pad(date.getUTCHours())
  }${pad(date.getUTCMinutes())}${pad(date.getUTCSeconds())}Z`;
}

function uidOf(uid: string): string {
  const clean = uid.replace(CONTROL, "").replace(/[\s;,\\]/g, "-");
  return clean.includes("@") ? clean : `${clean}@${UID_DOMAIN}`;
}

/** Renders a VCALENDAR (METHOD:PUBLISH) with one VEVENT per event. */
export function buildCalendar(calendar: IcsCalendar, now: Date = new Date()): string {
  const refresh = Math.max(15, Math.round(calendar.refreshMinutes ?? 60));
  const lines: string[] = [
    "BEGIN:VCALENDAR",
    "VERSION:2.0",
    `PRODID:${PRODID}`,
    "CALSCALE:GREGORIAN",
    "METHOD:PUBLISH",
    `X-WR-CALNAME:${escapeText(calendar.name)}`,
  ];
  if (calendar.timezone) lines.push(`X-WR-TIMEZONE:${escapeText(calendar.timezone)}`);
  lines.push(`REFRESH-INTERVAL;VALUE=DURATION:PT${refresh}M`, `X-PUBLISHED-TTL:PT${refresh}M`);

  const stamp = formatUtc(now);
  for (const event of calendar.events) {
    // An end before the start would make the event invalid for most clients.
    const end = event.end.getTime() > event.start.getTime() ? event.end : event.start;
    lines.push(
      "BEGIN:VEVENT",
      `UID:${uidOf(event.uid)}`,
      `DTSTAMP:${stamp}`,
      `DTSTART:${formatUtc(event.start)}`,
      `DTEND:${formatUtc(end)}`,
      `SUMMARY:${escapeText(event.summary)}`,
    );
    if (event.location) lines.push(`LOCATION:${escapeText(event.location)}`);
    if (event.description) lines.push(`DESCRIPTION:${escapeText(event.description)}`);
    lines.push(`STATUS:${event.status ?? "CONFIRMED"}`);
    if (event.status === "CANCELLED") lines.push("TRANSP:TRANSPARENT");
    if (event.updatedAt && !Number.isNaN(event.updatedAt.getTime())) {
      lines.push(`LAST-MODIFIED:${formatUtc(event.updatedAt)}`);
    }
    lines.push("END:VEVENT");
  }
  lines.push("END:VCALENDAR");
  return lines.map(foldLine).join("");
}
