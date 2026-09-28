-- 100 billing: the standing rules (billing_state, table-driven), set_billing_config
-- (validation, keys, trial backfill on the off -> on transition only, new
-- shops' trials, idempotency), plans (billing_upsert_plan validation and
-- upsert, billing_deactivate_plans_except, public_billing_plans: off = [],
-- order, curated keys, no Stripe ids), platform_plans / platform_config
-- access, and the grants of every billing function.
\ir fixtures/two_shops.psql

-- ============================================================ billing_state (pure)
create temp table cases (label text, enabled boolean, status text, trial timestamptz, period timestamptz,
                         comp timestamptz, expected text);
insert into cases values
  ('off: a fresh shop is active',                  false, 'none',     null,               null,               null,               'active/billing_off'),
  ('off: even an ended subscription is active',    false, 'canceled', null,               '2025-01-01Z',      null,               'active/billing_off'),
  ('off (null flag) counts as off',                null,  'none',     null,               null,               null,               'active/billing_off'),
  ('comp in the future wins',                      true,  'none',     null,               null,               '2026-02-01Z',      'comped/comped'),
  ('comp for good (infinity)',                     true,  'canceled', null,               '2025-01-01Z',      'infinity',         'comped/comped'),
  ('comp wins over an active subscription',        true,  'active',   null,               '2026-02-01Z',      '2026-01-20Z',      'comped/comped'),
  ('an ended comp no longer counts',               true,  'none',     null,               null,               '2026-01-01Z',      'lapsed/no_subscription'),
  ('comp ending right now has ended',              true,  'none',     null,               null,               '2026-01-15 12:00Z', 'lapsed/no_subscription'),
  ('active subscription',                          true,  'active',   null,               '2026-02-15Z',      null,               'active/subscribed'),
  ('active: an old trial end is irrelevant',       true,  'active',   '2025-12-01Z',      '2026-02-15Z',      null,               'active/subscribed'),
  ('Stripe trial',                                 true,  'trialing', '2026-01-20Z',      '2026-01-20Z',      null,               'trialing/subscription_trial'),
  ('past due can still write',                     true,  'past_due', null,               '2026-01-10Z',      null,               'past_due/past_due'),
  ('never subscribed, in-app trial running',       true,  'none',     '2026-01-16Z',      null,               null,               'trialing/trial'),
  ('never subscribed, trial over',                 true,  'none',     '2026-01-10Z',      null,               null,               'lapsed/trial_ended'),
  ('trial ending right now is over',               true,  'none',     '2026-01-15 12:00Z', null,              null,               'lapsed/trial_ended'),
  ('never subscribed, no trial',                   true,  'none',     null,               null,               null,               'lapsed/no_subscription'),
  ('no status reads as none',                      true,  null,       '2026-01-16Z',      null,               null,               'trialing/trial'),
  ('incomplete checkout inside the trial',         true,  'incomplete', '2026-01-16Z',    null,               null,               'trialing/trial'),
  ('incomplete checkout without a trial',          true,  'incomplete', null,             '2026-02-15Z',      null,               'lapsed/incomplete'),
  ('canceled, paid period still running',          true,  'canceled', null,               '2026-01-31Z',      null,               'active/period_remaining'),
  ('canceled, period over',                        true,  'canceled', null,               '2026-01-14Z',      null,               'lapsed/canceled'),
  ('canceled without a period end',                true,  'canceled', null,               null,               null,               'lapsed/canceled'),
  ('unpaid inside the period',                     true,  'unpaid',   null,               '2026-01-31Z',      null,               'active/period_remaining'),
  ('unpaid after the period',                      true,  'unpaid',   null,               '2026-01-01Z',      null,               'lapsed/unpaid'),
  ('incomplete_expired after the period',          true,  'incomplete_expired', null,     '2026-01-01Z',      null,               'lapsed/incomplete_expired'),
  ('paused inside the period',                     true,  'paused',   null,               '2026-01-31Z',      null,               'active/period_remaining'),
  ('paused after the period',                      true,  'paused',   null,               '2026-01-01Z',      null,               'lapsed/paused'),
  ('an unknown status is lapsed',                  true,  'weird',    '2026-02-01Z',      '2026-02-01Z',      null,               'lapsed/unknown_status');

