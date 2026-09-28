-- 40 integration: online booking cannot be a message relay or fill the
-- calendar (0104).
-- Regression: create_online_booking (anonymous, slug only) was limited only
-- to 5 bookings per email / phone per day. A script rotating contacts from
-- ONE connection booked every slot it wanted, and each booking made the shop
-- text (from its own Twilio number) and email the typed number / address
-- with the visitor's own text in the greeting and the vehicle line:
-- 'Hi URGENT: your card is locked, verify at evil.example/v, thanks for your
-- booking request with Shop A ...' to 18 distinct unverified numbers.
--   * 10 online bookings per client IP per shop, 100 per shop, rolling 24 h
--     (PT429); failed bookings are not counted; other shops are unaffected
--   * an anonymous booking's messages carry nothing the visitor typed (no
--     name, no vehicle) and are never texted to its unverified phone
--   * a signed-in client linked to the customer still gets their own name,
--     vehicle and text; an anonymous booking on a staff customer texts only
--     the staff-entered phone, without the visitor's text
--   * online_booking_log is internal: no client access
--   * 0105: an IPv6 client is one connection per /64 (an IPv4-mapped address
--     is its IPv4 address); signed-in clients with a confirmed email book
--     from their own allowance (10 per account, 100 per shop), so anonymous
--     traffic cannot close online booking for them
\ir fixtures/two_shops.psql
\ir fixtures/40_booking_setup.psql

