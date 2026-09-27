-- 40 integration: create_online_booking — customer upsert rules (email, then
-- phone among email-less customers; never overwrite; archived customers are
-- not reused), vehicle reuse, the daily abuse limit, coupon redemption
-- limits, and signed-in clients (portal link only for a confirmed matching
-- email, membership pricing only for the linked client, saved vehicles).
\ir fixtures/two_shops.psql
\ir fixtures/40_booking_setup.psql

update public.booking_settings set max_concurrent_jobs = 100 where shop_id = tests.fx('shop_a');

-- books as the current role at a fixed trusted clock (ignored for API roles)
create function pg_temp.book(p_payload jsonb) returns jsonb language sql as $$
  select public.create_online_booking('shop-a', p_payload, '2025-06-01 12:00Z')
$$;
create function pg_temp.job(p_result jsonb) returns public.jobs language sql as $$
  select * from public.jobs where public_token = (p_result ->> 'job_token')::uuid
$$;
create function pg_temp.contact(p_email text, p_phone text, p_first text default 'Guest', p_last text default null)
returns jsonb language sql as $$
  select jsonb_build_object('customer', jsonb_strip_nulls(jsonb_build_object('first_name', p_first, 'last_name', p_last,
                                                                            'email', p_email, 'phone', p_phone)))
$$;
grant execute on function pg_temp.book(jsonb), pg_temp.contact(text, text, text, text) to anon, authenticated, service_role;

-- ============================================================ customer matching
select tests.as_service();
-- existing customer by email (case-insensitive): nothing overwritten, blanks filled, opt-in upgraded
create temp table r1 as select pg_temp.book(pg_temp.booking(
  jsonb_build_object('customer', jsonb_build_object('first_name', 'Mallory', 'last_name', 'Evil', 'email', 'ALICE@Example.com',
                                                    'phone', '+12055559999', 'sms_opt_in', true, 'email_opt_in', false),
                     'vehicle', jsonb_build_object('year', 2021, 'make', 'honda', 'model', 'CIVIC ', 'color', 'Silver',
                                                   'category_id', tests.fx('cat_car_a'))))) as r;
select tests.as_superuser();
select tests.eq((select (pg_temp.job(r)).customer_id from r1), tests.fx('cust_a'), 'matched the existing customer by email');
select tests.ok((select first_name = 'Alice' and last_name = 'Anders' and email = 'alice@example.com' and phone = '+12055550101'
                        and source = 'staff' and not sms_opt_in and not email_opt_in and portal_user_id is null
                   from public.customers where id = tests.fx('cust_a')),
                'names, email, phone and source are never overwritten; an unverified booking changes no opt-in');
select tests.eq((select count(*) from public.customers where first_name = 'Mallory'), 0::bigint, 'no duplicate customer');
select tests.ok((select (pg_temp.job(r)).vehicle_id <> tests.fx('veh_a') from r1),
                'an unverified booking never reuses (or reveals) the matched customer''s vehicle, even the same make/model/year');
select tests.ok((select v.customer_id = tests.fx('cust_a') and v.year = 2021 and v.make = 'honda' and v.model = 'CIVIC'
                        and v.color = 'Silver'
                   from public.vehicles v where v.id = (select (pg_temp.job(r)).vehicle_id from r1)),
                'it gets a new vehicle on the matched customer, from the submitted fields only');
select tests.eq((select color from public.vehicles where id = tests.fx('veh_a')), null::text,
                'an unverified booking does not modify the on-file vehicle');
select tests.eq((select category_id from public.vehicles where id = tests.fx('veh_a')), tests.fx('cat_car_a'), 'category kept');

-- a different model is a new vehicle for the same customer
select tests.as_service();
create temp table r2 as select pg_temp.book(pg_temp.booking(
  pg_temp.contact('alice@example.com', null) || '{"vehicle": {"make": "Honda", "model": "Accord", "year": 2021}}')) as r;
select tests.as_superuser();
select tests.ok((select (pg_temp.job(r)).customer_id = tests.fx('cust_a') and (pg_temp.job(r)).vehicle_id <> tests.fx('veh_a')
                   from r2), 'a different model creates a new vehicle');