select tests.eq(s.state || '/' || s.reason, c.expected, 'billing_state: ' || c.label)
  from cases c
  cross join lateral public.billing_state(c.enabled, c.status, c.trial, c.period, c.comp, '2026-01-15 12:00Z') s;
select tests.throws($$select public.billing_state(true, 'none', null, null, null, null)$$, '22023', 'the time to judge at is required');

-- ============================================================ config access and validation
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.throws($$select public.set_billing_config(true, 14)$$, '42501', 'an owner cannot switch billing');
select tests.throws($$select * from public.platform_config$$, '42501', 'nor read the platform config');
select tests.as_anon();
select tests.throws($$select public.set_billing_config(true, 14)$$, '42501', 'anon cannot switch billing');

select tests.as_service();
select tests.throws($$select public.set_billing_config(null, 0)$$, '22023', 'on or off is required');
select tests.throws($$select public.set_billing_config(true, null)$$, '22023', 'trial days are required');
select tests.throws($$select public.set_billing_config(true, -1)$$, '22023', 'no negative trial');
select tests.throws($$select public.set_billing_config(true, 731)$$, '22023', 'at most 730 trial days');
select tests.throws($$insert into public.platform_config (key, value) values ('billing_enabled', 'yes')
                      on conflict (key) do update set value = excluded.value$$, '23514', 'billing_enabled is true or false');
select tests.throws($$insert into public.platform_config (key, value) values ('billing_trial_days', '14 days')
                      on conflict (key) do update set value = excluded.value$$, '23514', 'billing_trial_days is a number');
select tests.throws($$insert into public.platform_config (key, value) values ('billing_trial_days', '900')
                      on conflict (key) do update set value = excluded.value$$, '23514', 'billing_trial_days at most 730');

-- ============================================================ every shop has its row
select tests.as_superuser();
select tests.eq((select count(*) from public.shop_billing where shop_id in (tests.fx('shop_a'), tests.fx('shop_b'))
                   and status = 'none' and trial_ends_at is null and not trial_used and plan_id is null
                   and stripe_customer_id is null and comp_until is null),
                2::bigint, 'shops created while billing is off: a row each, never subscribed, no trial');
select tests.ok(public.shop_can_write(tests.fx('shop_a')), 'billing off: the shop can write');

-- ============================================================ turning billing on starts the trials
select tests.as_service();
select public.set_billing_config(false, 0);
select tests.eq((select array_agg(key || '=' || value order by key) from public.platform_config
                  where key in ('billing_enabled', 'billing_trial_days')),
                array['billing_enabled=false', 'billing_trial_days=0'], 'keys written');
update public.shop_billing set status = 'active', stripe_customer_id = 'cus_ShopB1', stripe_subscription_id = 'sub_ShopB1',
                               current_period_end = now() + interval '20 days'
 where shop_id = tests.fx('shop_b');
select public.set_billing_config(true, 14);
select tests.eq((select array_agg(key || '=' || value order by key) from public.platform_config
                  where key in ('billing_enabled', 'billing_trial_days')),
                array['billing_enabled=true', 'billing_trial_days=14'], 'billing on, 14-day trial');
select tests.eq((select trial_ends_at from public.shop_billing where shop_id = tests.fx('shop_a')),
                now() + interval '14 days', 'a never-subscribed shop gets the trial from now');
select tests.eq((select trial_ends_at from public.shop_billing where shop_id = tests.fx('shop_b')), null::timestamptz,
                'a subscribed shop gets no in-app trial');
select tests.ok(public.shop_can_write(tests.fx('shop_a')) and public.shop_can_write(tests.fx('shop_b')),
                'trialing and active shops can write');

-- idempotent: calling again (the deploy runs it every time) changes nothing
update public.shop_billing set trial_ends_at = null where shop_id = tests.fx('shop_a');
select public.set_billing_config(true, 30);
select tests.eq((select trial_ends_at from public.shop_billing where shop_id = tests.fx('shop_a')), null::timestamptz,
                'a repeat call while billing is already on starts no trial');
select tests.eq((select value from public.platform_config where key = 'billing_trial_days'), '30', 'the new length is stored');
select tests.ok(not public.shop_can_write(tests.fx('shop_a')), 'no subscription and no trial: lapsed');
select tests.eq((select s.state || '/' || s.reason from public.shop_billing_standing(tests.fx('shop_a')) s),
                'lapsed/no_subscription', 'standing of the shop');

