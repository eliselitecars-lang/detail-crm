/**
 * Form schemas for settings. Every bound mirrors a CHECK constraint in the
 * migrations (0002 shops, 0003 shop setup, 0005 coupons, 0023 forms, 0032
 * templates) so users see a field error instead of a server rejection. The
 * server remains the authority.
 */
import { z } from 'zod';
import { addLocalDays, isLocalDate, isValidTimeZone, shopLocalToUtcIso } from '@/lib/dates';
import { parsePercentToBps } from '@/lib/money';
import {
  zOptionalEmail,
  zOptionalPhone,
  zOptionalText,
  zPercentBps,
  zRequiredText,
} from '@/lib/validation';

// ---------------------------------------------------------------------------
// Small field helpers
// ---------------------------------------------------------------------------

/** Whole number typed as text, within [min, max]. */
export const zIntText = (label: string, min: number, max: number) =>
  z
    .string()
    .trim()
    .refine((v) => /^\d+$/.test(v), `${label} must be a whole number.`)
    .transform(Number)
    .refine((n) => n >= min && n <= max, `${label} must be between ${min} and ${max}.`);

/** Optional positive whole number ('' → null). */
export const zOptionalPositiveIntText = (label: string, max = 1_000_000) =>
  z
    .string()
    .trim()
    .refine((v) => v === '' || /^\d+$/.test(v), `${label} must be a whole number.`)
    .transform((v) => (v === '' ? null : Number(v)))
    .refine(
      (n) => n === null || (n >= 1 && n <= max),
      `${label} must be between 1 and ${max.toLocaleString('en-US')}.`,
    );

