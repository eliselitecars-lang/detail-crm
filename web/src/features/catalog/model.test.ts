import { describe, expect, it } from 'vitest';
import {
  buildPriceDrafts,
  checklistItemsError,
  checklistPayload,
  describeUsage,
  formatDuration,
  imageFileError,
  moveItem,
  parseChecklistItems,
  planHasChanges,
  planPriceChanges,
  resequence,
  commissionColumns,
  daysToOffsetParts,
  describeCommission,
  describeFollowupOffset,
  describeWeekdays,
  formatQuantity,
  offsetPartsToDays,
  parseQuantity,
  serviceColumns,
  serviceFormDefaults,
  weekdaysValue,
  serviceFormSchema,
  serviceImagePath,
  soleAddonServices,
  usageTotal,
  type PriceRow,
} from './model';

function price(overrides: Partial<PriceRow>): PriceRow {
  return {
    id: 'p1',
    shop_id: 'shop-1',
    service_id: 'svc-1',
    vehicle_category_id: null,
    price_cents: 10000,
    duration_minutes: null,
    created_at: '2026-01-01T00:00:00Z',
    updated_at: '2026-01-01T00:00:00Z',
    ...overrides,
  };
}

const categories = [
  { id: 'suv', name: 'SUV', sort: 20 },
  { id: 'car', name: 'Car', sort: 10 },
];

describe('formatDuration', () => {
  it('formats minutes', () => {
    expect(formatDuration(0)).toBe('No time');
    expect(formatDuration(45)).toBe('45 min');
    expect(formatDuration(60)).toBe('1 h');
    expect(formatDuration(150)).toBe('2 h 30 min');
    expect(formatDuration(null)).toBe('—');
  });
});

describe('service form', () => {
  it('parses text fields into columns', () => {
    const values = serviceFormSchema.parse({
      ...serviceFormDefaults(),
      name: '  Full detail ',
      durationMinutes: '180',
      sort: '-5',
      categoryId: '',
    });
    expect(serviceColumns(values)).toEqual({
      name: 'Full detail',
      description: null,
      kind: 'service',
      category_id: null,
      duration_minutes: 180,
      taxable: true,
      online_bookable: false,
      active: true,
      sort: -5,
      min_before_photos: 0,
      min_after_photos: 0,
    });
  });

  it('rejects out-of-range durations and empty names', () => {
    const result = serviceFormSchema.safeParse({
      ...serviceFormDefaults(),
      name: ' ',
      durationMinutes: '1441',
    });
    expect(result.success).toBe(false);
    const paths = result.error?.issues.map((i) => i.path[0]);
    expect(paths).toContain('name');
    expect(paths).toContain('durationMinutes');
  });

  it('adds commission columns only when asked, as bps or cents', () => {
    const percent = serviceFormSchema.parse({
      ...serviceFormDefaults(),
      name: 'Coating',
      commissionKind: 'percent',
      commissionPercent: '7.5',
    });
    expect(serviceColumns(percent)).not.toHaveProperty('commission_kind');
    expect(serviceColumns(percent, { commission: true })).toMatchObject({
      commission_kind: 'percent',
      commission_value: 750,
    });
    const flat = serviceFormSchema.parse({
      ...serviceFormDefaults(),
      name: 'Tint',
      commissionKind: 'flat',
      commissionCents: 2500,
    });
    expect(commissionColumns(flat)).toEqual({ commission_kind: 'flat', commission_value: 2500 });
    const missing = serviceFormSchema.safeParse({
      ...serviceFormDefaults(),
      name: 'Tint',
      commissionKind: 'flat',
      commissionCents: null,
    });
    expect(missing.success).toBe(false);
    expect(
      serviceFormSchema.safeParse({ ...serviceFormDefaults(), name: 'X', minAfterPhotos: '21' })
        .success,
    ).toBe(false);
  });

  it('round-trips a saved commission into the form', () => {
    const d = serviceFormDefaults({
      commission_kind: 'percent',
      commission_value: 1250,
      min_before_photos: 2,
      min_after_photos: 3,
    } as Parameters<typeof serviceFormDefaults>[0]);
    expect(d).toMatchObject({
      commissionKind: 'percent',
      commissionPercent: '12.5',
      minBeforePhotos: '2',
      minAfterPhotos: '3',
    });
    expect(describeCommission({ commission_kind: 'flat', commission_value: 500 }, 'usd')).toBe(
      '$5.00 per unit sold',
    );
    expect(describeCommission({ commission_kind: 'none', commission_value: 0 }, 'usd')).toBeNull();
  });
});

