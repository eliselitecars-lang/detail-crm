-- 100 billing: a lapsed shop's online booking is unavailable — the existing
-- 55000 path of create_online_booking (anon, signed-in client, service),
-- public_booking_slots / get_available_slots, public_booking_catalog,
-- public_booking_link, public_shop_profile's booking flag and tracking ids,
-- quote self-scheduling — while an active shop books as before, and
-- renewing brings it back. Unknown slugs still answer PT404.
\ir fixtures/two_shops.psql
\ir fixtures/40_booking_setup.psql

select tests.as_superuser();
update public.booking_settings set meta_pixel_id = '123456789012345', quote_self_schedule = true where shop_id = tests.fx('shop_a');
insert into public.booking_links (shop_id, name, service_ids) values (tests.fx('shop_a'), 'VIP', array[tests.fx('svc_hidden')])
  returning tests.fx_set('link_a', token);
insert into public.quotes (shop_id, customer_id) values (tests.fx('shop_a'), tests.fx('cust_a')) returning tests.fx_set('quote_a', id);
select tests.fx_set('u_client', tests.create_user('client@test.local'));

create function pg_temp.book(p_slug text default 'shop-a', p_n integer default 1) returns jsonb language sql as $$
  -- guest n books 10:00 CDT on June 10 + n (own email, own day: no limit or capacity clash)
  select public.create_online_booking(p_slug,
           jsonb_set(jsonb_set(pg_temp.booking(), '{customer,email}', to_jsonb('guest' || p_n || '@example.com')),
                     '{starts_at}', to_jsonb('2025-06-' || (10 + p_n)::text || 'T15:00:00Z')),
           '2025-06-01 12:00Z') $$;
create function pg_temp.self_schedule_reason() returns text language sql as $$
  select public.quote_self_schedule_reason(jsonb_populate_record(q, '{"status": "approved", "self_schedule": true}'))
    from public.quotes q where q.id = tests.fx('quote_a') $$;
grant execute on function pg_temp.book(text, integer), pg_temp.self_schedule_reason() to anon, authenticated, service_role;

-- ============================================================ billing on, shop A active: booking works
select tests.as_service();
select public.set_billing_config(true, 0);
update public.shop_billing set status = 'active', current_period_end = now() + interval '20 days' where shop_id = tests.fx('shop_a');
select tests.ok((pg_temp.book('shop-a', 1) ->> 'job_token') is not null, 'an active shop takes online bookings');
select tests.ok((select count(*) from public.public_booking_slots('shop-a', array[tests.fx('svc_a')], '2025-06-10', '2025-06-10',
                                                                  null, null, null, '2025-06-01 12:00Z')) > 0, 'and offers slots');
select tests.ok(pg_temp.self_schedule_reason() is null, 'an approved quote can be scheduled online');
select tests.as_anon();
select tests.eq(public.public_shop_profile('shop-a') #> '{booking,enabled}', 'true'::jsonb, 'profile: booking enabled');

-- ============================================================ shop A lapses
select tests.as_service();
update public.shop_billing set status = 'canceled', current_period_end = now() - interval '1 minute' where shop_id = tests.fx('shop_a');

select tests.throws_like($$select pg_temp.book('shop-a', 2)$$, '55000', 'online booking is not enabled for this shop',
                         'lapsed: create_online_booking answers 55000 (service_role too)');
select tests.throws($$select * from public.public_booking_slots('shop-a', array[tests.fx('svc_a')], '2025-06-10', '2025-06-10',
                                                                null, null, null, '2025-06-01 12:00Z')$$, '55000', 'public_booking_slots');
select tests.as_anon();
select tests.throws_like($$select public.create_online_booking('shop-a', pg_temp.booking())$$, '55000', '%not enabled%',
                         'anon: create_online_booking');
select tests.throws($$select * from public.get_available_slots('shop-a', array[tests.fx('svc_a')], current_date + 3, current_date + 3)$$,
                    '55000', 'anon: get_available_slots');
select tests.throws($$select public.public_booking_catalog('shop-a')$$, '55000', 'anon: public_booking_catalog');
select tests.throws($$select public.public_booking_link(tests.fx('link_a'))$$, '55000', 'anon: a private booking link');
select tests.eq((select jsonb_build_array(p #> '{booking,enabled}', p #> '{tracking,meta_pixel_id}', p -> 'name')
                   from public.public_shop_profile('shop-a') p),
                '[false, null, "Shop A"]'::jsonb, 'profile: booking disabled, no tracking ids, the rest unchanged');
select tests.throws($$select public.create_online_booking('no-such-shop', pg_temp.booking())$$, 'PT404', 'an unknown slug is still PT404');
select tests.authenticate_as(tests.fx('u_client'));
select tests.throws($$select public.create_online_booking('shop-a', pg_temp.booking())$$, '55000',
                    'a signed-in client gets the same answer (never PT402)');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$select public.create_online_booking('shop-a', pg_temp.booking())$$, '55000', 'so does staff of the shop');
select tests.as_superuser();
select tests.eq(pg_temp.self_schedule_reason(), 'online scheduling is not available; please contact the shop',
                'quotes cannot be scheduled online');
select tests.eq((select count(*) from public.jobs where shop_id = tests.fx('shop_a') and source = 'online_booking'), 1::bigint,
                'no booking was created while lapsed');

-- another shop is unaffected
select tests.as_anon();
select tests.eq(public.public_shop_profile('shop-b') #> '{booking,enabled}', 'false'::jsonb,
                'shop B (lapsed too: never subscribed) reads disabled');
select tests.as_service();
update public.shop_billing set status = 'trialing', trial_ends_at = now() + interval '3 days' where shop_id = tests.fx('shop_b');
select tests.as_anon();
select tests.eq(public.public_shop_profile('shop-b') #> '{booking,enabled}', 'true'::jsonb, 'a trialing shop takes bookings');
select tests.lives($$select public.public_booking_catalog('shop-b')$$, 'catalog of the trialing shop');

-- ============================================================ renewing brings it back
select tests.as_service();
update public.shop_billing set status = 'active', current_period_end = now() + interval '30 days' where shop_id = tests.fx('shop_a');
select tests.ok((pg_temp.book('shop-a', 3) ->> 'job_token') is not null, 'renewed: bookings again');
select tests.as_anon();
select tests.lives($$select public.public_booking_link(tests.fx('link_a'))$$, 'the private link works again');
select tests.eq(public.public_shop_profile('shop-a') #> '{tracking,meta_pixel_id}', '"123456789012345"'::jsonb, 'tracking ids back');

-- ============================================================ billing off: the lapsed standing is ignored
select tests.as_service();
update public.shop_billing set status = 'canceled', current_period_end = now() - interval '1 minute' where shop_id = tests.fx('shop_a');
select public.set_billing_config(false, 0);
select tests.ok((pg_temp.book('shop-a', 4) ->> 'job_token') is not null, 'billing off: bookings whatever the row says');
select tests.as_anon();
select tests.eq(public.public_shop_profile('shop-a') #> '{booking,enabled}', 'true'::jsonb, 'and the profile says enabled');

-- ============================================================ the wrapped function
select tests.as_superuser();
select tests.ok(not has_function_privilege('anon', 'public.create_online_booking_core(text, jsonb, timestamptz)', 'execute')
                and not has_function_privilege('authenticated', 'public.create_online_booking_core(text, jsonb, timestamptz)', 'execute')
                and has_function_privilege('anon', 'public.create_online_booking(text, jsonb, timestamptz)', 'execute'),
                'the 0054 body is internal; the public entry point keeps its grants');
