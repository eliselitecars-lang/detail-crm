-- 40 integration: unverified phones in online booking (0042 header,
-- "Customer matching").
-- Regression: a stranger who booked first with someone's email (and their
-- own phone) created that email's customer; every later booking with the
-- email was attached to it, so the real customer's confirmation / reminder
-- texts, each with the /booking link that reads the service address and
-- cancels the job, went to the stranger's phone.
--   * a customer created by a booking that did not prove the email gets
--     phone_unverified; a later booking with another phone (or none) gets
--     its own customer, the same phone reuses the record
--   * the mark clears when staff set the phone, and the verified email owner
--     replaces the unverified phone (and its opt-in) with the one they give
--   * staff-entered and owner-entered phones are unaffected
--   * only managers+ of the shop can change the record; per-shop matching
\ir fixtures/two_shops.psql
\ir fixtures/40_booking_setup.psql

update public.booking_settings set max_concurrent_jobs = 100 where shop_id = tests.fx('shop_a');

create function pg_temp.job(p_result jsonb) returns public.jobs language sql as $$
  select * from public.jobs where public_token = (p_result ->> 'job_token')::uuid
$$;
create function pg_temp.cust(p_result jsonb) returns public.customers language sql as $$
  select c.* from public.customers c join public.jobs j on j.customer_id = c.id
   where j.public_token = (p_result ->> 'job_token')::uuid
$$;
-- SMS about the booking (any status) sent to p_to
create function pg_temp.sms_to(p_result jsonb, p_to text) returns bigint language sql as $$
  select count(*) from public.messages m join public.jobs j on j.id = m.job_id
   where j.public_token = (p_result ->> 'job_token')::uuid and m.channel = 'sms' and m.to_address = p_to
$$;
-- an anonymous-style booking (service_role, fixed clock) with the given contact
create function pg_temp.anon_book(p_customer jsonb, p_extra jsonb default '{}') returns jsonb language sql as $$
  select public.create_online_booking('shop-a', pg_temp.booking(jsonb_build_object('customer', p_customer) || p_extra),
                                      '2025-06-01 12:00Z')
$$;
grant execute on function pg_temp.anon_book(jsonb, jsonb) to anon, authenticated, service_role;

-- ============================================================ the reported attack
-- 1. a stranger books first with the victim's email and the stranger's own phone
select tests.as_service();
create temp table b1 as select public.create_online_booking('shop-a', pg_temp.booking(jsonb_build_object(
  'customer', jsonb_build_object('first_name', 'Vera', 'email', 'vera@example.com', 'phone', '+12055550666'))),
  '2025-06-01 12:00Z') as r;
-- 2. the real customer books later: mobile service at home, her own phone
create temp table b2 as select public.create_online_booking('shop-a', pg_temp.booking(jsonb_build_object(
  'customer', jsonb_build_object('first_name', 'Vera', 'email', 'vera@example.com', 'phone', '+12055550777'),
  'starts_at', '2025-06-10T15:00:00Z',
  'location', jsonb_build_object('type', 'mobile', 'address_line1', '9 Home Rd', 'city', 'Birmingham', 'postal_code', '35203'))),
  '2025-06-01 12:00Z') as r;
select tests.as_superuser();
select tests.eq((select count(*) from public.messages m join public.jobs j on j.id = m.job_id
                  where j.public_token = (select (r->>'job_token')::uuid from b2)
                    and m.channel = 'sms' and m.to_address = '+12055550666'
                    and m.body like '%' || (select r->>'job_token' from b2) || '%'),
                0::bigint,
                'the real customer''s booking link must not be texted to the phone a stranger put on file');
select tests.eq((select pg_temp.sms_to(r, '+12055550666') from b2), 0::bigint, 'nothing about her booking goes to that phone');
select tests.eq((select pg_temp.sms_to(r, '+12055550777') from b2), 1::bigint,
                'her booking-received text goes to the phone she entered');
select tests.ok((select m.body like '%' || (select r->>'job_token' from b2) || '%'
                   from public.messages m join public.jobs j on j.id = m.job_id
                  where j.public_token = (select (r->>'job_token')::uuid from b2) and m.channel = 'sms'),
                'with her own booking link');
select tests.ok((select (pg_temp.cust(b1.r)).phone_unverified and (pg_temp.cust(b1.r)).phone = '+12055550666' from b1),
                'the anonymously created customer''s phone is marked unverified');
select tests.ok((select (pg_temp.cust(b2.r)).id <> (pg_temp.cust(b1.r)).id from b1, b2),
                'the later booking with another phone is not attached to the stranger-made record');
select tests.ok((select c.email = 'vera@example.com' and c.phone = '+12055550777' and c.address_line1 = '9 Home Rd'
                        and c.source = 'online_booking'
                   from b2 cross join lateral pg_temp.cust(b2.r) c),
                'it gets its own customer with exactly the details entered');
