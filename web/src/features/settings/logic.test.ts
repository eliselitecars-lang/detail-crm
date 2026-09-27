import { describe, expect, it, vi } from 'vitest';
import type { BlockedTime, Coupon } from './api';
import { logoFileProblem, logoPath } from './api';
import { blockToFormInput, describeBlock, isAllDayBlock } from './blockedTimes';
import {
  couponLastDay,
  couponState,
  couponToFormInput,
  describeDiscount,
  describeWindow,
} from './coupons';
import { bookingUrl } from './links';
import { confirmationMatches } from './deleteShop';
import { planHoursReplace } from './hoursPlan';
import { moveItem, nextSortPosition } from './reorder';
import {
  blockedTimeSchema,
  bookingSchema,
  businessSchema,
  couponSchema,
  depositValueOf,
  joinMinutes,
  normalizeUrl,
  parsePostalCodes,
  smsSchema,
  splitMinutes,
  taxesSchema,
  type BookingInput,
} from './schemas';

vi.mock('@/lib/supabase', () => import('@/test/supabaseMock'));

const TZ = 'America/Chicago';

describe('durations', () => {
  it('splits minutes into the largest whole unit and back', () => {
    expect(splitMinutes(120)).toEqual({ value: '2', unit: 'hours' });
    expect(splitMinutes(2880)).toEqual({ value: '2', unit: 'days' });
    expect(splitMinutes(90)).toEqual({ value: '90', unit: 'minutes' });
    expect(splitMinutes(0)).toEqual({ value: '0', unit: 'minutes' });
    expect(joinMinutes('3', 'days')).toBe(4320);
    expect(joinMinutes('1.5', 'hours')).toBeNull();
  });
});

describe('small helpers', () => {
  it('parses postal code lists', () => {
    expect(parsePostalCodes('35203, 35209\n35203 ;sw1a 1aa,, ')).toEqual([
      '35203',
      '35209',
      'SW1A 1AA',
    ]);
    expect(parsePostalCodes('  ')).toEqual([]);
  });

  it('normalizes urls and builds booking links', () => {
    expect(normalizeUrl('example.com')).toBe('https://example.com');
    expect(normalizeUrl('http://x.io')).toBe('http://x.io');
    expect(normalizeUrl(' ')).toBe('');
    expect(bookingUrl('glacier-detailing', 'https://app.test')).toBe(
      'https://app.test/book/glacier-detailing',
    );
  });

  it('moves list items', () => {
    expect(moveItem(['a', 'b', 'c'], 0, 1)).toEqual(['b', 'a', 'c']);
    expect(moveItem(['a', 'b', 'c'], 2, 5)).toEqual(['a', 'b', 'c']);
    expect(moveItem(['a', 'b', 'c'], 2, 0)).toEqual(['c', 'a', 'b']);
  });

  it('validates logo files and builds the storage path', () => {
    const png = new File(['x'], 'logo.png', { type: 'image/png' });
    const gif = new File(['x'], 'logo.gif', { type: 'image/gif' });
    expect(logoFileProblem(png)).toBeNull();
    expect(logoFileProblem(gif)).toMatch(/PNG, JPG or WebP/);
    expect(logoPath('shop-1', 'image/jpeg')).toBe('shop-1/logo.jpg');
  });
});

describe('businessSchema', () => {
  const base = {
    name: ' Glacier ',
    phone: '(205) 555-0123',
    email: 'HI@Glacier.test',
    website: 'glacier.test',
    addressLine1: '',
    addressLine2: '',
    city: 'Birmingham',
    region: 'AL',
    postalCode: '35203',
    country: 'us',
    timezone: TZ,
    businessType: 'mobile' as const,
    reviewUrl: '',
    brandColor: '#1f6feb',
  };

  it('normalizes values for the shops row', () => {
    expect(businessSchema.parse(base)).toMatchObject({
      name: 'Glacier',
      phone: '+12055550123',
      email: 'hi@glacier.test',
      website: 'https://glacier.test',
      addressLine1: null,
      country: 'US',
      reviewUrl: null,
      brandColor: '#1F6FEB',
    });
  });

  it('rejects bad colours, zones and urls', () => {
    const result = businessSchema.safeParse({
      ...base,
      brandColor: 'blue',
      timezone: 'Mars/Base',
      reviewUrl: 'not a url',
    });
    expect(result.success).toBe(false);
    const paths = result.error?.issues.map((i) => i.path[0]);
    expect(paths).toEqual(expect.arrayContaining(['brandColor', 'timezone', 'reviewUrl']));
  });
});

