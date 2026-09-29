-- 120 (0122): coupon codes on the public booking page are attempt-limited.
-- public_validate_coupon looks a code up only while the connection (an IPv4
-- address or IPv6 /64) has tried fewer than 10 different unknown codes in
-- the shop in the last hour and the shop fewer than 200 from everyone;
-- past that it answers valid=false 'too many coupon codes were tried ...'
-- without looking (a code the connection already looked up is still
-- answered). create_online_booking takes a coupon code only after the
-- connection looked it up, so the booking is no way around the limit.
\ir fixtures/two_shops.psql
\ir fixtures/40_booking_setup.psql

select tests.as_superuser();
update public.booking_settings set max_concurrent_jobs = 100 where shop_id = tests.fx('shop_a');
-- a code the shop never published (staff / in-person use)
insert into public.coupons (shop_id, code, kind, value, description)
  values (tests.fx('shop_a'), 'STAFF50', 'percent', 5000, 'Staff discount') returning tests.fx_set('cp_staff', id);

create function pg_temp.check(p_code text) returns jsonb language sql as $$
  select public.public_validate_coupon('shop-a', p_code, array[tests.fx('svc_a')], tests.fx('cat_car_a'))
$$;
create function pg_temp.answer(p_code text) returns text language sql as $$
  select case when (r ->> 'valid')::boolean then 'valid' else r ->> 'message' end from pg_temp.check(p_code) r
$$;
create function pg_temp.from_ip(p_ip text) returns void language sql as $$
  select set_config('request.headers', jsonb_build_object('x-forwarded-for', p_ip)::text, true)
$$;
create function pg_temp.book(p_day integer, p_code text) returns text language plpgsql as $$
begin
  perform public.create_online_booking('shop-a', pg_temp.booking(jsonb_build_object(
            'customer', jsonb_build_object('first_name', 'Nina', 'last_name', 'New', 'email', 'nina@example.com'),
            'service_ids', jsonb_build_array(tests.fx('svc_wash')),
            'starts_at', ((now() at time zone 'America/Chicago')::date + p_day)::text || 'T10:00:00',
            'coupon_code', p_code)));
  return 'booked';
exception when others then
  return sqlstate || ': ' || sqlerrm;
end $$;
grant execute on function pg_temp.check(text), pg_temp.answer(text), pg_temp.from_ip(text), pg_temp.book(integer, text)
  to anon, authenticated;

\set limit_msg 'too many coupon codes were tried; please try again later'

-- ============================================================ one connection
select tests.as_anon();
select pg_temp.from_ip('198.51.100.1');
select tests.eq(pg_temp.answer('SAVE10'), 'valid', 'a published code');
select tests.eq((pg_temp.check('') ->> 'message'), 'this coupon code is not valid', 'an empty code (plain price preview)');
select tests.eq(pg_temp.answer('bad code!'), 'this coupon code is not valid', 'a malformed code');
select tests.eq((select array_agg(pg_temp.answer('GUESS' || i) order by i) from generate_series(1, 10) i),
                array_fill('this coupon code is not valid'::text, array[10]), '10 unknown codes are answered');
select tests.as_superuser();
select tests.eq((select jsonb_build_array(count(*), count(*) filter (where found), count(distinct client_scope))
                   from public.coupon_code_attempts where shop_id = tests.fx('shop_a')),
                '[11, 1, 1]'::jsonb, 'each lookup is recorded (not the empty or malformed code)');
select tests.ok((select bool_and(code_hash ~ '^[0-9a-f]{64}$') from public.coupon_code_attempts), 'codes are kept only as hashes');

select tests.as_anon();
select pg_temp.from_ip('198.51.100.1');
select tests.eq(pg_temp.answer('GUESS11'), :'limit_msg', 'the 11th unknown code is not looked up');
select tests.eq(pg_temp.check('STAFF50') - array['subtotal_cents', 'discount_cents', 'tax_cents', 'total_cents'],
                jsonb_build_object('valid', false, 'message', :'limit_msg', 'code', 'STAFF50', 'kind', null, 'value', null,
                                   'description', null, 'eligible_service_ids', '[]'::jsonb, 'restrictions_text', null),
                'an unpublished code gets the same answer: nothing is learned');
