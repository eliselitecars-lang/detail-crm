-- ============================================================================
-- 0112 — Backfill for 0109's coupon rule: a job holds a coupon redemption
-- only while it is not cancelled / no-show.
--
-- 0109 changed the rule for jobs cancelled from then on (the redemption is
-- given back at the cancellation, deleting a cancelled / no-show job gives
-- back nothing, reopening one takes a redemption again) but never gave back
-- the redemptions held by jobs that were ALREADY cancelled or no-show when
-- it was applied. On a database that ran 0001-0108 with such jobs:
--   * those redemptions stayed counted forever, so limited "first N" promos
--     stayed used up;
--   * deleting such a job (which released the redemption before 0109) now
--     leaks it for good;
--   * reopening one counts it twice.
--
-- coupons.redemptions is lowered to the number of jobs that hold the coupon
-- under 0109's rule (coupon_id set, status not cancelled / no_show) wherever
-- it counts more. Idempotent, and a no-op on a database built from zero:
-- every other change to redemptions (redeem / release on a coupon change,
-- online booking, delete) already follows the holding jobs, so a count above
-- them can only be one of these stale redemptions. A count below them is
-- never raised (nothing here takes a redemption).
-- ============================================================================

update public.coupons c
   set redemptions = h.holding
  from (select c2.id,
               (select count(*)::integer from public.jobs j
                 where j.shop_id = c2.shop_id and j.coupon_id = c2.id
                   and j.status not in ('cancelled', 'no_show')) as holding
          from public.coupons c2) h
 where h.id = c.id and c.redemptions > h.holding;
