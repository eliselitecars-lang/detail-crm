-- 50 sched: day route order + job coordinates (P-18, 0057) — managers order
-- any jobs of a day, technicians only their assigned ones; one local day per
-- route; coordinates validation; cross-shop isolation; column grant.
\ir fixtures/two_shops.psql

select tests.as_superuser();
create function pg_temp.addr(p_job uuid) returns jsonb language sql stable as $$
  select jsonb_build_object('service_address_line1', j.service_address_line1, 'service_address_line2', j.service_address_line2,
                            'service_city', j.service_city, 'service_region', j.service_region,
                            'service_postal_code', j.service_postal_code)
    from public.jobs j where j.id = p_job
$$;
grant execute on function pg_temp.addr(uuid) to authenticated, anon, service_role;
-- job_a (tech_a) 10:00 and job_a2 (tech2_a) 13:00 local on Mon 2025-06-02
insert into public.jobs (shop_id, customer_id, location_type, service_address_line1, service_city, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a3'), 'mobile', '9 Oak St', 'Birmingham', '2025-06-02 20:00Z', '2025-06-02 21:00Z')
  returning tests.fx_set('job_m', id);
insert into public.job_assignments (shop_id, job_id, member_id) values (tests.fx('shop_a'), tests.fx('job_m'), tests.fx('m_tech_a'));
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a3'), '2025-06-03 15:00Z', '2025-06-03 16:00Z') returning tests.fx_set('job_tue', id);
insert into public.job_assignments (shop_id, job_id, member_id) values (tests.fx('shop_a'), tests.fx('job_tue'), tests.fx('m_tech_a'));
-- 22:30 local on Monday is Tuesday 03:30Z: still Monday's route
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a3'), '2025-06-03 03:30Z', '2025-06-03 04:00Z') returning tests.fx_set('job_late', id);
insert into public.jobs (shop_id, customer_id, status) values (tests.fx('shop_a'), tests.fx('cust_a3'), 'requested')
  returning tests.fx_set('job_unsched', id);

-- ============================================================ set_route_order
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(public.set_route_order(tests.fx('shop_a'), array[tests.fx('job_m'), tests.fx('job_a2'), tests.fx('job_a'), tests.fx('job_late')]),
                4, 'manager orders four jobs of the day');
select tests.eq((select array_agg(id order by route_position) from public.jobs
                  where id in (tests.fx('job_m'), tests.fx('job_a2'), tests.fx('job_a'), tests.fx('job_late'))),
                array[tests.fx('job_m'), tests.fx('job_a2'), tests.fx('job_a'), tests.fx('job_late')],
                'positions follow the list (shop-local day: 22:30 counts as Monday)');
select tests.eq((select route_position from public.jobs where id = tests.fx('job_m')), 0, 'the first stop is 0');
select tests.throws_like($$select public.set_route_order(tests.fx('shop_a'), array[tests.fx('job_a'), tests.fx('job_tue')])$$,
                         '22023', '%same day%', 'a route covers one local day');
select tests.throws_like($$select public.set_route_order(tests.fx('shop_a'), array[tests.fx('job_a'), tests.fx('job_unsched')])$$,
                         '22023', '%same day%', 'unscheduled jobs have no route');
select tests.throws_like($$select public.set_route_order(tests.fx('shop_a'), array[tests.fx('job_a'), tests.fx('job_a')])$$,
                         '22023', '%once%', 'each job once');
select tests.throws($$select public.set_route_order(tests.fx('shop_a'), '{}')$$, '22023', 'at least one job');
select tests.throws($$select public.set_route_order(tests.fx('shop_a'), null)$$, '22023', 'null list');
select tests.throws($$select public.set_route_order(tests.fx('shop_a'), array(select gen_random_uuid() from generate_series(1, 51)))$$,
                    '22023', 'at most 50 jobs');
select tests.throws($$select public.set_route_order(tests.fx('shop_a'), array[tests.fx('job_a'), tests.fx('job_b')])$$, 'P0002',
                    'another shop''s job is not found');
select tests.throws($$select public.set_route_order(tests.fx('shop_a'), array[gen_random_uuid()])$$, 'P0002', 'unknown job');
select tests.lives($$update public.jobs set route_position = 5 where id = tests.fx('job_a')$$, 'managers may also write the column');
select tests.throws($$update public.jobs set route_position = 1000 where id = tests.fx('job_a')$$, '23514', 'position 0..999');

-- technicians: only their own jobs
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(public.set_route_order(tests.fx('shop_a'), array[tests.fx('job_a'), tests.fx('job_m')]), 2,
                'a technician orders their own assigned jobs');
select tests.eq((select array_agg(route_position order by route_position) from public.jobs
                  where id in (tests.fx('job_a'), tests.fx('job_m'))), array[0, 1], 'own route saved');
select tests.throws_like($$select public.set_route_order(tests.fx('shop_a'), array[tests.fx('job_a'), tests.fx('job_a2')])$$,
                         '42501', '%assigned%', 'not a job assigned to someone else');
select tests.throws($$update public.jobs set route_position = 3 where id = tests.fx('job_a')$$, '42501',
                    'technicians cannot write the column directly');
select tests.ok(has_column_privilege('authenticated', 'public.jobs', 'route_position', 'SELECT'), 'route_position granted');
select tests.eq((select route_position from public.jobs where id = tests.fx('job_a')), 0, 'technicians read it');

-- other shops, outsiders, anon
select tests.authenticate_as(tests.fx('u_owner_b'));
select tests.throws($$select public.set_route_order(tests.fx('shop_a'), array[tests.fx('job_a')])$$, '42501', 'owner of B denied in A');
select tests.eq(public.set_route_order(tests.fx('shop_b'), array[tests.fx('job_b')]), 1, 'owner of B orders B''s jobs');
select tests.authenticate_as(tests.fx('u_outsider'));
select tests.throws($$select public.set_route_order(tests.fx('shop_a'), array[tests.fx('job_a')])$$, '42501', 'outsider denied');
select tests.as_anon();
select tests.throws($$select public.set_route_order(tests.fx('shop_a'), array[tests.fx('job_a')])$$, '42501', 'anon denied');
select tests.throws($$select public.set_job_coordinates(tests.fx('job_m'), 33.5, -86.8, '{}')$$, '42501', 'anon cannot set coordinates');

-- ============================================================ set_job_coordinates
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.lives($$select public.set_job_coordinates(tests.fx('job_m'), 33.5207, -86.8025, pg_temp.addr(tests.fx('job_m')))$$, 'the assigned technician geocodes');
select tests.eq((select service_lat::text || ',' || service_lng::text from public.jobs where id = tests.fx('job_m')), '33.5207,-86.8025',
                'coordinates stored');
select tests.throws_like($$select public.set_job_coordinates(tests.fx('job_a2'), 33.5, -86.8, pg_temp.addr(tests.fx('job_a2')))$$, '42501', '%assigned%',
                         'not on someone else''s job');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws_like($$select public.set_job_coordinates(tests.fx('job_a'), 33.5, -86.8, pg_temp.addr(tests.fx('job_a')))$$, '22023', '%no service address%',
                         'a job without a service address');
select tests.throws($$select public.set_job_coordinates(tests.fx('job_m'), 91, 0, pg_temp.addr(tests.fx('job_m')))$$, '22023', 'latitude range');
select tests.throws($$select public.set_job_coordinates(tests.fx('job_m'), 0, -181, pg_temp.addr(tests.fx('job_m')))$$, '22023', 'longitude range');
select tests.throws($$select public.set_job_coordinates(tests.fx('job_m'), 'NaN', 0, pg_temp.addr(tests.fx('job_m')))$$, '22023', 'NaN rejected');
select tests.throws($$select public.set_job_coordinates(tests.fx('job_m'), 'Infinity', 0, pg_temp.addr(tests.fx('job_m')))$$, '22023', 'infinity rejected');
select tests.throws($$select public.set_job_coordinates(tests.fx('job_m'), null, 1, pg_temp.addr(tests.fx('job_m')))$$, '22023', 'both coordinates');
select tests.throws($$select public.set_job_coordinates(tests.fx('job_b'), 1, 1, pg_temp.addr(tests.fx('job_b')))$$, 'P0002', 'another shop''s job is not found');
select tests.throws($$select public.set_job_coordinates(gen_random_uuid(), 1, 1, pg_temp.addr(gen_random_uuid()))$$, 'P0002', 'unknown job');
select tests.lives($$select public.set_job_coordinates(tests.fx('job_m'), -33.9, 151.2, pg_temp.addr(tests.fx('job_m')))$$, 'managers may set any job''s coordinates');
select tests.eq((select service_lat from public.calendar_events(tests.fx('shop_a'), '2025-06-02', '2025-06-03') where id = tests.fx('job_m')),
                -33.9::double precision, 'the calendar returns them');

-- ============================================================ a point found for a previous address is refused
-- the phone loaded job_m at 9 Oak St (no coordinates yet)
select tests.as_superuser();
update public.jobs set service_lat = null, service_lng = null where id = tests.fx('job_m');
create temp table phone_copy as select pg_temp.addr(tests.fx('job_m')) as a;
grant select on phone_copy to authenticated;
-- the manager corrects the address meanwhile
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.jobs set service_address_line1 = '1200 Pine Ave', service_city = 'Hoover' where id = tests.fx('job_m');
-- the phone stores the point it geocoded for 9 Oak St
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws_like($$select public.set_job_coordinates(tests.fx('job_m'), 33.5186, -86.8104, (select a from phone_copy))$$,
                         '40001', '%address changed%', 'a point geocoded for the previous address is refused');
select tests.as_superuser();
select tests.ok((select service_lat is null and service_lng is null from public.jobs where id = tests.fx('job_m')),
                'coordinates geocoded for the previous address are not stored on the new address');
-- after reloading the job, the point for the current address is stored
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.lives($$select public.set_job_coordinates(tests.fx('job_m'), 33.4057, -86.8114, pg_temp.addr(tests.fx('job_m')))$$,
                   'the point for the current address is stored');
select tests.eq((select service_lat from public.jobs where id = tests.fx('job_m')), 33.4057::double precision, 'stored');
-- missing keys mean no value (clients may omit nulls)
select tests.lives($$select public.set_job_coordinates(tests.fx('job_m'), 33.4, -86.8,
                       '{"service_address_line1": "1200 Pine Ave", "service_city": "Hoover"}')$$,
                   'keys left out count as null');
select tests.throws_like($$select public.set_job_coordinates(tests.fx('job_m'), 33.4, -86.8,
                            '{"service_address_line1": "1200 Pine Ave"}')$$,
                         '40001', '%address changed%', 'a partial address that differs is refused');
select tests.throws_like($$select public.set_job_coordinates(tests.fx('job_m'), 33.4, -86.8,
                            '{"service_address_line1": "1200 Pine Ave", "service_city": "Hoover", "zip": "35244"}')$$,
                         '22023', '%unknown field zip%', 'unknown address fields are rejected');
select tests.throws_like($$select public.set_job_coordinates(tests.fx('job_m'), 33.4, -86.8,
                            '{"service_address_line1": 12, "service_city": "Hoover"}')$$,
                         '22023', '%service_address_line1%', 'address values must be text');
select tests.throws_like($$select public.set_job_coordinates(tests.fx('job_m'), 33.4, -86.8, '["1200 Pine Ave"]')$$,
                         '22023', '%p_address%', 'the address must be an object');
select tests.throws_like($$select public.set_job_coordinates(tests.fx('job_m'), 33.4, -86.8, null)$$,
                         '22023', '%p_address%', 'the address is required');
select tests.as_superuser();
select tests.eq((select service_lat from public.jobs where id = tests.fx('job_m')), 33.4::double precision,
                'the refused writes changed nothing');
-- the other shop: its own job, its own check; A's staff cannot reach it
select tests.authenticate_as(tests.fx('u_owner_b'));
select tests.throws($$select public.set_job_coordinates(tests.fx('job_m'), 1, 1, '{}')$$, 'P0002',
                    'shop B cannot locate A''s job, whatever address it sends');
select tests.as_service();
select tests.throws($$select public.set_job_coordinates(tests.fx('job_m'), 1, 1, '{}')$$, 'P0002',
                    'the service role is not a shop member (the phone stores points through the user''s session)');
