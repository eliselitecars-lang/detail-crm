-- 130 (0130): "Refresh coupon" — restamp_job_coupon re-stamps a job's own
-- coupon eligibility in place, also for a coupon that has since expired,
-- been deactivated or been used up (re-applying it would redeem it anew and
-- fail), keeping the open-checkout guard (0118 / 0121).
\ir fixtures/two_shops.psql

select tests.as_superuser();
update public.shops set tax_rate_bps = 0 where id = tests.fx('shop_a');
insert into public.services (shop_id, name, duration_minutes) values (tests.fx('shop_a'), 'Ceramic add-on', 30)
  returning tests.fx_set('svc_cer', id);
create function pg_temp.job(p_id uuid) returns jsonb language sql security definer as $$
  select jsonb_build_array(j.total_cents, j.discount_cents,
                           (select array_agg(li.discount_eligible order by li.sort) from public.job_line_items li where li.job_id = j.id))
    from public.jobs j where j.id = p_id
$$;
grant execute on function pg_temp.job(uuid) to authenticated, service_role;
create function pg_temp.hint_of(p_sql text) returns text language plpgsql as $$
declare v_hint text;
begin
  execute p_sql;
  return null;
exception when others then
  get stacked diagnostics v_hint = pg_exception_hint;
  return v_hint;
end
$$;
grant execute on function pg_temp.hint_of(text) to authenticated;

-- SAVE10 limited to Full Detail; job_a: Full Detail 200.00 + Ceramic add-on 100.00
select tests.authenticate_as(tests.fx('u_owner_a'));
update public.coupons set service_ids = array[tests.fx('svc_a')] where id = tests.fx('coupon_a');
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.job_line_items set sort = 1 where id = tests.fx('line_a');
insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents, sort)
  values (tests.fx('shop_a'), tests.fx('job_a'), tests.fx('svc_cer'), 'Ceramic add-on', 10000, 2);
update public.jobs set coupon_id = tests.fx('coupon_a'), deposit_required_cents = 5000 where id = tests.fx('job_a');
set constraints public.jobs_zz_money_coupon_check immediate;
set constraints public.jobs_zz_money_coupon_check deferred;
select tests.as_superuser();
select tests.fx_set('line_cer', (select id from public.job_line_items where job_id = tests.fx('job_a') and service_id = tests.fx('svc_cer')));
select tests.eq(pg_temp.job(tests.fx('job_a')) -> 2, '[true, false]'::jsonb, 'setup: only Full Detail is eligible');
select tests.eq((pg_temp.job(tests.fx('job_a')) ->> 1)::int, (select (li.total_cents / 10)::int from public.job_line_items li where li.id = tests.fx('line_a')),
                'setup: 10% of the Full Detail line');

-- a deposit page is open while the owner widens the coupon to every service:
-- the held job keeps its eligibility (0121)
insert into public.job_checkout_holds (stripe_checkout_session_id, shop_id, job_id, expires_at)
  values ('cs_test_restamp1', tests.fx('shop_a'), tests.fx('job_a'), now() + interval '30 minutes');
select tests.authenticate_as(tests.fx('u_owner_a'));
update public.coupons set service_ids = null where id = tests.fx('coupon_a');
select tests.eq(pg_temp.job(tests.fx('job_a')) -> 2, '[true, false]'::jsonb, 'the held job was skipped');
select tests.ok(public.job_coupon_eligibility_stale(tests.fx('job_a')), 'its coupon eligibility is stale');
-- since then the coupon expired, was switched off and is used up
select tests.as_superuser();
update public.coupons set ends_at = now() - interval '1 day', active = false, max_redemptions = redemptions
 where id = tests.fx('coupon_a');

-- ============================================================ refusals
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(pg_temp.hint_of($$select public.restamp_job_coupon(tests.fx('job_a'))$$), 'checkout_open',
                'a lower total while the deposit page is open: 55000 HINT checkout_open');