select tests.eq((select count(*) from public.vehicles where customer_id = tests.fx('cust_a')), 3::bigint,
                'Alice now has three vehicles (hers plus one per unverified booking)');

-- phone match among email-less customers fills the email and missing names
insert into public.customers (shop_id, first_name, phone) values (tests.fx('shop_a'), 'Pat', '+12055550177')
  returning tests.fx_set('cust_pat', id);
select tests.as_service();
create temp table r3 as select pg_temp.book(pg_temp.booking(pg_temp.contact('pat@example.com', '205.555.0177', 'Patricia', 'Smith'))) as r;
select tests.as_superuser();
select tests.eq((select (pg_temp.job(r)).customer_id from r3), tests.fx('cust_pat'), 'matched an email-less customer by phone');
select tests.ok((select first_name = 'Pat' and last_name = 'Smith' and email is null
                   from public.customers where id = tests.fx('cust_pat')),
                'first name kept, empty last name filled; the unverified email is NOT attached');

-- a phone shared with a customer who has another email is a different person
insert into public.customers (shop_id, first_name, email, phone) values (tests.fx('shop_a'), 'Quinn', 'quinn@example.com', '+12055550188')
  returning tests.fx_set('cust_quinn', id);
select tests.as_service();
create temp table r4 as select pg_temp.book(pg_temp.booking(pg_temp.contact('quincy@example.com', '+12055550188', 'Quincy'))) as r;
select tests.as_superuser();
select tests.ok((select (pg_temp.job(r)).customer_id <> tests.fx('cust_quinn') from r4), 'not matched to Quinn');
select tests.ok((select c.first_name = 'Quincy' and c.email = 'quincy@example.com' and c.phone = '+12055550188'
                   from public.customers c where c.id = (select (pg_temp.job(r)).customer_id from r4)), 'a new customer');
select tests.eq((select email from public.customers where id = tests.fx('cust_quinn')), 'quinn@example.com', 'Quinn untouched');

-- archived customers are not reused
insert into public.customers (shop_id, first_name, email, archived_at)
  values (tests.fx('shop_a'), 'Old', 'arch@example.com', now()) returning tests.fx_set('cust_arch', id);
select tests.as_service();
create temp table r5 as select pg_temp.book(pg_temp.booking(pg_temp.contact('arch@example.com', null, 'Ari'))) as r;
select tests.as_superuser();
select tests.ok((select (pg_temp.job(r)).customer_id <> tests.fx('cust_arch') from r5), 'archived customer not reused');
select tests.ok((select archived_at is not null and first_name = 'Old' from public.customers where id = tests.fx('cust_arch')),
                'the archived record is untouched');

-- takeover attempts: a stranger's phone / email never lands on someone else's record
insert into public.customers (shop_id, first_name, email) values (tests.fx('shop_a'), 'Vic', 'vic@example.com')
  returning tests.fx_set('cust_vic', id);
select tests.fx_set('u_attacker', tests.create_user('attacker@example.com'));
select tests.as_service();
select pg_temp.book(pg_temp.booking(jsonb_build_object('customer', jsonb_build_object(
  'first_name', 'Vic', 'email', 'vic@example.com', 'phone', '+12055550666', 'sms_opt_in', true, 'email_opt_in', true),
  'location', jsonb_build_object('type', 'mobile', 'address_line1', '1 Fake St', 'city', 'Nowhere', 'postal_code', '35203'))));
select pg_temp.book(pg_temp.booking(pg_temp.contact('attacker@example.com', '+12055550177', 'Pat')));
select tests.as_superuser();
select tests.ok((select phone is null and not sms_opt_in and not email_opt_in and address_line1 is null
                   from public.customers where id = tests.fx('cust_vic')),
                'a public booking cannot add a phone, opt-ins or an address to an existing customer');
select tests.ok((select email is null from public.customers where id = tests.fx('cust_pat')),
                'nor an email to a customer matched by phone');
select tests.authenticate_as(tests.fx('u_attacker'));
select tests.eq(public.portal_claim_customers(), 0, 'so the attacker''s confirmed email claims nothing');
select tests.as_superuser();

