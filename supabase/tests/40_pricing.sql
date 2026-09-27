-- 40 integration: price_services (staff) / price_services_core (internal) —
-- catalog prices by vehicle category, missing prices, memberships (included
-- services at 0 with a note, plan discount suggested as a percent discount,
-- vehicle-scoped plans), role rules and cross-shop isolation.
\ir fixtures/two_shops.psql
\ir fixtures/40_booking_setup.psql

create function pg_temp.line(p jsonb, p_service uuid) returns jsonb language sql as $$
  select e from jsonb_array_elements(p -> 'lines') e where (e ->> 'service_id')::uuid = p_service
$$;
grant execute on function pg_temp.line(jsonb, uuid) to authenticated, service_role;

-- membership plans: Gold includes the wash + 15% off; Truck plan (vehicle-scoped) includes Full Detail
insert into public.membership_plans (shop_id, name, price_cents, included_service_ids, discount_bps)
  values (tests.fx('shop_a'), 'Gold', 9900, array[tests.fx('svc_wash')], 1500) returning tests.fx_set('plan_gold', id);
insert into public.membership_plans (shop_id, name, price_cents, included_service_ids, discount_bps)
  values (tests.fx('shop_a'), 'Truck Care', 4900, array[tests.fx('svc_a')], 500) returning tests.fx_set('plan_truck', id);
insert into public.vehicles (shop_id, customer_id, year, make, model, category_id)
  values (tests.fx('shop_a'), tests.fx('cust_a'), 2022, 'Ford', 'F-150', tests.fx('cat_truck_a')) returning tests.fx_set('veh_truck', id);

-- ------------------------------------------------------------ plain catalog pricing (manager)
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('dummy', gen_random_uuid());
create temp table r as
  select public.price_services(tests.fx('shop_a'), null, tests.fx('cat_car_a'),
                               array[tests.fx('svc_a'), tests.fx('addon_pet'), tests.fx('svc_a')]) as p;
select tests.eq(jsonb_array_length((select p from r) -> 'lines'), 2, 'duplicate ids are priced once');
select tests.eq((select p -> 'lines' -> 0 ->> 'service_id' from r)::uuid, tests.fx('svc_a'), 'input order is kept');
select tests.eq((select (pg_temp.line(p, tests.fx('svc_a')) ->> 'unit_price_cents')::bigint from r), 20000::bigint,
                'no category price: the base price applies');
select tests.eq((select (pg_temp.line(p, tests.fx('svc_a')) ->> 'duration_minutes')::int from r), 120, 'service duration');
select tests.eq((select (pg_temp.line(p, tests.fx('addon_pet')) ->> 'taxable')::boolean from r), false, 'taxable flag from the catalog');
select tests.eq((select p -> 'totals' from r),
                '{"subtotal_cents": 24000, "discount_cents": 0, "tax_cents": 2000, "total_cents": 26000}'::jsonb,
                'totals: tax only on the taxable line (10% of 20000)');
select tests.eq((select (p ->> 'duration_minutes')::int from r), 150, 'total duration');
select tests.eq((select p ->> 'suggested_discount_kind' from r), 'none', 'no customer: no membership discount');
select tests.eq((select p -> 'memberships' from r), '[]'::jsonb, 'no memberships');
drop table r;

select tests.eq((pg_temp.line(public.price_services(tests.fx('shop_a'), null, tests.fx('cat_truck_a'), array[tests.fx('svc_a')]),
                              tests.fx('svc_a')) ->> 'unit_price_cents')::bigint, 25000::bigint, 'category price wins');
select tests.eq((pg_temp.line(public.price_services(tests.fx('shop_a'), null, tests.fx('cat_truck_a'), array[tests.fx('svc_a')]),
                              tests.fx('svc_a')) ->> 'duration_minutes')::int, 180, 'category duration override');
select tests.eq((public.price_services(tests.fx('shop_a'), null, tests.fx('cat_car_a'), array[tests.fx('svc_van')]) ->> 'priced')::boolean,
                false, 'no price for this category: not priced');
select tests.ok((public.price_services(tests.fx('shop_a'), null, tests.fx('cat_car_a'), array[tests.fx('svc_van')]) -> 'totals')
                = 'null'::jsonb, 'unpriced: no totals');
select tests.eq((pg_temp.line(public.price_services(tests.fx('shop_a'), null, tests.fx('cat_van_a'), array[tests.fx('svc_van')]),
                              tests.fx('svc_van')) ->> 'unit_price_cents')::bigint, 9000::bigint, 'category-only price');
select tests.eq((pg_temp.line(public.price_services(tests.fx('shop_a'), null, null, array[tests.fx('svc_hidden')]),
                              tests.fx('svc_hidden')) ->> 'unit_price_cents')::bigint, 1000::bigint,
                'staff may price services that are not bookable online');