select tests.as_superuser();
delete from public.job_checkout_holds where stripe_checkout_session_id = 'cs_test_restamp1';
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$select public.restamp_job_coupon(tests.fx('job_a'))$$, '42501', 'technicians cannot (even assigned)');
select tests.throws($$select public.job_coupon_eligibility_stale(tests.fx('job_a'))$$, '42501', 'nor check staleness');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.throws($$select public.restamp_job_coupon(tests.fx('job_a'))$$, 'P0002', 'another shop: not found');
select tests.as_anon();
select tests.throws($$select public.restamp_job_coupon(tests.fx('job_a'))$$, '42501', 'anon cannot execute');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws_like($$select public.restamp_job_coupon(tests.fx('job_a2'))$$, '22023', '%no coupon%',
                         'a job without a coupon: nothing to refresh');
select tests.eq(public.job_coupon_eligibility_stale(tests.fx('job_a2')), false, 'and never stale');
-- the old advice fails for such a coupon
select tests.throws_like($$update public.jobs set coupon_id = null where id = tests.fx('job_a');
                           update public.jobs set coupon_id = tests.fx('coupon_a') where id = tests.fx('job_a')$$,
                         '23514', '%no longer active%', 're-applying an inactive / expired / used-up coupon is refused');

-- ============================================================ refresh
select tests.eq(public.restamp_job_coupon(tests.fx('job_a')),
                jsonb_build_object('lines_changed', 1,
                                   'total_cents', (select sum(li.total_cents) - (sum(li.total_cents) / 10) from public.job_line_items li
                                                    where li.job_id = tests.fx('job_a'))),
                'refreshed in place: one line changed, the new total');
select tests.eq(pg_temp.job(tests.fx('job_a')) -> 2, '[true, true]'::jsonb, 'every line is now eligible');
select tests.eq(public.job_coupon_eligibility_stale(tests.fx('job_a')), false, 'no longer stale');
select tests.as_superuser();
select tests.eq((select coupon_id from public.jobs where id = tests.fx('job_a')), tests.fx('coupon_a'), 'the job keeps its coupon');
select tests.eq((select redemptions = max_redemptions and not active from public.coupons where id = tests.fx('coupon_a')), true,
                'nothing was redeemed again');
select tests.eq((select count(*) from public.coupon_redemptions where job_id = tests.fx('job_a')), 1::bigint,
                'the job holds its one redemption');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(public.restamp_job_coupon(tests.fx('job_a')) -> 'lines_changed', '0'::jsonb, 'a second refresh changes nothing');

-- narrowing (the total goes up) is allowed while a page is open
select tests.as_superuser();
insert into public.job_checkout_holds (stripe_checkout_session_id, shop_id, job_id, expires_at)
  values ('cs_test_restamp2', tests.fx('shop_a'), tests.fx('job_a'), now() + interval '30 minutes');
update public.coupons set service_ids = array[tests.fx('svc_cer')] where id = tests.fx('coupon_a');
select tests.eq(pg_temp.job(tests.fx('job_a')) -> 2, '[true, true]'::jsonb, 'the held job was skipped again');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(public.restamp_job_coupon(tests.fx('job_a')) -> 'lines_changed', '1'::jsonb,
                'a refresh that raises the total is not blocked by the open page');
select tests.eq(pg_temp.job(tests.fx('job_a')) -> 2, '[false, true]'::jsonb, 'only the add-on is eligible now');
select tests.as_superuser();
delete from public.job_checkout_holds where stripe_checkout_session_id = 'cs_test_restamp2';

-- a billed job cannot change
update public.coupons set service_ids = null where id = tests.fx('coupon_a');
select tests.authenticate_as(tests.fx('u_owner_a'));
select public.create_invoice_from_job(tests.fx('job_a'));
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(public.job_coupon_eligibility_stale(tests.fx('job_a')), false, 'a billed job is never offered a refresh');
select tests.throws_like($$select public.restamp_job_coupon(tests.fx('job_a'))$$, '23514', '%billed on invoice%',
                         'a billed job: 23514');
