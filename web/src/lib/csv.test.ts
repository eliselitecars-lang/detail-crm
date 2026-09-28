import { describe, expect, it } from 'vitest';
import { centsCell, csvCell, rowsToCsv, stripFormulaGuard, toCsv } from './csv';
import { fileStem } from './download';

describe('csv', () => {
  it('quotes and neutralises cells', () => {
    expect(csvCell('a,b')).toBe('"a,b"');
    expect(csvCell('say "hi"')).toBe('"say ""hi"""');
    expect(csvCell('line\nbreak')).toBe('"line\nbreak"');
    expect(csvCell('=SUM(A1)')).toBe("'=SUM(A1)");
    expect(csvCell('+1 555')).toBe("'+1 555");
    expect(csvCell(-5)).toBe('-5');
    // Plain decimal strings (negative money from centsCell) stay numbers.
    expect(csvCell(centsCell(-1250))).toBe('-12.50');
    expect(csvCell('-3')).toBe('-3');
    // Text that only starts like a number is still guarded.
    expect(csvCell('-1+2')).toBe("'-1+2");
    expect(csvCell('-A1')).toBe("'-A1");
    // E.164 phones keep the guard so spreadsheets keep them as text.
    expect(csvCell('+15551234567')).toBe("'+15551234567");
    expect(csvCell(true)).toBe('true');
    expect(csvCell(null)).toBe('');
    expect(centsCell(12345)).toBe('123.45');
    expect(centsCell(null)).toBe('');
  });

  it('undoes its own formula guard only', () => {
    expect(stripFormulaGuard("'+15551234567")).toBe('+15551234567');
    expect(stripFormulaGuard("'=SUM(A1)")).toBe('=SUM(A1)');
    expect(stripFormulaGuard("'-12.50")).toBe('-12.50');
    expect(stripFormulaGuard("'Tis")).toBe("'Tis");
    expect(stripFormulaGuard("'")).toBe("'");
    expect(stripFormulaGuard('+1')).toBe('+1');
    for (const text of ['+15551234567', '=A1', '@x', '-A1', 'plain'])
      expect(stripFormulaGuard(csvCell(text))).toBe(text);
  });

  it('writes a header and CRLF rows', () => {
    const csv = toCsv(
      [
        { header: 'Name', value: (r: { name: string; cents: number }) => r.name },
        { header: 'Total', value: (r) => centsCell(r.cents) },
      ],
      [{ name: 'Doe, Jane', cents: 500 }],
    );
    expect(csv).toBe('Name,Total\r\n"Doe, Jane",5.00\r\n');
    expect(
      rowsToCsv([
        ['a', 1],
        ['b', null],
      ]),
    ).toBe('a,1\r\nb,\r\n');
  });

  it('makes safe file names', () => {
    expect(fileStem('Glacier Détailing & Co.')).toBe('glacier-detailing-co');
    expect(fileStem('***', 'fallback')).toBe('fallback');
  });
});
