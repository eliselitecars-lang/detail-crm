/**
 * Customer list search → PostgREST `ilike` patterns over customers.search_text
 * (lower(first last company email phone), trigram indexed).
 *
 * - Each whitespace-separated word must match (AND), in any column.
 * - LIKE wildcards typed by the user are literals: `\`, `%` and `_` are
 *   escaped with a backslash (Postgres' default LIKE escape). PostgREST also
 *   treats `*` as a `%` alias with no escape, so `*` is dropped.
 * - A word that looks like part of a phone number ("(205) 555-01") is reduced
 *   to its digits so it matches the stored E.164 value ("+12055550123").
 */

const PHONE_LIKE = /^[\d()+\-.\s]+$/;

export function escapeLike(text: string): string {
  return text.replace(/[\\%_]/g, (ch) => `\\${ch}`);
}

/** Splits a query into lower-cased search terms (phone-ish terms → digits). */
export function searchTerms(query: string): string[] {
  const trimmed = query.trim().toLowerCase().replace(/\*/g, '');
  if (!trimmed) return [];
  // A whole phone number typed with spaces is one term: "(205) 555 0123".
  if (PHONE_LIKE.test(trimmed)) {
    const digits = trimmed.replace(/\D/g, '');
    if (digits.length >= 3) return [digits];
  }
  const terms: string[] = [];
  for (const word of trimmed.split(/\s+/)) {
    if (!word) continue;
    const digits = word.replace(/\D/g, '');
    const term = PHONE_LIKE.test(word) && digits.length >= 3 ? digits : word;
    if (term && !terms.includes(term)) terms.push(term);
  }
  return terms.slice(0, 8);
}

/** `ilike` patterns (one per term) for `search_text`. */
export function searchPatterns(query: string): string[] {
  return searchTerms(query).map((term) => `%${escapeLike(term)}%`);
}
