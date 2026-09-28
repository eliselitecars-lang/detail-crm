/**
 * Lead form logic (pure, unit-tested): field validation mirroring
 * public_submit_lead (0088) and the payload. The server re-checks all of it.
 */
import { fromDraft, type CustomData, type CustomFieldDraft } from '@/lib/customFields';
import type { AppError } from '@/lib/errors';
import type { LeadField } from './api';

export interface LeadInput {
  firstName: string;
  lastName: string;
  email: string;
  phone: string;
  smsOptIn: boolean;
  emailOptIn: boolean;
  vehicleYear: string;
  vehicleMake: string;
  vehicleModel: string;
  message: string;
  /** Honeypot (hidden from people; bots fill it). */
  website: string;
}

export const EMPTY_LEAD: LeadInput = {
  firstName: '',
  lastName: '',
  email: '',
  phone: '',
  smsOptIn: false,
  emailOptIn: false,
  vehicleYear: '',
  vehicleMake: '',
  vehicleModel: '',
  message: '',
  website: '',
};

export type LeadErrors = Partial<Record<keyof LeadInput, string>>;

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

export interface LeadFormOptions {
  askVehicle: boolean;
  askMessage: boolean;
}

export function validateLead(input: LeadInput, options: LeadFormOptions): LeadErrors {
  const errors: LeadErrors = {};
  const first = input.firstName.trim();
  if (!first) errors.firstName = 'First name is required.';
  else if (first.length > 100) errors.firstName = 'First name must be 100 characters or fewer.';
  if (input.lastName.trim().length > 100) {
    errors.lastName = 'Last name must be 100 characters or fewer.';
  }
  const email = input.email.trim();
  const phone = input.phone.trim();
  if (email && (!EMAIL_RE.test(email) || email.length > 320)) {
    errors.email = 'Enter a valid email address.';
  }
  if (phone && (phone.replace(/\D/g, '').length < 7 || phone.length > 40)) {
    errors.phone = 'Enter a valid phone number.';
  }
  if (!email && !phone) {
    errors.email = 'Enter an email address or a phone number.';
    errors.phone = 'Enter a phone number or an email address.';
  }
  if (input.smsOptIn && !phone) errors.phone = 'Add a mobile number to get texts.';
  if (options.askVehicle) {
    const year = input.vehicleYear.trim();
    if (year && (!/^\d{4}$/.test(year) || Number(year) < 1886 || Number(year) > 2100)) {
      errors.vehicleYear = 'Enter a year like 2021.';
    }
    if (input.vehicleMake.trim().length > 60) errors.vehicleMake = 'Keep it to 60 characters.';
    if (input.vehicleModel.trim().length > 60) errors.vehicleModel = 'Keep it to 60 characters.';
  }
  if (options.askMessage && input.message.length > 5000) {
    errors.message = 'Keep the message to 5,000 characters.';
  }
  return errors;
}

/** public_submit_lead p_payload (a type alias so it is JSON-compatible). Unasked parts are left out. */
export type LeadPayload = {
  first_name: string;
  last_name: string | null;
  email: string | null;
  phone: string | null;
  sms_opt_in: boolean;
  email_opt_in: boolean;
  vehicle?: { year: number | null; make: string | null; model: string | null };
  message?: string | null;
  answers?: CustomData;
  website?: string;
};

const orNull = (v: string) => (v.trim() === '' ? null : v.trim());

export function leadAnswers(
  fields: readonly LeadField[],
  draft: CustomFieldDraft,
): { answers: CustomData; errors: Record<string, string> } {
  const { data, errors } = fromDraft(fields, draft, { enforceRequired: true });
  return { answers: data, errors };
}

export function buildLeadPayload(
  input: LeadInput,
  options: LeadFormOptions,
  answers: CustomData,
): LeadPayload {
  const phone = orNull(input.phone);
  const email = orNull(input.email);
  const payload: LeadPayload = {
    first_name: input.firstName.trim(),
    last_name: orNull(input.lastName),
    email: email ? email.toLowerCase() : null,
    phone,
    sms_opt_in: phone !== null && input.smsOptIn,
    email_opt_in: email !== null && input.emailOptIn,
  };
  if (options.askVehicle) {
    const year = input.vehicleYear.trim();
    const vehicle = {
      year: year === '' ? null : Number(year),
      make: orNull(input.vehicleMake),
      model: orNull(input.vehicleModel),
    };
    if (vehicle.year !== null || vehicle.make !== null || vehicle.model !== null) {
      payload.vehicle = vehicle;
    }
  }
  if (options.askMessage) payload.message = orNull(input.message);
  if (Object.keys(answers).length > 0) payload.answers = answers;
  if (input.website.trim() !== '') payload.website = input.website;
  return payload;
}

export interface LeadErrorBanner {
  tone: 'warning' | 'danger';
  title: string;
}

/** public_submit_lead's per-contact repeat limit (0088); its other PT429 is the form-wide cap. */
const ALREADY_RECEIVED_RE = /already received your request/i;

/**
 * The banner over a failed submission. Only the per-contact limit means the
 * shop has the request; the form-wide cap (and any other rate limit) saved
 * nothing, so it must not say so. The body is the server's own message.
 */
export function leadSubmitErrorBanner(
  error: Pick<AppError, 'kind' | 'code' | 'message'>,
): LeadErrorBanner {
  const rateLimited = error.kind === 'rate_limited' || error.code === 'PT429';
  if (!rateLimited) return { tone: 'danger', title: 'We couldn’t send your request' };
  if (error.code === 'PT429' && ALREADY_RECEIVED_RE.test(error.message)) {
    return { tone: 'warning', title: 'We already have your request' };
  }
  return { tone: 'warning', title: 'Your request wasn’t sent' };
}