describe('follow-up offsets, quantities and weekdays', () => {
  it('converts offsets between days and units', () => {
    expect(daysToOffsetParts(90)).toEqual({ amount: '3', unit: 'months' });
    expect(daysToOffsetParts(14)).toEqual({ amount: '2', unit: 'weeks' });
    expect(daysToOffsetParts(10)).toEqual({ amount: '10', unit: 'days' });
    expect(offsetPartsToDays('6', 'months')).toEqual({ days: 180, error: null });
    expect(offsetPartsToDays('0', 'days').error).toMatch(/1 or more/);
    expect(offsetPartsToDays('37', 'months').error).toMatch(/1095/);
    expect(describeFollowupOffset(30)).toBe('1 month after the visit');
    expect(describeFollowupOffset(21)).toBe('3 weeks after the visit');
  });

  it('parses consumable quantities', () => {
    expect(parseQuantity('1.5')).toBe(1.5);
    expect(parseQuantity('2,25')).toBe(2.25);
    expect(parseQuantity('0')).toBeNull();
    expect(parseQuantity('1.2345')).toBeNull();
    expect(formatQuantity(0.1 + 0.2)).toBe('0.3');
  });

  it('describes and stores bookable weekdays', () => {
    expect(describeWeekdays(null)).toBe('Every day');
    expect(describeWeekdays([3, 1])).toBe('Mon, Wed');
    expect(describeWeekdays([])).toMatch(/not bookable online/);
    expect(weekdaysValue(new Set([0, 1, 2, 3, 4, 5, 6]))).toBeNull();
    expect(weekdaysValue(new Set([5, 1]))).toEqual([1, 5]);
  });
});

describe('price grid', () => {
  it('builds base + categories in sort order', () => {
    const drafts = buildPriceDrafts(
      [
        price({ id: 'base', price_cents: 5000 }),
        price({ id: 'x', vehicle_category_id: 'suv', duration_minutes: 90 }),
      ],
      categories,
    );
    expect(drafts).toEqual([
      { vehicleCategoryId: null, id: 'base', priceCents: 5000, duration: '' },
      { vehicleCategoryId: 'car', id: null, priceCents: null, duration: '' },
      { vehicleCategoryId: 'suv', id: 'x', priceCents: 10000, duration: '90' },
    ]);
  });

  it('plans inserts, updates and deletes', () => {
    const saved = [
      price({ id: 'base', price_cents: 5000 }),
      price({ id: 'x', vehicle_category_id: 'suv', price_cents: 9000 }),
    ];
    const plan = planPriceChanges(
      [
        { vehicleCategoryId: null, id: 'base', priceCents: 5500, duration: '' },
        { vehicleCategoryId: 'car', id: null, priceCents: 6000, duration: '75' },
        { vehicleCategoryId: 'suv', id: 'x', priceCents: null, duration: '' },
      ],
      saved,
    );
    expect(plan).toEqual({
      updates: [{ id: 'base', price_cents: 5500, duration_minutes: null }],
      inserts: [{ vehicle_category_id: 'car', price_cents: 6000, duration_minutes: 75 }],
      deletes: ['x'],
      errors: {},
    });
    expect(planHasChanges(plan)).toBe(true);
  });

  it('skips unchanged rows and validates durations', () => {
    const saved = [price({ id: 'base', price_cents: 5000, duration_minutes: 60 })];
    const unchanged = planPriceChanges(
      [{ vehicleCategoryId: null, id: 'base', priceCents: 5000, duration: '60' }],
      saved,
    );
    expect(planHasChanges(unchanged)).toBe(false);

    const bad = planPriceChanges(
      [
        { vehicleCategoryId: null, id: null, priceCents: null, duration: '30' },
        { vehicleCategoryId: 'car', id: null, priceCents: 100, duration: 'abc' },
      ],
      [],
    );
    expect(bad.errors).toEqual({
      '': 'Enter a price to set a duration.',
      car: 'Duration must be 0–1440 minutes.',
    });
    expect(planHasChanges(bad)).toBe(false);
  });
});

