-- 110 coupons (0112): the backfill for 0109's rule (a job holds a coupon
-- redemption only while it is not cancelled / no-show). A database that ran
-- 0001-0108 still counted the redemptions of jobs already cancelled or
-- no-show when 0109 arrived; 0112 lowers coupons.redemptions to the jobs
-- that hold the coupon, so deleting such a job no longer leaks a redemption
-- and reopening one no longer counts it twice. The migration's statement is
-- re-run here on a simulated pre-0109 state (idempotent).
\ir fixtures/two_shops.psql

select tests.as_superuser();
insert into public.jobs (shop_id, customer_id, vehicle_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('veh_a'), '2025-06-03 15:00+00', '2025-06-03 16:00+00')
  returning tests.fx_set('job_ns', id);
insert into public.coupons (shop_id, code, kind, value) values (tests.fx('shop_a'), 'UNDER', 'percent', 500)
  returning tests.fx_set('cp_under', id);
create function pg_temp.redemptions(p_id uuid) returns integer language sql as $$
  select redemptions from public.coupons where id = p_id
$$;
select pg_temp.redemptions(tests.fx('coupon_a')) as base \gset

-- three jobs take coupon_a; one is cancelled and one marked no-show
select tests.authenticate_as(tests.fx('u_owner_a'));
update public.jobs set coupon_id = tests.fx('coupon_a') where id in (tests.fx('job_a'), tests.fx('job_a2'), tests.fx('job_ns'));
update public.jobs set status = 'cancelled' where id = tests.fx('job_a');
update public.jobs set status = 'no_show' where id = tests.fx('job_ns');
select tests.as_superuser();
select tests.eq(pg_temp.redemptions(tests.fx('coupon_a')), :base + 1, '0109: only the live job holds a redemption');

-- what a database upgraded from 0108 holds: the two closed jobs still counted
update public.coupons set redemptions = redemptions + 2 where id = tests.fx('coupon_a');
-- and a coupon counting fewer than its holders (not this bug) is left alone
update public.jobs set coupon_id = tests.fx('cp_under') where id = tests.fx('job_a2');
update public.coupons set redemptions = 0 where id = tests.fx('cp_under');
update public.coupons set redemptions = redemptions - 1 where id = tests.fx('coupon_a');   -- job_a2 moved to UNDER
select tests.eq(pg_temp.redemptions(tests.fx('coupon_a')), :base + 2, 'stale: two redemptions for no live holder');

\ir ../migrations/0112_money_coupon_redemption_backfill.sql

select tests.eq(pg_temp.redemptions(tests.fx('coupon_a')), 0, 'backfill: no live job holds coupon_a -> 0');
select tests.eq(pg_temp.redemptions(tests.fx('cp_under')), 0, 'a count below its holders is never raised');

-- deleting the cancelled job gives back nothing more; reopening the no-show takes one again
select tests.authenticate_as(tests.fx('u_owner_a'));
delete from public.jobs where id = tests.fx('job_a');
select tests.as_superuser();
select tests.eq(pg_temp.redemptions(tests.fx('coupon_a')), 0, 'deleting the cancelled job: still 0 (no leak, never negative)');
select tests.authenticate_as(tests.fx('u_owner_a'));
update public.jobs set status = 'scheduled' where id = tests.fx('job_ns');
select tests.as_superuser();
select tests.eq(pg_temp.redemptions(tests.fx('coupon_a')), 1, 'reopening the no-show counts it once');

\ir ../migrations/0112_money_coupon_redemption_backfill.sql
select tests.eq(pg_temp.redemptions(tests.fx('coupon_a')), 1, 'the backfill is idempotent');
select tests.eq((select count(*) from public.coupons c
                  where c.shop_id in (tests.fx('shop_a'), tests.fx('shop_b'))
                    and c.redemptions > (select count(*) from public.jobs j
                                          where j.coupon_id = c.id and j.status not in ('cancelled', 'no_show'))),
                0::bigint, 'no coupon of these shops counts more than the jobs holding it');
