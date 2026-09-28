import { describe, expect, it, vi } from 'vitest';
import { parseListParams, toListParams } from './listParams';
import {
  cardSetupMessage,
  customerAddress,
  customerName,
  normalizeTags,
  vehicleLabel,
} from './model';
import {
  customerFormSchema,
  customerFormToWrite,
  emptyCustomerForm,
  vehicleFormSchema,
  emptyVehicleForm,
} from './schemas';
import { escapeLike, searchPatterns, searchTerms } from './search';
import {
  decodeVin,
  normalizeVin,
  parseVpicResponse,
  smartCase,
  vinCheckDigit,
  vinProblem,
} from './vin';

describe('search', () => {
  it('escapes LIKE wildcards and backslashes', () => {
    expect(escapeLike('50%_off\\')).toBe('50\\%\\_off\\\\');
    expect(searchPatterns('100%')).toEqual(['%100\\%%']);
    expect(searchPatterns('a_b')).toEqual(['%a\\_b%']);
  });

  it('drops PostgREST * wildcards and splits words (AND)', () => {
    expect(searchTerms('  Jane*  DOE ')).toEqual(['jane', 'doe']);
    expect(searchTerms('*')).toEqual([]);
    expect(searchTerms('')).toEqual([]);
  });

  it('reduces phone-looking input to digits to match E.164', () => {
    expect(searchTerms('(205) 555-0123')).toEqual(['2055550123']);
    expect(searchTerms('205.555')).toEqual(['205555']);
    expect(searchTerms('jane 205-555')).toEqual(['jane', '205555']);
    // short numbers stay as typed (e.g. a street number inside a company name)
    expect(searchTerms('12')).toEqual(['12']);
  });
});

describe('model helpers', () => {
  it('names customers by person, falling back to company', () => {
    expect(customerName({ first_name: 'Jane', last_name: 'Doe', company: 'Acme' })).toBe(
      'Jane Doe',
    );
    expect(customerName({ first_name: null, last_name: ' ', company: 'Acme Fleet' })).toBe(
      'Acme Fleet',
    );
    expect(customerName({ first_name: null, last_name: null, company: null })).toBe(
      'Unnamed customer',
    );
  });

  it('formats addresses and vehicles', () => {
    expect(
      customerAddress({
        address_line1: '1 Main St',
        address_line2: null,
        city: 'Birmingham',
        region: 'AL',
        postal_code: '35203',
      }),
    ).toBe('1 Main St, Birmingham, AL 35203');
    expect(vehicleLabel({ year: 2021, make: 'Toyota', model: 'Camry', trim: 'SE' }, true)).toBe(
      '2021 Toyota Camry SE',
    );
    expect(vehicleLabel({ year: null, make: null, model: null })).toBe('Vehicle');
  });

  it('de-duplicates tags case-insensitively', () => {
    expect(normalizeTags([' VIP ', 'vip', 'Fleet  account', ''])).toEqual(['VIP', 'Fleet account']);
  });

  it('builds the card-setup text', () => {
    expect(cardSetupMessage('Glacier', 'Jane', 'https://x.test/s')).toBe(
      'Hi Jane, Glacier here. Add a card on file securely using this link: https://x.test/s',
    );
    expect(cardSetupMessage('Glacier', null, 'u')).toMatch(/^Hi, Glacier here\./);
  });
});

describe('list params: search text', () => {
  it('writes the search as typed (trailing space kept) and drops blank searches', () => {
    const base = parseListParams(new URLSearchParams());
    expect(toListParams({ ...base, search: 'jane ' }).get('q')).toBe('jane ');
    expect(parseListParams(toListParams({ ...base, search: 'jane ' })).search).toBe('jane ');
    expect(toListParams({ ...base, search: '   ' }).has('q')).toBe(false);
    expect(searchPatterns('jane ')).toEqual(['%jane%']);
  });
});

describe('list params', () => {
  it('round-trips non-default filters and ignores junk', () => {
    const f = parseListParams(
      new URLSearchParams(
        'q=jane&tag=VIP&lifecycle=lead&archived=all&sort=created_at&dir=asc&page=3',
      ),
    );
    expect(f).toMatchObject({
      search: 'jane',
      tag: 'VIP',
      lifecycle: 'lead',
      archived: 'all',
      sort: { key: 'created_at', direction: 'asc' },
      page: 3,
    });
    expect(toListParams(f).toString()).toBe(
      'q=jane&tag=VIP&lifecycle=lead&archived=all&sort=created_at&dir=asc&page=3',
    );
    const junk = parseListParams(new URLSearchParams('lifecycle=x&archived=y&sort=z&page=-2'));
    expect(junk).toMatchObject({
      lifecycle: null,
      archived: 'active',
      sort: { key: 'name', direction: 'asc' },
      page: 1,
    });
    expect(toListParams(junk).toString()).toBe('');
  });
});

