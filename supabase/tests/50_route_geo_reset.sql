-- 50 sched: jobs_56_route_geo_reset (0057) and series address edits (0051) —
--   * a job's coordinates are cleared when its location type or any service
--     address field changes, unless the same write sets new coordinates;
--     unrelated edits keep them; update_job_series clears the series'
--     coordinates on an address patch without coordinates, so regenerated
--     occurrences are geocoded again;
--   * route_position is cleared when scheduled_start moves the job to
--     another shop-local day (or unschedules it), kept for a same-day move
--     (including across the UTC date line) and when the same write sets it;
--   * both hold for every writer (manager API, trusted service role) and
--     never touch the other shop's jobs.
\ir fixtures/two_shops.psql

select tests.as_superuser();
create function pg_temp.addr(p_job uuid) returns jsonb language sql stable as $$
  select jsonb_build_object('service_address_line1', j.service_address_line1, 'service_address_line2', j.service_address_line2,
                            'service_city', j.service_city, 'service_region', j.service_region,
                            'service_postal_code', j.service_postal_code)
    from public.jobs j where j.id = p_job
$$;
grant execute on function pg_temp.addr(uuid) to authenticated, anon, service_role;
insert into public.jobs (shop_id, customer_id, location_type, service_address_line1, service_city, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a3'), 'mobile', '9 Oak St', 'Birmingham', '2025-06-02 20:00Z', '2025-06-02 21:00Z')
  returning tests.fx_set('job_m', id);
insert into public.jobs (shop_id, customer_id, location_type, service_address_line1, service_city, scheduled_start, scheduled_end)
  values (tests.fx('shop_b'), tests.fx('cust_b'), 'mobile', '9 Oak St', 'Birmingham', '2025-06-02 20:00Z', '2025-06-02 21:00Z')
  returning tests.fx_set('job_mb', id);

-- ============================================================ coordinates follow the address
select tests.authenticate_as(tests.fx('u_manager_a'));
select public.set_job_coordinates(tests.fx('job_m'), 33.5, -86.8, pg_temp.addr(tests.fx('job_m')));
select tests.eq((select service_lat from public.jobs where id = tests.fx('job_m')), 33.5::double precision, 'geocoded');
update public.jobs set notes = 'side gate' where id = tests.fx('job_m');
select tests.eq((select service_lat from public.jobs where id = tests.fx('job_m')), 33.5::double precision,
                'an unrelated edit keeps the coordinates');
update public.jobs set service_address_line1 = '1 Main St', service_city = 'Huntsville' where id = tests.fx('job_m');
select tests.eq((select service_lat from public.jobs where id = tests.fx('job_m')), null::double precision,
                'coordinates of the old address are cleared when the service address changes');
select tests.eq((select service_lng from public.jobs where id = tests.fx('job_m')), null::double precision,
                '... both of them');
select public.set_job_coordinates(tests.fx('job_m'), 34.7, -86.6, pg_temp.addr(tests.fx('job_m')));
update public.jobs set service_postal_code = '35801', service_lat = 34.73, service_lng = -86.58 where id = tests.fx('job_m');
select tests.eq((select array[service_lat, service_lng] from public.jobs where id = tests.fx('job_m')),
                array[34.73, -86.58]::double precision[], 'an address edit that sends new coordinates keeps them');
update public.jobs set service_address_line2 = 'Unit 4' where id = tests.fx('job_m');
select tests.eq((select service_lat from public.jobs where id = tests.fx('job_m')), null::double precision,
                'line 2 counts as an address change');
select public.set_job_coordinates(tests.fx('job_m'), 34.7, -86.6, pg_temp.addr(tests.fx('job_m')));
update public.jobs set location_type = 'shop' where id = tests.fx('job_m');
select tests.eq((select service_lat from public.jobs where id = tests.fx('job_m')), null::double precision,
                'a location type change clears them');
update public.jobs set location_type = 'mobile' where id = tests.fx('job_m');
select public.set_job_coordinates(tests.fx('job_m'), 34.7, -86.6, pg_temp.addr(tests.fx('job_m')));
select tests.as_service();
update public.jobs set service_region = 'AL' where id = tests.fx('job_m');
select tests.as_superuser();
select tests.eq((select service_lat from public.jobs where id = tests.fx('job_m')), null::double precision,
                'a trusted writer (service role) gets the same rule');
-- the other shop is not touched and not reachable
update public.jobs set service_lat = 33.5, service_lng = -86.8 where id = tests.fx('job_mb');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$update public.jobs set service_city = 'Mobile' where id = tests.fx('job_mb')$$), 0::bigint,
                'another shop''s job cannot be edited');
select tests.as_superuser();
select tests.eq((select service_lat from public.jobs where id = tests.fx('job_mb')), 33.5::double precision,
                'shop B''s coordinates are untouched');

-- ============================================================ series address patch clears the series coordinates
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('ser', (public.create_job_series(tests.fx('shop_a'), jsonb_build_object(
  'customer_id', tests.fx('cust_a3'), 'freq', 'week', 'local_start', '09:00', 'location_type', 'mobile',
  'service_address_line1', '9 Oak St', 'service_city', 'Birmingham', 'service_lat', 33.5, 'service_lng', -86.8,
  'start_date', to_char((now() at time zone 'America/Chicago')::date + 7, 'YYYY-MM-DD'),
  'template_lines', jsonb_build_array(jsonb_build_object('service_id', tests.fx('svc_a'))))) ->> 'series_id')::uuid);