-- a shop created while billing is on gets the current trial length
select tests.fx_set('shop_c', tests.make_shop('owner-c@test.local', 'shop-c', 'Shop C'));
select tests.as_superuser();
select tests.eq((select trial_ends_at from public.shop_billing where shop_id = tests.fx('shop_c')),
                now() + interval '30 days', 'new shop: trial of billing_trial_days');
select tests.ok(public.shop_can_write(tests.fx('shop_c')), 'a new shop in its trial can write');

-- off -> on again: only shops that never had a trial start one
select tests.as_service();
select public.set_billing_config(false, 30);
select tests.ok(public.shop_can_write(tests.fx('shop_a')), 'billing off again: everyone can write');
select tests.fx_set('shop_d', tests.make_shop('owner-d@test.local', 'shop-d', 'Shop D'));
select tests.as_service();
select tests.eq((select trial_ends_at from public.shop_billing where shop_id = tests.fx('shop_d')), null::timestamptz,
                'a shop created while billing is off has no trial');
update public.shop_billing set trial_ends_at = now() - interval '1 day' where shop_id = tests.fx('shop_c');
select public.set_billing_config(true, 7);
select tests.eq((select array_agg(coalesce(trial_ends_at - now(), interval '0') order by s.slug)
                   from public.shop_billing b join public.shops s on s.id = b.shop_id
                  where b.shop_id in (tests.fx('shop_a'), tests.fx('shop_b'), tests.fx('shop_c'), tests.fx('shop_d'))),
                array[interval '7 days', interval '0', interval '-1 day', interval '7 days'],
                'on again: A (trial cleared) and D start 7 days; B (subscribed) and C (trial used up) do not');
select public.set_billing_config(false, 0);
update public.shop_billing set trial_ends_at = null where shop_id = tests.fx('shop_d');
select public.set_billing_config(true, 0);
select tests.eq((select trial_ends_at from public.shop_billing where shop_id = tests.fx('shop_d')), null::timestamptz,
                'turning billing on with 0 days starts no trial');