describe('bookingSchema', () => {
  const base: BookingInput = {
    enabled: true,
    autoConfirm: false,
    leadTimeValue: '2',
    leadTimeUnit: 'hours',
    maxDaysAhead: '60',
    slotInterval: '30',
    buffer: '0',
    maxConcurrent: '1',
    requireDeposit: true,
    depositType: 'percent',
    depositPercent: '25',
    depositCents: null,
    postalCodes: '',
    bookingMessage: '',
    cancellationPolicy: '',
    cancelHours: '24',
  };

  it('stores percent deposits as basis points and fixed as cents', () => {
    expect(depositValueOf(bookingSchema.parse(base))).toBe(2500);
    expect(
      depositValueOf(bookingSchema.parse({ ...base, depositType: 'fixed', depositCents: 5000 })),
    ).toBe(5000);
  });

  it('requires a positive deposit only when deposits are on', () => {
    expect(bookingSchema.safeParse({ ...base, depositPercent: '0' }).success).toBe(false);
    expect(
      bookingSchema.safeParse({ ...base, depositType: 'fixed', depositCents: null }).success,
    ).toBe(false);
    expect(
      bookingSchema.safeParse({ ...base, requireDeposit: false, depositPercent: 'junk' }).success,
    ).toBe(true);
  });

  it('enforces the booking_settings ranges', () => {
    const bad = bookingSchema.safeParse({
      ...base,
      leadTimeValue: '31',
      leadTimeUnit: 'days',
      slotInterval: '1',
      maxConcurrent: '0',
      cancelHours: '9000',
    });
    expect(bad.error?.issues.map((i) => i.path[0])).toEqual(
      expect.arrayContaining(['leadTimeValue', 'slotInterval', 'maxConcurrent', 'cancelHours']),
    );
  });
});

describe('taxes & sms schemas', () => {
  it('parses tax percent to bps', () => {
    expect(
      taxesSchema.parse({
        taxRate: '9.25',
        quoteTerms: '',
        invoiceTerms: 'Net 7',
        invoiceDueDays: '7',
        techsCanCollectPayments: true,
      }),
    ).toEqual({
      taxRate: 925,
      quoteTerms: null,
      invoiceTerms: 'Net 7',
      invoiceDueDays: 7,
      techsCanCollectPayments: true,
    });
  });

  it('normalizes the SMS number to E.164 or null', () => {
    expect(smsSchema.parse({ smsFromNumber: '(205) 555-0100' })).toEqual({
      smsFromNumber: '+12055550100',
    });
    expect(smsSchema.parse({ smsFromNumber: '' })).toEqual({ smsFromNumber: null });
    expect(smsSchema.safeParse({ smsFromNumber: '123' }).success).toBe(false);
  });
});

describe('blocked times', () => {
  const schema = blockedTimeSchema(TZ);

  it('converts shop-local all-day ranges to UTC midnights (end exclusive)', () => {
    expect(
      schema.parse({
        memberId: '',
        allDay: true,
        startDate: '2026-12-24',
        startTime: '',
        endDate: '2026-12-25',
        endTime: '',
        reason: 'Holiday',
      }),
    ).toEqual({
      member_id: null,
      starts_at: '2026-12-24T06:00:00.000Z',
      ends_at: '2026-12-26T06:00:00.000Z',
      reason: 'Holiday',
    });
  });

  it('handles DST days and rejects backwards ranges', () => {
    expect(
      schema.parse({
        memberId: 'm1',
        allDay: false,
        startDate: '2026-03-08',
        startTime: '01:00',
        endDate: '2026-03-08',
        endTime: '04:00',
        reason: '',
      }),
    ).toMatchObject({
      member_id: 'm1',
      starts_at: '2026-03-08T07:00:00.000Z',
      ends_at: '2026-03-08T09:00:00.000Z',
      reason: null,
    });
    const bad = schema.safeParse({
      memberId: '',
      allDay: false,
      startDate: '2026-03-08',
      startTime: '10:00',
      endDate: '2026-03-08',
      endTime: '09:00',
      reason: '',
    });
    expect(bad.error?.issues[0]?.message).toBe('End must be after the start.');
  });

  it('describes and round-trips blocks in the shop zone', () => {
    const allDay: BlockedTime = {
      id: 'b1',
      member_id: null,
      starts_at: '2026-12-24T06:00:00Z',
      ends_at: '2026-12-26T06:00:00Z',
      reason: null,
    };
    expect(isAllDayBlock(allDay, TZ)).toBe(true);
    expect(describeBlock(allDay, TZ)).toBe('Dec 24 – Dec 25, 2026 · all day');
    expect(blockToFormInput(allDay, TZ)).toMatchObject({
      allDay: true,
      startDate: '2026-12-24',
      endDate: '2026-12-25',
    });
    const timed: BlockedTime = {
      ...allDay,
      starts_at: '2026-06-01T18:00:00Z',
      ends_at: '2026-06-01T20:30:00Z',
    };
    expect(describeBlock(timed, TZ)).toBe('Mon, Jun 1, 2026 · 1:00 – 3:30 PM');
    expect(blockToFormInput(timed, TZ)).toMatchObject({
      allDay: false,
      startTime: '13:00',
      endTime: '15:30',
    });
  });
});

