-- 90 integration: public_unsubscribe_info — what the /u/<token> page shows
-- before the visitor confirms: the shop's name and logo and whether the
-- address already unsubscribed. Anon may call it; only curated keys come
-- back (never the address, customer or message); unknown tokens are PT404.
\ir fixtures/two_shops.psql
-- marketing email carries the shop's postal address (0119: none on file = not sent)
update public.shops set address_line1 = '100 Main St', city = 'Birmingham', region = 'AL', postal_code = '35203'
 where id in (tests.fx('shop_a'), tests.fx('shop_b'));

select tests.as_superuser();
insert into public.platform_config (key, value) values ('app_base_url', 'https://app.example.test')
  on conflict (key) do update set value = excluded.value;
insert into storage.objects (bucket_id, name) values ('shop-assets', tests.fx('shop_a') || '/logo.png');
update public.shops set logo_path = tests.fx('shop_a') || '/logo.png' where id = tests.fx('shop_a');
update public.customers set email_opt_in = true where id = tests.fx('cust_a');
update public.booking_settings set enabled = true where shop_id = tests.fx('shop_a');
update public.message_templates set enabled = true where shop_id = tests.fx('shop_a') and key = 'follow_up';
-- a marketing email (follow_up) carries a fresh unsubscribe token
select tests.as_service();
select tests.fx_set('m_follow', public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'), 'follow_up', 'email',
                                                                 tests.fx('job_a')));
select tests.as_superuser();
select tests.fx_set('tok', (select unsubscribe_token from public.messages where id = tests.fx('m_follow')));
select tests.ok(tests.fx('tok') is not null, 'the marketing email has an unsubscribe token');
-- shop B: a token without a logo
insert into public.comms_unsubscribe_tokens (shop_id, token, address) values (tests.fx('shop_b'), gen_random_uuid(), 'bob@example.com')
  returning tests.fx_set('tok_b', token);

-- ------------------------------------------------------------ anon (the page is public)
select tests.as_anon();
select tests.eq(public.public_unsubscribe_info(tests.fx('tok')),
                jsonb_build_object('shop_name', 'Shop A', 'shop_logo_path', tests.fx('shop_a') || '/logo.png', 'unsubscribed', false,
                                   'scope', null, 'can_resubscribe', true),
                'shop name, logo path and state (0126: + scope, can_resubscribe)');
select tests.eq((select array_agg(k order by k) from jsonb_object_keys(public.public_unsubscribe_info(tests.fx('tok'))) k),
                array['can_resubscribe', 'scope', 'shop_logo_path', 'shop_name', 'unsubscribed'],
                'curated keys only (no address, customer or message)');
select tests.eq(public.public_unsubscribe_info(tests.fx('tok_b')),
                '{"shop_name": "Shop B", "shop_logo_path": null, "unsubscribed": false, "scope": null, "can_resubscribe": false}'::jsonb,
                'no logo: null; no customer has the address: nothing to resubscribe');
select tests.throws_like($$select public.public_unsubscribe_info(gen_random_uuid())$$, 'PT404', 'unsubscribe link not found',
                         'unknown token: PT404 (HTTP 404)');
select tests.throws_like($$select public.public_unsubscribe_info(null)$$, 'PT404', 'unsubscribe link not found', 'null token: PT404');
-- reading the info never unsubscribes (link scanners)
select tests.as_superuser();
select tests.ok(not public.comms_is_suppressed(tests.fx('shop_a'), 'email', 'alice@example.com'), 'still subscribed after reading');
select tests.as_anon();
select tests.eq(public.public_unsubscribe(tests.fx('tok')), true, 'the explicit button unsubscribes');
select tests.eq(public.public_unsubscribe_info(tests.fx('tok')) -> 'unsubscribed', 'true'::jsonb, 'then the page shows the done state');
select tests.eq(public.public_unsubscribe_info(tests.fx('tok')) ->> 'scope', 'marketing', 'from marketing only');
select tests.eq(public.public_unsubscribe_info(tests.fx('tok_b')) -> 'unsubscribed', 'false'::jsonb,
                'another shop''s address is unaffected');

-- ------------------------------------------------------------ signed-in users and service_role can call it too
select tests.authenticate_as(tests.fx('u_tech_b'));
select tests.eq(public.public_unsubscribe_info(tests.fx('tok')) ->> 'shop_name', 'Shop A', 'any signed-in user holding the link');
select tests.as_service();
select tests.eq(public.public_unsubscribe_info(tests.fx('tok')) ->> 'shop_name', 'Shop A', 'service_role');

-- the link keeps working after its customer (and message) is deleted
select tests.as_superuser();
delete from public.jobs where id = tests.fx('job_a');
delete from public.customers where id = tests.fx('cust_a');
select tests.ok(not exists (select 1 from public.messages where id = tests.fx('m_follow')), 'the email is gone with its customer');
select tests.as_anon();
select tests.eq(public.public_unsubscribe_info(tests.fx('tok')),
                jsonb_build_object('shop_name', 'Shop A', 'shop_logo_path', tests.fx('shop_a') || '/logo.png', 'unsubscribed', true,
                                   'scope', 'marketing', 'can_resubscribe', false),
                'the link still resolves (state is per address; nobody left to resubscribe)');

select tests.as_superuser();
select tests.ok(has_function_privilege('anon', 'public.public_unsubscribe_info(uuid)', 'execute')
                and has_function_privilege('authenticated', 'public.public_unsubscribe_info(uuid)', 'execute')
                and has_function_privilege('service_role', 'public.public_unsubscribe_info(uuid)', 'execute'),
                'granted to anon, authenticated and service_role');
select tests.ok((select prosecdef and provolatile = 's' and proconfig @> array['search_path=""']
                   from pg_proc where oid = 'public.public_unsubscribe_info(uuid)'::regprocedure),
                'STABLE SECURITY DEFINER with an empty search_path');
