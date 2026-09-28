import { describe, expect, it } from 'vitest';
import { csvCell, toCsv } from '@/lib/csv';
import { buildImportRows, normalizeServiceKind, parseCsv } from './importing';

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
