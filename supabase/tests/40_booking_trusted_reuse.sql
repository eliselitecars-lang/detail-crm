-- 40 integration: what a TRUSTED booking (signed-in client linked to the
-- customer by a confirmed email) may take from and give to the records on file.
--   * Vehicle reuse by make/model: the reused vehicle's on-file category
--     decides price, duration and the slot check (like a saved-vehicle
--     booking); the form's category only fills a vehicle that has none.
--     Regression: the job sat on the on-file truck but was priced and
--     scheduled as the Car typed into the form (120 instead of 180 minutes,
--     so online booking could double-book the last hour).
--   * Customer address: the mobile service address becomes the customer's
--     address only when they have none on file at all. Regression: a
--     customer with a partial address (city / region / ZIP / gate code, no
--     street line) had all of it replaced, region and line 2 set to NULL.
-- API callers book on the server clock, so slots are taken three days out.
\ir fixtures/two_shops.psql
\ir fixtures/40_booking_setup.psql

update public.booking_settings set max_concurrent_jobs = 100 where shop_id = tests.fx('shop_a');
select tests.fx_set('u_alice', tests.create_user('alice@example.com'));
select tests.fx_set('u_dana', tests.create_user('dana@example.com'));
select tests.fx_set('u_nora', tests.create_user('nora@example.com'));

-- Alice's Civic is on file as a Large SUV / Truck (Full Detail: 25000, 180 min)
update public.vehicles set category_id = tests.fx('cat_truck_a') where id = tests.fx('veh_a');

