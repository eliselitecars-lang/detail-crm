/** Display helpers for payment rows (shared by the invoices and payments features). */
import type { Row } from '@/lib/db';
import type { Enums } from '@/features/quotes/shared/types';

export type PaymentMethod = Enums['payment_method'];
export type PaymentKind = Enums['payment_kind'];
export type PaymentStatus = Enums['payment_status'];

export const PAYMENT_METHODS = [
  'card',
  'card_present',
  'cash',
  'check',
  'bank_transfer',
  'ach_debit',
  'bnpl',
  'gift_card',
  'other',
] as const satisfies readonly PaymentMethod[];

export const MANUAL_METHODS = [
  'cash',
  'check',
  'bank_transfer',
  'other',
] as const satisfies readonly PaymentMethod[];
export type ManualMethod = (typeof MANUAL_METHODS)[number];

export const PAYMENT_KINDS = [
  'deposit',
  'payment',
  'membership',
] as const satisfies readonly PaymentKind[];

export const PAYMENT_STATUSES = [
  'pending',
  'processing',
  'succeeded',
  'failed',
  'cancelled',
  'refunded',
  'partially_refunded',
] as const satisfies readonly PaymentStatus[];

export const METHOD_LABELS: Record<PaymentMethod, string> = {
  card: 'Card',
  card_present: 'Card (in person)',
  cash: 'Cash',
  check: 'Check',
  bank_transfer: 'Bank transfer',
  gift_card: 'Gift card / credit',
  ach_debit: 'Bank debit (ACH)',
  bnpl: 'Pay later',
  other: 'Other',
};

export const KIND_LABELS: Record<PaymentKind, string> = {
  deposit: 'Deposit',
  payment: 'Payment',
  membership: 'Membership',
};

const BRAND_LABELS: Record<string, string> = {
  visa: 'Visa',
  mastercard: 'Mastercard',
  amex: 'Amex',
  american_express: 'Amex',
  discover: 'Discover',
  diners: 'Diners',
  jcb: 'JCB',
  unionpay: 'UnionPay',
};

export function brandLabel(brand: string | null | undefined): string {
  if (!brand) return 'Card';
  return BRAND_LABELS[brand.toLowerCase()] ?? brand.charAt(0).toUpperCase() + brand.slice(1);
}

const PAY_LATER_PROVIDERS: Record<string, string> = {
  affirm: 'Affirm',
  klarna: 'Klarna',
  afterpay_clearpay: 'Afterpay',
  zip: 'Zip',
};

/** "Visa •••• 4242", "Cash", "Card (in person)", "Pay later · Klarna". */
export function paymentMethodLabel(
  payment: Pick<Row<'payments'>, 'method' | 'card_brand' | 'card_last4'> & {
    stripe_method_type?: string | null;
  },
): string {
  if ((payment.method === 'card' || payment.method === 'card_present') && payment.card_last4) {
    return `${brandLabel(payment.card_brand)} •••• ${payment.card_last4}`;
  }
  const provider = payment.stripe_method_type
    ? PAY_LATER_PROVIDERS[payment.stripe_method_type]
    : undefined;
  if (payment.method === 'bnpl' && provider) return `${METHOD_LABELS.bnpl} · ${provider}`;
  return METHOD_LABELS[payment.method];
}

export function isCardMethod(method: PaymentMethod): boolean {
  return method === 'card' || method === 'card_present';
}

/** Money that moved through Stripe (refunded through Stripe, never by hand). */
export const STRIPE_METHODS = [
  'card',
  'card_present',
  'ach_debit',
  'bnpl',
] as const satisfies readonly PaymentMethod[];

export function isStripeMethod(method: PaymentMethod): boolean {
  return (STRIPE_METHODS as readonly PaymentMethod[]).includes(method);
}

/**
 * Upper bound for a refund of this payment (amount + tip − already
 * refunded). Used only to bound the input; the server re-validates against
 * Stripe / the row and refuses anything larger.
 */
export function refundableCents(
  payment: Pick<Row<'payments'>, 'status' | 'amount_cents' | 'tip_cents' | 'refunded_cents'>,
): number {
  if (payment.status !== 'succeeded' && payment.status !== 'partially_refunded') return 0;
  return Math.max(0, payment.amount_cents + payment.tip_cents - payment.refunded_cents);
}
