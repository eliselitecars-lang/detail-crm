/** Small display helpers shared by the public pages and the portal. */

/**
 * "Central Daylight Time" for a zone at an instant (falls back to the IANA
 * name). Used to tell visitors which zone appointment times are shown in.
 */
export function timeZoneName(timeZone: string, at: Date = new Date()): string {
  try {
    const part = new Intl.DateTimeFormat('en-US', { timeZone, timeZoneName: 'long' })
      .formatToParts(at)
      .find((p) => p.type === 'timeZoneName');
    return part?.value ?? timeZone;
  } catch {
    return timeZone;
  }
}

/** 90 → "1 hr 30 min", 45 → "45 min", 120 → "2 hr". */
export function formatDuration(minutes: number | null | undefined): string | null {
  if (minutes === null || minutes === undefined || minutes <= 0) return null;
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  if (h === 0) return `${m} min`;
  return m === 0 ? `${h} hr` : `${h} hr ${m} min`;
}

/** "Jane Doe" / company / null from a curated customer object. */
export function personName(
  customer: { first_name: string | null; last_name: string | null; company: string | null } | null,
): string | null {
  if (!customer) return null;
  const name = [customer.first_name, customer.last_name].filter(Boolean).join(' ').trim();
  return name || customer.company || null;
}