-- another shop's customer with the same email is never matched
insert into public.customers (shop_id, first_name, email) values (tests.fx('shop_b'), 'Bea', 'bea@example.com')
  returning tests.fx_set('cust_bea_b', id);
select tests.as_service();
create temp table r6 as select pg_temp.book(pg_temp.booking(pg_temp.contact('bea@example.com', null, 'Bea'))) as r;
select tests.as_superuser();
select tests.ok((select c.shop_id = tests.fx('shop_a') and c.id <> tests.fx('cust_bea_b')
                   from public.customers c where c.id = (select (pg_temp.job(r)).customer_id from r6)),
                'customers are matched only within the booking''s shop');

-- ============================================================ daily abuse limit (5 per email / phone per shop)
select tests.as_service();
do $$
begin
  for i in 1 .. 5 loop
    perform pg_temp.book(pg_temp.booking(pg_temp.contact('busy@example.com', '+120555503' || lpad(i::text, 2, '0'))));
  end loop;
end
$$;
select tests.throws_like($$select pg_temp.book(pg_temp.booking(pg_temp.contact('Busy@Example.com', '+12055550399')))$$, 'PT429',
                         '%too many online bookings%', 'a 6th booking for the same email within 24 hours is refused');
do $$
begin
  for i in 1 .. 5 loop
    perform pg_temp.book(pg_temp.booking(pg_temp.contact('phone' || i || '@example.com', '(205) 555-0400')));
  end loop;
end
$$;
select tests.throws_like($$select pg_temp.book(pg_temp.booking(pg_temp.contact('phone6@example.com', '+12055550400')))$$, 'PT429',
                         '%too many%', 'and for the same phone number');
select tests.as_superuser();
update public.jobs set status = 'cancelled'
 where customer_id in (select id from public.customers where email = 'busy@example.com');
select tests.as_service();
select tests.throws($$select pg_temp.book(pg_temp.booking(pg_temp.contact('busy@example.com', '+12055550398')))$$, 'PT429',
                    'cancelled bookings still count');
select tests.lives($$select pg_temp.book(pg_temp.booking(pg_temp.contact('calm@example.com', '+12055550500')))$$,
                   'other contacts are unaffected');
-- shop B keeps its own count
select tests.as_superuser();
update public.booking_settings set enabled = true, max_concurrent_jobs = 100 where shop_id = tests.fx('shop_b');
select tests.as_service();
select tests.lives($$select public.create_online_booking('shop-b', pg_temp.booking(pg_temp.contact('busy@example.com', '+12055550301'))
                        || jsonb_build_object('service_ids', jsonb_build_array(tests.fx('svc_b')),
                                              'vehicle', jsonb_build_object('make', 'Kia', 'model', 'Soul')),
                                              '2025-06-01 12:00Z')$$,
                   'the limit is per shop');

-- ============================================================ coupons
create temp table c1 as select pg_temp.book(pg_temp.booking(pg_temp.contact('coupon1@example.com', null) || '{"coupon_code": " save10 "}')) as r;
select tests.as_superuser();
select tests.ok((select (pg_temp.job(r)).coupon_id = tests.fx('coupon_a') and (pg_temp.job(r)).discount_kind = 'percent'
                        and (pg_temp.job(r)).discount_value = 1000 and (pg_temp.job(r)).discount_cents = 2000
                        and (pg_temp.job(r)).total_cents = 19800 and (r ->> 'total_cents')::bigint = 19800 from c1),
                'coupon applied to the job (code trimmed, case-insensitive): (20000 - 2000) + 10% tax');
select tests.eq((select redemptions from public.coupons where id = tests.fx('coupon_a')), 1, 'redemption counted');
select tests.as_service();
select tests.lives($$select pg_temp.book(pg_temp.booking(pg_temp.contact('coupon2@example.com', null) || '{"coupon_code": "LIMITED"}'))$$,
                   'the only redemption of LIMITED');
select tests.throws_like($$select pg_temp.book(pg_temp.booking(pg_temp.contact('coupon3@example.com', null) || '{"coupon_code": "LIMITED"}'))$$,
                         '22023', '%fully redeemed%', 'over the redemption limit');
