-- 90 integration: shop deletion — Twilio numbers bound to a deleted shop (or
-- unbound / moved) are logged in sms_number_releases for the operator; the
-- money guard still refuses to delete a shop whose memberships bill; the log
-- is service_role only.
\ir fixtures/two_shops.psql

select tests.as_superuser();
insert into public.shop_sms_numbers (phone_number, shop_id) values ('+12055550100', tests.fx('shop_a'));
insert into public.shop_sms_numbers (phone_number, shop_id) values ('+12055550101', tests.fx('shop_a'));
insert into public.shop_sms_numbers (phone_number, shop_id) values ('+12055550200', tests.fx('shop_b'));
update public.shops set sms_from_number = '+12055550100' where id = tests.fx('shop_a');

-- ------------------------------------------------------------ unbinding a number logs it
select tests.as_service();
delete from public.shop_sms_numbers where phone_number = '+12055550101';
select tests.eq((select jsonb_build_object('shop', shop_id = tests.fx('shop_a'), 'name', shop_name, 'at', released_at = now())
                   from public.sms_number_releases where phone_number = '+12055550101'),
                '{"shop": true, "name": "Shop A", "at": true}'::jsonb, 'an unbound number is logged with its shop');

-- ------------------------------------------------------------ the money guard still applies
select tests.authenticate_as(tests.fx('u_manager_b'));
insert into public.membership_plans (shop_id, name, price_cents) values (tests.fx('shop_b'), 'B Club', 3000) returning tests.fx_set('plan_b', id);
select tests.fx_set('mem_b', (public.create_membership(tests.fx('plan_b'), tests.fx('cust_b'))).id);
select tests.as_service();
select public.sync_stripe_subscription(tests.fx('shop_b'), 'sub_b1', 'active', '2030-01-01', false, tests.fx('mem_b'));
select tests.as_service();  -- payments delete_shop (0117)
select tests.throws_like($$delete from public.shops where id = tests.fx('shop_b')$$, '55000', '%not cancelled%',
                         'a shop whose memberships bill cannot be deleted (cancel them in Stripe first)');
select tests.as_superuser();
select tests.eq((select count(*) from public.sms_number_releases where phone_number = '+12055550200'), 0::bigint,
                'the refused delete logged nothing');
select tests.ok(exists (select 1 from public.shop_sms_numbers where phone_number = '+12055550200'), 'and kept the binding');

-- ------------------------------------------------------------ deleting a shop logs every bound number
select tests.as_service();  -- payments delete_shop (0117)
select tests.eq(tests.row_count($$delete from public.shops where id = tests.fx('shop_a')$$), 1::bigint, 'shop A is deleted');
select tests.as_superuser();
select tests.eq((select jsonb_agg(jsonb_build_object('number', phone_number, 'shop', shop_id = tests.fx('shop_a'), 'name', shop_name)
                                  order by phone_number, released_at)
                   from public.sms_number_releases where shop_id = tests.fx('shop_a')),
                '[{"number": "+12055550100", "shop": true, "name": "Shop A"},
                  {"number": "+12055550101", "shop": true, "name": "Shop A"}]'::jsonb,
                'the cascade logged the deleted shop''s number, with the shop''s name (it outlives the shop)');
select tests.ok(not exists (select 1 from public.shop_sms_numbers where shop_id = tests.fx('shop_a')), 'the binding is gone');
select tests.ok(not exists (select 1 from public.shops where id = tests.fx('shop_a')), 'the shop is gone');
select tests.eq((select count(*) from public.sms_number_releases where shop_id = tests.fx('shop_b')), 0::bigint,
                'shop B''s number is untouched');

-- a number moved to another shop is logged as released by the first
select tests.as_service();
delete from public.shop_sms_numbers where phone_number = '+12055550200';
insert into public.shop_sms_numbers (phone_number, shop_id) values ('+12055550200', tests.fx('shop_b'));
select tests.eq((select count(*) from public.sms_number_releases where phone_number = '+12055550200' and shop_name = 'Shop B'),
                1::bigint, 'moving a number (delete + insert) logs the release');

-- ------------------------------------------------------------ access: service_role only
select tests.ok((select count(*) from public.sms_number_releases) >= 3, 'service_role reads the worklist');
select tests.authenticate_as(tests.fx('u_owner_b'));
select tests.throws($$select * from public.sms_number_releases$$, '42501', 'owners cannot read it');
select tests.throws($$insert into public.sms_number_releases (phone_number, shop_id) values ('+12055550999', tests.fx('shop_b'))$$,
                    '42501', 'nor write it');
select tests.as_anon();
select tests.throws($$select * from public.sms_number_releases$$, '42501', 'anon cannot read it');
select tests.as_superuser();
select tests.ok((select relrowsecurity from pg_class where oid = 'public.sms_number_releases'::regclass), 'RLS is on');
select tests.eq((select count(*) from pg_policies where schemaname = 'public' and tablename = 'sms_number_releases'), 0::bigint,
                'with no policies');
select tests.ok(not has_function_privilege('authenticated', 'public.shop_sms_numbers_log_release()', 'execute'),
                'the trigger function is not an RPC');
