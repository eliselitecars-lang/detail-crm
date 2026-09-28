/**
 * Phone numbers are stored as E.164 (+12055550123). Default country is US/CA
 * (NANP, +1); international numbers must be typed with a leading "+".
 */

export type E164 = string;

/**
 * E.164 exactly as the database checks it (`public.is_valid_e164`, 0001:
 * `^\+[1-9][0-9]{6,14}$`): 7–15 digits, no leading 0. The iPhone app
 * (DetailCore PhoneNumber.swift) applies the same rules, so a number saved
 * on one is accepted by the other.
 */
const E164_RE = /^\+[1-9]\d{6,14}$/;

/** Extension markers, checked in this order (same as the iPhone app). */
const EXTENSION_MARKERS = ['ext.', 'ext', 'x', '#'] as const;
/** Characters allowed between the digits. */
const PUNCTUATION = new Set([' ', '-', '.', '(', ')', '/', '\u00A0']);

function isValidNanp(national: string): boolean {
  // NXX-NXX-XXXX: area code and exchange cannot start with 0 or 1.
  return /^[2-9]\d{2}[2-9]\d{6}$/.test(national);
}

/** Leading spaces / "(" before a "+" ("( +44 …"). */
function leadingOffset(text: string): number {
  let offset = 0;
  for (const ch of text) {
    if (ch === ' ' || ch === '\u00A0' || ch === '(') offset += 1;
    else break;
  }
  return offset;
}

/**
 * Normalises user input to E.164 or returns `null` if it can't be a valid
 * number. Accepts "(205) 555-0123", "205.555.0123", "1-205-555-0123",
 * "+1 205 555 0123", "+44 20 7946 0958", "0044 20 7946 0958". An extension
 * ("x12", "ext. 4", "#5") is dropped. NANP (+1) numbers are checked strictly;
 * other international numbers need a leading "+" or "00".
 */
export function normalizePhone(input: string | null | undefined): E164 | null {
  if (!input) return null;
  let text = input.trim();
  if (text === '') return null;

  const lower = text.toLowerCase();
  for (const marker of EXTENSION_MARKERS) {
    const at = lower.indexOf(marker);
    if (at >= 0) {
      text = text.slice(0, at);
      break;
    }
  }

  let international = false;
  let digits = '';
  const plusAt = leadingOffset(text);
  for (let i = 0; i < text.length; i += 1) {
    const ch = text.charAt(i);
    if (ch >= '0' && ch <= '9') digits += ch;
    else if (ch === '+' && i === plusAt && digits === '') international = true;
    else if (!PUNCTUATION.has(ch)) return null;
  }

  if (!international && digits.startsWith('00')) {
    international = true;
    digits = digits.slice(2);
  }

  if (international) {
    const candidate = `+${digits}`;
    if (!E164_RE.test(candidate)) return null;
    if (digits.startsWith('1')) {
      return digits.length === 11 && isValidNanp(digits.slice(1)) ? candidate : null;
    }
    return candidate;
  }

  if (digits.length === 11 && digits.startsWith('1')) digits = digits.slice(1);
  if (digits.length === 10 && isValidNanp(digits)) return `+1${digits}`;
  return null;
}

export function isValidPhone(input: string | null | undefined): boolean {
  return normalizePhone(input) !== null;
}

/** E.164 → display: "+12055550123" → "(205) 555-0123"; others unchanged. */
export function formatPhone(value: string | null | undefined): string {
  if (!value) return '';
  const e164 = normalizePhone(value);
  if (!e164) return value;
  if (e164.startsWith('+1') && e164.length === 12) {
    const n = e164.slice(2);
    return `(${n.slice(0, 3)}) ${n.slice(3, 6)}-${n.slice(6)}`;
  }
  return e164;
}

/** Progressive US formatting while typing; leaves "+..." input untouched. */
export function formatPhoneAsYouType(input: string): string {
  if (input.trim().startsWith('+')) return input;
  let digits = input.replace(/\D/g, '');
  if (digits.length === 11 && digits.startsWith('1')) digits = digits.slice(1);
  digits = digits.slice(0, 10);
  if (digits.length === 0) return '';
  if (digits.length < 4) return `(${digits}`;
  if (digits.length < 7) return `(${digits.slice(0, 3)}) ${digits.slice(3)}`;
  return `(${digits.slice(0, 3)}) ${digits.slice(3, 6)}-${digits.slice(6)}`;
}

/** `tel:` / `sms:` href for an E.164 number. */
export function phoneHref(
  value: string | null | undefined,
  scheme: 'tel' | 'sms' = 'tel',
): string | undefined {
  const e164 = normalizePhone(value);
  return e164 ? `${scheme}:${e164}` : undefined;
}
