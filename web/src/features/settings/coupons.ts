import { addLocalDays, formatLocalDate, utcToShopLocal } from '@/lib/dates';
import { bpsToPercentInput, formatBps, formatCents } from '@/lib/money';
import type { Coupon } from './api';
import type { CouponFormInput } from './schemas';

/** "15% off" / "$25.00 off" (percent values are basis points, fixed are cents). */
export function describeDiscount(coupon: Pick<Coupon, 'kind' | 'value'>, currency = 'usd'): string {
  return coupon.kind === 'percent'
    ? `${formatBps(coupon.value)} off`
    : `${formatCents(coupon.value, { currency })} off`;
}

/** Shop-local first day (inclusive) of a coupon window. */
export function couponFirstDay(startsAt: string | null, tz: string): string | null {
  return startsAt ? utcToShopLocal(startsAt, tz).date : null;
}

/**
 * Shop-local last day (inclusive). Windows saved here end at 00:00 after the
 * last day; any other end instant counts its own day as the last one.
 */
export function couponLastDay(endsAt: string | null, tz: string): string | null {
  if (!endsAt) return null;
  const local = utcToShopLocal(endsAt, tz);
  return local.time === '00:00' ? addLocalDays(local.date, -1) : local.date;
}

export function describeWindow(coupon: Pick<Coupon, 'starts_at' | 'ends_at'>, tz: string): string {
  const first = couponFirstDay(coupon.starts_at, tz);
  const last = couponLastDay(coupon.ends_at, tz);
  if (first && last) return `${formatLocalDate(first)} – ${formatLocalDate(last)}`;
  if (first) return `From ${formatLocalDate(first)}`;
  if (last) return `Through ${formatLocalDate(last)}`;
  return 'No end date';
}

export type CouponState = 'active' | 'inactive' | 'scheduled' | 'expired' | 'used_up';

export function couponState(coupon: Coupon, now: Date = new Date()): CouponState {
  if (!coupon.active) return 'inactive';
  if (coupon.max_redemptions !== null && coupon.redemptions >= coupon.max_redemptions) {
    return 'used_up';
  }
  if (coupon.ends_at && new Date(coupon.ends_at).getTime() <= now.getTime()) return 'expired';
  if (coupon.starts_at && new Date(coupon.starts_at).getTime() > now.getTime()) return 'scheduled';
  return 'active';
}

export const COUPON_STATE_LABELS: Record<CouponState, string> = {
  active: 'Active',
  inactive: 'Off',
  scheduled: 'Scheduled',
  expired: 'Expired',
  used_up: 'Used up',
};

export function couponToFormInput(coupon: Coupon | null, tz: string): CouponFormInput {
  if (!coupon) {
    return {
      code: '',
      description: '',
      kind: 'percent',
      percent: '',
      amountCents: null,
      startDate: '',
      endDate: '',
      maxRedemptions: '',
      onlineOnly: false,
      active: true,
      limitServices: false,
      serviceIds: [],
      minSubtotalCents: null,
      oncePerCustomer: false,
      customerId: null,
      newCustomersOnly: false,
    };
  }
  return {
    code: coupon.code,
    description: coupon.description ?? '',
    kind: coupon.kind,
    percent: coupon.kind === 'percent' ? bpsToPercentInput(coupon.value) : '',
    amountCents: coupon.kind === 'fixed' ? coupon.value : null,
    startDate: couponFirstDay(coupon.starts_at, tz) ?? '',
    endDate: couponLastDay(coupon.ends_at, tz) ?? '',
    maxRedemptions: coupon.max_redemptions === null ? '' : String(coupon.max_redemptions),
    onlineOnly: coupon.online_only,
    active: coupon.active,
    limitServices: coupon.service_ids !== null,
    serviceIds: coupon.service_ids ?? [],
    minSubtotalCents: coupon.min_subtotal_cents,
    oncePerCustomer: coupon.once_per_customer,
    customerId: coupon.customer_id,
    newCustomersOnly: coupon.new_customers_only,
  };
}

/** Short restriction labels for the coupon list. */
export function couponRestrictions(
  coupon: Pick<
    Coupon,
    | 'service_ids'
    | 'min_subtotal_cents'
    | 'once_per_customer'
    | 'customer_id'
    | 'new_customers_only'
  >,
  currency = 'usd',
): string[] {
  const out: string[] = [];
  if (coupon.service_ids) {
    out.push(`${coupon.service_ids.length} service${coupon.service_ids.length === 1 ? '' : 's'}`);
  }
  if (coupon.min_subtotal_cents) {
    out.push(`Min ${formatCents(coupon.min_subtotal_cents, { currency })}`);
  }
  if (coupon.once_per_customer) out.push('Once per customer');
  if (coupon.customer_id) out.push('One customer');
  if (coupon.new_customers_only) out.push('New customers');
  return out;
}