select tests.throws_like($$select public.price_services(tests.fx('shop_a'), null, null, array[tests.fx('svc_inactive')])$$,
                         '22023', '%not available%', 'inactive services cannot be priced');
select tests.throws_like($$select public.price_services(tests.fx('shop_a'), null, null, '{}')$$, '22023', '%at least one%', 'no services');
select tests.throws($$select public.price_services(tests.fx('shop_a'), null, null, null)$$, '22023', 'null services');

-- vehicle supplies the customer and category
select tests.eq((pg_temp.line(public.price_services(tests.fx('shop_a'), null, null, array[tests.fx('svc_a')], tests.fx('veh_truck')),
                              tests.fx('svc_a')) ->> 'catalog_price_cents')::bigint, 25000::bigint, 'the vehicle''s category is used');
select tests.throws_like($$select public.price_services(tests.fx('shop_a'), tests.fx('cust_a2'), null, array[tests.fx('svc_a')], tests.fx('veh_a'))$$,
                         '22023', '%does not belong%', 'vehicle of another customer');

-- ------------------------------------------------------------ memberships
select tests.as_superuser();
insert into public.memberships (shop_id, plan_id, customer_id, status) values
  (tests.fx('shop_a'), tests.fx('plan_gold'), tests.fx('cust_a'), 'active') returning tests.fx_set('mem_gold', id);
insert into public.memberships (shop_id, plan_id, customer_id, vehicle_id, status) values
  (tests.fx('shop_a'), tests.fx('plan_truck'), tests.fx('cust_a'), tests.fx('veh_truck'), 'active');

select tests.authenticate_as(tests.fx('u_manager_a'));
create temp table r as
  select public.price_services(tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('cat_car_a'),
                               array[tests.fx('svc_a'), tests.fx('svc_wash')], tests.fx('veh_a')) as p;
select tests.eq((select pg_temp.line(p, tests.fx('svc_wash')) from r),
                jsonb_build_object('service_id', tests.fx('svc_wash'), 'name', 'Exterior Wash', 'kind', 'service', 'taxable', true,
                                   'duration_minutes', 60, 'catalog_price_cents', 5000, 'unit_price_cents', 0,
                                   'membership_included', true, 'note', 'Included with your Gold membership'),
                'an included service is priced 0 with a note');
select tests.eq((select (pg_temp.line(p, tests.fx('svc_a')) ->> 'unit_price_cents')::bigint from r), 20000::bigint,
                'the vehicle-scoped plan does not apply to another vehicle');
select tests.eq((select p ->> 'suggested_discount_kind' from r), 'percent', 'plan discount suggested as a percent');
select tests.eq((select (p ->> 'suggested_discount_value')::int from r), 1500, 'Gold discount 15%');
select tests.eq((select p -> 'totals' from r),
                '{"subtotal_cents": 20000, "discount_cents": 3000, "tax_cents": 1700, "total_cents": 18700}'::jsonb,
                'totals include the suggested discount');
select tests.eq((select jsonb_array_length(p -> 'memberships') from r), 1, 'only the shop-wide membership applies');
drop table r;

create temp table r as
  select public.price_services(tests.fx('shop_a'), tests.fx('cust_a'), null, array[tests.fx('svc_a'), tests.fx('svc_wash')],
                               tests.fx('veh_truck')) as p;
select tests.eq((select (pg_temp.line(p, tests.fx('svc_a')) ->> 'unit_price_cents')::bigint from r), 0::bigint,
                'vehicle-scoped plan includes Full Detail for its vehicle');
select tests.eq((select pg_temp.line(p, tests.fx('svc_a')) ->> 'note' from r), 'Included with your Truck Care membership', 'note names the plan');
select tests.eq((select (p ->> 'suggested_discount_value')::int from r), 1500, 'the largest plan discount is suggested');
select tests.eq((select jsonb_array_length(p -> 'memberships') from r), 2, 'both memberships apply');
drop table r;

-- inactive memberships do not apply
select tests.as_superuser();
update public.memberships set status = 'past_due' where id = tests.fx('mem_gold');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq((pg_temp.line(public.price_services(tests.fx('shop_a'), tests.fx('cust_a'), null, array[tests.fx('svc_wash')]),
                              tests.fx('svc_wash')) ->> 'unit_price_cents')::bigint, 5000::bigint, 'past_due memberships do not apply');
select tests.as_superuser();
update public.memberships set status = 'cancelled' where id = tests.fx('mem_gold');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.eq((public.price_services(tests.fx('shop_a'), tests.fx('cust_a'), null, array[tests.fx('svc_wash')]) ->> 'suggested_discount_kind'),
                'none', 'cancelled memberships do not apply (owner may price too)');

-- the internal variant can skip memberships
select tests.as_superuser();
select tests.eq((pg_temp.line(public.price_services_core(tests.fx('shop_a'), tests.fx('cust_a'), null, array[tests.fx('svc_a')],
                                                         tests.fx('veh_truck'), false), tests.fx('svc_a')) ->> 'unit_price_cents')::bigint,
                20000::bigint, 'core without memberships: the catalog (base) price, not the included 0');

