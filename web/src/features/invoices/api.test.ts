import { describe, expect, it } from 'vitest';
import { AppError } from '@/lib/errors';
import { EdgeFunctionError } from '@/features/quotes/shared/edge';
import { cancelOpenPaymentsSummary, isPaymentInFlight, isPaymentInProgressError } from './api';

describe('isPaymentInFlight (mirrors public.payment_in_flight)', () => {
  const now = new Date('2026-09-27T12:00:00Z');
  it('is a pending payment started within the last hour', () => {
    expect(isPaymentInFlight({ status: 'pending', created_at: '2026-09-27T11:30:00Z' }, now)).toBe(
      true,
    );
    expect(isPaymentInFlight({ status: 'pending', created_at: '2026-09-27T10:59:00Z' }, now)).toBe(
      false,
    );
    expect(
      isPaymentInFlight({ status: 'succeeded', created_at: '2026-09-27T11:59:00Z' }, now),
    ).toBe(false);
  });
});

describe('isPaymentInProgressError', () => {
  it('recognises the SQL guards and the payments function conflict', () => {
    expect(isPaymentInProgressError(new AppError('A payment is in progress on this invoice'))).toBe(
      true,
    );
    expect(
      isPaymentInProgressError({
        message: 'a payment is in progress on this invoice; wait for it to finish',
        code: '22023',
      }),
    ).toBe(true);
    expect(
      isPaymentInProgressError(
        new EdgeFunctionError('A payment for this is already being processed.', {
          status: 409,
          reason: 'payment_in_progress',
        }),
      ),
    ).toBe(true);
    expect(isPaymentInProgressError(new AppError('Something else'))).toBe(false);
  });
});

describe('cancelOpenPaymentsSummary', () => {
  it('summarises cancelled, recorded, processing and expired links', () => {
    expect(
      cancelOpenPaymentsSummary({
        invoice_id: 'i',
        cancelled: 2,
        succeeded: 1,
        in_progress: 1,
        sessions_expired: 0,
      }),
    ).toEqual({
      title: '2 open payments cancelled',
      description:
        '1 payment had already gone through and was recorded. 1 payment is still being processed by the bank and can’t be cancelled; the invoice updates when it finishes.',
    });
  });

  it('says so when there was nothing to cancel', () => {
    expect(
      cancelOpenPaymentsSummary({
        invoice_id: 'i',
        cancelled: 0,
        succeeded: 0,
        in_progress: 0,
        sessions_expired: 0,
      }),
    ).toEqual({ title: 'No open payments to cancel' });
    expect(
      cancelOpenPaymentsSummary({
        invoice_id: 'i',
        cancelled: 0,
        succeeded: 0,
        in_progress: 2,
        sessions_expired: 0,
      }).title,
    ).toBe('A payment is still processing');
  });
});
