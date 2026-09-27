-- 90 integration: the vehicle category is optional end to end. A shop with
-- no vehicle categories at all (base prices only) gets slots, coupon
-- previews, staff pricing and online bookings without passing one; the
-- category argument of get_available_slots / public_validate_coupon /
-- price_services defaults to null (PostgREST callers use named arguments).
\ir fixtures/two_shops.psql
\ir fixtures/40_booking_setup.psql

-- shop B removes every vehicle category (its vehicles keep no category)
select tests.as_superuser();
delete from public.vehicle_categories where shop_id = tests.fx('shop_b');
select tests.eq((select count(*) from public.vehicle_categories where shop_id = tests.fx('shop_b')), 0::bigint, 'shop B has no categories');
select tests.eq((select category_id from public.vehicles where id = tests.fx('veh_b')), null::uuid, 'its vehicle has none either');

-- ------------------------------------------------------------ catalog + slots (anon)
select tests.as_anon();
select tests.eq(public.public_booking_catalog('shop-b') -> 'vehicle_categories', '[]'::jsonb, 'the catalog lists no categories');
select tests.ok(exists (select 1 from public.get_available_slots('shop-b', array[tests.fx('svc_b')],
                                                                 (now() at time zone 'America/Chicago')::date + 3,
                                                                 (now() at time zone 'America/Chicago')::date + 3)),
                'slots without a category argument');
select tests.ok(exists (select 1 from public.get_available_slots(p_shop_slug => 'shop-b', p_service_ids => array[tests.fx('svc_b')],
                                                                 p_from => (now() at time zone 'America/Chicago')::date + 3,
                                                                 p_to => (now() at time zone 'America/Chicago')::date + 3)),
                'named arguments (as PostgREST sends them)');
select tests.ok(exists (select 1 from public.get_available_slots('shop-b', array[tests.fx('svc_b')],
                                                                 (now() at time zone 'America/Chicago')::date + 3,
                                                                 (now() at time zone 'America/Chicago')::date + 3, null)),
                'an explicit null category too');
select tests.throws_like($$select * from public.get_available_slots('shop-b', array[tests.fx('svc_b')], current_date + 3, current_date + 3,
                                                                    tests.fx('cat_car_a'))$$, '22023', '%vehicle category%',
                         'another shop''s category is still refused');

-- ------------------------------------------------------------ coupon preview (anon)
select tests.eq((select jsonb_build_array(r -> 'valid', r -> 'subtotal_cents', r -> 'discount_cents')
                   from (select public.public_validate_coupon('shop-b', 'SAVE10', array[tests.fx('svc_b')]) r) x),
                '[true, 5000, 500]'::jsonb, 'coupon preview without a category (base price)');
select tests.eq(public.public_validate_coupon(p_slug => 'shop-b', p_code => 'SAVE10', p_service_ids => array[tests.fx('svc_b')]) -> 'valid',
                'true'::jsonb, 'named arguments');

-- ------------------------------------------------------------ online booking without a category (service_role, fixed clock)
select tests.as_service();
create temp table nb as
  select public.create_online_booking('shop-b', jsonb_build_object(
           'customer', jsonb_build_object('first_name', 'Nia', 'last_name', 'Nocat', 'email', 'nia@example.com',
                                          'phone', '(205) 555-0177'),
           'vehicle', jsonb_build_object('year', 2019, 'make', 'Subaru', 'model', 'Outback'),
           'service_ids', jsonb_build_array(tests.fx('svc_b')),
           'addon_ids', jsonb_build_array(),
           'starts_at', '2025-06-09T15:00:00Z',
           'location', jsonb_build_object('type', 'shop')), '2025-06-01 12:00Z') as r;
select tests.as_superuser();
select tests.ok((select (r ->> 'job_token') is not null from nb), 'the booking is created');
select tests.eq((select concat_ws('/', j.total_cents, v.category_id is null, v.make)
                   from public.jobs j join public.vehicles v on v.id = j.vehicle_id
                  where j.public_token = (select (r ->> 'job_token')::uuid from nb)),
                '5000/t/Subaru', 'priced from the base price; the vehicle has no category');

-- ------------------------------------------------------------ staff pricing without a category
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq((select (p -> 'totals' ->> 'subtotal_cents')::bigint
                   from (select public.price_services(tests.fx('shop_b'), tests.fx('cust_b'), array[tests.fx('svc_b')]) p) x),
                5000::bigint, 'price_services without a category');
select tests.eq((select (p ->> 'priced')::boolean
                   from (select public.price_services(p_shop => tests.fx('shop_b'), p_customer_id => null,
                                                      p_service_ids => array[tests.fx('svc_b')], p_vehicle_id => tests.fx('veh_b')) p) x),
                true, 'named arguments, with a vehicle that has no category');
select tests.throws_like($$select public.price_services(tests.fx('shop_b'), null, array[tests.fx('svc_b')], tests.fx('cat_car_a'))$$,
                         '22023', '%unknown vehicle category%', 'another shop''s category is refused');

-- ------------------------------------------------------------ signatures
select tests.as_superuser();
select tests.ok(to_regprocedure('public.get_available_slots(text, uuid[], date, date, uuid, timestamptz)') is not null,
                'get_available_slots(slug, services, from, to, category = null, now = now())');
select tests.ok(to_regprocedure('public.price_services(uuid, uuid, uuid[], uuid, uuid)') is not null,
                'price_services(shop, customer, services, category = null, vehicle = null)');
select tests.eq((select pronargdefaults from pg_proc where oid = 'public.public_validate_coupon(text, text, uuid[], uuid, timestamptz)'::regprocedure),
                2::smallint, 'public_validate_coupon: category and now default');
select tests.ok(has_function_privilege('anon', 'public.get_available_slots(text, uuid[], date, date, uuid, timestamptz)', 'execute')
                and has_function_privilege('anon', 'public.public_validate_coupon(text, text, uuid[], uuid, timestamptz)', 'execute')
                and not has_function_privilege('anon', 'public.price_services(uuid, uuid, uuid[], uuid, uuid)', 'execute'),
                'grants follow the new signatures');