-- ------------------------------------------------------------ roles & isolation
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.lives($$select public.price_services(tests.fx('shop_a'), null, null, array[tests.fx('svc_a')])$$, 'admins may price');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws_like($$select public.price_services(tests.fx('shop_a'), null, null, array[tests.fx('svc_a')])$$, '42501',
                         '%owners, admins and managers%', 'technicians cannot price (memberships are manager+ data)');
select tests.authenticate_as(tests.fx('u_outsider'));
select tests.throws_like($$select public.price_services(tests.fx('shop_a'), null, null, array[tests.fx('svc_a')])$$, '42501',
                         '%not a member%', 'non-members cannot price');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.throws($$select public.price_services(tests.fx('shop_a'), null, null, array[tests.fx('svc_a')])$$, '42501',
                    'managers of another shop cannot price shop A');
select tests.throws_like($$select public.price_services(tests.fx('shop_b'), null, null, array[tests.fx('svc_a')])$$, '22023',
                         '%not available%', 'another shop''s service cannot be priced');
select tests.throws($$select public.price_services(tests.fx('shop_b'), tests.fx('cust_a'), null, array[tests.fx('svc_b')])$$, 'P0002',
                    'another shop''s customer is not found');
select tests.throws($$select public.price_services(tests.fx('shop_b'), null, null, array[tests.fx('svc_b')], tests.fx('veh_a'))$$, 'P0002',
                    'another shop''s vehicle is not found');
select tests.throws_like($$select public.price_services(tests.fx('shop_b'), null, tests.fx('cat_car_a'), array[tests.fx('svc_b')])$$, '22023',
                         '%category%', 'another shop''s vehicle category is rejected');
select tests.eq((pg_temp.line(public.price_services(tests.fx('shop_b'), tests.fx('cust_b'), null, array[tests.fx('svc_b')]),
                              tests.fx('svc_b')) ->> 'unit_price_cents')::bigint, 5000::bigint, 'shop B prices its own catalog');
select tests.as_anon();
select tests.throws($$select public.price_services(tests.fx('shop_a'), null, null, array[tests.fx('svc_a')])$$, '42501',
                    'anon cannot call price_services');
select tests.throws($$select public.price_services_core(tests.fx('shop_a'), null, null, array[tests.fx('svc_a')], null, false)$$, '42501',
                    'anon cannot call the internal variant');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.throws($$select public.price_services_core(tests.fx('shop_a'), null, null, array[tests.fx('svc_a')], null, false)$$, '42501',
                    'staff cannot call the internal variant (no caller checks)');
select tests.as_service();
select tests.lives($$select public.price_services_core(tests.fx('shop_a'), null, null, array[tests.fx('svc_a')], null, false)$$,
                   'service_role may call the internal variant');

-- ------------------------------------------------------------ helpers
select tests.as_superuser();
select tests.eq(public.normalize_phone_e164('(205) 555-0142', 'US'), '+12055550142', 'NANP 10 digits');
select tests.eq(public.normalize_phone_e164('1-205-555-0142', 'US'), '+12055550142', 'NANP with country code');
select tests.eq(public.normalize_phone_e164('+44 20 7123 4567', 'GB'), '+442071234567', 'international E.164');
select tests.eq(public.normalize_phone_e164('2055550142', 'GB'), null::text, 'national numbers only for US/CA');
select tests.eq(public.normalize_phone_e164('555-0142', 'US'), null::text, 'too short');
select tests.eq(public.normalize_phone_e164('abc', 'US'), null::text, 'garbage');
select tests.ok(public.postal_code_in_area('35203', '{}'), 'empty area = everywhere');
select tests.ok(public.postal_code_in_area('35203-1234', array['35203']), 'ZIP+4 matches its ZIP');
select tests.ok(public.postal_code_in_area('sw1a 1aa', array['SW1A1AA']), 'case and spaces ignored');
select tests.ok(not public.postal_code_in_area('35204', array['35203']), 'other ZIP');
select tests.ok(not public.postal_code_in_area(null, array['35203']), 'missing postal code');
select tests.eq(public.effective_now('2025-01-01Z'), '2025-01-01Z'::timestamptz, 'trusted sessions: p_now is honoured');
select tests.as_service();
select tests.eq(public.effective_now('2025-01-01Z'), '2025-01-01Z'::timestamptz, 'service_role: p_now is honoured');
select tests.as_superuser();
-- a JWT role claim of anon/authenticated alone is enough (the SET ROLE signal
-- is exercised by the anon booking tests)
select tests._set_claims('{"role": "authenticated"}');
select tests.eq(public.effective_now('2025-01-01Z'), now(), 'API requests always get the server clock');
select tests.as_superuser();
