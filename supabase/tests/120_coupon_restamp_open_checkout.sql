-- 120 (0121): editing a coupon's service list is not blocked by a
-- customer's open deposit page. coupons_money_restamp_jobs re-stamps the
-- open jobs carrying the coupon, but a job whose deposit page can still be
-- paid keeps its eligibility (as a paid job does), so 0118's
-- jobs_98_open_checkout never refuses the owner's coupon edit; the other
-- open jobs are re-stamped as before, and the held job can be re-stamped by
-- re-applying the coupon once its page is gone.
\ir fixtures/two_shops.psql

select tests.as_superuser();
update public.shops set tax_rate_bps = 0 where id = tests.fx('shop_a');
insert into public.services (shop_id, name, duration_minutes) values (tests.fx('shop_a'), 'Ceramic add-on', 30)
  returning tests.fx_set('svc_cer', id);

create function pg_temp.check_coupons() returns void language plpgsql as $$
begin
  set constraints public.jobs_zz_money_coupon_check immediate;
  set constraints public.jobs_zz_money_coupon_check deferred;
end $$;
grant execute on function pg_temp.check_coupons() to authenticated;
create function pg_temp.job(p_id uuid) returns jsonb language sql security definer as $$
  select jsonb_build_array(j.total_cents, j.discount_cents,
                           (select array_agg(li.discount_eligible order by li.sort) from public.job_line_items li where li.job_id = j.id))
    from public.jobs j where j.id = p_id
$$;
grant execute on function pg_temp.job(uuid) to authenticated, service_role;

-- SAVE10 limited to Full Detail; two open jobs with Full Detail 200.00 + Ceramic add-on 100.00
select tests.authenticate_as(tests.fx('u_owner_a'));
update public.coupons set service_ids = array[tests.fx('svc_a')] where id = tests.fx('coupon_a');
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents, sort)
  values (tests.fx('shop_a'), tests.fx('job_a'), tests.fx('svc_cer'), 'Ceramic add-on', 10000, 2);
update public.jobs set coupon_id = tests.fx('coupon_a'), deposit_required_cents = 5000 where id = tests.fx('job_a');
select pg_temp.check_coupons();
insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents, sort) values
  (tests.fx('shop_a'), tests.fx('job_a2'), tests.fx('svc_a'), 'Full Detail', 20000, 1),
  (tests.fx('shop_a'), tests.fx('job_a2'), tests.fx('svc_cer'), 'Ceramic add-on', 10000, 2);
update public.jobs set coupon_id = tests.fx('coupon_a') where id = tests.fx('job_a2');
select pg_temp.check_coupons();
select tests.eq(pg_temp.job(tests.fx('job_a')), '[28000, 2000, [true, false]]'::jsonb, 'job_a: 10% of Full Detail only');
select tests.eq(pg_temp.job(tests.fx('job_a2')), '[28000, 2000, [true, false]]'::jsonb, 'job_a2: the same');

-- ============================================================ the repro: job_a's deposit page is open
select tests.as_superuser();
insert into public.shop_stripe_accounts (shop_id, stripe_account_id, charges_enabled) values (tests.fx('shop_a'), 'acct_A1', true);
select tests.as_service();
select public.payments_hold_job_checkout(tests.fx('shop_a'), tests.fx('job_a'), 'cs_test_dep1', now() + interval '35 minutes');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.lives($$update public.coupons set service_ids = null where id = tests.fx('coupon_a')$$,
                   'editing a coupon is not blocked by a customer''s open deposit page');
select tests.eq(pg_temp.job(tests.fx('job_a')), '[28000, 2000, [true, false]]'::jsonb,
                'the job with the open page keeps its price (the page charges what it was opened for)');
select tests.eq(pg_temp.job(tests.fx('job_a2')), '[27000, 3000, [true, true]]'::jsonb, 'the other open job takes the wider list');

-- narrowing again: the held job is still left alone, the other re-stamped
select tests.lives($$update public.coupons set service_ids = array[tests.fx('svc_a')] where id = tests.fx('coupon_a')$$, 'narrowing');
select tests.eq(pg_temp.job(tests.fx('job_a')), '[28000, 2000, [true, false]]'::jsonb, 'held job unchanged');
select tests.eq(pg_temp.job(tests.fx('job_a2')), '[28000, 2000, [true, false]]'::jsonb, 'open job re-stamped');

-- once the page is released, the next edit re-stamps job_a too
select tests.as_service();
select public.payments_release_job_checkouts(tests.fx('shop_a'), tests.fx('job_a'));
select tests.authenticate_as(tests.fx('u_owner_a'));
update public.coupons set service_ids = null where id = tests.fx('coupon_a');
select tests.eq(pg_temp.job(tests.fx('job_a')), '[27000, 3000, [true, true]]'::jsonb, 'no page open: re-stamped');

-- the job's own price cut still waits for its open page (0118 unchanged)
select tests.as_service();
select public.payments_hold_job_checkout(tests.fx('shop_a'), tests.fx('job_a'), 'cs_test_dep2', now() + interval '35 minutes');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws_like($$update public.job_line_items set unit_price_cents = 1000 where job_id = tests.fx('job_a') and sort = 2$$,
                         '55000', 'a card payment page for this job is still open%', 'a line price cut on the job still waits');
