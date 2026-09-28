import { describe, expect, it, vi } from 'vitest';
import type { BlockedTime, Coupon } from './api';
import { logoFileProblem, logoPath } from './api';
import { blockToFormInput, describeBlock, describeRecurrence, isAllDayBlock } from './blockedTimes';
import {
  couponLastDay,
  couponRestrictions,
  couponState,
  couponToFormInput,
  describeDiscount,
  describeWindow,
} from './coupons';
import { bookingUrl } from './links';
import { confirmationMatches } from './deleteShop';
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
    maxConcurrentShop: '',
    maxConcurrentMobile: '',
    countMemberAvailability: false,
    allowMultiDay: false,
    multiDayMaxDays: '2',
    quoteSelfSchedule: false,
    metaPixelId: '',
    ga4MeasurementId: '',
  };

  it('validates tracking ids like the database CHECKs', () => {
    const ok = bookingSchema.parse({
      ...base,
      metaPixelId: ' 123456789012 ',
      ga4MeasurementId: 'g-abc1234',
    });
    expect(ok.metaPixelId).toBe('123456789012');
    expect(ok.ga4MeasurementId).toBe('G-ABC1234');
    expect(bookingSchema.parse(base).metaPixelId).toBeNull();
    const bad = bookingSchema.safeParse({
      ...base,
      metaPixelId: 'fb-123',
      ga4MeasurementId: 'UA-1',
    });
    expect(bad.error?.issues.map((i) => i.path[0])).toEqual(
      expect.arrayContaining(['metaPixelId', 'ga4MeasurementId']),
    );
  });

  it('bounds the location caps and multi-day length', () => {
    const ok = bookingSchema.parse({ ...base, maxConcurrentShop: '2', multiDayMaxDays: '7' });
    expect(ok.maxConcurrentShop).toBe(2);
    expect(ok.maxConcurrentMobile).toBeNull();
    const bad = bookingSchema.safeParse({
      ...base,
      maxConcurrentMobile: '101',
      multiDayMaxDays: '8',
    });
    expect(bad.error?.issues.map((i) => i.path[0])).toEqual(
      expect.arrayContaining(['maxConcurrentMobile', 'multiDayMaxDays']),
    );
  });

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
        techsCanShareReports: false,
      }),
    ).toEqual({
      taxRate: 925,
      quoteTerms: null,
      invoiceTerms: 'Net 7',
      invoiceDueDays: 7,
      techsCanCollectPayments: true,
      techsCanShareReports: false,
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
  const extra = {
    kind: 'closed' as const,
    title: '',
    affectsCapacity: true,
    repeat: '' as const,
    interval: '1',
    weekdays: [],
    repeatEnd: 'never' as const,
    untilDate: '',
    count: '10',
  };

  it('converts shop-local all-day ranges to UTC midnights (end exclusive)', () => {
    expect(
      schema.parse({
        ...extra,
        memberId: '',
        allDay: true,
        startDate: '2026-12-24',
        startTime: '',
        endDate: '2026-12-25',
        endTime: '',
        reason: 'Holiday',
      }),
    ).toEqual({
      kind: 'closed',
      member_id: null,
      title: null,
      starts_at: '2026-12-24T06:00:00.000Z',
      ends_at: '2026-12-26T06:00:00.000Z',
      reason: 'Holiday',
      affects_capacity: true,
      recurrence: null,
    });
  });

  it('handles DST days and rejects backwards ranges', () => {
    expect(
      schema.parse({
        ...extra,
        kind: 'time_off',
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
      ...extra,
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

  it('builds repeat rules and checks their bounds', () => {
    const base = {
      ...extra,
      kind: 'meeting' as const,
      memberId: '',
      allDay: false,
      startDate: '2026-06-01',
      startTime: '08:00',
      endDate: '2026-06-01',
      endTime: '08:30',
      reason: '',
      affectsCapacity: false,
    };
    expect(
      schema.parse({
        ...base,
        repeat: 'week',
        interval: '2',
        weekdays: [3, 1, 3],
        repeatEnd: 'until',
        untilDate: '2026-12-31',
      }),
    ).toMatchObject({
      kind: 'meeting',
      affects_capacity: false,
      recurrence: { freq: 'week', interval: 2, by_weekday: [1, 3], until_date: '2026-12-31' },
    });
    expect(
      schema.parse({ ...base, repeat: 'month', repeatEnd: 'count', count: '6' }).recurrence,
    ).toEqual({ freq: 'month', interval: 1, count: 6 });
    const bad = schema.safeParse({
      ...base,
      repeat: 'week',
      interval: '13',
      weekdays: [],
      repeatEnd: 'until',
      untilDate: '2026-05-01',
    });
    expect(bad.error?.issues.map((i) => i.path[0])).toEqual(
      expect.arrayContaining(['interval', 'weekdays', 'untilDate']),
    );
    expect(schema.safeParse({ ...base, kind: 'time_off' }).error?.issues[0]?.path[0]).toBe(
      'memberId',
    );
    expect(describeRecurrence({ freq: 'week', interval: 2, by_weekday: [1, 3], count: 4 })).toBe(
      'Every 2 weeks on Mon, Wed · 4 times',
    );
    expect(describeRecurrence({ freq: 'day', until_date: '2026-12-31' })).toBe(
      'Every day · until Dec 31, 2026',
    );
    expect(describeRecurrence({ freq: 'week', except_dates: ['2026-10-05', '2026-10-12'] })).toBe(
      'Every week · 2 dates skipped',
    );
  });

  it('describes and round-trips blocks in the shop zone', () => {
    const allDay: BlockedTime = {
      id: 'b1',
      member_id: null,
      starts_at: '2026-12-24T06:00:00Z',
      ends_at: '2026-12-26T06:00:00Z',
      reason: null,
      kind: 'closed',
      title: null,
      customer_id: null,
      affects_capacity: true,
      color: null,
      recurrence: null,
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
    service_ids: null,
    min_subtotal_cents: null,
    once_per_customer: false,
    customer_id: null,
    new_customers_only: false,
  };

  it('round-trips restrictions (services, minimum, once, customer, new customers)', () => {
    const restricted: Coupon = {
      ...coupon,
      service_ids: ['s1', 's2'],
      min_subtotal_cents: 10000,
      once_per_customer: true,
    };
    expect(couponSchema(TZ).parse(couponToFormInput(restricted, TZ))).toMatchObject({
      service_ids: ['s1', 's2'],
      min_subtotal_cents: 10000,
      once_per_customer: true,
      customer_id: null,
      new_customers_only: false,
    });
    expect(couponSchema(TZ).parse(couponToFormInput(coupon, TZ))).toMatchObject({
      service_ids: null,
      min_subtotal_cents: null,
    });
    expect(couponRestrictions(restricted)).toEqual([
      '2 services',
      'Min $100.00',
      'Once per customer',
    ]);
    const conflicting = couponSchema(TZ).safeParse({
      ...couponToFormInput(coupon, TZ),
      customerId: 'cust-1',
      newCustomersOnly: true,
      limitServices: true,
      serviceIds: [],
    });
    expect(conflicting.error?.issues.map((i) => i.path[0])).toEqual(
      expect.arrayContaining(['newCustomersOnly', 'serviceIds']),
    );
  });

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

describe('confirmationMatches', () => {
  it('requires the exact shop name, ignoring surrounding spaces', () => {
    expect(confirmationMatches('Glacier Detailing', 'Glacier Detailing')).toBe(true);
    expect(confirmationMatches('  Glacier Detailing ', 'Glacier Detailing')).toBe(true);
    expect(confirmationMatches('glacier detailing', 'Glacier Detailing')).toBe(false);
    expect(confirmationMatches('Glacier', 'Glacier Detailing')).toBe(false);
    expect(confirmationMatches('', '   ')).toBe(false);
  });
});
