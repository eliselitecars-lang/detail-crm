-- 110 (0119): the nightly series extension (generate_series_jobs, pg_cron
-- detail-crm-generate-series) skips a lapsed shop's series, as BILLING.md §8
-- pauses new jobs and recurring series for it; the active shop in the same
-- run is extended as usual, and the lapsed shop's series catch up once it
-- pays again. Billing off extends everyone.
\ir fixtures/two_shops.psql

create function pg_temp.series(p_shop uuid, p_mgr uuid, p_cust uuid, p_veh uuid, p_svc uuid) returns uuid
language plpgsql as $$
begin
  perform tests.authenticate_as(p_mgr);
  return ((public.create_job_series(p_shop, jsonb_build_object(
            'customer_id', p_cust, 'vehicle_id', p_veh, 'freq', 'week', 'local_start', '09:00',
            'start_date', (now() at time zone 'America/Chicago')::date,
            'template_lines', jsonb_build_array(jsonb_build_object('service_id', p_svc))))) ->> 'series_id')::uuid;
end
$$;
create function pg_temp.occurrences(p_series uuid) returns bigint language sql as $$
  select count(*) from public.jobs where series_id = p_series $$;
grant execute on function pg_temp.occurrences(uuid) to service_role;

-- while billing is off each shop sets up a weekly series starting today
-- (shop B's wash needs a price)
insert into public.service_prices (shop_id, service_id, vehicle_category_id, price_cents)
  select tests.fx('shop_b'), tests.fx('svc_b'), null, 5000
   where not exists (select 1 from public.service_prices where service_id = tests.fx('svc_b') and vehicle_category_id is null);
select tests.fx_set('ser_a', pg_temp.series(tests.fx('shop_a'), tests.fx('u_manager_a'), tests.fx('cust_a'), tests.fx('veh_a'), tests.fx('svc_a')));
select tests.fx_set('ser_b', pg_temp.series(tests.fx('shop_b'), tests.fx('u_manager_b'), tests.fx('cust_b'), tests.fx('veh_b'), tests.fx('svc_b')));
select tests.as_superuser();
create temp table counts as
  select pg_temp.occurrences(tests.fx('ser_a')) as a0, pg_temp.occurrences(tests.fx('ser_b')) as b0;
grant select on counts to service_role;
select tests.ok((select a0 > 0 and b0 > 0 from counts), 'both series have their first occurrences');

-- billing on: A lapsed (never subscribed, no trial), B active
select tests.as_service();
select public.set_billing_config(true, 0);
update public.shop_billing set status = 'active', current_period_end = now() + interval '90 days' where shop_id = tests.fx('shop_b');
select tests.eq((public.shop_billing_standing(tests.fx('shop_a'))).state, 'lapsed', 'shop A is lapsed');

-- the nightly job, 60 days later: only shop B's series grows
select tests.ok(public.generate_series_jobs(now() + interval '60 days') > 0, 'the run creates jobs');
select tests.eq(pg_temp.occurrences(tests.fx('ser_a')), (select a0 from counts), 'no new visits for the lapsed shop');
select tests.ok(pg_temp.occurrences(tests.fx('ser_b')) > (select b0 from counts), 'the active shop''s series is extended');
select tests.ok((select active from public.job_series where id = tests.fx('ser_a')), 'the lapsed shop''s series stays active');

-- once shop A pays again, the next run catches its series up
select public.billing_set_comp(tests.fx('shop_a'), 'infinity');
select tests.ok(public.generate_series_jobs(now() + interval '60 days') > 0, 'the next run creates shop A''s jobs');
select tests.ok(pg_temp.occurrences(tests.fx('ser_a')) > (select a0 from counts), 'shop A''s series is extended again');

-- billing off: everyone (shop A lapsed again, but billing is off)
select public.billing_set_comp(tests.fx('shop_a'), null);
select public.set_billing_config(false, 0);
select tests.as_superuser();
update counts set a0 = pg_temp.occurrences(tests.fx('ser_a'));
select tests.as_service();
select public.generate_series_jobs(now() + interval '120 days');
select tests.ok(pg_temp.occurrences(tests.fx('ser_a')) > (select a0 from counts), 'billing off: every shop''s series is extended');
