import { assert, assertEquals, assertThrows } from "@std/assert";
import { buildCalendar, escapeText, foldLine, formatUtc } from "./ics.ts";

const encoder = new TextEncoder();

/** Undoes folding (RFC 5545 section 3.1) for assertions. */
function unfold(ics: string): string[] {
  return ics.replace(/\r\n /g, "").split("\r\n").filter((l) => l !== "");
}

Deno.test("ics: TEXT escaping covers backslash, semicolon, comma and newlines", () => {
  assertEquals(escapeText("a\\b;c,d\ne\r\nf\rg"), "a\\\\b\\;c\\,d\\ne\\nf\\ng");
  assertEquals(escapeText("tab\there\u0007bell"), "tab\therebell");
  assertEquals(escapeText("Café: 2 × Wash"), "Café: 2 × Wash");
});

Deno.test("ics: lines fold at 75 octets with CRLF + space, never inside a character", () => {
  assertEquals(foldLine("SUMMARY:short"), "SUMMARY:short\r\n");
  const long = "DESCRIPTION:" + "x".repeat(200);
  const folded = foldLine(long);
  const physical = folded.split("\r\n").filter((l) => l !== "");
  assert(physical.length > 2);
  for (const line of physical) assert(encoder.encode(line).byteLength <= 75, line);
  assertEquals(physical.slice(1).every((l) => l.startsWith(" ")), true);
  assertEquals(folded.replace(/\r\n /g, "").replace(/\r\n$/, ""), long);

  // Multi-byte characters (3-byte "€", 4-byte emoji) are never split.
  const wide = "SUMMARY:" + "€".repeat(40) + "🚗".repeat(10);
  const wideLines = foldLine(wide).split("\r\n").filter((l) => l !== "");
  for (const line of wideLines) {
    assert(encoder.encode(line).byteLength <= 75);
    assert(!line.includes("�"));
  }
  assertEquals(foldLine(wide).replace(/\r\n /g, "").replace(/\r\n$/, ""), wide);
});

Deno.test("ics: instants are UTC, including across DST changes", () => {
  // 2026-03-08 is the US spring-forward day: 9:00 CST (-6) then 9:00 CDT (-5).
  assertEquals(formatUtc(new Date("2026-03-07T09:00:00-06:00")), "20260307T150000Z");
  assertEquals(formatUtc(new Date("2026-03-09T09:00:00-05:00")), "20260309T140000Z");
  assertEquals(formatUtc(new Date("2026-11-01T01:30:00-05:00")), "20261101T063000Z");
  assertEquals(formatUtc(new Date("2026-11-01T01:30:00-06:00")), "20261101T073000Z");
  assertThrows(() => formatUtc(new Date("nope")), RangeError);
});

Deno.test("ics: a calendar has the envelope and one VEVENT per event", () => {
  const ics = buildCalendar({
    name: "Shine Auto Spa, Alex",
    timezone: "America/Chicago",
    events: [
      {
        uid: "job-11111111-1111-4111-8111-111111111111",
        start: new Date("2026-06-02T15:00:00Z"),
        end: new Date("2026-06-02T18:00:00Z"),
        summary: "Job #1042 - Full detail; wax - Dana R.",
        location: "12 Oak St, Birmingham, AL 35203",
        description: "2021 Honda Civic\nFull detail\nhttps://app.example.com/app/jobs/1",
        status: "TENTATIVE",
        updatedAt: new Date("2026-05-30T12:00:00Z"),
      },
      {
        uid: "event-22222222-2222-4222-8222-222222222222-20260603T140000Z",
        start: new Date("2026-06-03T14:00:00Z"),
        end: new Date("2026-06-03T13:00:00Z"), // inverted: clamped to zero length
        summary: "Time off",
        status: "CANCELLED",
      },
    ],
  }, new Date("2026-06-01T00:00:00Z"));
  assert(ics.endsWith("\r\n"));
  assert(!/[^\r]\n/.test(ics), "every line ends with CRLF");
  const lines = unfold(ics);
  assertEquals(lines.slice(0, 9), [
    "BEGIN:VCALENDAR",
    "VERSION:2.0",
    "PRODID:-//Detail CRM//Calendar//EN",
    "CALSCALE:GREGORIAN",
    "METHOD:PUBLISH",
    "X-WR-CALNAME:Shine Auto Spa\\, Alex",
    "X-WR-TIMEZONE:America/Chicago",
    "REFRESH-INTERVAL;VALUE=DURATION:PT60M",
    "X-PUBLISHED-TTL:PT60M",
  ]);
  assertEquals(lines.filter((l) => l === "BEGIN:VEVENT").length, 2);
  assert(lines.includes("UID:job-11111111-1111-4111-8111-111111111111@detail-crm"));
  assert(lines.includes("DTSTAMP:20260601T000000Z"));
  assert(lines.includes("DTSTART:20260602T150000Z"));
  assert(lines.includes("DTEND:20260602T180000Z"));
  assert(lines.includes("SUMMARY:Job #1042 - Full detail\\; wax - Dana R."));
  assert(lines.includes("LOCATION:12 Oak St\\, Birmingham\\, AL 35203"));
  assert(
    lines.includes(
      "DESCRIPTION:2021 Honda Civic\\nFull detail\\nhttps://app.example.com/app/jobs/1",
    ),
  );
  assert(lines.includes("STATUS:TENTATIVE"));
  assert(lines.includes("LAST-MODIFIED:20260530T120000Z"));
  assert(lines.includes("STATUS:CANCELLED"));
  assert(lines.includes("DTEND:20260603T140000Z"));
  assertEquals(lines.at(-1), "END:VCALENDAR");
});

Deno.test("ics: an empty feed is still a valid calendar", () => {
  const lines = unfold(buildCalendar({ name: "X", events: [] }));
  assertEquals(lines[0], "BEGIN:VCALENDAR");
  assertEquals(lines.at(-1), "END:VCALENDAR");
  assertEquals(lines.includes("BEGIN:VEVENT"), false);
});
