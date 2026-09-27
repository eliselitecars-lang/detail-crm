import { formatBps, formatCents } from '@/lib/money';
import type { Enums } from './types';

export type DiscountKind = Enums['discount_kind'];

export function isDiscountKind(value: string): value is DiscountKind {
  return value === 'none' || value === 'percent' || value === 'fixed';
}

export function describeDiscount(kind: DiscountKind, value: number, currency: string): string {
  if (kind === 'percent') return `${formatBps(value)} off`;
  if (kind === 'fixed') return `${formatCents(value, { currency })} off`;
  return 'None';
}
