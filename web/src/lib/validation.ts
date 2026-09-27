/**
 * Shared zod field schemas so every form validates the same way.
 * Use with react-hook-form: `useForm({ resolver: zodResolver(schema) })`.
 */
import { z } from 'zod';
import { parseMoneyInput, parsePercentToBps } from './money';
import { normalizePhone } from './phone';

export const zRequiredText = (label = 'This field', max = 200) =>
  z
    .string()
    .trim()
    .min(1, `${label} is required.`)
    .max(max, `${label} must be ${max} characters or fewer.`);

export const zOptionalText = (max = 2000) =>
  z
    .string()
    .trim()
    .max(max, `Must be ${max} characters or fewer.`)
    .transform((v) => (v === '' ? null : v));

export const zEmail = z
  .string()
  .trim()
  .min(1, 'Email is required.')
  .pipe(z.email('Enter a valid email address.'))
  .transform((v) => v.toLowerCase());

export const zOptionalEmail = z
  .string()
  .trim()
  .transform((v) => v.toLowerCase())
  .refine((v) => v === '' || z.email().safeParse(v).success, 'Enter a valid email address.')
  .transform((v) => (v === '' ? null : v));

/** Required phone → E.164. */
export const zPhone = z
  .string()
  .trim()
  .min(1, 'Phone is required.')
  .refine((v) => normalizePhone(v) !== null, 'Enter a valid phone number.')
  .transform((v) => normalizePhone(v) ?? v);

/** Optional phone → E.164 or null. */
export const zOptionalPhone = z
  .string()
  .trim()
  .refine((v) => v === '' || normalizePhone(v) !== null, 'Enter a valid phone number.')
  .transform((v) => (v === '' ? null : normalizePhone(v)));

/** A MoneyInput value (integer cents). */
export const zCents = z
  .number({ error: 'Enter an amount.' })
  .int('Amount must be whole cents.')
  .min(0, 'Amount cannot be negative.');

/** Money typed as text → cents. */
export const zMoneyText = z
  .string()
  .refine((v) => parseMoneyInput(v) !== null, 'Enter a valid amount, like 125.00.')
  .transform((v) => parseMoneyInput(v) ?? 0);

/** Percent typed as text ("8.25") → basis points (825). */
export const zPercentBps = (max = 100) =>
  z
    .string()
    .trim()
    .refine(
      (v) => parsePercentToBps(v, { maxPercent: max }) !== null,
      `Enter a percentage between 0 and ${max}.`,
    )
    .transform((v) => parsePercentToBps(v, { maxPercent: max }) ?? 0);

export const zPassword = z
  .string()
  .min(8, 'Use at least 8 characters.')
  .max(72, 'Use 72 characters or fewer.');