select tests.as_superuser();
select tests.ok((select bool_and(service_lat = 33.5) from public.jobs where series_id = tests.fx('ser')),
                'occurrences copy the series coordinates');
select tests.authenticate_as(tests.fx('u_manager_a'));
select public.update_job_series(tests.fx('ser'), '{"notes": "gate code"}');
select tests.as_superuser();
select tests.ok((select service_lat = 33.5 from public.job_series where id = tests.fx('ser')),
                'a patch without address changes keeps the series coordinates');
select tests.authenticate_as(tests.fx('u_manager_a'));
select public.update_job_series(tests.fx('ser'), '{"service_address_line1": "1 Main St", "service_city": "Huntsville"}');
select tests.as_superuser();
select tests.ok((select service_lat is null and service_lng is null from public.job_series where id = tests.fx('ser')),
                'an address patch without coordinates clears the series coordinates');
select tests.ok((select bool_and(service_lat is null and service_address_line1 = '1 Main St')
                   from public.jobs where series_id = tests.fx('ser')),
                'regenerated occurrences have the new address and no stale coordinates');
select tests.authenticate_as(tests.fx('u_manager_a'));
select public.update_job_series(tests.fx('ser'), '{"service_address_line1": "2 Main St", "service_lat": 34.7, "service_lng": -86.6}');
select tests.as_superuser();
select tests.ok((select service_lat = 34.7 from public.job_series where id = tests.fx('ser')),
                'an address patch that sends coordinates keeps them');
select tests.ok((select bool_and(service_lat = 34.7) from public.jobs where series_id = tests.fx('ser')),
                '... and the occurrences get them');
select tests.authenticate_as(tests.fx('u_manager_a'));
select public.update_job_series(tests.fx('ser'), '{"location_type": "shop"}');
select tests.as_superuser();
select tests.ok((select service_lat is null from public.job_series where id = tests.fx('ser')),
                'a location type patch clears them too');

-- ============================================================ route position follows the local day
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end) values
  (tests.fx('shop_a'), tests.fx('cust_a3'), '2025-06-02 14:00Z', '2025-06-02 15:00Z') returning tests.fx_set('m1', id);
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end) values
  (tests.fx('shop_a'), tests.fx('cust_a3'), '2025-06-02 16:00Z', '2025-06-02 17:00Z') returning tests.fx_set('m2', id);
-- 22:30 local on Monday is Tuesday 03:30Z
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end) values
  (tests.fx('shop_a'), tests.fx('cust_a3'), '2025-06-03 03:30Z', '2025-06-03 04:00Z') returning tests.fx_set('m3', id);
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end) values
  (tests.fx('shop_a'), tests.fx('cust_a3'), '2025-06-03 14:00Z', '2025-06-03 15:00Z') returning tests.fx_set('t1', id);
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end) values
  (tests.fx('shop_a'), tests.fx('cust_a3'), '2025-06-03 16:00Z', '2025-06-03 17:00Z') returning tests.fx_set('t2', id);
select tests.authenticate_as(tests.fx('u_manager_a'));
select public.set_route_order(tests.fx('shop_a'), array[tests.fx('m1'), tests.fx('m2'), tests.fx('m3')]);
select public.set_route_order(tests.fx('shop_a'), array[tests.fx('t1'), tests.fx('t2')]);
update public.jobs set scheduled_start = '2025-06-03 22:00Z', scheduled_end = '2025-06-03 23:00Z' where id = tests.fx('m1');
select tests.eq((select route_position from public.jobs where id = tests.fx('m1')), null::integer,
                'a job moved to another local day loses its stop number');
select tests.eq((select array_agg(id order by route_position nulls last, scheduled_start) from public.jobs
                  where (scheduled_start at time zone 'America/Chicago')::date = '2025-06-03' and shop_id = tests.fx('shop_a')),
                array[tests.fx('t1'), tests.fx('t2'), tests.fx('m1')],
                'a job moved to another day does not take over that day''s first stop');
update public.jobs set scheduled_start = '2025-06-02 18:00Z', scheduled_end = '2025-06-02 19:00Z' where id = tests.fx('m2');
select tests.eq((select route_position from public.jobs where id = tests.fx('m2')), 1,
                'a same-day time change keeps the stop number');
-- Monday 22:30 local -> Monday 08:00 local: the UTC date changes, the local day does not
update public.jobs set scheduled_start = '2025-06-02 13:00Z', scheduled_end = '2025-06-02 13:30Z' where id = tests.fx('m3');
select tests.eq((select route_position from public.jobs where id = tests.fx('m3')), 2,
                'the local day decides (a move across the UTC date line on the same local day keeps it)');
update public.jobs set scheduled_start = '2025-06-02 20:00Z', scheduled_end = '2025-06-02 21:00Z', route_position = 0
 where id = tests.fx('t2');
select tests.eq((select route_position from public.jobs where id = tests.fx('t2')), 0,
                'a write that moves the job and sets its position keeps the one it sets');
select tests.as_service();
update public.jobs set scheduled_start = null, scheduled_end = null, status = 'requested' where id = tests.fx('m2');
select tests.as_superuser();
select tests.eq((select route_position from public.jobs where id = tests.fx('m2')), null::integer,
                'unscheduling a job clears its stop number (any writer)');
select tests.eq((select route_position from public.jobs where id = tests.fx('t1')), 0, 'other jobs keep theirs');
-- the trigger function is internal
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$select public.jobs_route_geo_reset()$$, '42501', 'the trigger function is not callable');