const URL_RE = /^https?:\/\/[^\s/$.?#][^\s]*\.[^\s]+$/i;

/** Adds https:// to a bare domain ("example.com" → "https://example.com"). */
export function normalizeUrl(value: string): string {
  const trimmed = value.trim();
  if (trimmed === '') return '';
  return /^[a-z][a-z0-9+.-]*:\/\//i.test(trimmed) ? trimmed : `https://${trimmed}`;
}

/** Optional web address ('' → null); bare domains get https://. */
export const zOptionalUrl = (max: number) =>
  z
    .string()
    .trim()
    .transform(normalizeUrl)
    .refine((v) => v === '' || URL_RE.test(v), 'Enter a web address, like https://example.com.')
    .refine((v) => v.length <= max, `Use ${max} characters or fewer.`)
    .transform((v) => (v === '' ? null : v));

export const HEX_COLOR_RE = /^#[0-9A-Fa-f]{6}$/;

// ---------------------------------------------------------------------------
// Business profile
// ---------------------------------------------------------------------------

export const BUSINESS_TYPES = ['fixed', 'mobile', 'both'] as const;

export const businessSchema = z.object({
  name: zRequiredText('Business name', 120),
  phone: zOptionalPhone,
  email: zOptionalEmail,
  website: zOptionalUrl(500),
  addressLine1: zOptionalText(200),
  addressLine2: zOptionalText(200),
  city: zOptionalText(100),
  region: zOptionalText(100),
  postalCode: zOptionalText(20),
  country: z
    .string()
    .trim()
    .transform((v) => v.toUpperCase())
    .refine((v) => /^[A-Z]{2}$/.test(v), 'Use a two-letter country code, like US.'),
  timezone: z.string().refine(isValidTimeZone, 'Choose a valid time zone.'),
  businessType: z.enum(BUSINESS_TYPES),
  reviewUrl: zOptionalUrl(1000),
  brandColor: z
    .string()
    .trim()
    .refine((v) => v === '' || HEX_COLOR_RE.test(v), 'Use a hex colour like #1F6FEB.')
    .transform((v) => (v === '' ? null : v.toUpperCase())),
});
export type BusinessInput = z.input<typeof businessSchema>;
export type BusinessValues = z.output<typeof businessSchema>;

// ---------------------------------------------------------------------------
// Durations (lead time) — minutes shown as the largest whole unit
// ---------------------------------------------------------------------------

export const DURATION_UNITS = ['minutes', 'hours', 'days'] as const;
export type DurationUnit = (typeof DURATION_UNITS)[number];
export const UNIT_MINUTES: Record<DurationUnit, number> = { minutes: 1, hours: 60, days: 1440 };

/** 1440 → {value:'1', unit:'days'}; 90 → {value:'90', unit:'minutes'}. */
export function splitMinutes(minutes: number): { value: string; unit: DurationUnit } {
  const abs = Math.abs(minutes);
  if (abs !== 0 && abs % 1440 === 0) return { value: String(abs / 1440), unit: 'days' };
  if (abs !== 0 && abs % 60 === 0) return { value: String(abs / 60), unit: 'hours' };
  return { value: String(abs), unit: 'minutes' };
}

/** {value:'2', unit:'hours'} → 120; null when not a whole number. */
export function joinMinutes(value: string, unit: DurationUnit): number | null {
  const text = value.trim();
  if (!/^\d+$/.test(text)) return null;
  return Number(text) * UNIT_MINUTES[unit];
}

// ---------------------------------------------------------------------------
// Online booking
// ---------------------------------------------------------------------------

/** Splits a free-text list of postal codes (commas, spaces, new lines). */
export function parsePostalCodes(text: string): string[] {
  const seen = new Set<string>();
  const codes: string[] = [];
  for (const raw of text.split(/[\n,;]+/)) {
    const code = raw.trim().toUpperCase();
    if (code === '' || seen.has(code)) continue;
    seen.add(code);
    codes.push(code);
  }
  return codes;
}

export const DEPOSIT_TYPES = ['percent', 'fixed'] as const;

export const bookingSchema = z
  .object({
    enabled: z.boolean(),
    autoConfirm: z.boolean(),
    leadTimeValue: z.string(),
    leadTimeUnit: z.enum(DURATION_UNITS),
    maxDaysAhead: zIntText('Booking window', 1, 365),
    slotInterval: zIntText('Start time interval', 5, 240),
    buffer: zIntText('Buffer', 0, 480),
    maxConcurrent: zIntText('Jobs at the same time', 1, 100),
    requireDeposit: z.boolean(),
    depositType: z.enum(DEPOSIT_TYPES),
    depositPercent: z.string(),
    depositCents: z.number().int().nullable(),
    postalCodes: z.string().max(20000, 'That list is too long.'),
    bookingMessage: zOptionalText(5000),
    cancellationPolicy: zOptionalText(5000),
    cancelHours: zIntText('Cancellation window', 0, 8760),
  })
  .superRefine((v, ctx) => {
    const lead = joinMinutes(v.leadTimeValue, v.leadTimeUnit);
    if (lead === null || lead > 43200) {
      ctx.addIssue({
        code: 'custom',
        path: ['leadTimeValue'],
        message: 'Minimum notice must be a whole number up to 30 days.',
      });
    }
    if (!v.requireDeposit) {
      // Hidden fields: nothing to validate (deposit_value may stay as stored).
    } else if (v.depositType === 'percent') {
      const bps = parsePercentToBps(v.depositPercent);
      if (bps === null || bps === 0) {
        ctx.addIssue({
          code: 'custom',
          path: ['depositPercent'],
          message: 'Enter a percentage between 0.01 and 100.',
        });
      }
    } else if (v.depositCents === null || v.depositCents <= 0) {
      ctx.addIssue({
        code: 'custom',
        path: ['depositCents'],
        message: 'Enter a deposit amount greater than $0.',
      });
    }
    if (parsePostalCodes(v.postalCodes).some((code) => code.length > 20)) {
      ctx.addIssue({
        code: 'custom',
        path: ['postalCodes'],
        message: 'Each postal code must be 20 characters or fewer.',
      });
    }
  });
export type BookingInput = z.input<typeof bookingSchema>;
export type BookingValues = z.output<typeof bookingSchema>;

/** deposit_value for the chosen type: basis points for percent, cents for fixed. */
export function depositValueOf(v: BookingValues): number {
  if (v.depositType === 'percent') return parsePercentToBps(v.depositPercent) ?? 0;
  return v.depositCents ?? 0;
}

// ---------------------------------------------------------------------------
// Taxes & documents
// ---------------------------------------------------------------------------

export const taxesSchema = z.object({
  taxRate: zPercentBps(100),
  quoteTerms: zOptionalText(20000),
  invoiceTerms: zOptionalText(20000),
  invoiceDueDays: zIntText('Payment due', 0, 365),
  techsCanCollectPayments: z.boolean(),
});
export type TaxesInput = z.input<typeof taxesSchema>;
export type TaxesValues = z.output<typeof taxesSchema>;

// ---------------------------------------------------------------------------
// Blocked times (shop-local inputs → UTC instants)
// ---------------------------------------------------------------------------

const TIME_RE = /^\d{2}:\d{2}$/;

export function blockedTimeSchema(timeZone: string) {
  return z
    .object({
      memberId: z.string(),
      allDay: z.boolean(),
      startDate: z.string().refine(isLocalDate, 'Choose a start date.'),
      startTime: z.string(),
      endDate: z.string().refine(isLocalDate, 'Choose an end date.'),
      endTime: z.string(),
      reason: zOptionalText(500),
    })
    .superRefine((v, ctx) => {
      if (!v.allDay) {
        if (!TIME_RE.test(v.startTime)) {
          ctx.addIssue({ code: 'custom', path: ['startTime'], message: 'Choose a start time.' });
        }
        if (!TIME_RE.test(v.endTime)) {
          ctx.addIssue({ code: 'custom', path: ['endTime'], message: 'Choose an end time.' });
        }
      }
      const range = blockedRange(v, timeZone);
      if (range && range.endsAt <= range.startsAt) {
        ctx.addIssue({
          code: 'custom',
          path: ['endDate'],
          message: 'End must be after the start.',
        });
      }
    })
    .transform((v) => {
      const range = blockedRange(v, timeZone);
      return {
        member_id: v.memberId === '' ? null : v.memberId,
        starts_at: range?.startsAt ?? '',
        ends_at: range?.endsAt ?? '',
        reason: v.reason,
      };
    });
}
export type BlockedTimeFormInput = z.input<ReturnType<typeof blockedTimeSchema>>;
export type BlockedTimeFormValues = z.output<ReturnType<typeof blockedTimeSchema>>;

/**
 * Shop-local inputs → UTC instants. All-day blocks run from 00:00 on the
 * start date to 00:00 after the (inclusive) end date, in the shop zone.
 */
export function blockedRange(
  v: { allDay: boolean; startDate: string; startTime: string; endDate: string; endTime: string },
  timeZone: string,
): { startsAt: string; endsAt: string } | null {
  if (!isLocalDate(v.startDate) || !isLocalDate(v.endDate)) return null;
  try {
    if (v.allDay) {
      return {
        startsAt: shopLocalToUtcIso(v.startDate, '00:00', timeZone),
        endsAt: shopLocalToUtcIso(addLocalDays(v.endDate, 1), '00:00', timeZone),
      };
    }
    if (!TIME_RE.test(v.startTime) || !TIME_RE.test(v.endTime)) return null;
    return {
      startsAt: shopLocalToUtcIso(v.startDate, v.startTime, timeZone),
      endsAt: shopLocalToUtcIso(v.endDate, v.endTime, timeZone),
    };
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Resources, vehicle categories
// ---------------------------------------------------------------------------

export const RESOURCE_KINDS = ['bay', 'van', 'other'] as const;

export const resourceSchema = z.object({
  name: zRequiredText('Name', 80),
  kind: z.enum(RESOURCE_KINDS),
});
export type ResourceValues = z.output<typeof resourceSchema>;

export const categorySchema = z.object({ name: zRequiredText('Name', 60) });

// ---------------------------------------------------------------------------
// Coupons (dates are shop-local calendar days, end date inclusive)
// ---------------------------------------------------------------------------

export const COUPON_CODE_RE = /^[A-Za-z0-9_-]{3,40}$/;
export const COUPON_KINDS = ['percent', 'fixed'] as const;

export function couponSchema(timeZone: string) {
  return z
    .object({
      code: z
        .string()
        .trim()
        .transform((v) => v.toUpperCase())
        .refine(
          (v) => COUPON_CODE_RE.test(v),
          'Use 3–40 letters, numbers, hyphens or underscores.',
        ),
      description: zOptionalText(500),
      kind: z.enum(COUPON_KINDS),
      percent: z.string(),
      amountCents: z.number().int().nullable(),
      startDate: z.string(),
      endDate: z.string(),
      maxRedemptions: zOptionalPositiveIntText('Limit'),
      onlineOnly: z.boolean(),
      active: z.boolean(),
    })
    .superRefine((v, ctx) => {
      if (v.kind === 'percent') {
        const bps = parsePercentToBps(v.percent);
        if (bps === null || bps <= 0) {
          ctx.addIssue({
            code: 'custom',
            path: ['percent'],
            message: 'Enter a percentage between 0.01 and 100.',
          });
        }
      } else if (v.amountCents === null || v.amountCents <= 0) {
        ctx.addIssue({
          code: 'custom',
          path: ['amountCents'],
          message: 'Enter an amount greater than $0.',
        });
      }
      if (v.startDate !== '' && !isLocalDate(v.startDate)) {
        ctx.addIssue({ code: 'custom', path: ['startDate'], message: 'Enter a valid date.' });
      }
      if (v.endDate !== '' && !isLocalDate(v.endDate)) {
        ctx.addIssue({ code: 'custom', path: ['endDate'], message: 'Enter a valid date.' });
      }
      if (isLocalDate(v.startDate) && isLocalDate(v.endDate) && v.endDate < v.startDate) {
        ctx.addIssue({
          code: 'custom',
          path: ['endDate'],
          message: 'The last day must be on or after the first day.',
        });
      }
    })
    .transform((v) => ({
      code: v.code,
      description: v.description,
      kind: v.kind,
      value: v.kind === 'percent' ? (parsePercentToBps(v.percent) ?? 0) : (v.amountCents ?? 0),
      starts_at: isLocalDate(v.startDate)
        ? shopLocalToUtcIso(v.startDate, '00:00', timeZone)
        : null,
      ends_at: isLocalDate(v.endDate)
        ? shopLocalToUtcIso(addLocalDays(v.endDate, 1), '00:00', timeZone)
        : null,
      max_redemptions: v.maxRedemptions,
      online_only: v.onlineOnly,
      active: v.active,
    }));
}
export type CouponFormInput = z.input<ReturnType<typeof couponSchema>>;
export type CouponFormValues = z.output<ReturnType<typeof couponSchema>>;

// ---------------------------------------------------------------------------
// Form templates
// ---------------------------------------------------------------------------

export const FORM_ATTACH_TO = ['all_jobs', 'online_booking', 'manual'] as const;

export const formTemplateSchema = z.object({
  name: zRequiredText('Name', 120),
  body: z
    .string()
    .refine((v) => v.trim().length > 0, 'Write the form text.')
    .refine((v) => v.length <= 100000, 'Use 100,000 characters or fewer.'),
  requiresSignature: z.boolean(),
  attachTo: z.enum(FORM_ATTACH_TO),
  active: z.boolean(),
});
export type FormTemplateValues = z.output<typeof formTemplateSchema>;

// ---------------------------------------------------------------------------
// SMS sender number
// ---------------------------------------------------------------------------

export const smsSchema = z.object({ smsFromNumber: zOptionalPhone });
export type SmsInput = z.input<typeof smsSchema>;
export type SmsValues = z.output<typeof smsSchema>;
