-- 90 integration: account_deletion_blockers — before an account is deleted
-- (App Store 5.1.1(v)) the client learns which shops the caller owns: an
-- owner cannot be deleted until ownership moves or the shop is deleted.
\ir fixtures/two_shops.psql

-- the owner of shop A also owns a second shop
select tests.fx_set('shop_c', tests.make_shop('owner-a@test.local', 'shop-c', 'Alpha Detailing'));

select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.eq(public.account_deletion_blockers(),
                jsonb_build_object('owned_shops', jsonb_build_array(
                  jsonb_build_object('shop_id', tests.fx('shop_c'), 'name', 'Alpha Detailing'),
                  jsonb_build_object('shop_id', tests.fx('shop_a'), 'name', 'Shop A'))),
                'an owner lists every shop they own, by name');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(public.account_deletion_blockers(), '{"owned_shops": []}'::jsonb, 'a technician owns nothing');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.eq(public.account_deletion_blockers(), '{"owned_shops": []}'::jsonb, 'an admin is not an owner');
select tests.authenticate_as(tests.fx('u_outsider'));
select tests.eq(public.account_deletion_blockers(), '{"owned_shops": []}'::jsonb, 'a client / user without shops');
select tests.authenticate_as(tests.fx('u_owner_b'));
select tests.eq(public.account_deletion_blockers() -> 'owned_shops' -> 0 ->> 'name', 'Shop B', 'only the caller''s own shops');
select tests.eq(jsonb_array_length(public.account_deletion_blockers() -> 'owned_shops'), 1, 'never another owner''s');

-- after a transfer the old owner is no longer blocked by that shop, and can be deleted
select tests.authenticate_as(tests.fx('u_owner_a'));
select public.transfer_ownership(tests.fx('shop_a'), tests.fx('m_admin_a'));
select tests.eq(public.account_deletion_blockers() -> 'owned_shops',
                jsonb_build_array(jsonb_build_object('shop_id', tests.fx('shop_c'), 'name', 'Alpha Detailing')),
                'a transferred shop no longer blocks');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.eq(public.account_deletion_blockers() -> 'owned_shops' -> 0 ->> 'name', 'Shop A', 'the new owner is now blocked by it');
select tests.as_superuser();
select tests.throws_like($$delete from auth.users where id = tests.fx('u_owner_a')$$, '23514', '%owner membership%',
                         'the database agrees: an owner (of shop C) cannot be deleted');
select tests.as_service();  -- payments delete_shop (0117)
delete from public.shops where id = tests.fx('shop_c');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.eq(public.account_deletion_blockers(), '{"owned_shops": []}'::jsonb, 'no blockers once the last owned shop is deleted');
select tests.as_superuser();
select tests.lives($$delete from auth.users where id = tests.fx('u_owner_a')$$, 'then the account can be deleted');

-- ------------------------------------------------------------ access
select tests.as_anon();
select tests.throws($$select public.account_deletion_blockers()$$, '42501', 'anon cannot execute');
select tests.as_service();
select tests.throws($$select public.account_deletion_blockers()$$, '42501', 'service_role has no caller (and no grant)');
select tests.as_superuser();
select tests.ok(has_function_privilege('authenticated', 'public.account_deletion_blockers()', 'execute')
                and not has_function_privilege('anon', 'public.account_deletion_blockers()', 'execute')
                and not has_function_privilege('service_role', 'public.account_deletion_blockers()', 'execute'),
                'granted to authenticated only');
select tests.ok((select prosecdef and provolatile = 's' and proconfig @> array['search_path=""']
                   from pg_proc where oid = 'public.account_deletion_blockers()'::regprocedure),
                'STABLE SECURITY DEFINER with an empty search_path');