-- ============================================================ plans
-- (a shared database may hold real plans: they are retired inside this file's
-- transaction, so only this file's plans are active below)
select tests.as_superuser();
update public.platform_plans set active = false where active;
select tests.as_service();
select tests.throws($$select public.billing_upsert_plan('pr_1', 'prod_A', 'Pro', null, 1000, 'usd', 'month', 1, null, '{}', 0, true)$$,
                    '22023', 'price id must be a Stripe price id');
select tests.throws($$select public.billing_upsert_plan('price_1', 'product', 'Pro', null, 1000, 'usd', 'month', 1, null, '{}', 0, true)$$,
                    '22023', 'product id must be a Stripe product id');
select tests.throws($$select public.billing_upsert_plan('price_1', 'prod_A', '  ', null, 1000, 'usd', 'month', 1, null, '{}', 0, true)$$,
                    '22023', 'a name is required');
select tests.throws($$select public.billing_upsert_plan('price_1', 'prod_A', 'Pro', null, -1, 'usd', 'month', 1, null, '{}', 0, true)$$,
                    '22023', 'no negative amounts');
select tests.throws($$select public.billing_upsert_plan('price_1', 'prod_A', 'Pro', null, 1000, 'us', 'month', 1, null, '{}', 0, true)$$,
                    '22023', 'currency is an ISO code');
select tests.throws($$select public.billing_upsert_plan('price_1', 'prod_A', 'Pro', null, 1000, 'usd', 'week', 1, null, '{}', 0, true)$$,
                    '22023', 'monthly or yearly only');
select tests.throws($$select public.billing_upsert_plan('price_1', 'prod_A', 'Pro', null, 1000, 'usd', 'month', 0, null, '{}', 0, true)$$,
                    '22023', 'interval count at least 1');
select tests.throws($$select public.billing_upsert_plan('price_1', 'prod_A', 'Pro', null, 1000, 'usd', 'month', 1, 0, '{}', 0, true)$$,
                    '22023', 'max members at least 1');
select tests.throws($$select public.billing_upsert_plan('price_1', 'prod_A', 'Pro', null, 1000, 'usd', 'month', 1, null, '{Bad Key}', 0, true)$$,
                    '22023', 'features are lower-case keys');
select tests.throws($$select public.billing_upsert_plan('price_1', 'prod_A', 'Pro', null, 1000, 'usd', 'month', 1, null, array[null]::text[], 0, true)$$,
                    '22023', 'no empty features');

select tests.fx_set('plan_solo', public.billing_upsert_plan('price_SoloM', 'prod_Solo', ' Solo ', '  ', 2900, 'USD', 'month', 1, 1,
                                                            '{online_booking,sms,sms}', 1, null));
select tests.fx_set('plan_team', public.billing_upsert_plan('price_TeamM', 'prod_Team', 'Team', 'For crews', 7900, 'usd', 'month', null, 5,
                                                            '{}', 2, true));
select tests.fx_set('plan_team_y', public.billing_upsert_plan('price_TeamY', 'prod_Team', 'Team', 'For crews', 79000, 'usd', 'year', 1, 5,
                                                              null, 2, true));
select tests.fx_set('plan_old', public.billing_upsert_plan('price_OldM', 'prod_Old', 'Legacy', null, 1900, 'usd', 'month', 1, null,
                                                           '{}', 0, true));
select tests.ok((select name = 'Solo' and description is null and currency = 'usd' and interval_count = 1 and max_members = 1
                        and features = '{online_booking,sms}' and sort = 1 and active
                   from public.platform_plans where id = tests.fx('plan_solo')),
                'trimmed name, blank description = null, lower-case currency, duplicate features dropped, active by default');
select tests.ok((select interval_count = 1 and features = '{}' from public.platform_plans where id = tests.fx('plan_team')),
                'null interval count = 1; null features = none');
select tests.eq(public.billing_upsert_plan('price_TeamM', 'prod_Team', 'Team+', 'For crews', 8900, 'usd', 'month', 1, 6, '{sms}', 2, true),
                tests.fx('plan_team'), 'upsert by price keeps the plan id');
select tests.ok((select name = 'Team+' and amount_cents = 8900 and max_members = 6 and features = '{sms}'
                   from public.platform_plans where id = tests.fx('plan_team')), 'and updates its fields');
select tests.fx_set('plan_long', public.billing_upsert_plan('price_Long', 'prod_Long', repeat('x', 300), repeat('d', 3000), 100,
                                                            'usd', 'month', 1, null, '{}', 9, true));
select tests.eq((select char_length(name) from public.platform_plans where id = tests.fx('plan_long')), 200,
                'long names are cut to 200');
select tests.eq((select char_length(description) from public.platform_plans where stripe_price_id = 'price_Long'), 2000,
                'descriptions to 2000');

select tests.eq(public.billing_deactivate_plans_except(array['price_SoloM', 'price_TeamM', 'price_TeamY']), 2,
                'plans no longer listed are retired');
select tests.ok((select not active from public.platform_plans where id = tests.fx('plan_old')), 'Legacy retired');
select tests.eq(public.billing_deactivate_plans_except(array['price_SoloM', 'price_TeamM', 'price_TeamY']), 0, 'idempotent');
select tests.eq(public.billing_upsert_plan('price_OldM', 'prod_Old', 'Legacy', null, 1900, 'usd', 'month', 1, null, '{}', 0, true),
                tests.fx('plan_old'), 'a retired price listed again comes back');
select tests.eq(public.billing_deactivate_plans_except(array['price_SoloM', 'price_TeamM', 'price_TeamY']), 1, 'and can be retired again');

-- ============================================================ public_billing_plans
select tests.as_anon();
select tests.eq(jsonb_array_length(public.public_billing_plans()), 3, 'anon sees the three active plans');
select tests.eq((select array_agg(p ->> 'name' || ':' || (p ->> 'amount_cents') || '/' || (p ->> 'interval') order by o)
                   from jsonb_array_elements(public.public_billing_plans()) with ordinality as x(p, o)),
                array['Solo:2900/month', 'Team+:8900/month', 'Team:79000/year'], 'ordered by sort, then amount');
select tests.eq((select string_agg(k, ',' order by k) from jsonb_object_keys(public.public_billing_plans() -> 0) k),
                'amount_cents,currency,description,features,id,interval,interval_count,max_members,name',
                'exactly the documented keys');
select tests.ok(strpos(public.public_billing_plans()::text, 'price_') = 0 and strpos(public.public_billing_plans()::text, 'prod_') = 0,
                'never a Stripe id');
select tests.eq(public.public_billing_plans() -> 0 -> 'features', '["online_booking", "sms"]'::jsonb, 'features as a list');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(jsonb_array_length(public.public_billing_plans()), 3, 'any signed-in user may list them');
select tests.as_service();
select public.set_billing_config(false, 0);
select tests.as_anon();
select tests.eq(public.public_billing_plans(), '[]'::jsonb, 'billing off: no plans are offered');

-- ============================================================ no direct client access to plans
select tests.as_anon();
select tests.throws($$select * from public.platform_plans$$, '42501', 'anon cannot read platform_plans');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.throws($$select id from public.platform_plans$$, '42501', 'an owner cannot read platform_plans directly');
select tests.throws($$update public.platform_plans set amount_cents = 0$$, '42501', 'nor change a price');
select tests.throws($$insert into public.platform_plans (stripe_price_id, stripe_product_id, name, amount_cents, currency, interval)
                      values ('price_Mine', 'prod_Mine', 'Free', 0, 'usd', 'month')$$, '42501', 'nor add a plan');
select tests.as_service();
select tests.eq((select count(*) from public.platform_plans
                  where stripe_price_id in ('price_SoloM', 'price_TeamM', 'price_TeamY', 'price_OldM')),
                4::bigint, 'the service role reads them (the billing function)');

-- ============================================================ grants
select tests.as_superuser();
select tests.eq((
  select coalesce(string_agg(f, ', ' order by f), '')
  from unnest(array[
    'public.set_billing_config(boolean, integer)',
    'public.billing_upsert_plan(text, text, text, text, integer, text, text, integer, integer, text[], integer, boolean)',
    'public.billing_deactivate_plans_except(text[])',
    'public.billing_checkout_context(uuid, uuid)',
    'public.billing_link_customer(uuid, text)',
    'public.billing_apply_subscription(text, text, text, text, timestamptz, timestamptz, boolean, timestamptz)',
    'public.billing_payment_failed(text, timestamptz)',
    'public.billing_set_comp(uuid, timestamptz)',
    'public.billing_state(boolean, text, timestamptz, timestamptz, timestamptz, timestamptz)',
    'public.shop_billing_standing(uuid)',
    'public.shop_can_write(uuid)',
    'public.billing_seats_used(uuid, uuid, text)',
    'public.billing_max_members(uuid)',
    'public.billing_enabled()',
    'public.billing_trial_days()',
    'public.billing_is_end_user()',
    'public.billing_inactive_message()',
    'public.billing_seats_message(integer)']) as f
  where has_function_privilege('anon', f, 'execute')
     or has_function_privilege('authenticated', f, 'execute')
     or not has_function_privilege('service_role', f, 'execute')),
  '', 'service-role and internal billing functions: service_role only');
select tests.ok(has_function_privilege('authenticated', 'public.shop_entitlement(uuid)', 'execute')
                and not has_function_privilege('anon', 'public.shop_entitlement(uuid)', 'execute'),
                'shop_entitlement: signed-in users only');
select tests.ok(has_function_privilege('anon', 'public.public_billing_plans()', 'execute')
                and has_function_privilege('authenticated', 'public.public_billing_plans()', 'execute'),
                'public_billing_plans: anon and authenticated');
select tests.eq((
  select coalesce(string_agg(p.oid::regprocedure::text, ', ' order by 1), '')
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname in ('shops_seed_billing', 'billing_guard_new_record', 'billing_invite_seat_guard',
                                               'billing_member_seat_guard')
    and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))),
  '', 'billing trigger functions are not callable');
select tests.eq((select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'public' and p.proname in ('shop_entitlement', 'public_billing_plans', 'set_billing_config',
                                                               'billing_checkout_context', 'billing_apply_subscription')
                    and p.prosecdef and 'search_path=""' = any (p.proconfig)), 5::bigint,
                'entry points are SECURITY DEFINER with search_path pinned');
