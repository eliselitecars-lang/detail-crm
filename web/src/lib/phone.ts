/**
 * Phone numbers are stored as E.164 (+12055550123). Default country is US/CA
 * (NANP, +1); international numbers must be typed with a leading "+".
 */

export type E164 = string;

const E164_RE = /^\+[1-9]\d{7,14}$/;

function isValidNanp(national: string): boolean {
  // NXX-NXX-XXXX: area code and exchange cannot start with 0 or 1.
  return /^[2-9]\d{2}[2-9]\d{6}$/.test(national);
}

/**
 * Normalises user input to E.164 or returns `null` if it can't be a valid
 * number. Accepts "(205) 555-0123", "205.555.0123", "1-205-555-0123",
 * "+1 205 555 0123", "+44 20 7946 0958". Extensions are not supported.
 */
export function normalizePhone(input: string | null | undefined): E164 | null {
  if (!input) return null;
  const trimmed = input.trim();
  if (trimmed === '') return null;
  if (/[a-z]/i.test(trimmed)) return null;

  const hasPlus = trimmed.startsWith('+') || trimmed.startsWith('00');
  let digits = trimmed.replace(/\D/g, '');
  if (trimmed.startsWith('00')) digits = digits.slice(2);

  if (hasPlus) {
    if (digits.startsWith('1')) {
      return digits.length === 11 && isValidNanp(digits.slice(1)) ? `+${digits}` : null;
    }
    const candidate = `+${digits}`;
    return E164_RE.test(candidate) ? candidate : null;
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
