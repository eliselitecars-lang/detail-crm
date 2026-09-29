-- 131 (0131): public_billing_offer() — the plans exactly as
-- public_billing_plans() lists them, the trial length of a person's first
-- shop (billing_trial_days while billing is on, else 0) and, signed in,
-- whether a shop the caller creates now would get that trial (once per
-- person, 0120). public_billing_plans keeps its shape.
\ir fixtures/two_shops.psql

-- ============================================================ billing off
select tests.as_service();
select public.set_billing_config(false, 14);
select tests.as_anon();
select tests.eq(public.public_billing_offer(), '{"plans": [], "trial_days": 0, "trial_available": null}'::jsonb,
                'billing off: no plans and no trial, even with trial days configured');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.eq(public.public_billing_offer() -> 'trial_available', 'false'::jsonb,
                'signed in while billing is off: no trial to give');

-- ============================================================ billing on
select tests.as_service();
select public.billing_upsert_plan('price_SoloM', 'prod_Solo', 'Solo', null, 2900, 'usd', 'month', 1, 1, '{sms}', 1, true);
select public.billing_upsert_plan('price_TeamY', 'prod_Team', 'Team', 'For crews', 79000, 'usd', 'year', 1, 5, '{}', 2, true);
select public.set_billing_config(true, 14);

select tests.as_anon();
select tests.eq((select string_agg(k, ',' order by k) from jsonb_object_keys(public.public_billing_offer()) k),
                'plans,trial_available,trial_days', 'exactly the documented keys');
select tests.eq(public.public_billing_offer() -> 'plans', public.public_billing_plans(),
                'plans are public_billing_plans() unchanged');
select tests.eq(jsonb_array_length(public.public_billing_offer() -> 'plans'), 2, 'the active plans');
select tests.eq((select string_agg(k, ',' order by k) from jsonb_object_keys(public.public_billing_plans() -> 0) k),
                'amount_cents,currency,description,features,id,interval,interval_count,max_members,name',
                'public_billing_plans keeps its item shape');
select tests.eq(jsonb_typeof(public.public_billing_plans()), 'array', 'and stays an array');
select tests.eq(public.public_billing_offer() -> 'trial_days', '14'::jsonb, 'the configured trial length');
select tests.eq(public.public_billing_offer() -> 'trial_available', 'null'::jsonb, 'signed out: unknown');
select tests.ok(strpos(public.public_billing_offer()::text, 'price_') = 0 and strpos(public.public_billing_offer()::text, 'prod_') = 0,
                'never a Stripe id');

-- owner A's shop got the go-live trial when billing was turned on (0120)
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.eq(public.public_billing_offer() -> 'trial_available', 'false'::jsonb,
                'an owner who already had the trial: their next shop gets none');
select tests.eq(public.public_billing_offer() -> 'trial_days', '14'::jsonb, 'the length is still stated');

-- a person who never had a trial
select tests.fx_set('u_new', tests.create_user('newcomer@test.local'));
select tests.authenticate_as(tests.fx('u_new'));
select tests.eq(public.public_billing_offer() -> 'trial_available', 'true'::jsonb, 'a newcomer''s first shop gets it');
-- the same inbox under a +tag is the same person (billing_trial_email_key)
select tests.fx_set('u_alias', tests.create_user('owner-a+second@test.local'));
select tests.authenticate_as(tests.fx('u_alias'));
select tests.eq(public.public_billing_offer() -> 'trial_available', 'false'::jsonb,
                'a +tag of an address that had the trial gets none');

-- once the newcomer creates a shop, the offer changes for them only
select tests.fx_set('new_shop', tests.make_shop('newcomer@test.local', 'newcomer-shop', 'Newcomer'));
select tests.authenticate_as(tests.fx('u_new'));
select tests.eq(public.public_billing_offer() -> 'trial_available', 'false'::jsonb, 'after their first shop: used');
select tests.fx_set('u_other', tests.create_user('other-newcomer@test.local'));
select tests.authenticate_as(tests.fx('u_other'));
select tests.eq(public.public_billing_offer() -> 'trial_available', 'true'::jsonb, 'someone else still gets it');

-- no trial configured
select tests.as_service();
select public.set_billing_config(true, 0);
select tests.authenticate_as(tests.fx('u_other'));
select tests.eq(public.public_billing_offer() - 'plans', '{"trial_days": 0, "trial_available": false}'::jsonb,
                'trial length 0: no trial for anyone');

-- ============================================================ grants
select tests.as_superuser();
select tests.ok(has_function_privilege('anon', 'public.public_billing_offer()', 'execute')
                and has_function_privilege('authenticated', 'public.public_billing_offer()', 'execute')
                and has_function_privilege('service_role', 'public.public_billing_offer()', 'execute'),
                'anon, authenticated and the service role may call it');
select tests.ok(not has_function_privilege('public', 'public.public_billing_offer()', 'execute'),
                'not granted to public');
select tests.ok((select p.prosecdef and p.proconfig @> array['search_path=""']
                   from pg_proc p where p.oid = 'public.public_billing_offer()'::regprocedure),
                'security definer with an empty search_path');