select tests.ok((select c.phone = '+12055550666' and c.address_line1 is null from b1 cross join lateral pg_temp.cust(b1.r) c),
                'the stranger-made record gains neither her phone nor her address');
select tests.eq((select count(*) from public.messages m join public.jobs j on j.id = m.job_id
                   join public.customers c on c.id = j.customer_id
                  where c.id = (select (pg_temp.cust(r)).id from b1) and m.body like '%9 Home Rd%'),
                0::bigint, 'no text to the stranger mentions her service address');

-- 3. the real customer books again without a phone: again not the stranger's record
select tests.as_service();
create temp table b3 as select pg_temp.anon_book(jsonb_build_object('first_name', 'Vera', 'email', 'vera@example.com')) as r;
select tests.as_superuser();
select tests.ok((select c.id not in ((select (pg_temp.cust(r)).id from b1), (select (pg_temp.cust(r)).id from b2))
                        and c.phone is null and not c.phone_unverified
                   from b3 cross join lateral pg_temp.cust(b3.r) c),
                'a booking without a phone never lands on a record with an unverified phone');
select tests.eq((select count(*) from public.messages m join public.jobs j on j.id = m.job_id
                  where j.public_token = (select (r ->> 'job_token')::uuid from b3) and m.channel = 'sms'),
                0::bigint, 'and is texted to nobody');
select tests.eq((select count(*) from public.messages m join public.jobs j on j.id = m.job_id
                  where j.public_token = (select (r ->> 'job_token')::uuid from b3) and m.channel = 'email'
                    and m.to_address = 'vera@example.com'),
                1::bigint, 'its confirmation goes to the email entered');
-- a phone-less record has nothing unverified to protect: it is reused
select tests.as_service();
create temp table b4 as select pg_temp.anon_book(jsonb_build_object('first_name', 'Vera', 'email', 'vera@example.com')) as r;
select tests.as_superuser();
select tests.eq((select (pg_temp.cust(r)).id from b4), (select (pg_temp.cust(r)).id from b3),
                'the next phone-less booking reuses the phone-less record (no endless duplicates)');

-- 4. the stranger's own later booking (same email AND phone) reuses the stranger's record
select tests.as_service();
create temp table b5 as select pg_temp.anon_book(jsonb_build_object('first_name', 'V', 'email', 'VERA@example.com',
                                                                    'phone', '(205) 555-0666')) as r;
select tests.as_superuser();
select tests.eq((select (pg_temp.cust(r)).id from b5), (select (pg_temp.cust(r)).id from b1),
                'the same phone reuses the record it was entered on');
select tests.eq((select count(*) from public.customers where shop_id = tests.fx('shop_a') and email = 'vera@example.com'),
                3::bigint, 'three records for the email: the stranger''s, hers with her phone, hers without a phone');

-- ============================================================ staff set the phone: vouched
select tests.as_service();
create temp table w1 as select pg_temp.anon_book(jsonb_build_object('first_name', 'Wes', 'email', 'wes@example.com',
                                                                    'phone', '+12055550601')) as r;
create temp table x1 as select pg_temp.anon_book(jsonb_build_object('first_name', 'Xia', 'email', 'xia@example.com',
                                                                    'phone', '+12055550603')) as r;
select tests.as_superuser();
select tests.fx_set('cust_wes', (select (pg_temp.cust(r)).id from w1));
select tests.fx_set('cust_xia', (select (pg_temp.cust(r)).id from x1));
-- denial: only managers+ of the shop may touch the record
select tests.as_anon();
select tests.throws($$update public.customers set phone_unverified = false where id = tests.fx('cust_wes')$$, '42501',
                    'anon has no access to customers');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$update public.customers set phone = '+12055550602' where id = tests.fx('cust_wes')$$), 0::bigint,
                'a technician cannot change the phone');
select tests.authenticate_as(tests.fx('u_owner_b'));
select tests.eq(tests.row_count($$update public.customers set phone = '+12055550602', phone_unverified = false
                                   where id = tests.fx('cust_wes')$$), 0::bigint,
                'another shop''s owner cannot change it');
select tests.as_superuser();
select tests.ok((select phone_unverified and phone = '+12055550601' from public.customers where id = tests.fx('cust_wes')),
                'still unverified after the refused writes');
-- a staff edit of something else keeps the mark; a new phone clears it
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$update public.customers set notes = 'called' where id = tests.fx('cust_xia')$$), 1::bigint,
                'staff edit another field');
select tests.eq(tests.row_count($$update public.customers set phone = '+12055550602' where id = tests.fx('cust_wes')$$), 1::bigint,
                'staff set the phone');