-- API callers book on the server clock: Exterior Wash slots (60 min,
-- capacity 1, 9 a day) on days +3 .. +5 in shop A, +3 in shop B
create temp table wash_slots as
  select row_number() over (order by s.starts_at)::integer as n,
         to_char(s.starts_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') as starts_at
    from public.get_available_slots('shop-a', array[tests.fx('svc_wash')], (now() at time zone 'America/Chicago')::date + 3,
                                    (now() at time zone 'America/Chicago')::date + 5, tests.fx('cat_car_a')) s;
create temp table b_slots as
  select row_number() over (order by s.starts_at)::integer as n,
         to_char(s.starts_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') as starts_at
    from public.get_available_slots('shop-b', array[tests.fx('svc_b')], (now() at time zone 'UTC')::date + 3,
                                    (now() at time zone 'UTC')::date + 3) s;
grant select on wash_slots, b_slots to anon, authenticated;
select tests.ok((select count(*) from wash_slots) >= 24 and (select count(*) from b_slots) >= 2,
                'setup: enough real slots on the server clock');

-- the attacker's booking: contact n, slot p_slot (default n)
create function pg_temp.relay(p_n integer, p_slot integer default null) returns jsonb language sql as $$
  select public.create_online_booking('shop-a', pg_temp.booking(jsonb_build_object(
    'customer', jsonb_build_object('first_name', 'URGENT: your card is locked, verify at evil.example/v',
                                   'email', 'victim' || p_n || '@example.com',
                                   'phone', '+1205777' || lpad(p_n::text, 4, '0'), 'sms_opt_in', true),
    'vehicle', jsonb_build_object('make', 'Call 205-555-0199', 'model', 'to unlock', 'category_id', tests.fx('cat_car_a')),
    'service_ids', jsonb_build_array(tests.fx('svc_wash')),
    'starts_at', (select starts_at from wash_slots where n = coalesce(p_slot, p_n)))))
$$;
grant execute on function pg_temp.relay(integer, integer) to anon, authenticated, service_role;
create function pg_temp.from_ip(p_ip text) returns void language sql as $$
  select set_config('request.headers', jsonb_build_object('x-forwarded-for', p_ip)::text, true)::text
$$;
grant execute on function pg_temp.from_ip(text) to anon, authenticated, service_role;

-- ============================================================ the reported attack, one connection
select tests.as_anon();
select pg_temp.from_ip('198.51.100.7');
do $$ begin for i in 1 .. 10 loop perform pg_temp.relay(i); end loop; end $$;
select tests.throws_like($$select pg_temp.relay(11)$$, 'PT429', '%too many online bookings from this connection%',
                         'the 11th booking from one connection in 24 hours is refused');
select tests.as_superuser();
select tests.eq((select count(*) from public.jobs where shop_id = tests.fx('shop_a') and source = 'online_booking'),
                10::bigint, 'one connection books at most 10 slots a day');
select tests.eq((select count(*) from public.online_booking_log where shop_id = tests.fx('shop_a') and client_ip = '198.51.100.7'),
                10::bigint, 'each accepted booking is logged with its client IP');

-- another connection has its own allowance
select tests.as_anon();
select pg_temp.from_ip('198.51.100.8');
select tests.ok(pg_temp.relay(11) ? 'job_token', 'another connection can still book');
-- a failed booking (slot already taken) is not counted
select tests.throws($$select pg_temp.relay(12, 1)$$, '23P01', 'a taken slot fails');
select tests.as_superuser();
select tests.eq((select count(*) from public.online_booking_log where client_ip = '198.51.100.8'), 1::bigint,
                'the failed booking was not counted');

-- ============================================================ nothing relayed
select tests.eq((select count(*) from public.customers
                  where shop_id = tests.fx('shop_a') and phone like '+1205777%' and phone_unverified),
                11::bigint, 'setup: every attacker contact is a new customer with an unverified phone');
select tests.eq((select count(*) from public.messages m join public.jobs j on j.id = m.job_id
                  where j.shop_id = tests.fx('shop_a') and j.source = 'online_booking' and m.channel = 'sms'),
                0::bigint, 'no booking text goes to any of the typed (unverified) numbers');
select tests.eq((select count(*) from public.messages m join public.jobs j on j.id = m.job_id
                  where j.shop_id = tests.fx('shop_a') and j.source = 'online_booking' and m.channel = 'email'
                    and m.template_key = 'booking_request_received'),
                11::bigint, 'the booking-received email still goes to the address typed (the booker''s confirmation)');
select tests.eq((select count(*) from public.messages m join public.jobs j on j.id = m.job_id
                  where j.shop_id = tests.fx('shop_a') and j.source = 'online_booking'
                    and (m.body ~* 'urgent|evil\.example|205-555-0199|unlock|vehicle:'
                         or coalesce(m.subject, '') ~* 'urgent|evil\.example|205-555-0199|unlock')),
                0::bigint, 'no message carries the name or vehicle the visitor typed');
select tests.ok((select bool_and(m.body like 'Hi there,%' and m.body like '%/booking/%' and m.body like '%Services: Exterior Wash%')
                   from public.messages m join public.jobs j on j.id = m.job_id
                  where j.shop_id = tests.fx('shop_a') and j.source = 'online_booking'),
                'the emails greet "there" and keep the booking link and the catalog services');
select tests.eq((select count(*) from public.notifications n join public.jobs j on j.id = n.job_id
                  where j.shop_id = tests.fx('shop_a') and n.kind = 'new_booking'),
                33::bigint, 'staff are still notified of every request (3 managers+ x 11)');

-- ============================================================ rolling window and pruning
update public.online_booking_log set created_at = now() - interval '25 hours' where client_ip = '198.51.100.7';
select tests.as_anon();
select pg_temp.from_ip('198.51.100.7');
select tests.ok(pg_temp.relay(13) ? 'job_token', 'bookings older than 24 hours no longer count');
select tests.as_superuser();
update public.online_booking_log set created_at = now() - interval '3 days' where client_ip = '198.51.100.7'
   and created_at < now() - interval '1 hour';
select tests.as_anon();
select pg_temp.from_ip('198.51.100.9');
select pg_temp.relay(14);
select tests.as_superuser();
select tests.eq((select count(*) from public.online_booking_log
                  where shop_id = tests.fx('shop_a') and created_at < now() - interval '2 days'),
                0::bigint, 'rows older than 2 days are dropped as new bookings arrive');

-- ============================================================ per-shop limit
insert into public.online_booking_log (shop_id, client_ip)
select tests.fx('shop_a'), ('203.0.113.' || g)::inet
  from generate_series(1, 99 - (select count(*)::integer from public.online_booking_log
                                 where shop_id = tests.fx('shop_a') and created_at > now() - interval '24 hours')) g;
select tests.as_anon();
select pg_temp.from_ip('198.51.100.10');
select tests.ok(pg_temp.relay(15) ? 'job_token', 'the 100th online booking of the day is accepted');
select pg_temp.from_ip('198.51.100.11');
select tests.throws_like($$select pg_temp.relay(16)$$, 'PT429', '%receiving too many online bookings%',
                         'the 101st is refused, whichever connection sends it');
-- other shops are unaffected
select tests.ok(public.create_online_booking('shop-b', pg_temp.booking(jsonb_build_object(
                  'customer', jsonb_build_object('first_name', 'Bea', 'email', 'bea@example.com'),
                  'vehicle', jsonb_build_object('make', 'Ford', 'model', 'Focus'),
                  'service_ids', jsonb_build_array(tests.fx('svc_b')),
                  'starts_at', (select starts_at from b_slots where n = 1)))) ? 'job_token',
                'another shop''s bookings are counted on their own');
select tests.as_superuser();
delete from public.online_booking_log where shop_id = tests.fx('shop_a') and client_ip << '203.0.113.0/24'::inet;

-- ============================================================ proven bookers keep their messages
-- a client signed in with the confirmed email creates (and is linked to) her record
select tests.fx_set('u_rhea', tests.create_user('rhea@example.com'));
select tests.authenticate_as(tests.fx('u_rhea'));
select pg_temp.from_ip('198.51.100.20');
create temp table rhea as select public.create_online_booking('shop-a', pg_temp.booking(jsonb_build_object(
  'customer', jsonb_build_object('first_name', 'Rhea', 'email', 'rhea@example.com', 'phone', '+12055550881',
                                 'sms_opt_in', true),
  'service_ids', jsonb_build_array(tests.fx('svc_wash')),
  'starts_at', (select starts_at from wash_slots where n = 20)))) as r;
select tests.as_superuser();
select tests.eq((select string_agg(m.channel::text || ':' || m.to_address, ',' order by m.channel)
                   from public.messages m join public.jobs j on j.id = m.job_id
                  where j.public_token = (select (r ->> 'job_token')::uuid from rhea)),
                'sms:+12055550881,email:rhea@example.com',
                'the signed-in owner of the email is texted and emailed (her phone is verified)');
select tests.ok((select bool_and(m.body like 'Hi Rhea,%') and bool_or(m.body like '%Vehicle: 2020 Toyota Camry%')
                   from public.messages m join public.jobs j on j.id = m.job_id
                  where j.public_token = (select (r ->> 'job_token')::uuid from rhea)),
                'with her name and vehicle');

-- an anonymous booking with a staff customer's email: the staff-entered
-- phone may be texted, but without the visitor's text
update public.customers set sms_opt_in = true where id = tests.fx('cust_a');
select tests.as_anon();
select pg_temp.from_ip('198.51.100.21');
create temp table alice as select public.create_online_booking('shop-a', pg_temp.booking(jsonb_build_object(
  'customer', jsonb_build_object('first_name', 'URGENT: call 205-555-0199', 'email', 'alice@example.com',
                                 'phone', '+12057770999'),
  'vehicle', jsonb_build_object('make', 'Visit evil.example', 'model', 'now', 'category_id', tests.fx('cat_car_a')),
  'service_ids', jsonb_build_array(tests.fx('svc_wash')),
  'starts_at', (select starts_at from wash_slots where n = 21)))) as r;
select tests.as_superuser();
select tests.eq((select string_agg(m.channel::text || ':' || m.to_address, ',' order by m.channel)
                   from public.messages m join public.jobs j on j.id = m.job_id
                  where j.public_token = (select (r ->> 'job_token')::uuid from alice)),
                'sms:+12055550101,email:alice@example.com',
                'matched to the staff customer: only the phone staff entered is texted');
select tests.ok((select bool_and(m.body like 'Hi there,%' and m.body !~* 'urgent|evil\.example|205-555-0199|vehicle:')
                   from public.messages m join public.jobs j on j.id = m.job_id
                  where j.public_token = (select (r ->> 'job_token')::uuid from alice)),
                'and nothing the anonymous visitor typed is in either message');

-- ============================================================ 0105: an IPv6 client is one connection per /64
-- Regression: the per-connection limit compared exact addresses, and an IPv6
-- client chooses its own interface id: 25 bookings from 2001:db8:1:2::<i>
-- were all accepted, and one machine could use up the shop's 100 of the day.
select tests.as_anon();
select pg_temp.from_ip('2001:db8:1:3::1');
select tests.ok(pg_temp.relay(17) ? 'job_token', 'an IPv6 client books');
select tests.as_superuser();
select tests.eq((select host(client_ip) from public.online_booking_log where client_ip << '2001:db8:1:3::/64'::inet),
                '2001:db8:1:3::1', 'the log keeps the exact address');
-- ten earlier bookings from ten addresses of one /64
insert into public.online_booking_log (shop_id, client_ip)
select tests.fx('shop_a'), ('2001:db8:1:2::' || to_hex(g))::inet from generate_series(1, 10) g;
select tests.as_anon();
select pg_temp.from_ip('2001:db8:1:2:abcd:ef01:2345:6789');
select tests.throws_like($$select pg_temp.relay(18)$$, 'PT429', '%too many online bookings from this connection%',
                         'a new interface id in the same /64 is the same connection');
select pg_temp.from_ip('2001:db8:1:2::1');
select tests.throws_like($$select pg_temp.relay(18)$$, 'PT429', '%from this connection%', 'and so is an address it used');
select pg_temp.from_ip('2001:db8:1:4::1');
select tests.ok(pg_temp.relay(18) ? 'job_token', 'another /64 is another connection');
-- an IPv4 client seen as an IPv4-mapped IPv6 address is that IPv4 address
select tests.as_superuser();
insert into public.online_booking_log (shop_id, client_ip)
select tests.fx('shop_a'), '198.51.100.30'::inet from generate_series(1, 10);
select tests.as_anon();
select pg_temp.from_ip('::ffff:198.51.100.30');
select tests.throws_like($$select pg_temp.relay(19)$$, 'PT429', '%from this connection%',
                         'an IPv4-mapped address counts as its IPv4 address');
select tests.as_superuser();
select tests.eq(public.client_ip_scope('203.0.113.9'), '203.0.113.9'::inet, 'scope: IPv4 as is');
select tests.eq(public.client_ip_scope('::ffff:203.0.113.9'), '203.0.113.9'::inet, 'scope: IPv4-mapped -> IPv4');
select tests.eq(public.client_ip_scope('2001:db8:aa:bb:1:2:3:4'), '2001:db8:aa:bb::/64'::inet, 'scope: IPv6 -> /64');
select tests.eq(public.client_ip_scope(null), null::inet, 'scope: unknown stays unknown');
delete from public.online_booking_log
 where shop_id = tests.fx('shop_a') and (client_ip << '2001:db8:1:2::/64'::inet or client_ip = '198.51.100.30');

-- ============================================================ 0105: signed-in clients keep their own allowance
-- The shop cap counted every caller, so anonymous traffic (ten IPv4
-- addresses) could close online booking for the shop's signed-in clients.
insert into public.online_booking_log (shop_id, client_ip)
select tests.fx('shop_a'), ('203.0.113.' || g)::inet
  from generate_series(1, 100 - (select count(*)::integer from public.online_booking_log
                                  where shop_id = tests.fx('shop_a') and user_id is null
                                    and created_at > now() - interval '24 hours')) g;
select tests.eq((select count(*) from public.online_booking_log where shop_id = tests.fx('shop_a') and user_id = tests.fx('u_rhea')),
                1::bigint, 'the signed-in booking above was logged with its account');
select tests.as_anon();
select pg_temp.from_ip('198.51.100.31');
select tests.throws_like($$select pg_temp.relay(19)$$, 'PT429', '%receiving too many online bookings%',
                         'the anonymous allowance of the day is used up');
select tests.authenticate_as(tests.fx('u_rhea'));
select pg_temp.from_ip('198.51.100.32');
select tests.ok(public.create_online_booking('shop-a', pg_temp.booking(jsonb_build_object(
                  'customer', jsonb_build_object('first_name', 'Rhea', 'email', 'rhea@example.com'),
                  'service_ids', jsonb_build_array(tests.fx('svc_wash')),
                  'starts_at', (select starts_at from wash_slots where n = 22)))) ? 'job_token',
                'a signed-in client (confirmed email) still books');
-- an unconfirmed account proves nothing: it books from the anonymous allowance
select tests.as_superuser();
select tests.fx_set('u_unconf', tests.create_user('unconfirmed@example.com', false));
select tests.authenticate_as(tests.fx('u_unconf'));
select pg_temp.from_ip('198.51.100.33');
select tests.throws_like($$select pg_temp.relay(19)$$, 'PT429', '%receiving too many online bookings%',
                         'a signed-in user without a confirmed email is anonymous');
-- 10 per account per shop
select tests.as_superuser();
insert into public.online_booking_log (shop_id, user_id)
select tests.fx('shop_a'), tests.fx('u_rhea') from generate_series(1, 8);
select tests.authenticate_as(tests.fx('u_rhea'));
select pg_temp.from_ip('198.51.100.34');
select tests.throws_like($$select public.create_online_booking('shop-a', pg_temp.booking(jsonb_build_object(
                  'customer', jsonb_build_object('first_name', 'Rhea', 'email', 'rhea@example.com'),
                  'service_ids', jsonb_build_array(tests.fx('svc_wash')),
                  'starts_at', (select starts_at from wash_slots where n = 23))))$$,
                         'PT429', '%too many online bookings from this account%', 'the 11th booking of one account is refused');
-- 100 signed-in bookings per shop
select tests.as_superuser();
select tests.fx_set('u_sam', tests.create_user('sam@example.com'));
insert into public.online_booking_log (shop_id, user_id)
select tests.fx('shop_a'), gen_random_uuid()
  from generate_series(1, 100 - (select count(*)::integer from public.online_booking_log
                                  where shop_id = tests.fx('shop_a') and user_id is not null)) g;
select tests.authenticate_as(tests.fx('u_sam'));
select pg_temp.from_ip('198.51.100.35');
select tests.throws_like($$select public.create_online_booking('shop-a', pg_temp.booking(jsonb_build_object(
                  'customer', jsonb_build_object('first_name', 'Sam', 'email', 'sam@example.com'),
                  'service_ids', jsonb_build_array(tests.fx('svc_wash')),
                  'starts_at', (select starts_at from wash_slots where n = 23))))$$,
                         'PT429', '%receiving too many online bookings%', 'signed-in bookings have a daily cap of their own');
select tests.as_superuser();
select tests.eq((select count(*) from public.online_booking_log where shop_id = tests.fx('shop_a')
                    and created_at > now() - interval '24 hours'), 200::bigint,
                'at most 100 anonymous + 100 signed-in bookings a day');

-- ============================================================ the log is internal
select tests.as_anon();
select tests.throws($$select count(*) from public.online_booking_log$$, '42501', 'anon cannot read the booking log');
select tests.throws($$insert into public.online_booking_log (shop_id) values (tests.fx('shop_a'))$$, '42501',
                    'anon cannot write it');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.throws($$select count(*) from public.online_booking_log$$, '42501', 'nor can the shop''s owner read it');
select tests.throws($$delete from public.online_booking_log$$, '42501', 'or clear it to lift the limit');
select tests.as_anon();
select tests.throws($$select public.integration_online_booking_created(tests.fx('job_a'))$$, '42501',
                    'the booking side effects are not callable by clients');
