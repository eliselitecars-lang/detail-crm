import { describe, expect, it } from 'vitest';
import { AppError } from '@/lib/errors';
import {
  answersFor,
  applyPrefill,
  buildPayload,
  describeBookableDays,
  readPrefill,
  visibleQuestions,
  weekdayRestriction,
  canGoToNextWeek,
  canGoToPreviousWeek,
  classifyBookingError,
  eligibleAddons,
  groupServices,
  groupSlotsByDay,
  initialWizardState,
  lastBookableDate,
  previousWeekStart,
  priceFor,
  pruneSelection,
  showsBalance,
  validateDetails,
  validateVehicle,
  weekWindow,
  type WizardState,
} from './model';
import {
  catalogFixture,
  COAT,
  PET,
  profileFixture,
  SEDAN,
  TRUCK,
  TZ,
  WASH,
  WAX,
} from './testFixtures';

const catalog = catalogFixture();

describe('catalog helpers', () => {
  it('uses the category price, and null when not offered', () => {
    const wash = catalog.services[0]!;
    const coat = catalog.services[1]!;
    expect(priceFor(wash, TRUCK)).toEqual({ priceCents: 20000, durationMinutes: 90 });
    expect(priceFor(coat, TRUCK)).toBeNull();
    expect(priceFor(wash, null)).toEqual({ priceCents: 15000, durationMinutes: 120 });
    expect(priceFor(coat, null)).toBeNull();
  });

  it('offers only add-ons linked to a chosen service and priced for the category', () => {
    expect(eligibleAddons(catalog, [], SEDAN)).toEqual([]);
    expect(eligibleAddons(catalog, [COAT], SEDAN).map((a) => a.id)).toEqual([WAX]);
    expect(eligibleAddons(catalog, [WASH], SEDAN).map((a) => a.id)).toEqual([WAX, PET]);
    expect(eligibleAddons(catalog, [WASH], TRUCK).map((a) => a.id)).toEqual([WAX]);
  });

  it('prunes services and add-ons that the new category does not offer', () => {
    expect(
      pruneSelection(catalog, {
        serviceIds: [WASH, COAT],
        addonIds: [WAX, PET],
        categoryId: TRUCK,
      }),
    ).toEqual({ serviceIds: [WASH], addonIds: [WAX] });
  });

  it('groups services by category', () => {
    expect(groupServices(catalog)).toEqual([
      { id: 'sc-1', name: 'Detailing', services: catalog.services },
    ]);
  });
});

describe('availability window', () => {
  // 2026-03-07 18:00 UTC = 12:00 in Chicago (Saturday before the DST change).
  const now = new Date('2026-03-07T18:00:00Z');

  it('builds a 7-day window and clamps navigation', () => {
    expect(weekWindow('2026-03-07')).toEqual({ from: '2026-03-07', to: '2026-03-13' });
    expect(canGoToPreviousWeek('2026-03-07', TZ, now)).toBe(false);
    expect(canGoToPreviousWeek('2026-03-10', TZ, now)).toBe(true);
    expect(previousWeekStart('2026-03-10', TZ, now)).toBe('2026-03-07');
    expect(previousWeekStart('2026-03-21', TZ, now)).toBe('2026-03-14');
    const last = lastBookableDate(TZ, 10, now);
    expect(last).toBe('2026-03-17');
    expect(canGoToNextWeek('2026-03-07', last)).toBe(true);
    expect(canGoToNextWeek('2026-03-14', last)).toBe(false);
    expect(canGoToNextWeek('2026-03-14', null)).toBe(true);
  });

  it('buckets slots by the SHOP-local date, not the browser zone', () => {
    // 23:30 Chicago on Mar 7 = 05:30Z Mar 8 = 19:30 Mar 7 in Honolulu (test zone).
    const days = groupSlotsByDay(
      [
        { starts_at: '2026-03-09T15:00:00Z', ends_at: '2026-03-09T16:00:00Z' },
        { starts_at: '2026-03-08T05:30:00Z', ends_at: '2026-03-08T06:00:00Z' },
      ],
      TZ,
      weekWindow('2026-03-07'),
    );
    expect(days).toHaveLength(7);
    expect(days[0]).toEqual({
      date: '2026-03-07',
      slots: [{ startsAt: '2026-03-08T05:30:00Z', endsAt: '2026-03-08T06:00:00Z' }],
    });
    expect(days[2]?.slots).toHaveLength(1);
    expect(days[1]?.slots).toHaveLength(0);
  });
});

