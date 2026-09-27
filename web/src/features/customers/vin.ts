/**
 * VIN helpers + decode through NHTSA vPIC (free, no key; SPEC §4.2).
 * https://vpic.nhtsa.dot.gov/api/vehicles/DecodeVinValues/<VIN>?format=json
 */
import { z } from 'zod';
import { AppError } from '@/lib/errors';

/** Upper-case, strip spaces/dashes (mirrors the vehicles_normalize trigger). */
export function normalizeVin(input: string): string {
  return input.toUpperCase().replace(/[\s-]/g, '');
}

// prettier-ignore
const TRANSLIT: Record<string, number> = {
  A: 1, B: 2, C: 3, D: 4, E: 5, F: 6, G: 7, H: 8,
  J: 1, K: 2, L: 3, M: 4, N: 5, P: 7, R: 9,
  S: 2, T: 3, U: 4, V: 5, W: 6, X: 7, Y: 8, Z: 9,
};
const WEIGHTS = [8, 7, 6, 5, 4, 3, 2, 10, 0, 9, 8, 7, 6, 5, 4, 3, 2];

function charValue(ch: string): number | null {
  if (/\d/.test(ch)) return Number(ch);
  return TRANSLIT[ch] ?? null;
}

/** The ISO 3779 / North American check digit (position 9) for a 17-char VIN. */
export function vinCheckDigit(vin: string): string | null {
  if (vin.length !== 17) return null;
  let sum = 0;
  for (let i = 0; i < 17; i += 1) {
    const value = charValue(vin.charAt(i));
    if (value === null) return null;
    sum += value * (WEIGHTS[i] ?? 0);
  }
  const rem = sum % 11;
  return rem === 10 ? 'X' : String(rem);
}

export type VinProblem = 'empty' | 'length' | 'characters' | 'check_digit';

/**
 * Why a VIN can't be decoded, or null if it looks valid. Modern VINs are 17
 * characters of A–Z/0–9 without I, O or Q, with a check digit in position 9.
 */
export function vinProblem(input: string): VinProblem | null {
  const vin = normalizeVin(input);
  if (!vin) return 'empty';
  if (!/^[A-Z0-9]+$/.test(vin) || /[IOQ]/.test(vin)) return 'characters';
  if (vin.length !== 17) return 'length';
  if (vinCheckDigit(vin) !== vin.charAt(8)) return 'check_digit';
  return null;
}

export const VIN_PROBLEM_TEXT: Record<VinProblem, string> = {
  empty: 'Enter a VIN to decode.',
  length: 'A VIN has exactly 17 characters.',
  characters: 'A VIN uses only letters and numbers, never I, O or Q.',
  check_digit: 'This VIN doesn’t pass the check-digit test. Double-check it.',
};

/** "TOYOTA" → "Toyota", "MERCEDES-BENZ" → "Mercedes-Benz", "BMW" stays. */
export function smartCase(value: string): string {
  const text = value.trim();
  if (!text || text !== text.toUpperCase()) return text;
  return text.replace(/[A-Z0-9]+/g, (word) =>
    word.length <= 3 || /\d/.test(word) ? word : word.charAt(0) + word.slice(1).toLowerCase(),
  );
}

const vpicSchema = z.object({
  Results: z
    .array(
      z
        .object({
          ModelYear: z.string().nullish(),
          Make: z.string().nullish(),
          Model: z.string().nullish(),
          Trim: z.string().nullish(),
          Series: z.string().nullish(),
          ErrorCode: z.string().nullish(),
          ErrorText: z.string().nullish(),
        })
        .loose(),
    )
    .min(1),
});

export interface DecodedVin {
  year: number | null;
  make: string | null;
  model: string | null;
  trim: string | null;
}

export const VPIC_URL = 'https://vpic.nhtsa.dot.gov/api/vehicles/DecodeVinValues/';

function clean(value: string | null | undefined, max: number): string | null {
  const text = value?.trim();
  if (!text || /^(null|not applicable)$/i.test(text)) return null;
  return text.slice(0, max);
}

/** Parses a vPIC DecodeVinValues response. Throws when nothing useful decoded. */
export function parseVpicResponse(body: unknown): DecodedVin {
  const parsed = vpicSchema.safeParse(body);
  if (!parsed.success) {
    throw new AppError('The VIN service returned an unexpected response. Try again later.', {
      kind: 'server',
    });
  }
  const result = parsed.data.Results[0];
  const year = Number(result?.ModelYear);
  const decoded: DecodedVin = {
    year: Number.isInteger(year) && year >= 1886 && year <= 2100 ? year : null,
    make: result?.Make ? smartCase(clean(result.Make, 60) ?? '') || null : null,
    model: clean(result?.Model, 60),
    trim: clean(result?.Trim, 60) ?? clean(result?.Series, 60),
  };
  if (!decoded.make && !decoded.model && decoded.year === null) {
    throw new AppError('We couldn’t decode this VIN. Enter the vehicle details by hand.', {
      kind: 'not_found',
    });
  }
  return decoded;
}

/** Calls vPIC for a validated VIN. Errors are friendly AppErrors (offline, timeout, bad VIN). */
export async function decodeVin(
  input: string,
  { fetchImpl = fetch, timeoutMs = 10_000 }: { fetchImpl?: typeof fetch; timeoutMs?: number } = {},
): Promise<DecodedVin> {
  const vin = normalizeVin(input);
  const problem = vinProblem(vin);
  if (problem) throw new AppError(VIN_PROBLEM_TEXT[problem], { kind: 'validation' });
  if (typeof navigator !== 'undefined' && navigator.onLine === false) {
    throw new AppError('You’re offline. Connect to the internet to decode a VIN.', {
      kind: 'network',
    });
  }
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  let response: Response;
  try {
    response = await fetchImpl(`${VPIC_URL}${encodeURIComponent(vin)}?format=json`, {
      signal: controller.signal,
      headers: { accept: 'application/json' },
    });
  } catch (error) {
    throw new AppError(
      controller.signal.aborted
        ? 'The VIN service took too long to answer. Try again.'
        : 'Couldn’t reach the VIN service. Check your connection and try again.',
      { kind: 'network', cause: error },
    );
  } finally {
    clearTimeout(timer);
  }
  if (!response.ok) {
    throw new AppError('The VIN service is unavailable right now. Try again later.', {
      kind: 'server',
      status: response.status,
    });
  }
  let body: unknown;
  try {
    body = await response.json();
  } catch (error) {
    throw new AppError('The VIN service returned an unexpected response. Try again later.', {
      kind: 'server',
      cause: error,
    });
  }
  return parseVpicResponse(body);
}
