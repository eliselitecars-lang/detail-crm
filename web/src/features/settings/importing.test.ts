import { describe, expect, it } from 'vitest';
import { csvCell, toCsv } from '@/lib/csv';
import {
  autoMap,
  buildImportRows,
  customCellValue,
  importTargets,
  normalizeServiceKind,
  parseCsv,
  type ImportCustomField,
} from './importing';

describe('CSV import of our own exports', () => {
  it('re-imports phones exactly as they were exported', () => {
    const csv = toCsv(
      [
        { header: 'First name', value: (r: { name: string; phone: string }) => r.name },
        { header: 'Phone', value: (r) => r.phone },
      ],
      [
        { name: 'Jane', phone: '+15551234567' },
        { name: 'Ian', phone: '+447700900123' },
      ],
    );
    // The export keeps the formula guard, so spreadsheets keep the phone as text.
    expect(csv).toContain("'+15551234567");
    const parsed = parseCsv(`\uFEFF${csv}`);
    const { rows, errors } = buildImportRows(parsed.records, {
      'First name': 'first_name',
      Phone: 'phone',
    });
    expect(errors).toEqual([]);
    expect(rows.map((r) => r.payload)).toEqual([
      { first_name: 'Jane', phone: '+15551234567' },
      { first_name: 'Ian', phone: '+447700900123' },
    ]);
  });

  it('removes only the guard apostrophe', () => {
    const { rows } = buildImportRows(
      [
        { Company: "'Tis Detailing", Notes: "'=SUM(A1)", Tags: "  '-vip  " },
        { Company: "''+1", Notes: "'", Tags: "'@home" },
      ],
      { Company: 'company', Notes: 'notes', Tags: 'tags' },
    );
    expect(rows.map((r) => r.payload)).toEqual([
      { company: "'Tis Detailing", notes: '=SUM(A1)', tags: '-vip' },
      { company: "''+1", notes: "'", tags: '@home' },
    ]);
    // What was stored with a formula character is guarded again on the next export.
    expect(csvCell('=SUM(A1)')).toBe("'=SUM(A1)");
  });
});

describe('service type', () => {
  it('writes add-on the way the server spells it', () => {
    expect(normalizeServiceKind('Add-on')).toBe('addon');
    expect(normalizeServiceKind('add on')).toBe('addon');
    expect(normalizeServiceKind('ADDON')).toBe('addon');
    expect(normalizeServiceKind('Package')).toBe('package');
    expect(normalizeServiceKind('Service')).toBe('service');
    expect(normalizeServiceKind('Product')).toBe('product');
    // Unknown values are sent as typed so the server's row error names them.
    expect(normalizeServiceKind('Bundle')).toBe('Bundle');
  });

  it('normalises the mapped kind column', () => {
    const { rows } = buildImportRows([{ Name: 'Wax', Type: 'Add-On' }], {
      Name: 'name',
      Type: 'kind',
    });
    expect(rows[0]?.payload).toEqual({ name: 'Wax', kind: 'addon' });
  });
});

describe('custom field columns (0114)', () => {
  const FIELDS: ImportCustomField[] = [
    { key: 'referred_by', label: 'Referred by', type: 'text', options: [] },
    {
      key: 'interest',
      label: 'Interested in',
      type: 'select',
      options: ['Ceramic coating', 'Detail'],
    },
    { key: 'extras', label: 'Extras', type: 'multiselect', options: ['Wax', 'Tint', 'PPF'] },
    { key: 'fleet_size', label: 'Fleet size', type: 'number', options: [] },
    { key: 'has_garage', label: 'Has a garage', type: 'checkbox', options: [] },
    { key: 'birthday', label: 'Birthday', type: 'date', options: [] },
  ];

  it('round-trips our customer export: headers are the field labels, values typed back', () => {
    // as ExportCard writes them: arrays joined with "; ", booleans / numbers via String()
    const csv = toCsv(
      [
        { header: 'First name', value: () => 'Ann' },
        { header: 'Email', value: () => 'ann@example.com' },
        { header: 'Referred by', value: () => 'Bob' },
        { header: 'Interested in', value: () => 'Detail' },
        { header: 'Extras', value: () => ['Wax', 'PPF'].join('; ') },
        { header: 'Fleet size', value: () => String(1200) },
        { header: 'Has a garage', value: () => String(true) },
        { header: 'Birthday', value: () => '1990-04-05' },
      ],
      [{}],
    );
    const parsed = parseCsv(csv);
    const mapping = autoMap(parsed.headers, importTargets('customers', [], FIELDS));
    expect(mapping).toMatchObject({
      'Referred by': 'custom.referred_by',
      'Interested in': 'custom.interest',
      Extras: 'custom.extras',
      'Fleet size': 'custom.fleet_size',
      'Has a garage': 'custom.has_garage',
      Birthday: 'custom.birthday',
    });
    const { rows, errors } = buildImportRows(parsed.records, mapping, FIELDS);
    expect(errors).toEqual([]);
    expect(rows[0]?.payload).toEqual({
      first_name: 'Ann',
      email: 'ann@example.com',
      custom_data: {
        referred_by: 'Bob',
        interest: 'Detail',
        extras: ['Wax', 'PPF'],
        fleet_size: 1200,
        has_garage: true,
        birthday: '1990-04-05',
      },
    });
  });

  it('leaves blank cells out and reports unreadable numbers / checkboxes locally', () => {
    const { rows, errors } = buildImportRows(
      [
        { Name: 'Ann', 'Fleet size': '', Garage: '' },
        { Name: 'Bo', 'Fleet size': 'lots', Garage: 'maybe' },
      ],
      { Name: 'first_name', 'Fleet size': 'custom.fleet_size', Garage: 'custom.has_garage' },
      FIELDS,
    );
    expect(rows.map((r) => r.payload)).toEqual([{ first_name: 'Ann' }]);
    expect(errors).toEqual([
      { line: 2, message: '"lots" isn’t a number (Fleet size); "maybe" isn’t yes or no (Garage)' },
    ]);
  });

  it('spells options as the field does and ignores a mapping to a field that is gone', () => {
    expect(customCellValue(FIELDS[1]!, 'detail')).toEqual({ value: 'Detail' });
    expect(customCellValue(FIELDS[1]!, 'Tint')).toEqual({ value: 'Tint' }); // the server names it
    expect(customCellValue(FIELDS[2]!, 'wax; ppf;wax')).toEqual({ value: ['Wax', 'PPF'] });
    expect(customCellValue(FIELDS[3]!, '1,250')).toEqual({ value: 1250 });
    expect(customCellValue(FIELDS[3]!, ',')).toEqual({ error: '"," isn’t a number' });
    expect(customCellValue(FIELDS[4]!, 'No')).toEqual({ value: false });
    const { rows } = buildImportRows([{ Name: 'Ann', Old: 'x' }], {
      Name: 'first_name',
      Old: 'custom.removed',
    });
    expect(rows[0]?.payload).toEqual({ first_name: 'Ann' });
  });

  it('services have no custom field targets', () => {
    expect(importTargets('services', [], FIELDS).some((t) => t.id.startsWith('custom.'))).toBe(
      false,
    );
  });
});
