/**
 * Custom fields (customers.custom_data / jobs.custom_data, booking questions,
 * lead forms). Mirrors the server validator comms_validate_custom_data /
 * comms_custom_value_error (0088) so forms show the same messages before a
 * save; the server stays the authority (it re-validates every write).
 *
 * Stored shape: `{ [field.key]: value }` where value is
 *   text / textarea / select / date → string, number → number,
 *   checkbox → boolean, multiselect → string[] (distinct options).
 * null, blank strings and empty lists are never stored (dropped).
 *
 * Forms edit a DRAFT (`CustomFieldDraft`): numbers and dates stay strings
 * while typing; `fromDraft` converts and validates.
 */
import { z } from 'zod';
import type { Database } from './database.types';

export type CustomFieldType = Database['public']['Enums']['custom_field_type'];
export type CustomFieldEntity = Database['public']['Enums']['custom_field_entity'];

export const CUSTOM_FIELD_TYPES = [
  'text',
  'textarea',
  'number',
  'select',
  'multiselect',
  'checkbox',
  'date',
] as const satisfies readonly CustomFieldType[];

export const CUSTOM_FIELD_TYPE_LABELS: Record<CustomFieldType, string> = {
  text: 'Short text',
  textarea: 'Long text',
  number: 'Number',
  select: 'Choice (one)',
  multiselect: 'Choices (several)',
  checkbox: 'Yes / no',
  date: 'Date',
};

/** Limits of the server (custom_fields CHECKs and the value validator). */
export const CUSTOM_FIELD_LIMITS = {
  keyPattern: /^[a-z][a-z0-9_]{0,39}$/,
  labelMax: 120,
  helpMax: 300,
  optionsMin: 1,
  optionsMax: 50,
  optionMax: 100,
  textMax: 2000,
  textareaMax: 10000,
} as const;

/**
 * The part of a field definition the inputs need. Matches custom_fields rows
 * and the public JSON of public_booking_questions / public_get_lead_form.
 */
export interface CustomFieldDef {
  key: string;
  label: string;
  type: CustomFieldType;
  options: readonly string[];
  help_text?: string | null;
  required?: boolean;
  /** custom_fields.archived_at (staff rows only): archived fields keep old values read-only. */
  archived_at?: string | null;
}

export type CustomValue = string | number | boolean | string[];
export type CustomData = Record<string, CustomValue>;

/** Draft value per key: numbers / dates as strings while editing. */
export type CustomDraftValue = string | boolean | string[];
export type CustomFieldDraft = Record<string, CustomDraftValue>;

/** Zod schema for untyped custom_data JSON (RPC / select results). */
export const customValueSchema = z.union([
  z.string(),
  z.number(),
  z.boolean(),
  z.array(z.string()),
]);
export const customDataSchema = z.record(z.string(), customValueSchema);

/** Parses unknown JSON into CustomData, dropping values of unexpected shapes. */
export function readCustomData(raw: unknown): CustomData {
  if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) return {};
  const out: CustomData = {};
  for (const [key, value] of Object.entries(raw as Record<string, unknown>)) {
    const parsed = customValueSchema.safeParse(value);
    if (parsed.success) out[key] = parsed.data;
  }
  return out;
}

const DATE_PATTERN = /^(\d{4})-(\d{2})-(\d{2})$/;

/** A real calendar date written YYYY-MM-DD (what Postgres' ::date accepts and prints back). */
export function isCustomDate(value: string): boolean {
  const match = DATE_PATTERN.exec(value);
  if (!match) return false;
  const [, y, m, d] = match;
  const date = new Date(Date.UTC(Number(y), Number(m) - 1, Number(d)));
  return (
    date.getUTCFullYear() === Number(y) &&
    date.getUTCMonth() === Number(m) - 1 &&
    date.getUTCDate() === Number(d)
  );
}

/** Whether a value counts as "no answer" (the server drops it). */
export function isEmptyCustomValue(value: unknown): boolean {
  if (value === null || value === undefined) return true;
  if (typeof value === 'string') return value.trim() === '';
  if (Array.isArray(value)) return value.length === 0;
  return false;
}

