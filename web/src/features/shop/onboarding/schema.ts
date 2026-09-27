import { z } from 'zod';
import { isValidTimeZone } from '@/lib/dates';
import {
  zOptionalEmail,
  zOptionalPhone,
  zOptionalText,
  zPercentBps,
  zRequiredText,
} from '@/lib/validation';
import { validateWeek, type DayHours } from '../businessHours';

/** Same rule as public.is_valid_slug (migration 0001). */
export const SLUG_RE = /^[a-z0-9][a-z0-9-]{1,48}[a-z0-9]$/;

/** Same list as public.is_reserved_slug (migration 0001). */
export const RESERVED_SLUGS: ReadonlySet<string> = new Set([
  'app',
  'api',
  'admin',
  'book',
  'booking',
  'login',
  'signup',
  'portal',
  'invite',
  'www',
  'support',
  'help',
  'static',
  'assets',
  'q',
  'i',
  'f',
]);

/** "Joe's Mobile Detailing!" → "joes-mobile-detailing" (max 50 chars). */
export function slugify(name: string): string {
  return name
    .normalize('NFKD')
    .replace(/[̀-ͯ]/g, '')
    .toLowerCase()
    .replace(/['’]/g, '')
    .replace(/&/g, ' and ')
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 50)
    .replace(/-+$/g, '');
}

/** Human explanation of what's wrong with a slug, or null if it's valid. */
export function slugProblem(slug: string): string | null {
  if (slug.length === 0) return 'Choose a booking link.';
  if (slug.length < 3) return 'Use at least 3 characters.';
  if (slug.length > 50) return 'Use 50 characters or fewer.';
  if (/[^a-z0-9-]/.test(slug)) return 'Use only lowercase letters, numbers and hyphens.';
  if (slug.startsWith('-') || slug.endsWith('-')) return 'Can’t start or end with a hyphen.';
  if (!SLUG_RE.test(slug)) return 'Use only lowercase letters, numbers and hyphens.';
  if (RESERVED_SLUGS.has(slug)) return 'That link is reserved. Try another.';
  return null;
}

export const BUSINESS_TYPES = ['fixed', 'mobile', 'both'] as const;
export type BusinessType = (typeof BUSINESS_TYPES)[number];

export const onboardingSchema = z.object({
  name: zRequiredText('Shop name', 120),
  slug: z
    .string()
    .trim()
    .superRefine((value, ctx) => {
      const problem = slugProblem(value);
      if (problem) ctx.addIssue({ code: 'custom', message: problem });
    }),
  businessType: z.enum(BUSINESS_TYPES, { error: 'Choose how you serve customers.' }),
  timezone: z.string().refine(isValidTimeZone, 'Choose a valid time zone.'),
  phone: zOptionalPhone,
  email: zOptionalEmail,
  addressLine1: zOptionalText(200),
  addressLine2: zOptionalText(200),
  city: zOptionalText(100),
  region: zOptionalText(100),
  postalCode: zOptionalText(20),
  taxRate: zPercentBps(100),
  hours: z
    .custom<DayHours[]>((v) => Array.isArray(v))
    .superRefine((days, ctx) => {
      if (Object.keys(validateWeek(days)).length > 0) {
        ctx.addIssue({ code: 'custom', message: 'Fix the highlighted opening hours.' });
      }
    }),
});

export type OnboardingInput = z.input<typeof onboardingSchema>;
export type OnboardingValues = z.output<typeof onboardingSchema>;

/** Fields validated before leaving each step. */
export const STEP_FIELDS = [
  ['name', 'slug', 'businessType'],
  ['timezone', 'phone', 'email', 'addressLine1', 'addressLine2', 'city', 'region', 'postalCode'],
  ['taxRate', 'hours'],
] as const satisfies readonly (readonly (keyof OnboardingInput)[])[];
