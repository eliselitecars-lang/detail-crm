import { describe, expect, it } from 'vitest';
import { paymentRow } from '@/features/quotes/testFixtures';
import { ledgerDateFilter, type LedgerRow } from './api';
import { csvCell, ledgerToCsv } from './csv';
import { paymentMethodLabel, refundableCents } from './paymentFormat';

describe('paymentFormat', () => {
  it('labels card payments with brand and last4 only', () => {
    expect(paymentMethodLabel(paymentRow())).toBe('Visa •••• 4242');
    expect(
      paymentMethodLabel(paymentRow({ method: 'cash', card_brand: null, card_last4: null })),
    ).toBe('Cash');
    expect(
      paymentMethodLabel(
        paymentRow({ method: 'bank_transfer', card_brand: null, card_last4: null }),
      ),
    ).toBe('Bank transfer');
  });

  it('bounds refunds by amount + tip − refunded, only for received payments', () => {
    expect(refundableCents(paymentRow())).toBe(11500);
    expect(
      refundableCents(paymentRow({ status: 'partially_refunded', refunded_cents: 1500 })),
    ).toBe(10000);
    expect(refundableCents(paymentRow({ status: 'refunded', refunded_cents: 11500 }))).toBe(0);
    expect(refundableCents(paymentRow({ status: 'pending' }))).toBe(0);
  });
});

describe('ledger CSV', () => {
  const row: LedgerRow = {
    ...paymentRow({ note: 'Paid, "thanks"' }),
    customer: { id: 'c1', first_name: 'Jane', last_name: 'Doe', company: null },
    invoice: { id: 'inv-1', number: 2001 },
    job: null,
  };

  it('escapes cells and neutralises formulas', () => {
    expect(csvCell('a,b')).toBe('"a,b"');
    expect(csvCell('say "hi"')).toBe('"say ""hi"""');
    expect(csvCell('=SUM(A1)')).toBe("'=SUM(A1)");
    expect(csvCell(null)).toBe('');
    expect(csvCell(12)).toBe('12');
  });

  it('writes one line per payment with shop-local dates and decimal amounts', () => {
    const csv = ledgerToCsv([row], 'America/Chicago');
    const [header, line] = csv.trim().split('\r\n');
    expect(header).toBe(
      'Date,Customer,Invoice,Job,Kind,Method,Card,Status,Amount,Tip,Refunded,Note',
    );
    expect(line).toBe(
      '2026-09-21 10:00,Jane Doe,2001,,Payment,Card,Visa 4242,succeeded,100.00,15.00,0.00,"Paid, ""thanks"""',
    );
  });
});

describe('ledgerDateFilter', () => {
  it('matches received payments by paid_at and others by created_at', () => {
    expect(ledgerDateFilter('A', 'B')).toBe(
      'and(paid_at.gte."A",paid_at.lt."B"),and(paid_at.is.null,created_at.gte."A",created_at.lt."B")',
    );
  });
});