select tests.as_superuser();
select tests.eq((select redemptions from public.coupons where id = tests.fx('cp_limited')), 1, 'the refused booking consumed nothing');
select tests.eq((select count(*) from public.customers where email = 'coupon3@example.com'), 0::bigint,
                'and left no customer behind');
select tests.eq((select redemptions from public.coupons where id = tests.fx('coupon_b')), 0, 'shop B''s SAVE10 untouched');

-- ============================================================ signed-in clients
insert into public.membership_plans (shop_id, name, price_cents, included_service_ids, discount_bps)
  values (tests.fx('shop_a'), 'Gold', 9900, array[tests.fx('svc_wash')], 1500) returning tests.fx_set('plan_gold', id);
insert into public.memberships (shop_id, plan_id, customer_id, status)
  values (tests.fx('shop_a'), tests.fx('plan_gold'), tests.fx('cust_a'), 'active');
select tests.fx_set('u_alice', tests.create_user('alice@example.com'));
select tests.fx_set('u_unconfirmed', tests.create_user('eve@example.com', false));

-- API callers always book on the server clock: a real slot three days out
create temp table fs as
  select to_char(min(s.starts_at) at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') as starts_at
  from public.get_available_slots('shop-a', array[tests.fx('svc_a'), tests.fx('svc_wash')], (now() at time zone 'America/Chicago')::date + 3,
                                  (now() at time zone 'America/Chicago')::date + 3,
                                  tests.fx('cat_car_a')) s;
grant select on fs to anon, authenticated;
create function pg_temp.live(p_overrides jsonb) returns jsonb language sql as $$
  select pg_temp.booking(p_overrides) || jsonb_build_object('starts_at', (select starts_at from fs),
                                                            'service_ids', jsonb_build_array(tests.fx('svc_a'), tests.fx('svc_wash')))
$$;
grant execute on function pg_temp.live(jsonb) to anon, authenticated;

-- anonymous: typing a member's email never unlocks membership pricing or links an account
select tests.as_anon();
create temp table p1 as select public.create_online_booking('shop-a', pg_temp.live(pg_temp.contact('alice@example.com', null))) as r;
select tests.as_superuser();
select tests.ok((select (pg_temp.job(r)).customer_id = tests.fx('cust_a') and (pg_temp.job(r)).discount_kind = 'none'
                        and (r ->> 'total_cents')::bigint = 27500 from p1),
                'anon booking for a member''s email: catalog prices, no membership discount (25000 + 10% tax)');
select tests.eq((select count(*) from public.job_line_items li join p1 on li.job_id = (pg_temp.job(p1.r)).id
                  where li.unit_price_cents = 0), 0::bigint, 'no included (free) lines for anon');
select tests.ok((select portal_user_id is null from public.customers where id = tests.fx('cust_a')), 'anon never links an account');

-- an unconfirmed account is not linked (and gets no member pricing)
select tests.authenticate_as(tests.fx('u_unconfirmed'));
create temp table p2 as select public.create_online_booking('shop-a', pg_temp.live(pg_temp.contact('eve@example.com', null, 'Eve'))) as r;
select tests.as_superuser();
select tests.ok((select c.portal_user_id is null and c.email = 'eve@example.com'
                   from public.customers c where c.id = (select (pg_temp.job(r)).customer_id from p2)),
                'unconfirmed email: customer created but not linked');
select tests.eq((select (pg_temp.job(r)).created_by from p2), tests.fx('u_unconfirmed'), 'the job records the signed-in booker');

-- a confirmed account booking under a DIFFERENT email is not linked
select tests.authenticate_as(tests.fx('u_outsider'));
create temp table p3 as select public.create_online_booking('shop-a', pg_temp.live(pg_temp.contact('someone.else@example.com', null))) as r;
select tests.as_superuser();
select tests.ok((select c.portal_user_id is null from public.customers c where c.id = (select (pg_temp.job(r)).customer_id from p3)),
                'booking for another email address links nothing');

-- the confirmed owner of the email: linked, and member pricing applies
select tests.authenticate_as(tests.fx('u_alice'));
create temp table p4 as select public.create_online_booking('shop-a', pg_temp.live(jsonb_build_object('customer',
    jsonb_build_object('first_name', 'Al', 'email', 'ALICE@example.com', 'email_opt_in', true)))) as r;
select tests.as_superuser();
select tests.eq((select portal_user_id from public.customers where id = tests.fx('cust_a')), tests.fx('u_alice'),
                'a confirmed matching email links the customer to the caller');
select tests.eq((select (pg_temp.job(r)).vehicle_id from p4), (select (pg_temp.job(r)).vehicle_id from p1),
                'the verified client''s booking reuses the customer''s same make/model vehicle');
select tests.ok((select email_opt_in and first_name = 'Alice' from public.customers where id = tests.fx('cust_a')),
                'the verified client may opt in (names are still never overwritten)');
select tests.eq((select jsonb_agg(jsonb_build_object('name', li.name, 'price', li.unit_price_cents, 'note', li.description)
                                  order by li.sort)
                   from public.job_line_items li where li.job_id = (select (pg_temp.job(r)).id from p4)),
                '[{"name": "Full Detail", "price": 20000, "note": null},
                  {"name": "Exterior Wash", "price": 0, "note": "Included with your Gold membership"}]'::jsonb,
                'the included service is free with a note');