/**
 * Why `value` is not valid for a field of `type` (null = valid). Same rules
 * and wording as comms_custom_value_error; the caller prefixes the label.
 */
export function customValueError(
  type: CustomFieldType,
  options: readonly string[],
  value: unknown,
): string | null {
  switch (type) {
    case 'text':
      if (typeof value !== 'string') return 'must be text';
      return value.length > CUSTOM_FIELD_LIMITS.textMax
        ? 'is too long (max 2000 characters)'
        : null;
    case 'textarea':
      if (typeof value !== 'string') return 'must be text';
      return value.length > CUSTOM_FIELD_LIMITS.textareaMax
        ? 'is too long (max 10000 characters)'
        : null;
    case 'number':
      return typeof value === 'number' && Number.isFinite(value) ? null : 'must be a number';
    case 'select':
      return typeof value === 'string' && options.includes(value)
        ? null
        : 'must be one of the options';
    case 'multiselect':
      if (
        !Array.isArray(value) ||
        value.some((v) => typeof v !== 'string' || !options.includes(v)) ||
        new Set(value).size !== value.length
      ) {
        return 'must be a list of the options';
      }
      return null;
    case 'checkbox':
      return typeof value === 'boolean' ? null : 'must be true or false';
    case 'date':
      return typeof value === 'string' && isCustomDate(value)
        ? null
        : 'must be a date (YYYY-MM-DD)';
  }
}

/** Stored value → draft value for the inputs. */
export function toDraftValue(
  field: CustomFieldDef,
  value: CustomValue | undefined,
): CustomDraftValue {
  switch (field.type) {
    case 'checkbox':
      return value === true;
    case 'multiselect':
      return Array.isArray(value) ? value.filter((v) => typeof v === 'string') : [];
    case 'number':
      return typeof value === 'number' ? String(value) : typeof value === 'string' ? value : '';
    default:
      return typeof value === 'string' ? value : value === undefined ? '' : String(value);
  }
}

/** Stored data → draft for these fields. */
export function toDraft(fields: readonly CustomFieldDef[], data: CustomData): CustomFieldDraft {
  const draft: CustomFieldDraft = {};
  for (const field of fields) draft[field.key] = toDraftValue(field, data[field.key]);
  return draft;
}

/** "1,5" / " 12 " → number; '' → undefined; anything else → NaN. */
function parseNumberInput(text: string): number | undefined {
  const trimmed = text.trim().replace(/\s/g, '');
  if (trimmed === '') return undefined;
  if (!/^-?(\d+([.,]\d*)?|[.,]\d+)$/.test(trimmed)) return Number.NaN;
  return Number(trimmed.replace(',', '.'));
}

export interface FromDraftOptions {
  /** Enforce `required` (public booking questions and lead forms). Staff edits don't. */
  enforceRequired?: boolean;
  /**
   * The stored data being edited. Keys not among `fields` (other fields,
   * archived ones) are carried over unchanged, as the server keeps them.
   */
  previous?: CustomData;
}

export interface FromDraftResult {
  data: CustomData;
  /** key → "<Label> must be …" */
  errors: Record<string, string>;
  valid: boolean;
}

/**
 * Draft → stored data + per-field errors (label-prefixed, like the server).
 * Archived fields are read-only: their previous value is kept as is.
 */