select tests.as_superuser();
select tests.ok((select phone_unverified from public.customers where id = tests.fx('cust_xia')),
                'editing another field does not vouch for the phone');
select tests.ok((select not phone_unverified and phone = '+12055550602' from public.customers where id = tests.fx('cust_wes')),
                'a phone set by staff is no longer unverified');
-- a staff-vouched record is matched by email like any staff customer (its phone is never replaced)
select tests.as_service();
create temp table w2 as select pg_temp.anon_book(jsonb_build_object('first_name', 'Wes', 'email', 'wes@example.com')) as r;
create temp table x2 as select pg_temp.anon_book(jsonb_build_object('first_name', 'Xia', 'email', 'xia@example.com')) as r;
select tests.as_superuser();
select tests.eq((select (pg_temp.cust(r)).id from w2), tests.fx('cust_wes'), 'the vouched record is reused');
select tests.eq((select phone from public.customers where id = tests.fx('cust_wes')), '+12055550602', 'its phone kept');
select tests.ok((select (pg_temp.cust(r)).id <> tests.fx('cust_xia') from x2), 'the still-unverified one is not');

-- staff customers are unaffected: another phone still lands on the staff record, which keeps its phone
select tests.as_service();
create temp table s1 as select pg_temp.anon_book(jsonb_build_object('first_name', 'Al', 'email', 'alice@example.com',
                                                                    'phone', '+12055550604')) as r;
select tests.as_superuser();
select tests.ok((select (pg_temp.cust(r)).id = tests.fx('cust_a') and (pg_temp.cust(r)).phone = '+12055550101'
                        and not (pg_temp.cust(r)).phone_unverified from s1),
                'a staff-entered phone is never marked unverified and the record is still matched by email');

