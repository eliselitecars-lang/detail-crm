/**
 * Form schemas (react-hook-form + zod) for customers and vehicles, and the
 * mapping from a saved row back to form values. Limits mirror the CHECK
 * constraints in 0004_foundation_crm.sql so errors show on the field.
 */
import { z } from 'zod';
import type { InsertRow, UpdateRow } from '@/lib/db';
import { formatPhone } from '@/lib/phone';
import { zOptionalEmail, zOptionalPhone, zOptionalText } from '@/lib/validation';
import {
  LIFECYCLES,
  MAX_TAG_LENGTH,
  MAX_TAGS,
  normalizeTags,
  SOURCES,
  type CustomerRow,
  type VehicleRow,
} from './model';
import { normalizeVin } from './vin';

// ---------------------------------------------------------------- customers

export const customerFormSchema = z
  .object({
    firstName: zOptionalText(100),
    lastName: zOptionalText(100),
    company: zOptionalText(200),
    phone: zOptionalPhone,
    email: zOptionalEmail,
    addressLine1: zOptionalText(200),
    addressLine2: zOptionalText(200),
    city: zOptionalText(100),
    region: zOptionalText(100),
    postalCode: zOptionalText(20),
    country: z
      .string()
      .trim()
      .toUpperCase()
      .refine((v) => v === '' || /^[A-Z]{2}$/.test(v), 'Use a 2-letter country code, like US.')
      .transform((v) => (v === '' ? null : v)),
    tags: z
      .array(z.string().max(MAX_TAG_LENGTH, `Tags must be ${MAX_TAG_LENGTH} characters or fewer.`))
      .transform((tags) => normalizeTags(tags))
      .refine((tags) => tags.length <= MAX_TAGS, `Use at most ${MAX_TAGS} tags.`),
    lifecycle: z.enum(LIFECYCLES),
    source: z.enum(SOURCES),
    smsOptIn: z.boolean(),
    emailOptIn: z.boolean(),
    notes: zOptionalText(20000),
  })
  .superRefine((v, ctx) => {
    if (!v.firstName && !v.lastName && !v.company) {
      ctx.addIssue({
        code: 'custom',
        path: ['firstName'],
        message: 'Enter a first name, last name or company.',
      });
    }
  });

export type CustomerFormInput = z.input<typeof customerFormSchema>;
export type CustomerFormValues = z.output<typeof customerFormSchema>;

export function emptyCustomerForm(): CustomerFormInput {
  return {
    firstName: '',
    lastName: '',
    company: '',
    phone: '',
    email: '',
    addressLine1: '',
    addressLine2: '',
    city: '',
    region: '',
    postalCode: '',
    country: '',
    tags: [],
    lifecycle: 'customer',
    source: 'staff',
    smsOptIn: false,
    emailOptIn: false,
    notes: '',
  };
}

export function customerToForm(c: CustomerRow): CustomerFormInput {
  return {
    firstName: c.first_name ?? '',
    lastName: c.last_name ?? '',
    company: c.company ?? '',
    phone: c.phone ? formatPhone(c.phone) : '',
    email: c.email ?? '',
    addressLine1: c.address_line1 ?? '',
    addressLine2: c.address_line2 ?? '',
    city: c.city ?? '',
    region: c.region ?? '',
    postalCode: c.postal_code ?? '',
    country: c.country ?? '',
    tags: [...c.tags],
    lifecycle: c.lifecycle,
    source: c.source,
    smsOptIn: c.sms_opt_in,
    emailOptIn: c.email_opt_in,
    notes: c.notes ?? '',
  };
}

/** Editable columns only — never portal_user_id / stripe_customer_id / opt-out stamps. */
export type CustomerWrite = Pick<
  UpdateRow<'customers'>,
  | 'first_name'
  | 'last_name'
  | 'company'
  | 'phone'
  | 'email'
  | 'address_line1'
  | 'address_line2'
  | 'city'
  | 'region'
  | 'postal_code'
  | 'country'
  | 'tags'
  | 'lifecycle'
  | 'source'
  | 'sms_opt_in'
  | 'email_opt_in'
  | 'notes'