export function fromDraft(
  fields: readonly CustomFieldDef[],
  draft: CustomFieldDraft,
  options: FromDraftOptions = {},
): FromDraftResult {
  const { enforceRequired = false, previous = {} } = options;
  const data: CustomData = {};
  const errors: Record<string, string> = {};
  const known = new Set(fields.map((f) => f.key));
  for (const [key, value] of Object.entries(previous)) {
    if (!known.has(key) && !isEmptyCustomValue(value)) data[key] = value;
  }
  for (const field of fields) {
    if (field.archived_at) {
      const kept = previous[field.key];
      if (kept !== undefined && !isEmptyCustomValue(kept)) data[field.key] = kept;
      continue;
    }
    const raw = draft[field.key];
    let value: CustomValue | undefined;
    switch (field.type) {
      case 'checkbox':
        // An unticked optional box is "no answer" unless it was answered before.
        value = raw === true ? true : previous[field.key] === undefined ? undefined : false;
        break;
      case 'multiselect':
        value = Array.isArray(raw) && raw.length > 0 ? [...new Set(raw)] : undefined;
        break;
      case 'number': {
        const parsed = typeof raw === 'string' ? parseNumberInput(raw) : undefined;
        value = parsed;
        break;
      }
      default: {
        const text = typeof raw === 'string' ? raw.trim() : '';
        value = text === '' ? undefined : text;
      }
    }
    if (value === undefined) {
      if (enforceRequired && field.required) errors[field.key] = `${field.label} is required`;
      continue;
    }
    if (field.type === 'checkbox' && enforceRequired && field.required && value !== true) {
      errors[field.key] = `${field.label} is required`;
      continue;
    }
    const problem = customValueError(field.type, field.options, value);
    if (problem) {
      errors[field.key] = `${field.label} ${problem}`;
      continue;
    }
    data[field.key] = value;
  }
  return { data, errors, valid: Object.keys(errors).length === 0 };
}

/** Human text of a stored value ("Yes", "Mar 8, 2026", "Red, Blue"). */
export function formatCustomValue(field: Pick<CustomFieldDef, 'type'>, value: CustomValue): string {
  switch (field.type) {
    case 'checkbox':
      return value === true ? 'Yes' : 'No';
    case 'multiselect':
      return Array.isArray(value) ? value.join(', ') : String(value);
    case 'date': {
      if (typeof value !== 'string' || !isCustomDate(value)) return String(value);
      const [y, m, d] = value.split('-').map(Number);
      return new Date(Date.UTC(y ?? 1970, (m ?? 1) - 1, d ?? 1)).toLocaleDateString('en-US', {
        timeZone: 'UTC',
        month: 'short',
        day: 'numeric',
        year: 'numeric',
      });
    }
    case 'number':
      return typeof value === 'number' ? value.toLocaleString('en-US') : String(value);
    default:
      return Array.isArray(value) ? value.join(', ') : String(value);
  }
}

/** A label → a valid key suggestion ("Gate code #" → "gate_code"). */
export function suggestFieldKey(label: string): string {
  const base = label
    .normalize('NFKD')
    .replace(/[̀-ͯ]/g, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '_')
    .replace(/^_+|_+$/g, '');
  const key = /^[0-9]/.test(base) ? `f_${base}` : base;
  return key.slice(0, 40).replace(/_+$/, '');
}

/**
 * Options as the server stores them: trimmed, non-empty, distinct. Returns a
 * message when they break custom_fields_options (null = fine).
 */
export function customFieldOptionsProblem(
  type: CustomFieldType,
  options: readonly string[],
): string | null {
  if (type !== 'select' && type !== 'multiselect') return null;
  if (options.length < CUSTOM_FIELD_LIMITS.optionsMin) return 'Add at least one option.';
  if (options.length > CUSTOM_FIELD_LIMITS.optionsMax) return 'Use at most 50 options.';
  if (options.some((o) => o.trim() !== o || o.length === 0)) return 'Options can’t be blank.';
  if (options.some((o) => o.length > CUSTOM_FIELD_LIMITS.optionMax)) {
    return 'Keep each option to 100 characters or fewer.';
  }
  if (new Set(options).size !== options.length) return 'Each option must be different.';
  return null;
}

/** Splits an options textarea (one per line) into clean, distinct options. */
export function parseOptionLines(text: string): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  for (const line of text.split(/\r?\n/)) {
    const option = line.trim();
    if (option === '' || seen.has(option)) continue;
    seen.add(option);
    out.push(option);
  }
  return out;
}
