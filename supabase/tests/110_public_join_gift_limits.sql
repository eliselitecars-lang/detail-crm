-- 110 public sales abuse limits (0110): the membership join page and the
-- online gift card page are capped per connection (the visitor's IP the
-- payments edge function passes as p_client_ip; an IPv6 /64) and per shop,
-- counting only attempts that were not paid; a join creates a lead without
-- marketing consent, which it gets (and becomes a customer) once paid.
\ir fixtures/two_shops.psql

select tests.as_superuser();
insert into public.membership_plans (shop_id, name, price_cents, interval, interval_count, online_joinable)
  values (tests.fx('shop_a'), 'Club', 4000, 'month', 1, true) returning tests.fx_set('club', id);
update public.gift_card_settings set online_enabled = true, allow_custom_amount = true, min_custom_cents = 1000,
                                     max_custom_cents = 50000
 where shop_id = tests.fx('shop_a');

create function pg_temp.join_(p_n integer, p_ip text, p_extra jsonb default '{}') returns jsonb language sql as $$
  select public.membership_join_prepare('shop-a', tests.fx('club'),
           jsonb_build_object('customer', jsonb_build_object('first_name', 'Spam', 'email', 'x' || p_n || '@example.com',
                                                             'email_opt_in', true) || p_extra,
                              'vehicle', jsonb_build_object('make', 'Fake', 'model', 'Car')),
           now(), p_ip::inet) $$;
create function pg_temp.gift(p_n integer, p_ip text) returns jsonb language sql as $$
  select public.gift_card_order_prepare('shop-a', jsonb_build_object('amount_cents', 5000,
           'purchaser', jsonb_build_object('name', 'Pat', 'email', 'pat' || p_n || '@example.com'),
           'recipient', jsonb_build_object('email', 'sam' || p_n || '@example.com')), now(), p_ip::inet) $$;
grant execute on function pg_temp.join_(integer, text, jsonb), pg_temp.gift(integer, text) to service_role;

-- ============================================================ joins: per connection
select tests.as_service();
select pg_temp.join_(i, '203.0.113.7') from generate_series(1, 10) as i;
select tests.throws_like($$select pg_temp.join_(11, '203.0.113.7')$$, 'PT429', '%from this connection%',
                         'the 11th unpaid join from one address in a day is refused');
select tests.throws_like($$select pg_temp.join_(12, '::ffff:203.0.113.7')$$, 'PT429', '%from this connection%',
                         'the same IPv4 client seen through an IPv6 socket is the same connection');
select tests.lives($$select pg_temp.join_(13, '198.51.100.20')$$, 'another address still joins');
-- IPv6: the /64 is one connection
select pg_temp.join_(100 + i, '2001:db8:1:2::' || to_hex(i)) from generate_series(1, 10) as i;
select tests.throws_like($$select pg_temp.join_(200, '2001:db8:1:2:ffff::1')$$, 'PT429', '%from this connection%',
                         'rotating the interface id of one IPv6 /64 does not reset the allowance');
select tests.lives($$select pg_temp.join_(201, '2001:db8:1:3::1')$$, 'another /64 joins');

select tests.as_superuser();
select tests.eq((select count(*) from public.membership_join_log where shop_id = tests.fx('shop_a')), 22::bigint,
                'one log row per accepted join (refused ones leave none)');
select tests.eq((select client_ip from public.membership_join_log l
                  join public.customers c on c.id = l.customer_id where c.email = 'x13@example.com'),
                '198.51.100.20'::inet, 'the exact address is recorded');

-- ============================================================ a join creates a lead without consent
select tests.eq((select count(*) from public.customers
                  where shop_id = tests.fx('shop_a') and first_name = 'Spam'
                    and (lifecycle <> 'lead' or email_opt_in or sms_opt_in)), 0::bigint,
                'every customer a join created is a lead without email / text consent');
select tests.eq((select count(*) from public.customers
                  where shop_id = tests.fx('shop_a') and first_name = 'Spam' and lifecycle = 'lead'), 22::bigint,
                '22 leads');

-- a paid join frees its allowance, makes its customer a customer and applies the consent asked for
select tests.as_service();
select public.sync_stripe_subscription(tests.fx('shop_a'), 'sub_paid1',
         'active', now() + interval '30 days', false,
         (select m.id from public.memberships m join public.customers c on c.id = m.customer_id
           where c.email = 'x1@example.com'));
select tests.as_superuser();
select tests.ok((select lifecycle = 'customer' and email_opt_in and not sms_opt_in
                   from public.customers where shop_id = tests.fx('shop_a') and email = 'x1@example.com'),
                'paid: a customer, with the email consent the visitor asked for (no phone: no text consent)');
select tests.as_service();
select tests.lives($$select pg_temp.join_(14, '203.0.113.7')$$, 'the paid join no longer counts against its connection');
select tests.throws($$select pg_temp.join_(15, '203.0.113.7')$$, 'PT429', 'the connection is full again');

-- an existing customer the join matched is never given consent; a lead becomes a customer
select tests.as_superuser();
insert into public.customers (shop_id, first_name, email, phone, lifecycle, email_opt_in, sms_opt_in, phone_unverified)
  values (tests.fx('shop_a'), 'Lena', 'lena@example.com', '+12055550188', 'lead', false, false, false)
  returning tests.fx_set('lena', id);