describe('coupons', () => {
  const coupon: Coupon = {
    id: 'c1',
    code: 'SPRING15',
    description: null,
    kind: 'percent',
    value: 1500,
    starts_at: '2026-03-01T06:00:00Z',
    ends_at: '2026-04-01T05:00:00Z',
    max_redemptions: 10,
    redemptions: 3,
    online_only: false,
    active: true,
  };

  it('converts inclusive local days to a half-open UTC window', () => {
    const values = couponSchema(TZ).parse(couponToFormInput(coupon, TZ));
    expect(values).toMatchObject({
      code: 'SPRING15',
      kind: 'percent',
      value: 1500,
      starts_at: '2026-03-01T06:00:00.000Z',
      ends_at: '2026-04-01T05:00:00.000Z',
      max_redemptions: 10,
    });
    expect(couponLastDay(coupon.ends_at, TZ)).toBe('2026-03-31');
    expect(describeWindow(coupon, TZ)).toBe('Mar 1, 2026 – Mar 31, 2026');
  });

  it('validates code, value and window', () => {
    const bad = couponSchema(TZ).safeParse({
      ...couponToFormInput(null, TZ),
      code: 'a b',
      kind: 'fixed',
      amountCents: 0,
      startDate: '2026-05-02',
      endDate: '2026-05-01',
      maxRedemptions: '0',
    });
    expect(bad.error?.issues.map((i) => i.path[0])).toEqual(
      expect.arrayContaining(['code', 'amountCents', 'endDate', 'maxRedemptions']),
    );
  });

  it('describes discounts and state', () => {
    expect(describeDiscount(coupon)).toBe('15% off');
    expect(describeDiscount({ kind: 'fixed', value: 2500 })).toBe('$25.00 off');
    const now = new Date('2026-03-15T12:00:00Z');
    expect(couponState(coupon, now)).toBe('active');
    expect(couponState({ ...coupon, redemptions: 10 }, now)).toBe('used_up');
    expect(couponState({ ...coupon, active: false }, now)).toBe('inactive');
    expect(couponState(coupon, new Date('2026-05-01T00:00:00Z'))).toBe('expired');
    expect(couponState(coupon, new Date('2026-02-01T00:00:00Z'))).toBe('scheduled');
  });
});

describe('nextSortPosition', () => {
  it('is one past the largest sort', () => {
    expect(nextSortPosition([])).toBe(1);
    expect(nextSortPosition([{ sort: 3 }, { sort: 7 }, { sort: 1 }])).toBe(8);
  });

  it("never yields NaN for rows without a sort (e.g. another feature's cache shape)", () => {
    expect(nextSortPosition([{}, { sort: null }, { sort: 2 }])).toBe(3);
    expect(Number.isNaN(nextSortPosition([{}, {}]))).toBe(false);
  });
});

describe('planHoursReplace', () => {
  const stored = [
    { id: 'a', weekday: 1, opens_at: '08:00:00', closes_at: '12:00:00' },
    { id: 'b', weekday: 1, opens_at: '13:00:00', closes_at: '17:00:00' },
    { id: 'c', weekday: 6, opens_at: '10:00:00', closes_at: '24:00:00' },
  ];

  it('keeps unchanged intervals (seconds and 24:00 normalised)', () => {
    const plan = planHoursReplace(stored, [
      { weekday: 1, opens_at: '08:00', closes_at: '12:00' },
      { weekday: 1, opens_at: '13:00', closes_at: '17:00' },
      { weekday: 6, opens_at: '10:00', closes_at: '24:00' },
    ]);
    expect(plan).toEqual({ remove: [], insert: [] });
  });

  it('removes changed/closed intervals and inserts new ones only', () => {
    const plan = planHoursReplace(stored, [
      { weekday: 1, opens_at: '08:00', closes_at: '12:00' },
      { weekday: 1, opens_at: '12:30', closes_at: '17:00' },
      { weekday: 3, opens_at: '09:00', closes_at: '17:00' },
    ]);
    expect(plan.remove.map((r) => r.id)).toEqual(['b', 'c']);
    expect(plan.insert).toEqual([
      { weekday: 1, opens_at: '12:30', closes_at: '17:00' },
      { weekday: 3, opens_at: '09:00', closes_at: '17:00' },
    ]);
  });
});

describe('confirmationMatches', () => {
  it('requires the exact shop name, ignoring surrounding spaces', () => {
    expect(confirmationMatches('Glacier Detailing', 'Glacier Detailing')).toBe(true);
    expect(confirmationMatches('  Glacier Detailing ', 'Glacier Detailing')).toBe(true);
    expect(confirmationMatches('glacier detailing', 'Glacier Detailing')).toBe(false);
    expect(confirmationMatches('Glacier', 'Glacier Detailing')).toBe(false);
    expect(confirmationMatches('', '   ')).toBe(false);
  });
});