select tests.eq((pg_temp.check('STAFF50') ->> 'total_cents')::bigint, 22000::bigint, 'the price preview still works (undiscounted)');
select tests.eq(pg_temp.answer('SAVE10'), 'valid', 'a code this connection already looked up is still answered');
select tests.eq(pg_temp.answer('GUESS3'), 'this coupon code is not valid', 'so is a re-check of a code already tried');
select tests.eq(pg_temp.answer(''), 'this coupon code is not valid', 'and the plain preview');
-- an IPv6 client counts by its /64
select pg_temp.from_ip('2001:db8:1:2::1');
select tests.eq((select count(*) from generate_series(1, 10) i where pg_temp.answer('V6GUESS' || i) = 'this coupon code is not valid'),
                10::bigint, 'a v6 client gets its own allowance');
select pg_temp.from_ip('2001:db8:1:2:aaaa:bbbb:cccc:dddd');
select tests.eq(pg_temp.answer('STAFF50'), :'limit_msg', 'another address in the same /64 shares it');

-- another connection is unaffected
select pg_temp.from_ip('198.51.100.2');
select tests.eq(pg_temp.answer('STAFF50'), 'valid', 'a different connection looks the code up');
-- another shop is unaffected
select pg_temp.from_ip('198.51.100.1');
select tests.eq((public.public_validate_coupon('shop-b', 'SAVE10', array[tests.fx('svc_b')]) ->> 'valid'), 'true',
                'the limit is per shop');

-- an hour later the connection may try again
select tests.as_superuser();
update public.coupon_code_attempts set created_at = created_at - interval '61 minutes'
 where shop_id = tests.fx('shop_a') and client_scope = '198.51.100.1'::inet;
select tests.as_anon();
select pg_temp.from_ip('198.51.100.1');
select tests.eq(pg_temp.answer('GUESS12'), 'this coupon code is not valid', 'the hourly allowance comes back');

-- ============================================================ the shop-wide cap (many connections)
select tests.as_superuser();
insert into public.coupon_code_attempts (shop_id, client_scope, code_hash, found)
select tests.fx('shop_a'), ('10.0.' || (i / 250) || '.' || (i % 250))::inet, public.coupon_code_attempt_hash(tests.fx('shop_a'), 'SPRAY' || i), false
  from generate_series(1, 200) i;
select tests.as_anon();
select pg_temp.from_ip('198.51.100.3');
select tests.eq(pg_temp.answer('STAFF50'), :'limit_msg', '200 unknown codes from everyone in an hour: codes wait');
select pg_temp.from_ip('198.51.100.2');
select tests.eq(pg_temp.answer('STAFF50'), 'valid', 'a connection that already looked the code up is still answered');
select tests.as_superuser();
update public.coupon_code_attempts set created_at = created_at - interval '61 minutes' where code_hash in
  (select public.coupon_code_attempt_hash(tests.fx('shop_a'), 'SPRAY' || i) from generate_series(1, 200) i);

-- ============================================================ the booking is no way around it
select tests.as_anon();
select pg_temp.from_ip('198.51.100.1');
select tests.eq(pg_temp.book(10, 'STAFF50'),
                '22023: enter the coupon code again on the booking page, or book without it',
                'a known code this connection never looked up is not taken');
select tests.eq(pg_temp.book(10, 'NOSUCH1'), pg_temp.book(10, 'STAFF50'), 'the same answer as an unknown code');
select tests.eq(pg_temp.book(10, 'GUESS12'), pg_temp.book(10, 'STAFF50'), '... or a code it tried that does not exist');
select tests.eq(pg_temp.book(10, 'save10'), 'booked', 'a code it looked up books (any case)');
select pg_temp.from_ip('198.51.100.2');
select tests.eq(pg_temp.book(11, 'STAFF50'), 'booked', 'the connection that looked STAFF50 up can book with it');
select tests.eq(pg_temp.book(12, null), 'booked', 'no code: no check');
-- without a known connection (server-side callers) the booking is as before
select set_config('request.headers', '', true);
select tests.eq(pg_temp.book(13, 'FIXED25'), 'booked', 'no client address: unchanged');

-- ============================================================ privacy
select tests.throws($$select * from public.coupon_code_attempts$$, '42501', 'anon cannot read the attempts');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.throws($$select * from public.coupon_code_attempts$$, '42501', 'nor can staff');
select tests.throws($$select public.coupon_code_lookup_allowed(tests.fx('shop_a'), null, 'x')$$, '42501', 'nor call the helpers');