describe('validation', () => {
  it('requires the category, make and model', () => {
    expect(
      validateVehicle(
        { categoryId: null, year: '19', make: ' ', model: '', color: '' },
        true,
        2026,
      ),
    ).toEqual({
      categoryId: 'Choose your vehicle type.',
      year: 'Enter a year between 1886 and 2028.',
      make: 'Make is required.',
      model: 'Model is required.',
    });
    expect(
      validateVehicle(
        { categoryId: SEDAN, year: '2021', make: 'Toyota', model: 'Camry', color: '' },
        true,
      ),
    ).toEqual({});
  });

  it('requires an address only for mobile service', () => {
    const details = initialWizardState(profileFixture()).details;
    const filled = { ...details, firstName: 'Ana', email: 'ana@example.com' };
    expect(validateDetails(filled, 'fixed')).toEqual({});
    expect(Object.keys(validateDetails(filled, 'mobile'))).toEqual([
      'addressLine1',
      'city',
      'postalCode',
    ]);
    expect(validateDetails({ ...filled, locationType: 'mobile' }, 'both')).toHaveProperty('city');
    expect(validateDetails({ ...filled, phone: '12' }, 'fixed')).toEqual({
      phone: 'Enter a valid phone number.',
    });
    expect(validateDetails({ ...filled, smsOptIn: true }, 'fixed')).toEqual({
      phone: 'Add a mobile number to get text updates.',
    });
  });

  it('asks non-NANP shops’ customers for the international format', () => {
    const details = initialWizardState(profileFixture()).details;
    const filled = { ...details, firstName: 'Ana', email: 'ana@example.com' };
    // The server (normalize_phone_e164 with a GB shop) rejects local numbers too.
    expect(validateDetails({ ...filled, phone: '07700 900123' }, 'fixed', 'GB')).toEqual({
      phone: 'Enter your number with the country code, starting with + (e.g. +44 7700 900123).',
    });
    expect(validateDetails({ ...filled, phone: '+44 7700 900123' }, 'fixed', 'GB')).toEqual({});
    expect(validateDetails({ ...filled, phone: '12' }, 'fixed', 'ca')).toEqual({
      phone: 'Enter a valid phone number.',
    });
  });
});

describe('showsBalance', () => {
  it('never shows the job total as owed on a cancelled or no-show booking', () => {
    expect(showsBalance('cancelled', 15000)).toBe(false);
    expect(showsBalance('no_show', 15000)).toBe(false);
  });

  it('shows open bookings’ balance and only a real balance once completed', () => {
    expect(showsBalance('scheduled', 15000)).toBe(true);
    expect(showsBalance('in_progress', 0)).toBe(true);
    expect(showsBalance('completed', 0)).toBe(false);
    expect(showsBalance('completed', 2500)).toBe(true);
  });
});

describe('buildPayload', () => {
  const base = initialWizardState(profileFixture());
  const state: WizardState = {
    ...base,
    vehicle: { categoryId: SEDAN, year: '2021', make: ' Toyota ', model: 'Camry', color: '' },
    serviceIds: [WASH],
    addonIds: [WAX],
    slot: { startsAt: '2026-03-09T15:00:00+00:00', endsAt: '2026-03-09T16:30:00+00:00' },
    details: {
      ...base.details,
      firstName: 'Ana',
      email: 'ANA@Example.com ',
      phone: '(205) 555-0123',
      smsOptIn: true,
      couponCode: 'SPRING10',
    },
  };

  it('sends only ids, contact details and the exact slot — never prices', () => {
    const payload = buildPayload(state, 'fixed');
    expect(payload).toEqual({
      customer: {
        first_name: 'Ana',
        last_name: null,
        email: 'ana@example.com',
        phone: '+12055550123',
        sms_opt_in: true,
        email_opt_in: false,
      },
      vehicle: { year: 2021, make: 'Toyota', model: 'Camry', color: null, category_id: SEDAN },
      service_ids: [WASH],
      addon_ids: [WAX],
      starts_at: '2026-03-09T15:00:00+00:00',
      location: { type: 'shop' },
      notes: null,
      coupon_code: 'SPRING10',
    });
    expect(JSON.stringify(payload)).not.toMatch(/price|total|cents/);
  });

  it('includes the service address for mobile work', () => {
    const payload = buildPayload(
      {
        ...state,
        details: {
          ...state.details,
          addressLine1: '1 Elm St',
          city: 'Hoover',
          postalCode: '35226',
        },
      },
      'mobile',
    );
    expect(payload.location).toEqual({
      type: 'mobile',
      address_line1: '1 Elm St',
      address_line2: null,
      city: 'Hoover',
      region: null,
      postal_code: '35226',
    });
  });
});

