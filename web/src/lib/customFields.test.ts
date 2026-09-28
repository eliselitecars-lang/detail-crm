import { describe, expect, it } from 'vitest';
import {
  customFieldOptionsProblem,
  customValueError,
  formatCustomValue,
  fromDraft,
  isCustomDate,
  parseOptionLines,
  readCustomData,
  suggestFieldKey,
  toDraft,
  type CustomFieldDef,
} from './customFields';

const fields: CustomFieldDef[] = [
  { key: 'gate_code', label: 'Gate code', type: 'text', options: [], required: true },
  { key: 'notes', label: 'Notes', type: 'textarea', options: [] },
  { key: 'pets', label: 'Pets', type: 'number', options: [] },
  { key: 'size', label: 'Size', type: 'select', options: ['Small', 'Large'] },
  { key: 'extras', label: 'Extras', type: 'multiselect', options: ['Wax', 'Glass', 'Tyres'] },
  { key: 'garage', label: 'Garage', type: 'checkbox', options: [] },
  { key: 'birthday', label: 'Birthday', type: 'date', options: [] },
];

describe('customValueError (mirrors comms_custom_value_error)', () => {
  it('checks each type like the server', () => {
    expect(customValueError('text', [], 'x')).toBeNull();
    expect(customValueError('text', [], 5)).toBe('must be text');
    expect(customValueError('text', [], 'a'.repeat(2001))).toBe(
      'is too long (max 2000 characters)',
    );
    expect(customValueError('textarea', [], 'a'.repeat(10000))).toBeNull();
    expect(customValueError('textarea', [], 'a'.repeat(10001))).toBe(
      'is too long (max 10000 characters)',
    );
    expect(customValueError('number', [], 3.5)).toBeNull();
    expect(customValueError('number', [], '3')).toBe('must be a number');
    expect(customValueError('select', ['A'], 'A')).toBeNull();
    expect(customValueError('select', ['A'], 'B')).toBe('must be one of the options');
    expect(customValueError('multiselect', ['A', 'B'], ['A', 'B'])).toBeNull();
    expect(customValueError('multiselect', ['A', 'B'], ['A', 'A'])).toBe(
      'must be a list of the options',
    );
    expect(customValueError('multiselect', ['A'], 'A')).toBe('must be a list of the options');
    expect(customValueError('checkbox', [], false)).toBeNull();
    expect(customValueError('checkbox', [], 'yes')).toBe('must be true or false');
    expect(customValueError('date', [], '2026-02-28')).toBeNull();
    expect(customValueError('date', [], '2026-02-30')).toBe('must be a date (YYYY-MM-DD)');
    expect(customValueError('date', [], '2026-2-3')).toBe('must be a date (YYYY-MM-DD)');
  });

  it('knows real calendar dates', () => {
    expect(isCustomDate('2024-02-29')).toBe(true);
    expect(isCustomDate('2025-02-29')).toBe(false);
    expect(isCustomDate('2025-13-01')).toBe(false);
  });
});

describe('draft round trip', () => {
  it('turns stored data into a draft and back', () => {
    const data = {
      gate_code: '1234',
      pets: 2,
      size: 'Large',
      extras: ['Wax'],
      garage: true,
      birthday: '1990-05-01',
    };
    const draft = toDraft(fields, data);
    expect(draft).toEqual({
      gate_code: '1234',
      notes: '',
      pets: '2',
      size: 'Large',
      extras: ['Wax'],
      garage: true,
      birthday: '1990-05-01',
    });
    expect(fromDraft(fields, draft, { previous: data })).toEqual({
      data,
      errors: {},
      valid: true,
    });
  });

  it('drops blanks, trims text, parses numbers and orders multiselect like the options', () => {
    const result = fromDraft(fields, {
      gate_code: '  42 ',
      notes: '   ',
      pets: '1,5',
      extras: ['Tyres', 'Wax'],
      garage: false,
      birthday: '',
    });
    expect(result.valid).toBe(true);
    expect(result.data).toEqual({ gate_code: '42', pets: 1.5, extras: ['Tyres', 'Wax'] });
  });

  it('reports label-prefixed errors like the server', () => {
    const result = fromDraft(fields, { pets: 'two', birthday: '2025-02-30' });
    expect(result.valid).toBe(false);
    expect(result.errors).toEqual({
      pets: 'Pets must be a number',
      birthday: 'Birthday must be a date (YYYY-MM-DD)',
    });
  });

  it('enforces required answers only when asked (public forms)', () => {
    expect(fromDraft(fields, {}).valid).toBe(true);
    expect(fromDraft(fields, {}, { enforceRequired: true }).errors).toEqual({
      gate_code: 'Gate code is required',
    });
    const box: CustomFieldDef[] = [
      { key: 'agree', label: 'Agree', type: 'checkbox', options: [], required: true },
    ];
    expect(fromDraft(box, { agree: false }, { enforceRequired: true }).errors).toEqual({
      agree: 'Agree is required',
    });
    expect(fromDraft(box, { agree: true }, { enforceRequired: true }).data).toEqual({
      agree: true,
    });
  });

  it('keeps a previously answered checkbox as false and archived / unknown keys unchanged', () => {
    const archived: CustomFieldDef[] = [
      ...fields,
      { key: 'old', label: 'Old', type: 'text', options: [], archived_at: '2026-01-01T00:00:00Z' },
    ];
    const previous = { garage: true, old: 'kept', other_field: 'x' };
    const result = fromDraft(archived, { garage: false, old: 'changed' }, { previous });
    expect(result.data).toEqual({ garage: false, old: 'kept', other_field: 'x' });
  });
});

describe('helpers', () => {
  it('reads untyped JSON safely', () => {
    expect(readCustomData({ a: 'x', b: 2, c: [1], d: null, e: ['y'] })).toEqual({
      a: 'x',
      b: 2,
      e: ['y'],
    });
    expect(readCustomData('nope')).toEqual({});
    expect(readCustomData([1])).toEqual({});
  });

  it('formats values for display', () => {
    expect(formatCustomValue({ type: 'checkbox' }, true)).toBe('Yes');
    expect(formatCustomValue({ type: 'checkbox' }, false)).toBe('No');
    expect(formatCustomValue({ type: 'multiselect' }, ['A', 'B'])).toBe('A, B');
    expect(formatCustomValue({ type: 'date' }, '2026-03-08')).toBe('Mar 8, 2026');
    expect(formatCustomValue({ type: 'number' }, 1234.5)).toBe('1,234.5');
  });

  it('suggests valid keys from labels', () => {
    expect(suggestFieldKey('Gate code #')).toBe('gate_code');
    expect(suggestFieldKey('  2nd Phone ')).toBe('f_2nd_phone');
    expect(suggestFieldKey('Café au lait')).toBe('cafe_au_lait');
    expect(suggestFieldKey('!!!')).toBe('');
    expect(suggestFieldKey('x'.repeat(60))).toHaveLength(40);
  });

  it('checks options like custom_fields_options', () => {
    expect(customFieldOptionsProblem('text', [])).toBeNull();
    expect(customFieldOptionsProblem('select', [])).toBe('Add at least one option.');
    expect(customFieldOptionsProblem('select', ['A', 'A'])).toBe('Each option must be different.');
    expect(customFieldOptionsProblem('multiselect', ['A', 'B'])).toBeNull();
    expect(customFieldOptionsProblem('select', ['x'.repeat(101)])).toBe(
      'Keep each option to 100 characters or fewer.',
    );
    expect(parseOptionLines(' A \n\nB\nA\r\nC ')).toEqual(['A', 'B', 'C']);
  });
});
