import { describe, expect, it, vi } from 'vitest';
import { decodeVin, normalizeVin, vinProblem } from './vin';

function response(body: unknown, ok = true, status = 200): Response {
  return { ok, status, json: () => Promise.resolve(body) } as Response;
}

describe('VIN decode (NHTSA vPIC)', () => {
  it('normalizes and validates VINs', () => {
    expect(normalizeVin(' 1hgcm-8263 3a004352 ')).toBe('1HGCM82633A004352');
    expect(vinProblem('')).toMatch(/Enter a VIN/);
    expect(vinProblem('1HGCM82633A00435O')).toMatch(/never I, O or Q/);
    expect(vinProblem('1HGCM826')).toMatch(/17 characters/);
    expect(vinProblem('1HGCM82633A004352')).toBeNull();
  });

  it('decodes year, make, model and trim', async () => {
    const fetchImpl = vi.fn(() =>
      Promise.resolve(
        response({
          Results: [
            { ModelYear: '2003', Make: 'HONDA', Model: 'Accord', Trim: 'EX', ErrorCode: '0' },
          ],
        }),
      ),
    );
    await expect(decodeVin('1hgcm82633a004352', fetchImpl)).resolves.toEqual({
      year: 2003,
      make: 'Honda',
      model: 'Accord',
      trim: 'EX',
    });
    expect(fetchImpl).toHaveBeenCalledWith(
      'https://vpic.nhtsa.dot.gov/api/vehicles/DecodeVinValues/1HGCM82633A004352?format=json',
    );
  });

  it('never calls the network for an invalid VIN', async () => {
    const fetchImpl = vi.fn();
    await expect(decodeVin('bad', fetchImpl)).rejects.toThrow(/17 characters/);
    expect(fetchImpl).not.toHaveBeenCalled();
  });

  it('reports unknown VINs and decoder outages with a manual-entry hint', async () => {
    const empty = vi.fn(() =>
      Promise.resolve(response({ Results: [{ ModelYear: '', Make: '', Model: '' }] })),
    );
    await expect(decodeVin('1HGCM82633A004352', empty)).rejects.toThrow(/No vehicle was found/);
    const down = vi.fn(() => Promise.resolve(response({}, false, 503)));
    await expect(decodeVin('1HGCM82633A004352', down)).rejects.toThrow(/unavailable/);
    const offline = vi.fn(() => Promise.reject(new TypeError('Failed to fetch')));
    await expect(decodeVin('1HGCM82633A004352', offline)).rejects.toThrow(/Couldn’t reach/);
  });
});