describe('classifyBookingError', () => {
  const err = (code: string, message: string) => new AppError(message, { code });

  it('maps the create_online_booking error codes', () => {
    expect(classifyBookingError(err('23P01', 'That time is no longer available.'))).toMatchObject({
      kind: 'slot_taken',
      step: 'time',
    });
    expect(classifyBookingError(err('55000', 'Online booking is not enabled.')).kind).toBe(
      'closed',
    );
    expect(classifyBookingError(err('PT429', 'Too many online bookings.')).kind).toBe(
      'rate_limited',
    );
    expect(classifyBookingError(err('PT404', 'Shop not found.'))).toMatchObject({
      kind: 'not_found',
      message: 'Shop not found.',
    });
    // A raw PostgREST error with PT404 is classified the same way.
    expect(
      classifyBookingError({ code: 'PT404', message: 'saved vehicle not found', details: null })
        .kind,
    ).toBe('not_found');
  });

  it('routes 22023 messages to the step that can fix them', () => {
    const step = (message: string) => classifyBookingError(err('22023', message)).step;
    expect(step('This address is outside our service area.')).toBe('details');
    expect(step('One or more services are not offered for this vehicle type.')).toBe('services');
    expect(step('VIN must be 5-17 letters and digits.')).toBe('vehicle');
    expect(step('One or more add-ons are not offered with the selected services.')).toBe(
      'services',
    );
    expect(step('Enter a valid email address.')).toBe('details');
    expect(step('This coupon has expired.')).toBe('details');
  });
});

describe('links into the wizard (prefill)', () => {
  it('reads only well-formed ids and codes', () => {
    const p = readPrefill(
      new URLSearchParams(
        `services=${WASH.toUpperCase()},bad,${WAX}&category=${SEDAN}&coupon=FRIEND-7K2&link=nope&embed=1`,
      ),
    );
    expect(p).toEqual({
      serviceIds: [WASH, WAX],
      categoryId: SEDAN,
      coupon: 'FRIEND-7K2',
      linkToken: null,
      embed: true,
    });
    expect(readPrefill(new URLSearchParams('coupon=<script>')).coupon).toBeNull();
  });

  it('applies what the catalog offers for that size', () => {
    const state = applyPrefill(initialWizardState(profileFixture()), catalogFixture(), {
      serviceIds: [WASH, WAX, 'ffffffff-ffff-4fff-8fff-ffffffffffff'],
      categoryId: TRUCK,
      coupon: 'SAVE5',
      linkToken: null,
      embed: false,
    });
    expect(state.vehicle.categoryId).toBe(TRUCK);
    expect(state.serviceIds).toEqual([WASH]);
    expect(state.addonIds).toEqual([WAX]);
    expect(state.couponPrefill).toBe('SAVE5');
    const unknownSize = applyPrefill(initialWizardState(profileFixture()), catalogFixture(), {
      serviceIds: [COAT],
      categoryId: 'ffffffff-ffff-4fff-8fff-ffffffffffff',
      coupon: null,
      linkToken: null,
      embed: false,
    });
    expect(unknownSize.vehicle.categoryId).toBeNull();
    expect(unknownSize.serviceIds).toEqual([COAT]);
  });
});

describe('booking questions and weekdays', () => {
  const questions = [
    {
      key: 'gate_code',
      label: 'Gate code',
      type: 'text' as const,
      options: [],
      help_text: null,
      required: true,
      location_scope: 'mobile' as const,
    },
    {
      key: 'pets',
      label: 'Pets',
      type: 'checkbox' as const,
      options: [],
      help_text: null,
      required: false,
      location_scope: null,
    },
  ];

  it('shows questions for the location and validates the answers', () => {
    expect(visibleQuestions(questions, 'shop').map((q) => q.key)).toEqual(['pets']);
    expect(visibleQuestions(questions, 'mobile').map((q) => q.key)).toEqual(['gate_code', 'pets']);
    expect(answersFor(questions, {}).errors).toEqual({ gate_code: 'Gate code is required' });
    expect(answersFor(questions, { gate_code: ' 12 ', pets: true }).answers).toEqual({
      gate_code: '12',
      pets: true,
    });
  });

  it('only sends answers to the questions shown', () => {
    const state = {
      ...initialWizardState(profileFixture({ business_type: 'fixed' })),
      slot: { startsAt: '2026-10-01T14:00:00.000Z', endsAt: '2026-10-01T15:30:00.000Z' },
      answers: { gate_code: '9', pets: true },
    };
    const payload = buildPayload(state, 'fixed', { questions, linkToken: null });
    expect(payload.answers).toEqual({ pets: true });
    expect(payload).not.toHaveProperty('link_token');
  });

  it('sends a question error back to the details step', () => {
    const error = Object.assign(new Error('Gate code is required'), { code: '22023' });
    expect(classifyBookingError(error, ['Gate code']).step).toBe('details');
  });

  it('describes category weekday limits', () => {
    const catalog = catalogFixture();
    expect(weekdayRestriction(catalog, [WASH])).toBeNull();
    catalog.service_categories = [{ id: 'sc-1', name: 'Detailing', bookable_weekdays: [5, 1] }];
    expect(weekdayRestriction(catalog, [WASH, WAX])).toEqual({
      categories: ['Detailing'],
      weekdays: [1, 5],
    });
    expect(describeBookableDays([1, 5])).toBe('Mondays and Fridays');
    expect(describeBookableDays([0, 2, 4])).toBe('Sundays, Tuesdays and Thursdays');
  });
});