>;

export function customerFormToWrite(v: CustomerFormValues): CustomerWrite {
  return {
    first_name: v.firstName,
    last_name: v.lastName,
    company: v.company,
    phone: v.phone,
    email: v.email,
    address_line1: v.addressLine1,
    address_line2: v.addressLine2,
    city: v.city,
    region: v.region,
    postal_code: v.postalCode,
    country: v.country,
    tags: v.tags,
    lifecycle: v.lifecycle,
    source: v.source,
    sms_opt_in: v.smsOptIn,
    email_opt_in: v.emailOptIn,
    notes: v.notes,
  };
}

/** Maps a DB constraint name to the form field it belongs to. */
export const CUSTOMER_CONSTRAINT_FIELDS: Record<string, keyof CustomerFormInput> = {
  customers_has_name: 'firstName',
  customers_first_name_check: 'firstName',
  customers_last_name_check: 'lastName',
  customers_company_check: 'company',
  customers_phone_check: 'phone',
  customers_email_check: 'email',
  customers_address_line1_check: 'addressLine1',
  customers_address_line2_check: 'addressLine2',
  customers_city_check: 'city',
  customers_region_check: 'region',
  customers_postal_code_check: 'postalCode',
  customers_country_check: 'country',
  customers_tags_check: 'tags',
  customers_notes_check: 'notes',
};

// ---------------------------------------------------------------- vehicles

const MAX_YEAR = 2100;

export const vehicleFormSchema = z.object({
  year: z
    .string()
    .trim()
    .refine(
      (v) => v === '' || (/^\d{4}$/.test(v) && Number(v) >= 1886 && Number(v) <= MAX_YEAR),
      'Enter a 4-digit year.',
    )
    .transform((v) => (v === '' ? null : Number(v))),
  make: zOptionalText(60),
  model: zOptionalText(60),
  trim: zOptionalText(60),
  color: zOptionalText(40),
  vin: z
    .string()
    .transform(normalizeVin)
    .refine(
      (v) => v === '' || /^[A-Z0-9]{5,17}$/.test(v),
      'A VIN is 5–17 letters and numbers (17 for modern vehicles).',
    )
    .transform((v) => (v === '' ? null : v)),
  licensePlate: z
    .string()
    .trim()
    .toUpperCase()
    .max(15, 'Plates are 15 characters or fewer.')
    .transform((v) => (v === '' ? null : v)),
  categoryId: z.string().transform((v) => (v === '' ? null : v)),
  notes: zOptionalText(20000),
});

export type VehicleFormInput = z.input<typeof vehicleFormSchema>;
export type VehicleFormValues = z.output<typeof vehicleFormSchema>;

export function emptyVehicleForm(): VehicleFormInput {
  return {
    year: '',
    make: '',
    model: '',
    trim: '',
    color: '',
    vin: '',
    licensePlate: '',
    categoryId: '',
    notes: '',
  };
}

export function vehicleToForm(v: VehicleRow): VehicleFormInput {
  return {
    year: v.year === null ? '' : String(v.year),
    make: v.make ?? '',
    model: v.model ?? '',
    trim: v.trim ?? '',
    color: v.color ?? '',
    vin: v.vin ?? '',
    licensePlate: v.license_plate ?? '',
    categoryId: v.category_id ?? '',
    notes: v.notes ?? '',
  };
}

export type VehicleWrite = Pick<
  InsertRow<'vehicles'>,
  'year' | 'make' | 'model' | 'trim' | 'color' | 'vin' | 'license_plate' | 'category_id' | 'notes'
>;

export function vehicleFormToWrite(v: VehicleFormValues): VehicleWrite {
  return {
    year: v.year,
    make: v.make,
    model: v.model,
    trim: v.trim,
    color: v.color,
    vin: v.vin,
    license_plate: v.licensePlate,
    category_id: v.categoryId,
    notes: v.notes,
  };
}