-- ============================================================ bookers who proved the email
-- API callers book on the server clock: a real slot three days out
create temp table live as
  select to_char(min(s.starts_at) at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') as starts_at
  from public.get_available_slots('shop-a', array[tests.fx('svc_a')], (now() at time zone 'America/Chicago')::date + 3,
                                  (now() at time zone 'America/Chicago')::date + 3,
                                  tests.fx('cat_car_a')) s;
grant select on live to anon, authenticated;
create function pg_temp.live_book(p_customer jsonb, p_extra jsonb default '{}') returns jsonb language sql as $$
  select public.create_online_booking('shop-a', pg_temp.booking(jsonb_build_object('customer', p_customer,
                                                                                   'starts_at', (select starts_at from live))
                                                                || p_extra))
$$;
grant execute on function pg_temp.live_book(jsonb, jsonb) to authenticated;
select tests.fx_set('u_olga', tests.create_user('olga@example.com'));
select tests.fx_set('u_pia', tests.create_user('pia@example.com'));
select tests.fx_set('u_quin', tests.create_user('quin@example.com'));

-- the verified owner replaces the unverified phone (and its opt-in) with her own
select tests.as_service();
create temp table o1 as select pg_temp.anon_book(jsonb_build_object('first_name', 'Olga', 'email', 'olga@example.com',
                                                                    'phone', '+12055550611', 'sms_opt_in', true)) as r;
select tests.as_superuser();
select tests.fx_set('cust_olga', (select (pg_temp.cust(r)).id from o1));
select tests.ok((select phone_unverified and sms_opt_in from public.customers where id = tests.fx('cust_olga')),
                'setup: the stranger''s phone and opt-in are on file, unverified');
select tests.eq((select count(*) from public.messages where customer_id = tests.fx('cust_olga') and to_address = '+12055550611'
                   and status = 'queued'), 1::bigint, 'setup: the stranger''s own booking text is queued');
select tests.authenticate_as(tests.fx('u_olga'));
create temp table o2 as select pg_temp.live_book(jsonb_build_object('first_name', 'Olga', 'email', 'olga@example.com',
                                                                    'phone', '+12055550612', 'sms_opt_in', false)) as r;
select tests.as_superuser();
select tests.eq((select (pg_temp.cust(r)).id from o2), tests.fx('cust_olga'), 'the verified owner reuses the record');
select tests.ok((select phone = '+12055550612' and not phone_unverified and not sms_opt_in and portal_user_id = tests.fx('u_olga')
                   from public.customers where id = tests.fx('cust_olga')),
                'her phone replaces the unverified one, with her own opt-in, and the record is hers');
select tests.eq((select pg_temp.sms_to(r, '+12055550611') from o2), 0::bigint, 'nothing about her booking goes to the old phone');
select tests.eq((select pg_temp.sms_to(r, '+12055550612') from o2), 1::bigint, 'her booking text goes to her phone');
select tests.eq((select count(*) from public.messages where customer_id = tests.fx('cust_olga') and to_address = '+12055550611'
                   and status = 'queued'), 0::bigint, 'texts still queued to the old phone are withdrawn (0033)');

-- a saved-vehicle booking by the verified owner, without a phone, drops the unverified one
select tests.as_service();
create temp table p1 as select pg_temp.anon_book(jsonb_build_object('first_name', 'Pia', 'email', 'pia@example.com',
                                                                    'phone', '+12055550621')) as r;
select tests.as_superuser();
select tests.fx_set('cust_pia', (select (pg_temp.cust(r)).id from p1));
select tests.fx_set('veh_pia', (select (pg_temp.job(r)).vehicle_id from p1));
select tests.authenticate_as(tests.fx('u_pia'));
select tests.eq(public.portal_claim_customers(), 1, 'the owner of the email claims the record');
create temp table p2 as select public.create_online_booking('shop-a',
  (pg_temp.booking(jsonb_build_object('starts_at', (select starts_at from live))) - 'customer')
  || jsonb_build_object('vehicle', jsonb_build_object('id', tests.fx('veh_pia')))) as r;
select tests.as_superuser();
select tests.ok((select (pg_temp.cust(r)).id = tests.fx('cust_pia') and (pg_temp.cust(r)).phone is null
                        and not (pg_temp.cust(r)).phone_unverified and not (pg_temp.cust(r)).sms_opt_in from p2),
                'the verified owner gave no phone: the unverified one is dropped, not texted');
select tests.eq((select count(*) from public.messages m join public.jobs j on j.id = m.job_id
                  where j.public_token = (select (r ->> 'job_token')::uuid from p2) and m.channel = 'sms'),
                0::bigint, 'so her booking is texted to nobody');

-- a record the verified owner creates has a verified phone
select tests.authenticate_as(tests.fx('u_quin'));
create temp table q1 as select pg_temp.live_book(jsonb_build_object('first_name', 'Quin', 'email', 'quin@example.com',
                                                                    'phone', '+12055550631')) as r;
select tests.as_superuser();
select tests.ok((select not (pg_temp.cust(r)).phone_unverified and (pg_temp.cust(r)).portal_user_id = tests.fx('u_quin') from q1),
                'created by the confirmed owner of the email: verified and linked');
select tests.as_service();
create temp table q2 as select pg_temp.anon_book(jsonb_build_object('first_name', 'Quin', 'email', 'quin@example.com')) as r;
select tests.as_superuser();
select tests.eq((select (pg_temp.cust(r)).id from q2), (select (pg_temp.cust(r)).id from q1),
                'so a later phone-less booking for the email reuses it (owner-entered phone)');

-- a signed-in user booking for SOMEONE ELSE's email proves nothing
select tests.authenticate_as(tests.fx('u_outsider'));
create temp table r1 as select pg_temp.live_book(jsonb_build_object('first_name', 'Rae', 'email', 'rae@example.com',
                                                                    'phone', '+12055550641')) as r;
select tests.as_superuser();
select tests.ok((select (pg_temp.cust(r)).phone_unverified and (pg_temp.cust(r)).portal_user_id is null from r1),
                'another account''s booking for this email: the phone is unverified');
-- nor does an anonymous booking without a phone leave anything unverified
select tests.as_service();
create temp table t1 as select pg_temp.anon_book(jsonb_build_object('first_name', 'Tia', 'email', 'tia@example.com')) as r;
create temp table t2 as select pg_temp.anon_book(jsonb_build_object('first_name', 'Tia', 'email', 'tia@example.com',
                                                                    'phone', '+12055550651')) as r;
select tests.as_superuser();
select tests.ok((select (pg_temp.cust(t2.r)).id = (pg_temp.cust(t1.r)).id and (pg_temp.cust(t2.r)).phone is null
                        and not (pg_temp.cust(t2.r)).phone_unverified from t1, t2),
                'phone-less record: reused, and an anonymous booking still cannot add a phone to it');

-- ============================================================ per shop
select tests.as_service();
create temp table sb as select public.create_online_booking('shop-b', pg_temp.booking(jsonb_build_object(
    'customer', jsonb_build_object('first_name', 'Vera', 'email', 'vera@example.com', 'phone', '+12055550666'),
    'service_ids', jsonb_build_array(tests.fx('svc_b')),
    'vehicle', jsonb_build_object('make', 'Kia', 'model', 'Soul'))), '2025-06-01 12:00Z') as r;
select tests.as_superuser();
select tests.ok((select c.shop_id = tests.fx('shop_b') and c.phone_unverified
                   from sb cross join lateral pg_temp.cust(sb.r) c),
                'shop B gets its own (unverified) customer: records never match across shops');
select tests.eq((select count(*) from public.customers where shop_id = tests.fx('shop_a') and email = 'vera@example.com'),
                3::bigint, 'shop A''s records are untouched');
