-- 120 (0120): the in-app free trial is given once per person, not once per
-- shop. An owner whose trial lapsed cannot get another one by creating a new
-- shop, by deleting the lapsed shop and re-creating it under the same slug,
-- or by deleting the account and signing up again with the same email (a
-- "+tag" variant included). Turning billing on records the trials it
-- starts, and the operator can clear a person's grant.
\ir fixtures/two_shops.psql

create function pg_temp.standing(p_shop uuid) returns text language sql as $$
  select s.state || '/' || s.reason from public.shop_billing_standing(p_shop) s $$;
create function pg_temp.trial_left(p_shop uuid) returns interval language sql as $$
  select trial_ends_at - now() from public.shop_billing where shop_id = p_shop $$;
create function pg_temp.grants(p_user uuid) returns bigint language sql as $$
  select count(*) from public.billing_trial_grants where user_id = p_user $$;
grant execute on function pg_temp.standing(uuid), pg_temp.trial_left(uuid), pg_temp.grants(uuid) to service_role;

-- ============================================================ turning billing on
select tests.as_service();
select public.set_billing_config(false, 0);
select public.set_billing_config(true, 14);
select tests.eq(pg_temp.trial_left(tests.fx('shop_a')), interval '14 days', 'existing shops still get the go-live trial');
select tests.eq(pg_temp.grants(tests.fx('u_owner_a')), 1::bigint, 'and the owner''s trial is recorded');
select tests.ok((select email_key = encode(sha256(convert_to('owner-a@test.local', 'UTF8')), 'hex') and trial_shop_id = tests.fx('shop_a')
                   from public.billing_trial_grants where user_id = tests.fx('u_owner_a')),
                'the grant keeps an email hash (not the address) and the shop');

-- an owner who had the go-live trial gets none on a new shop
select tests.fx_set('shop_a2', tests.make_shop('owner-a@test.local', 'shop-a-two', 'Shop A Two'));
select tests.as_service();
select tests.eq(pg_temp.trial_left(tests.fx('shop_a2')), null::interval, 'second shop of owner A: no trial');
select tests.eq(pg_temp.standing(tests.fx('shop_a2')), 'lapsed/no_subscription', 'it must subscribe to create work');

-- ============================================================ the repro: lapse, then a new shop
select tests.fx_set('u_eve', tests.create_user('eve@test.local'));
select tests.fx_set('shine1', tests.make_shop('eve@test.local', 'shine-co', 'Shine Co'));
select tests.as_service();
select tests.eq(pg_temp.trial_left(tests.fx('shine1')), interval '14 days', 'a first shop gets the trial');
select tests.eq(pg_temp.grants(tests.fx('u_eve')), 1::bigint, 'recorded against its creator');
update public.shop_billing set trial_ends_at = now() - interval '1 day' where shop_id = tests.fx('shine1');
select tests.authenticate_as(tests.fx('u_eve'));
select tests.eq((select jsonb_build_array(e ->> 'state', e -> 'can_write') from public.shop_entitlement(tests.fx('shine1')) e),
                '["lapsed", false]'::jsonb, 'the trial ended: lapsed');

select tests.fx_set('shine2', (public.create_shop('Shine Co', 'shine-co-2', 'America/Chicago')).id);
select tests.eq((select jsonb_build_array(e ->> 'state', e ->> 'reason', e -> 'can_write', e -> 'trial_ends_at')
                   from public.shop_entitlement(tests.fx('shine2')) e),
                '["lapsed", "no_subscription", false, null]'::jsonb, 'a new shop of the same owner starts without a trial');
select tests.as_service();
select tests.eq((public.billing_checkout_context(tests.fx('shine2'), tests.fx('u_eve')) -> 'trial_end'), 'null'::jsonb,
                'checkout carries no trial over');
select tests.eq(pg_temp.grants(tests.fx('u_eve')), 1::bigint, 'no second grant');