describe('checklists', () => {
  it('parses stored items defensively', () => {
    expect(parseChecklistItems([{ id: 'a', label: 'Wash' }])).toEqual([{ id: 'a', label: 'Wash' }]);
    expect(parseChecklistItems('nope')).toEqual([]);
    expect(parseChecklistItems([{ id: 'bad id!', label: 'x' }])).toEqual([]);
  });

  it('builds the payload: trims, drops blanks, keeps ids of existing items', () => {
    expect(
      checklistPayload([
        { key: 'a', id: 'a', label: ' Rinse ' },
        { key: 'b', id: null, label: 'Dry' },
        { key: 'c', id: null, label: '   ' },
      ]),
    ).toEqual([{ id: 'a', label: 'Rinse' }, { label: 'Dry' }]);
  });

  it('limits items', () => {
    const many = Array.from({ length: 201 }, (_, i) => ({ key: String(i), id: null, label: 'x' }));
    expect(checklistItemsError(many)).toMatch(/at most 200/);
    expect(checklistItemsError([{ key: 'a', id: null, label: 'x'.repeat(201) }])).toMatch(
      /200 characters/,
    );
    expect(checklistItemsError([{ key: 'a', id: null, label: 'ok' }])).toBeNull();
  });
});

describe('ordering', () => {
  it('moves and resequences only changed rows', () => {
    const rows = [
      { id: 'a', sort: 10 },
      { id: 'b', sort: 20 },
      { id: 'c', sort: 30 },
    ];
    expect(resequence(moveItem(rows, 2, 0))).toEqual([
      { id: 'c', sort: 10 },
      { id: 'a', sort: 20 },
      { id: 'b', sort: 30 },
    ]);
    expect(resequence(rows)).toEqual([]);
  });
});

describe('images and usage', () => {
  it('validates files and builds the storage path', () => {
    expect(imageFileError({ type: 'image/gif', size: 10 })).toMatch(/PNG, JPEG or WebP/);
    expect(imageFileError({ type: 'image/png', size: 6 * 1024 * 1024 })).toMatch(/5 MB/);
    expect(imageFileError({ type: 'image/webp', size: 1000 })).toBeNull();
    expect(serviceImagePath('shop-1', 'svc-1', 'image/jpeg')).toBe('shop-1/services/svc-1.jpg');
  });

  it('describes usage', () => {
    const usage = { jobLines: 2, quoteLines: 0, invoiceLines: 1, packages: 1, plans: 0 };
    expect(usageTotal(usage)).toBe(4);
    expect(describeUsage(usage)).toBe('2 job lines, 1 invoice line, 1 package');
  });
});

describe('soleAddonServices', () => {
  it('finds services that would switch to "all add-ons" if the add-on went away', () => {
    const links = [
      { service_id: 's1', addon_id: 'a1' },
      { service_id: 's2', addon_id: 'a1' },
      { service_id: 's2', addon_id: 'a2' },
      { service_id: 's3', addon_id: 'a1' },
    ];
    expect(soleAddonServices('a1', ['s1', 's2', 's3'], links)).toEqual(['s1', 's3']);
    expect(soleAddonServices('a1', [], links)).toEqual([]);
  });
});