select tests.ok((select (pg_temp.job(r)).discount_kind = 'percent' and (pg_temp.job(r)).discount_value = 1500
                        and (r ->> 'total_cents')::bigint = 18700 from p4),
                'the plan discount applies to the booking: (20000 - 15%) + 10% tax = 18700');

-- a saved vehicle (no contact needed); a coupon replaces the membership discount
select tests.authenticate_as(tests.fx('u_alice'));
create temp table p5 as select public.create_online_booking('shop-a',
    (pg_temp.live('{"coupon_code": "SAVE10"}') - 'customer')
    || jsonb_build_object('vehicle', jsonb_build_object('id', tests.fx('veh_a'), 'category_id', tests.fx('cat_truck_a')))) as r;
select tests.as_superuser();
select tests.ok((select (pg_temp.job(r)).customer_id = tests.fx('cust_a') and (pg_temp.job(r)).vehicle_id = tests.fx('veh_a') from p5),
                'booked for the saved vehicle''s owner');
select tests.eq((select sum(li.unit_price_cents) from public.job_line_items li where li.job_id = (select (pg_temp.job(r)).id from p5)),
                20000::numeric, 'the vehicle''s own category (Car) is used, not the payload''s; the wash stays included');
select tests.ok((select (pg_temp.job(r)).discount_kind = 'percent' and (pg_temp.job(r)).discount_value = 1000 from p5),
                'a coupon replaces the membership discount');
select tests.eq((select count(*) from public.vehicles where customer_id = tests.fx('cust_a')), 4::bigint,
                'no new vehicle (two Civics, the Accord, and the Camry of the anon booking that her verified booking reused)');

-- nobody else may book Alice's saved vehicle
select tests.authenticate_as(tests.fx('u_outsider'));
select tests.throws_like($$select public.create_online_booking('shop-a', pg_temp.live('{}') || jsonb_build_object('vehicle',
                             jsonb_build_object('id', tests.fx('veh_a'))))$$, 'PT404', '%vehicle not found%',
                         'another user cannot book a saved vehicle');
select tests.as_anon();
select tests.throws($$select public.create_online_booking('shop-a', pg_temp.live('{}') || jsonb_build_object('vehicle',
                      jsonb_build_object('id', tests.fx('veh_a'))))$$, 'PT404', 'anon cannot book a saved vehicle');
select tests.authenticate_as(tests.fx('u_alice'));
select tests.throws($$select public.create_online_booking('shop-a', pg_temp.live('{}') || jsonb_build_object('vehicle',
                      jsonb_build_object('id', tests.fx('veh_b'))))$$, 'PT404', 'a vehicle of another shop is not found');
select tests.as_superuser();
update public.vehicles set archived_at = now() where id = tests.fx('veh_a');
select tests.authenticate_as(tests.fx('u_alice'));
select tests.throws($$select public.create_online_booking('shop-a', pg_temp.live('{}') || jsonb_build_object('vehicle',
                      jsonb_build_object('id', tests.fx('veh_a'))))$$, 'PT404', 'archived vehicles cannot be booked');
select tests.as_superuser();
