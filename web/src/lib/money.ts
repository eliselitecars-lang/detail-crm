/**
 * Money is ALWAYS integer cents (SPEC §4.5). Floats are used only to build
 * display strings; parsing is done on the decimal string so "19.99" becomes
 * exactly 1999 — never 1998.9999.
 */

export type Cents = number;

const formatters = new Map<string, Intl.NumberFormat>();

function formatter(currency: string, showCents: boolean): Intl.NumberFormat {
  const key = `${currency}|${showCents ? 2 : 0}`;
  let f = formatters.get(key);
  if (!f) {
    f = new Intl.NumberFormat('en-US', {
      style: 'currency',
      currency: currency.toUpperCase(),
      minimumFractionDigits: showCents ? 2 : 0,
      maximumFractionDigits: showCents ? 2 : 0,
    });
    formatters.set(key, f);
  }
  return f;
}

export interface FormatCentsOptions {
  /** ISO currency code; shops are `usd` today. */
  currency?: string;
  /** Drop ".00" for whole amounts (e.g. chart axes, compact tiles). */
  compactWhole?: boolean;
  /** Prefix positive values with "+" (e.g. adjustments). */
  signed?: boolean;
}

/** 123456 → "$1,234.56"; -500 → "-$5.00"; null → "—". */
export function formatCents(
  cents: Cents | null | undefined,
  { currency = 'usd', compactWhole = false, signed = false }: FormatCentsOptions = {},
): string {
  if (cents === null || cents === undefined || !Number.isFinite(cents)) return '—';
  const whole = Number.isInteger(cents) ? cents : Math.round(cents);
  const showCents = !(compactWhole && whole % 100 === 0);
  const text = formatter(currency, showCents).format(whole / 100);
  return signed && whole > 0 ? `+${text}` : text;
}

/** Cents → the plain editable string used by MoneyInput ("1234.50"). */
export function centsToInputValue(cents: Cents | null | undefined): string {
  if (cents === null || cents === undefined || !Number.isFinite(cents)) return '';
  const whole = Math.round(cents);
  const negative = whole < 0;
  const abs = Math.abs(whole);
  const dollars = Math.trunc(abs / 100);
  const rest = String(abs % 100).padStart(2, '0');
  return `${negative ? '-' : ''}${dollars}.${rest}`;
}

export interface ParseMoneyOptions {
  allowNegative?: boolean;
  /** Upper bound in cents (inclusive). Defaults to $10,000,000. */
  maxCents?: Cents;
}

/**
 * Parses user input into integer cents. Accepts "$1,234.56", "1234.5", ".5",
 * "12", " 12.00 " and (with allowNegative) one of "-5", "-$5", "$-5", "($5)".
 * Returns `null` for empty or invalid input (more than two decimals, letters,
 * doubled signs, negative when not allowed, over max).
 */
export function parseMoneyInput(
  input: string | null | undefined,
  { allowNegative = false, maxCents = 1_000_000_000 }: ParseMoneyOptions = {},
): Cents | null {
  if (input === null || input === undefined) return null;
  let text = input.trim().replace(/[\s,]/g, '');
  if (text === '') return null;

  // Exactly one negative marker is allowed: "(5)", "-5", "-$5" or "$-5".
  // Anything doubled ("-$-5", "(-5)", "--5") is malformed, not a sign flip.
  let signs = 0;
  if (text.startsWith('(') && text.endsWith(')')) {
    signs += 1;
    text = text.slice(1, -1);
  }
  if (text.startsWith('-')) {
    signs += 1;
    text = text.slice(1);
  }
  text = text.replace(/^\$/, '');
  if (text.startsWith('-')) {
    signs += 1;
    text = text.slice(1);
  }
  if (signs > 1) return null;
  const negative = signs === 1;

  const match = /^(\d*)(?:\.(\d{0,2}))?$/.exec(text);
  if (!match) return null;
  const [, intPart = '', fracPart = ''] = match;
  if (intPart === '' && fracPart === '') return null;
  if (intPart.length > 12) return null;

  const cents = Number(intPart || '0') * 100 + Number(fracPart.padEnd(2, '0'));
  if (!Number.isSafeInteger(cents)) return null;
  if (negative && cents !== 0 && !allowNegative) return null;
  if (cents > maxCents) return null;
  return negative && cents !== 0 ? -cents : cents;
}

/** Basis points → percent string for inputs: 825 → "8.25", 700 → "7". */
export function bpsToPercentInput(bps: number | null | undefined): string {
  if (bps === null || bps === undefined || !Number.isFinite(bps)) return '';
  const whole = Math.trunc(bps / 100);
  const frac = Math.abs(Math.round(bps) % 100);
  if (frac === 0) return String(whole);
  return `${whole}.${String(frac).padStart(2, '0').replace(/0$/, '')}`;
}

/** 825 → "8.25%". */
export function formatBps(bps: number | null | undefined): string {
  const text = bpsToPercentInput(bps);
  return text === '' ? '—' : `${text}%`;
}

/**
 * Percent input → basis points: "8.25" → 825, "7" → 700, "8.5%" → 850.
 * Returns null for invalid input, >2 decimals, or outside [0, maxPercent].
 */
export function parsePercentToBps(
  input: string | null | undefined,
  { maxPercent = 100 }: { maxPercent?: number } = {},
): number | null {
  if (input === null || input === undefined) return null;
  const text = input.trim().replace(/%$/, '').trim();
  if (text === '') return null;
  const match = /^(\d{1,3})?(?:\.(\d{0,2}))?$/.exec(text);
  if (!match) return null;
  const [, intPart = '', fracPart = ''] = match;
  if (intPart === '' && fracPart === '') return null;
  const bps = Number(intPart || '0') * 100 + Number(fracPart.padEnd(2, '0'));
  if (bps > maxPercent * 100) return null;
  return bps;
}

/** Sums cents safely (ignores null/undefined). */
export function sumCents(values: readonly (Cents | null | undefined)[]): Cents {
  let total = 0;
  for (const v of values) if (typeof v === 'number' && Number.isFinite(v)) total += Math.round(v);
  return total;
}