describe('customer form schema', () => {
  it('requires a first name, last name or company', () => {
    const result = customerFormSchema.safeParse(emptyCustomerForm());
    expect(result.success).toBe(false);
    expect(result.error?.issues[0]?.path).toEqual(['firstName']);
  });

  it('normalises phone, email, country and tags; blanks become null', () => {
    const values = customerFormSchema.parse({
      ...emptyCustomerForm(),
      firstName: ' Jane ',
      phone: '(205) 555-0123',
      email: 'Jane@Example.COM',
      country: 'us',
      tags: ['vip', 'VIP', ' fleet '],
    });
    const write = customerFormToWrite(values);
    expect(write).toMatchObject({
      first_name: 'Jane',
      last_name: null,
      phone: '+12055550123',
      email: 'jane@example.com',
      country: 'US',
      tags: ['vip', 'fleet'],
      lifecycle: 'customer',
      source: 'staff',
    });
    expect(write).not.toHaveProperty('portal_user_id');
    expect(write).not.toHaveProperty('stripe_customer_id');
  });

  it('rejects bad phones and countries', () => {
    const result = customerFormSchema.safeParse({
      ...emptyCustomerForm(),
      company: 'Acme',
      phone: '555',
      country: 'USA',
    });
    expect(result.success).toBe(false);
    const paths = result.error?.issues.map((i) => i.path[0]);
    expect(paths).toContain('phone');
    expect(paths).toContain('country');
  });

  it('accepts every email the database stores, so an iPhone/imported customer stays editable', () => {
    // public.is_valid_email accepts these; zod's z.email() rejected them.
    for (const email of ['josé@example.com', 'user@münchen.de', 'a!b@example.com', 'x@y.z']) {
      const result = customerFormSchema.safeParse({
        ...emptyCustomerForm(),
        firstName: 'Jane',
        email,
        notes: 'Only the notes changed',
      });
      expect(result.success, email).toBe(true);
    }
    const bad = customerFormSchema.safeParse({
      ...emptyCustomerForm(),
      firstName: 'Jane',
      email: 'jane@example',
    });
    expect(bad.success).toBe(false);
    expect(bad.error?.issues[0]?.message).toBe('Enter a valid email address.');
  });
});

describe('vehicle form schema', () => {
  it('normalises VIN and plate, converts year', () => {
    const v = vehicleFormSchema.parse({
      ...emptyVehicleForm(),
      year: '2021',
      vin: '1hgcm-82633 a004352',
      licensePlate: 'abc 123',
    });
    expect(v).toMatchObject({ year: 2021, vin: '1HGCM82633A004352', licensePlate: 'ABC 123' });
    expect(vehicleFormSchema.safeParse({ ...emptyVehicleForm(), year: '21' }).success).toBe(false);
    expect(vehicleFormSchema.safeParse({ ...emptyVehicleForm(), vin: 'ABC' }).success).toBe(false);
  });
});

describe('VIN', () => {
  it('computes check digits', () => {
    expect(vinCheckDigit('1HGCM82633A004352')).toBe('3');
    expect(vinCheckDigit('1M8GDM9AXKP042788')).toBe('X');
    expect(vinCheckDigit('short')).toBeNull();
  });

  it('explains what is wrong with a VIN', () => {
    expect(vinProblem('')).toBe('empty');
    expect(vinProblem('1HGCM82633A00435')).toBe('length');
    expect(vinProblem('1HGCM82633A00435O')).toBe('characters');
    expect(vinProblem('1HGCM82643A004352')).toBe('check_digit');
    expect(vinProblem(' 1hgcm82633a004352 ')).toBeNull();
    expect(normalizeVin('1hg-cm 8')).toBe('1HGCM8');
  });

  it('title-cases shouting makes but keeps short acronyms', () => {
    expect(smartCase('TOYOTA')).toBe('Toyota');
    expect(smartCase('MERCEDES-BENZ')).toBe('Mercedes-Benz');
    expect(smartCase('LAND ROVER')).toBe('Land Rover');
    expect(smartCase('BMW')).toBe('BMW');
    expect(smartCase('McLaren')).toBe('McLaren');
  });

  it('parses vPIC results', () => {
    expect(
      parseVpicResponse({
        Results: [
          { ModelYear: '2003', Make: 'HONDA', Model: 'Accord', Trim: 'EX', ErrorCode: '0' },
        ],
      }),
    ).toEqual({ year: 2003, make: 'Honda', model: 'Accord', trim: 'EX' });
    expect(() =>
      parseVpicResponse({ Results: [{ ModelYear: '', Make: '', Model: '', ErrorCode: '11' }] }),
    ).toThrow(/couldn’t decode/);
    expect(() => parseVpicResponse({ nope: true })).toThrow(/unexpected response/);
  });

  it('calls vPIC and maps failures to friendly errors', async () => {
    const ok = vi.fn(() =>
      Promise.resolve(
        new Response(
          JSON.stringify({ Results: [{ ModelYear: '2003', Make: 'HONDA', Model: 'Accord' }] }),
        ),
      ),
    );
    await expect(decodeVin('1HGCM82633A004352', { fetchImpl: ok })).resolves.toMatchObject({
      make: 'Honda',
    });
    expect(ok).toHaveBeenCalledWith(
      'https://vpic.nhtsa.dot.gov/api/vehicles/DecodeVinValues/1HGCM82633A004352?format=json',
      expect.anything(),
    );

    const offline = vi.fn(() => Promise.reject(new TypeError('Failed to fetch')));
    await expect(decodeVin('1HGCM82633A004352', { fetchImpl: offline })).rejects.toThrow(
      /Couldn’t reach the VIN service/,
    );

    const down = vi.fn(() => Promise.resolve(new Response('x', { status: 503 })));
    await expect(decodeVin('1HGCM82633A004352', { fetchImpl: down })).rejects.toThrow(
      /unavailable/,
    );

    await expect(decodeVin('bad', { fetchImpl: ok })).rejects.toThrow(/letters and numbers|17/);
    expect(ok).toHaveBeenCalledTimes(1);
  });
});