-- delete the lapsed shop and re-create it under the freed slug
select tests.as_superuser();
delete from public.shops where id in (tests.fx('shine1'), tests.fx('shine2'));
select tests.eq(pg_temp.grants(tests.fx('u_eve')), 1::bigint, 'the grant outlives the shop');
select tests.fx_set('shine3', tests.make_shop('eve@test.local', 'shine-co', 'Shine Co'));
select tests.as_service();
select tests.eq(pg_temp.standing(tests.fx('shine3')), 'lapsed/no_subscription', 'same slug again: still no trial');

-- delete the account, sign up again with the same address (+tag, other case)
select tests.as_superuser();
delete from public.shops where id = tests.fx('shine3');
delete from auth.users where id = tests.fx('u_eve');
select tests.eq((select count(*) from public.billing_trial_grants where user_id is null and trial_shop_id is not null
                   and email_key = public.billing_trial_email_key('eve@test.local')), 1::bigint,
                'the account is gone; its email hash stays');
select tests.fx_set('shine4', tests.make_shop('Eve+again@Test.local', 'shine-co', 'Shine Co'));
select tests.as_service();
select tests.eq(pg_temp.standing(tests.fx('shine4')), 'lapsed/no_subscription', 'a re-registered address gets no new trial');

-- ============================================================ other people are unaffected
select tests.fx_set('fresh', tests.make_shop('fresh@test.local', 'fresh-shop', 'Fresh'));
select tests.as_service();
select tests.eq(pg_temp.trial_left(tests.fx('fresh')), interval '14 days', 'a new owner gets the trial');
select tests.eq(pg_temp.standing(tests.fx('fresh')), 'trialing/trial', 'and can work');
-- an invited member who never owned a shop gets a trial on their own shop
select tests.fx_set('tech_shop', tests.make_shop('tech-a@test.local', 'tech-own', 'Tech Own'));
select tests.as_service();
select tests.eq(pg_temp.trial_left(tests.fx('tech_shop')), interval '14 days', 'a team member''s own first shop gets it');

-- a shop created without a creator (operator SQL) is seeded as before
select tests.as_superuser();
insert into public.shops (name, slug, timezone) values ('Ops', 'ops-shop', 'UTC') returning tests.fx_set('ops', id);
select tests.eq(pg_temp.trial_left(tests.fx('ops')), interval '14 days', 'no creator: the trial as before');

-- billing off: no trial and no grant (as before)
select tests.as_service();
select public.set_billing_config(false, 14);
select tests.fx_set('off_shop', tests.make_shop('offline@test.local', 'off-shop', 'Off'));
select tests.as_service();
select tests.eq(pg_temp.trial_left(tests.fx('off_shop')), null::interval, 'billing off: no trial');
select tests.eq(pg_temp.grants(tests.user_id('offline@test.local')), 0::bigint, 'and no grant');
-- switching on starts that shop's trial and records it
select public.set_billing_config(true, 7);
select tests.eq(pg_temp.trial_left(tests.fx('off_shop')), interval '7 days', 'go-live trial');
select tests.eq(pg_temp.grants(tests.user_id('offline@test.local')), 1::bigint, 'recorded');

-- the operator can allow another trial by deleting the grant
delete from public.billing_trial_grants where user_id = tests.fx('u_owner_a');
select tests.fx_set('shop_a3', tests.make_shop('owner-a@test.local', 'shop-a-three', 'Shop A Three'));
select tests.as_service();
select tests.eq(pg_temp.trial_left(tests.fx('shop_a3')), interval '7 days', 'grant cleared: a trial again');

-- ============================================================ privacy
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.throws($$select * from public.billing_trial_grants$$, '42501', 'owners cannot read the grants');
select tests.throws($$select public.billing_trial_already_given(tests.fx('u_owner_a'))$$, '42501', 'nor call the check');
select tests.as_anon();
select tests.throws($$select * from public.billing_trial_grants$$, '42501', 'anon cannot read the grants');
