/** Absolute public booking URL for a shop slug (the /book/:slug route). */
export function bookingUrl(slug: string, origin: string = window.location.origin): string {
  return `${origin}/book/${encodeURIComponent(slug)}`;
}