create temp table slot as
  select to_char(min(s.starts_at) at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') as first_car,
         to_char(max(s.starts_at) at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') as last_car
  from public.get_available_slots('shop-a', array[tests.fx('svc_a')], (now() at time zone 'America/Chicago')::date + 3,
         (now() at time zone 'America/Chicago')::date + 3, tests.fx('cat_car_a')) s;
create temp table slot_b as
  select to_char(min(s.starts_at) at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') as first_b
  from public.get_available_slots('shop-b', array[tests.fx('svc_b')], (now() at time zone 'America/Chicago')::date + 3,
         (now() at time zone 'America/Chicago')::date + 3, tests.fx('cat_car_b')) s;
grant select on slot, slot_b to anon, authenticated;

-- Alice's contact + a Honda Civic typed into the form with the given category
create function pg_temp.civic(p_cat uuid, p_starts text, p_extra jsonb default '{}') returns jsonb language sql as $$
  select pg_temp.booking(jsonb_build_object(
    'starts_at', p_starts,
    'customer', jsonb_build_object('first_name', 'Alice', 'email', 'alice@example.com'),
    'vehicle', jsonb_build_object('make', 'Honda', 'model', 'Civic', 'category_id', p_cat)) || p_extra)
$$;
create function pg_temp.job(p_result jsonb) returns public.jobs language sql as $$
  select * from public.jobs where public_token = (p_result ->> 'job_token')::uuid
$$;
grant execute on function pg_temp.civic(uuid, text, jsonb) to anon, authenticated;

-- sanity: the last Car start of the day is too late for the truck's 180 minutes
select tests.ok((select not exists (
                   select 1 from public.get_available_slots('shop-a', array[tests.fx('svc_a')], (now() at time zone 'America/Chicago')::date + 3,
                          (now() at time zone 'America/Chicago')::date + 3, tests.fx('cat_truck_a')) s
                    where s.starts_at = last_car::timestamptz) from slot),
                'setup: the last Car slot is not offered for a truck');

-- ============================================================ vehicle category
-- form says Car, the reused Civic is on file as a truck: truck price and duration
select tests.authenticate_as(tests.fx('u_alice'));
create temp table r1 as
  select public.create_online_booking('shop-a', pg_temp.civic(tests.fx('cat_car_a'), (select first_car from slot))) as r;
select tests.as_superuser();
select tests.eq((select (pg_temp.job(r)).vehicle_id from r1), tests.fx('veh_a'),
                'the verified client''s booking reuses her on-file Civic');
select tests.eq((select (pg_temp.job(r)).scheduled_end - (pg_temp.job(r)).scheduled_start from r1), interval '180 minutes',
                'the reused truck is scheduled for the truck duration (as a vehicle.id booking would be)');
select tests.eq((select (pg_temp.job(r)).subtotal_cents from r1), 25000::bigint, 'and priced at the truck price');
select tests.eq((select jsonb_agg(jsonb_build_object('price', li.unit_price_cents, 'minutes', li.duration_minutes))
                   from public.job_line_items li where li.job_id = (select (pg_temp.job(r)).id from r1)),
                '[{"price": 25000, "minutes": 180}]'::jsonb, 'the line carries the truck price and duration');
select tests.eq((select category_id from public.vehicles where id = tests.fx('veh_a')), tests.fx('cat_truck_a'),
                'the on-file category is kept');

-- the slot is re-checked for the truck: the last Car start does not fit 180 minutes
select tests.authenticate_as(tests.fx('u_alice'));
select tests.throws_like($$select public.create_online_booking('shop-a',
                             pg_temp.civic(tests.fx('cat_car_a'), (select last_car from slot)))$$,
                         '23P01', '%no longer available%',
                         'a Car slot the reused truck does not fit into is refused (no half-booked truck job)');
-- a service the on-file category has no price for is refused, whatever the form says
select tests.throws_like($$select public.create_online_booking('shop-a',
                             pg_temp.civic(tests.fx('cat_van_a'), (select first_car from slot),
                                           jsonb_build_object('service_ids', jsonb_build_array(tests.fx('svc_van')))))$$,
                         '22023', '%not offered for this vehicle type%',
                         'Van-only pricing typed into the form does not apply to the on-file truck');
select tests.as_superuser();
select tests.eq((select count(*) from public.jobs where customer_id = tests.fx('cust_a') and source = 'online_booking'),
                1::bigint, 'refused bookings leave nothing behind');

-- the other way round: on file as a Car, the form says truck -> Car price and duration
update public.vehicles set category_id = tests.fx('cat_car_a') where id = tests.fx('veh_a');
select tests.authenticate_as(tests.fx('u_alice'));
create temp table r2 as
  select public.create_online_booking('shop-a', pg_temp.civic(tests.fx('cat_truck_a'), (select first_car from slot))) as r;
select tests.as_superuser();
select tests.ok((select (pg_temp.job(r)).vehicle_id = tests.fx('veh_a') and (pg_temp.job(r)).subtotal_cents = 20000
                        and (pg_temp.job(r)).scheduled_end - (pg_temp.job(r)).scheduled_start = interval '120 minutes'
                   from r2),
                'an on-file Car is never charged the truck price the form asked for');

-- an on-file vehicle without a category takes the form's (and is priced with it)
update public.vehicles set category_id = null where id = tests.fx('veh_a');
select tests.authenticate_as(tests.fx('u_alice'));
create temp table r3 as
  select public.create_online_booking('shop-a', pg_temp.civic(tests.fx('cat_truck_a'), (select first_car from slot))) as r;
select tests.as_superuser();
select tests.ok((select (pg_temp.job(r)).vehicle_id = tests.fx('veh_a') and (pg_temp.job(r)).subtotal_cents = 25000
                        and (pg_temp.job(r)).scheduled_end - (pg_temp.job(r)).scheduled_start = interval '180 minutes'
                   from r3),
                'a vehicle with no category on file is priced and scheduled with the form''s category');
select tests.eq((select category_id from public.vehicles where id = tests.fx('veh_a')), tests.fx('cat_truck_a'),
                'and the form''s category fills the gap');

-- untrusted (anonymous) booking for Alice's email: no reuse, so the form's category applies
update public.vehicles set category_id = tests.fx('cat_truck_a') where id = tests.fx('veh_a');
select tests.as_anon();
create temp table r4 as
  select public.create_online_booking('shop-a', pg_temp.civic(tests.fx('cat_car_a'), (select first_car from slot))) as r;
select tests.as_superuser();
select tests.ok((select (pg_temp.job(r)).vehicle_id <> tests.fx('veh_a') and (pg_temp.job(r)).subtotal_cents = 20000
                        and (pg_temp.job(r)).customer_id = tests.fx('cust_a') from r4),
                'an anonymous booking gets a new vehicle priced from the form (the on-file category is neither used nor revealed)');

-- cross-shop: Alice booking at shop B never reuses shop A's Civic
select tests.authenticate_as(tests.fx('u_alice'));
create temp table r5 as
  select public.create_online_booking('shop-b', pg_temp.civic(tests.fx('cat_car_b'), (select first_b from slot_b),
                                        jsonb_build_object('service_ids', jsonb_build_array(tests.fx('svc_b'))))) as r;
select tests.as_superuser();
select tests.ok((select j.shop_id = tests.fx('shop_b') and j.vehicle_id <> tests.fx('veh_a') and j.subtotal_cents = 5000
                        and v.shop_id = tests.fx('shop_b') and v.category_id = tests.fx('cat_car_b')
                   from public.jobs j join public.vehicles v on v.id = j.vehicle_id
                  where j.public_token = (select (r ->> 'job_token')::uuid from r5)),
                'at another shop the booking gets that shop''s own vehicle, category and price');
select tests.eq((select category_id from public.vehicles where id = tests.fx('veh_a')), tests.fx('cat_truck_a'),
                'shop A''s Civic is untouched');

-- ============================================================ customer address
-- a partial address on file (no street line) is never overwritten or mixed
update public.customers set city = 'Birmingham', region = 'AL', postal_code = '35203', address_line2 = 'Gate code 4411'
 where id = tests.fx('cust_a');
select tests.authenticate_as(tests.fx('u_alice'));
create temp table r6 as
  select public.create_online_booking('shop-a', pg_temp.booking(jsonb_build_object(
    'starts_at', (select first_car from slot),
    'customer', jsonb_build_object('first_name', 'Alice', 'email', 'alice@example.com'),
    'location', jsonb_build_object('type', 'mobile', 'address_line1', '9 Office Park', 'city', 'Hoover',
                                   'postal_code', '35244')))) as r;
select tests.as_superuser();
select tests.ok((select address_line1 is null and city = 'Birmingham' and region = 'AL' and postal_code = '35203'
                        and address_line2 = 'Gate code 4411'
                   from public.customers where id = tests.fx('cust_a')),
                'a booking only fills missing customer fields; it never overwrites the city / region / ZIP / line 2 on file');
select tests.ok((select (pg_temp.job(r)).service_address_line1 = '9 Office Park' and (pg_temp.job(r)).service_city = 'Hoover'
                        and (pg_temp.job(r)).service_postal_code = '35244' from r6),
                'the job keeps the booking''s own service address');

-- a linked customer with no address at all gets the whole service address
insert into public.customers (shop_id, first_name, email) values (tests.fx('shop_a'), 'Dana', 'dana@example.com')
  returning tests.fx_set('cust_dana', id);
insert into public.customers (shop_id, first_name, email, lat, lng)
  values (tests.fx('shop_a'), 'Gina', 'gina@example.com', 33.5, -86.8) returning tests.fx_set('cust_gina', id);
select tests.fx_set('u_gina', tests.create_user('gina@example.com'));
create function pg_temp.mobile(p_first text, p_email text) returns jsonb language sql as $$
  select pg_temp.booking(jsonb_build_object(
    'starts_at', (select first_car from slot),
    'customer', jsonb_build_object('first_name', p_first, 'email', p_email),
    'location', jsonb_build_object('type', 'mobile', 'address_line1', '9 Office Park', 'address_line2', 'Suite 4',
                                   'city', 'Hoover', 'region', 'AL', 'postal_code', '35244')))
$$;
grant execute on function pg_temp.mobile(text, text) to anon, authenticated;
select tests.authenticate_as(tests.fx('u_dana'));
select tests.lives($$select public.create_online_booking('shop-a', pg_temp.mobile('Dana', 'dana@example.com'))$$,
                   'Dana (confirmed email, no address on file) books a mobile job');
select tests.as_superuser();
select tests.ok((select address_line1 = '9 Office Park' and address_line2 = 'Suite 4' and city = 'Hoover' and region = 'AL'
                        and postal_code = '35244' and portal_user_id = tests.fx('u_dana')
                   from public.customers where id = tests.fx('cust_dana')),
                'an empty address is filled with the whole service address');

-- a customer created by the booking gets it too
select tests.authenticate_as(tests.fx('u_nora'));
select tests.lives($$select public.create_online_booking('shop-a', pg_temp.mobile('Nora', 'nora@example.com'))$$,
                   'a new client books a mobile job');
select tests.as_superuser();
select tests.ok((select address_line1 = '9 Office Park' and city = 'Hoover' and postal_code = '35244'
                   from public.customers where shop_id = tests.fx('shop_a') and email = 'nora@example.com'),
                'the new customer''s address is the service address');

-- coordinates on file count as an address: they are not left pointing elsewhere
select tests.authenticate_as(tests.fx('u_gina'));
select tests.lives($$select public.create_online_booking('shop-a', pg_temp.mobile('Gina', 'gina@example.com'))$$,
                   'Gina (coordinates on file, no address fields) books a mobile job');
select tests.as_superuser();
select tests.ok((select address_line1 is null and city is null and lat = 33.5 and lng = -86.8
                   from public.customers where id = tests.fx('cust_gina')),
                'no address is written next to coordinates of another place');

-- denial: an anonymous booking never fills an address, even an empty one
update public.customers set address_line1 = null, address_line2 = null, city = null, region = null, postal_code = null,
                            portal_user_id = null
 where id = tests.fx('cust_dana');
select tests.as_anon();
select tests.lives($$select public.create_online_booking('shop-a', pg_temp.mobile('Dana', 'dana@example.com'))$$,
                   'anonymous mobile booking for Dana''s email');
select tests.as_superuser();
select tests.ok((select address_line1 is null and address_line2 is null and city is null and region is null
                        and postal_code is null
                   from public.customers where id = tests.fx('cust_dana')),
                'an unverified booking adds no address to an existing customer');
