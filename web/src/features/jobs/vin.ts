/**
 * VIN decode through NHTSA vPIC (free, no key; SPEC §4.2) for the new-job
 * vehicle form. https://vpic.nhtsa.dot.gov/api/
 */
import { z } from 'zod';
import { AppError } from '@/lib/errors';

/** Upper-case, strip spaces/dashes (mirrors the vehicles_normalize trigger). */
export function normalizeVin(input: string): string {
  return input.toUpperCase().replace(/[\s-]/g, '');
}

/** Why a VIN can't be decoded, or null when it looks like a modern 17-char VIN. */
export function vinProblem(input: string): string | null {
  const vin = normalizeVin(input);
  if (!vin) return 'Enter a VIN to decode.';
  if (!/^[A-Z0-9]+$/.test(vin) || /[IOQ]/.test(vin)) {
    return 'A VIN uses only letters and numbers, never I, O or Q.';
  }
  if (vin.length !== 17) return 'A VIN has exactly 17 characters.';
  return null;
}

const resultSchema = z.object({
  Results: z
    .array(
      z
        .object({
          ModelYear: z.string().optional(),
          Make: z.string().optional(),
          Model: z.string().optional(),
          Trim: z.string().optional(),
          ErrorCode: z.string().optional(),
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

function titleCase(value: string | undefined): string | null {
  const v = value?.trim();
  if (!v) return null;
  // vPIC returns makes in upper case ("TOYOTA"); models are already cased.
  return v === v.toUpperCase() && v.length > 3
    ? v.toLowerCase().replace(/\b\w/g, (c) => c.toUpperCase())
    : v;
}

export async function decodeVin(
  input: string,
  fetchImpl: typeof fetch = fetch,
): Promise<DecodedVin> {
  const vin = normalizeVin(input);
  const problem = vinProblem(vin);
  if (problem) throw new AppError(problem, { kind: 'validation' });
  let response: Response;
  try {
    response = await fetchImpl(
      `https://vpic.nhtsa.dot.gov/api/vehicles/DecodeVinValues/${encodeURIComponent(vin)}?format=json`,
    );
  } catch (cause) {
    throw new AppError('Couldn’t reach the VIN decoder. Enter the vehicle details by hand.', {
      kind: 'network',
      cause,
    });
  }
  if (!response.ok) {
    throw new AppError('The VIN decoder is unavailable. Enter the vehicle details by hand.', {
      kind: 'server',
      status: response.status,
    });
  }
  const parsed = resultSchema.safeParse(await response.json());
  const row = parsed.success ? parsed.data.Results[0] : undefined;
  const year = Number(row?.ModelYear);
  const decoded: DecodedVin = {
    year: Number.isInteger(year) && year >= 1886 && year <= 2100 ? year : null,
    make: titleCase(row?.Make),
    model: row?.Model?.trim() || null,
    trim: row?.Trim?.trim() || null,
  };
  if (!decoded.make && !decoded.model) {
    throw new AppError('No vehicle was found for this VIN. Enter the details by hand.', {
      kind: 'not_found',
    });
  }
  return decoded;
}