select tests.as_service();
select public.membership_join_prepare('shop-a', tests.fx('club'),
         jsonb_build_object('customer', jsonb_build_object('first_name', 'Mallory', 'email', 'lena@example.com',
                                                           'phone', '+12055550188', 'email_opt_in', true, 'sms_opt_in', true)),
         now(), '192.0.2.44'::inet) as jl \gset
select tests.eq((:'jl'::jsonb ->> 'customer_id')::uuid, tests.fx('lena'), 'matched the existing lead');
select tests.eq((select array(select jsonb_object_keys(:'jl'::jsonb) order by 1)),
                array['customer_id', 'email', 'membership_id', 'shop_id'], 'the answer keeps its keys (nothing internal)');
select public.sync_stripe_subscription(tests.fx('shop_a'), 'sub_lena', 'active', now() + interval '30 days', false,
                                       (:'jl'::jsonb ->> 'membership_id')::uuid);
select tests.as_superuser();
select tests.ok((select lifecycle = 'customer' and first_name = 'Lena' and not email_opt_in and not sms_opt_in
                   from public.customers where id = tests.fx('lena')),
                'a matched customer becomes a customer when paid, and gets no consent from the visitor');

-- ============================================================ joins: per shop, and without an address
-- 78 more unpaid attempts from 78 addresses: the shop's 100 unpaid joins of the day
select tests.as_service();
select pg_temp.join_(1000 + i, '10.0.' || (i / 200)::text || '.' || (i % 200 + 1)::text) from generate_series(1, 78) as i;
select tests.as_superuser();
select tests.eq((select count(*) from public.membership_join_log l
                  where l.shop_id = tests.fx('shop_a')
                    and not exists (select 1 from public.memberships m where m.id = l.membership_id and m.started_at is not null)),
                100::bigint, '100 unpaid joins today');
select tests.as_service();
select tests.throws_like($$select pg_temp.join_(2000, '172.16.0.1')$$, 'PT429', '%too many membership sign-ups right now%',
                         'the shop cap: a fresh address is refused too');
select tests.throws_like($$select pg_temp.join_(2001, null)$$, 'PT429', '%right now%',
                         'without an address (older edge function) the shop cap still applies');
select tests.throws($$select public.membership_join_prepare('shop-b', gen_random_uuid(), '{}'::jsonb, now(), '172.16.0.1'::inet)$$,
                    '55000', 'another shop is not capped by shop A''s joins (it answers its own refusal)');

-- ============================================================ gift card orders
select tests.as_service();
select pg_temp.gift(i, '203.0.113.9') from generate_series(1, 10) as i;
select tests.throws_like($$select pg_temp.gift(11, '203.0.113.9')$$, 'PT429', '%gift card orders from this connection%',
                         'the 11th unpaid gift card order from one address is refused');
select tests.lives($$select pg_temp.gift(12, '203.0.113.10')$$, 'another address still orders');
select tests.as_superuser();
select tests.eq((select signer_ip from public.gift_card_orders where purchaser_email = 'pat12@example.com'),
                '203.0.113.10'::inet, 'the order records the visitor''s address');
-- a paid order no longer counts
update public.gift_card_orders set status = 'paid' where purchaser_email = 'pat1@example.com';
select tests.as_service();
select tests.lives($$select pg_temp.gift(13, '203.0.113.9')$$, 'a paid order frees its connection''s allowance');
select tests.throws($$select pg_temp.gift(14, '203.0.113.9')$$, 'PT429', 'full again');
-- the shop cap: 100 unpaid orders a day
select pg_temp.gift(100 + i, '10.1.' || (i / 200)::text || '.' || (i % 200 + 1)::text) from generate_series(1, 89) as i;
select tests.as_superuser();
select tests.eq((select count(*) from public.gift_card_orders where shop_id = tests.fx('shop_a') and status in ('pending', 'expired')),
                100::bigint, '100 unpaid orders today');
select tests.as_service();
select tests.throws_like($$select pg_temp.gift(500, '172.16.0.2')$$, 'PT429', '%too many gift card orders right now%',
                         'the shop cap');
select tests.throws($$select pg_temp.gift(501, null)$$, 'PT429', 'also without an address');
select tests.throws($$select public.gift_card_order_prepare('no-such-shop', '{}'::jsonb, now(), '172.16.0.2'::inet)$$, 'PT404',
                    'unknown shop: PT404');

-- ============================================================ access
select tests.as_anon();
select tests.throws($$select count(*) from public.membership_join_log$$, '42501', 'anon cannot read the join log');
select tests.throws($$select pg_temp.join_(3000, '1.2.3.4')$$, '42501', 'nor call the prepare functions');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.throws($$select count(*) from public.membership_join_log$$, '42501', 'nor can staff');
select tests.as_superuser();
select tests.ok(not has_function_privilege('anon', 'public.membership_join_prepare(text, uuid, jsonb, timestamptz, inet)', 'execute')
                and not has_function_privilege('authenticated', 'public.membership_join_prepare(text, uuid, jsonb, timestamptz, inet)', 'execute')
                and not has_function_privilege('anon', 'public.gift_card_order_prepare(text, jsonb, timestamptz, inet)', 'execute')
                and not has_function_privilege('authenticated', 'public.gift_card_order_prepare(text, jsonb, timestamptz, inet)', 'execute')
                and has_function_privilege('service_role', 'public.membership_join_prepare(text, uuid, jsonb, timestamptz, inet)', 'execute')
                and has_function_privilege('service_role', 'public.gift_card_order_prepare(text, jsonb, timestamptz, inet)', 'execute'),
                'the prepare functions stay service_role only');
