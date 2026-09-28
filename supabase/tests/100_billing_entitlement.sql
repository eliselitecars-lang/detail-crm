-- 100 billing: shop_entitlement for every role (owner / admin / manager /
-- technician / portal client / outsider / inactive member / anon), the
-- curated keys, details for managers+ only, seats (active members + pending
-- unexpired invites), comp, billing off; shop_billing RLS and column grants
-- (no Stripe ids to anyone), two-shop isolation.
\ir fixtures/two_shops.psql

select tests.as_service();
select public.set_billing_config(true, 0);
select tests.fx_set('plan_team', public.billing_upsert_plan('price_EntTeam', 'prod_EntTeam', 'Team', null, 7900, 'usd', 'month', 1,
                                                            8, '{}', 0, true));
update public.shop_billing
   set status = 'active', plan_id = tests.fx('plan_team'), stripe_customer_id = 'cus_EntA', stripe_subscription_id = 'sub_EntA',
       current_period_end = '2099-01-01Z', cancel_at_period_end = true, trial_ends_at = '2020-01-01Z', trial_used = true
 where shop_id = tests.fx('shop_a');
-- shop B never subscribed and has no trial: lapsed

-- a portal client of shop A (linked to Alice)
select tests.as_superuser();
select tests.fx_set('u_client', tests.create_user('alice@example.com'));
update public.customers set portal_user_id = tests.fx('u_client') where id = tests.fx('cust_a');

create function pg_temp.ent(p_shop uuid) returns jsonb language sql as $$ select public.shop_entitlement(p_shop) $$;
grant execute on function pg_temp.ent(uuid) to anon, authenticated, service_role;

-- ============================================================ owner / admin / manager: the full view
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.eq((select string_agg(k, ',' order by k) from jsonb_object_keys(pg_temp.ent(tests.fx('shop_a'))) k),
                'billing_enabled,can_write,cancel_at_period_end,current_period_end,is_owner,max_members,members_used,plan_name,reason,state,trial_ends_at',
                'exactly the documented keys');
select tests.eq(pg_temp.ent(tests.fx('shop_a')) - 'current_period_end' - 'trial_ends_at',
                '{"billing_enabled": true, "state": "active", "reason": "subscribed", "plan_name": "Team",
                  "cancel_at_period_end": true, "max_members": 8, "members_used": 5, "can_write": true, "is_owner": true}'::jsonb,
                'owner: standing, plan, cancellation, seats (5 active members), owner flag');
select tests.eq((pg_temp.ent(tests.fx('shop_a')) ->> 'current_period_end')::timestamptz, '2099-01-01Z'::timestamptz,
                'owner: renewal / end date');
select tests.eq((pg_temp.ent(tests.fx('shop_a')) ->> 'trial_ends_at')::timestamptz, '2020-01-01Z'::timestamptz, 'owner: trial end');
select tests.ok(pg_temp.ent(tests.fx('shop_a'))::text !~ '(cus_|sub_|price_|prod_|7900)', 'never Stripe ids or prices');

select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.eq(pg_temp.ent(tests.fx('shop_a')) - 'current_period_end' - 'trial_ends_at',
                '{"billing_enabled": true, "state": "active", "reason": "subscribed", "plan_name": "Team",
                  "cancel_at_period_end": true, "max_members": 8, "members_used": 5, "can_write": true, "is_owner": false}'::jsonb,
                'admin: the same view, not the owner');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq((select jsonb_build_array(e -> 'plan_name', e -> 'max_members', e -> 'is_owner') from pg_temp.ent(tests.fx('shop_a')) e),
                '["Team", 8, false]'::jsonb, 'manager: the same view');

-- ============================================================ technician: the standing only
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(pg_temp.ent(tests.fx('shop_a')),
                '{"billing_enabled": true, "state": "active", "reason": "subscribed", "plan_name": null, "trial_ends_at": null,
                  "current_period_end": null, "cancel_at_period_end": false, "max_members": null, "members_used": null,
                  "can_write": true, "is_owner": false}'::jsonb,
                'technician: no plan, dates or seats');

-- ============================================================ everyone else: not found
select tests.authenticate_as(tests.fx('u_client'));
select tests.throws($$select pg_temp.ent(tests.fx('shop_a'))$$, 'P0002', 'a portal client is not a member');
select tests.authenticate_as(tests.fx('u_outsider'));
select tests.throws($$select pg_temp.ent(tests.fx('shop_a'))$$, 'P0002', 'an outsider gets not found');
select tests.throws($$select pg_temp.ent(gen_random_uuid())$$, 'P0002', 'an unknown shop is not found');
select tests.authenticate_as(tests.fx('u_owner_b'));
select tests.throws($$select pg_temp.ent(tests.fx('shop_a'))$$, 'P0002', 'another shop''s owner gets not found');
select tests.as_anon();
select tests.throws($$select public.shop_entitlement(tests.fx('shop_a'))$$, '42501', 'anon cannot call it');
select tests.as_superuser();
update public.shop_members set active = false where id = tests.fx('m_tech2_a');
select tests.authenticate_as(tests.fx('u_tech2_a'));
select tests.throws($$select pg_temp.ent(tests.fx('shop_a'))$$, 'P0002', 'an inactive member gets not found');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.eq((pg_temp.ent(tests.fx('shop_a')) ->> 'members_used')::integer, 4, 'an inactive member frees the seat');

-- ============================================================ lapsed shop (B)
select tests.authenticate_as(tests.fx('u_owner_b'));
select tests.eq((select jsonb_build_array(e -> 'state', e -> 'reason', e -> 'can_write', e -> 'is_owner', e -> 'plan_name', e -> 'max_members')
                   from pg_temp.ent(tests.fx('shop_b')) e),
                '["lapsed", "no_subscription", false, true, null, null]'::jsonb, 'owner of B: lapsed, no plan, no seat limit');
select tests.authenticate_as(tests.fx('u_tech_b'));
select tests.eq((select jsonb_build_array(e -> 'state', e -> 'can_write') from pg_temp.ent(tests.fx('shop_b')) e),
                '["lapsed", false]'::jsonb, 'technicians learn the shop is lapsed (to explain refusals)');

-- ============================================================ pending invites take seats
select tests.authenticate_as(tests.fx('u_owner_a'));
select public.invite_member(tests.fx('shop_a'), 'new1@test.local', 'technician');
select public.invite_member(tests.fx('shop_a'), 'new2@test.local', 'manager');
select tests.eq((pg_temp.ent(tests.fx('shop_a')) ->> 'members_used')::integer, 6, 'two pending invites: 4 members + 2');
select public.invite_member(tests.fx('shop_a'), 'NEW1@test.local', 'admin');
select tests.eq((pg_temp.ent(tests.fx('shop_a')) ->> 'members_used')::integer, 6, 're-inviting an address replaces its invite');
select tests.as_superuser();
update public.shop_invites set expires_at = now() - interval '1 minute' where shop_id = tests.fx('shop_a') and email = 'new2@test.local';
insert into public.shop_invites (shop_id, email, role, invited_by)
  values (tests.fx('shop_a'), 'manager-a@test.local', 'technician', tests.fx('u_owner_a'));
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.eq((pg_temp.ent(tests.fx('shop_a')) ->> 'members_used')::integer, 5,
                'expired invites and invites to addresses already on the team take no seat');

-- ============================================================ comp
select tests.authenticate_as(tests.fx('u_owner_b'));
select tests.throws($$select public.billing_set_comp(tests.fx('shop_b'), 'infinity')$$, '42501', 'owners cannot comp themselves');
select tests.as_service();
select tests.throws($$select public.billing_set_comp(gen_random_uuid(), 'infinity')$$, 'P0002', 'unknown shop');
select public.billing_set_comp(tests.fx('shop_b'), 'infinity');
select public.billing_set_comp(tests.fx('shop_a'), now() + interval '1 day');
select tests.authenticate_as(tests.fx('u_owner_b'));
select tests.eq((select jsonb_build_array(e -> 'state', e -> 'reason', e -> 'can_write') from pg_temp.ent(tests.fx('shop_b')) e),
                '["comped", "comped", true]'::jsonb, 'a comped shop can write');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.eq((select jsonb_build_array(e -> 'state', e -> 'max_members', e -> 'plan_name') from pg_temp.ent(tests.fx('shop_a')) e),
                '["comped", null, "Team"]'::jsonb, 'comp lifts the seat limit (the plan is still shown)');
select tests.as_service();
select public.billing_set_comp(tests.fx('shop_b'), null);
select public.billing_set_comp(tests.fx('shop_a'), now() - interval '1 second');
select tests.authenticate_as(tests.fx('u_owner_b'));
select tests.eq(pg_temp.ent(tests.fx('shop_b')) ->> 'state', 'lapsed', 'comp ended: lapsed again');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.eq(pg_temp.ent(tests.fx('shop_a')) ->> 'state', 'active', 'a past comp date: back to the subscription');

-- ============================================================ billing off
select tests.as_service();
select public.set_billing_config(false, 0);
select tests.authenticate_as(tests.fx('u_owner_b'));
select tests.eq((select jsonb_build_array(e -> 'billing_enabled', e -> 'state', e -> 'reason', e -> 'can_write') from pg_temp.ent(tests.fx('shop_b')) e),
                '[false, "active", "billing_off", true]'::jsonb, 'billing off: every shop is active');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.eq(pg_temp.ent(tests.fx('shop_a')) -> 'max_members', 'null'::jsonb, 'billing off: no seat limit');
select tests.as_service();
select public.set_billing_config(true, 0);

-- ============================================================ shop_billing: RLS and columns
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.eq((select array_agg(status) from public.shop_billing), array['active'], 'owner of A reads A''s row only');
select tests.eq((select array_agg(plan_id) from public.shop_billing where shop_id = tests.fx('shop_a')), array[tests.fx('plan_team')],
                'with the plan id');
select tests.throws($$select stripe_customer_id from public.shop_billing$$, '42501', 'never the Stripe customer id');
select tests.throws($$select stripe_subscription_id from public.shop_billing$$, '42501', 'nor the subscription id');
select tests.throws($$select * from public.shop_billing$$, '42501', 'select * is refused (explicit columns only)');
select tests.throws($$update public.shop_billing set status = 'active'$$, '42501', 'owners cannot change their standing');
select tests.throws($$update public.shop_billing set comp_until = 'infinity'$$, '42501', 'nor comp themselves');
select tests.throws($$insert into public.shop_billing (shop_id) values (tests.fx('shop_a'))$$, '42501', 'nor insert rows');
select tests.throws($$delete from public.shop_billing$$, '42501', 'nor delete them');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.eq(tests.row_count($$select shop_id, status, current_period_end, cancel_at_period_end from public.shop_billing$$), 1::bigint,
                'admins read it');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$select shop_id, status from public.shop_billing$$), 1::bigint, 'managers read it');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$select shop_id, status from public.shop_billing$$), 0::bigint, 'technicians do not');
select tests.authenticate_as(tests.fx('u_client'));
select tests.eq(tests.row_count($$select shop_id, status from public.shop_billing$$), 0::bigint, 'portal clients do not');
select tests.authenticate_as(tests.fx('u_owner_b'));
select tests.eq((select array_agg(shop_id) from public.shop_billing), array[tests.fx('shop_b')], 'owner of B: only B');
select tests.eq(tests.row_count($$select status from public.shop_billing where shop_id = tests.fx('shop_a')$$), 0::bigint,
                'shop A''s row is invisible to B');
select tests.as_anon();
select tests.throws($$select status from public.shop_billing$$, '42501', 'anon has no access');
select tests.as_service();
select tests.eq((select stripe_customer_id from public.shop_billing where shop_id = tests.fx('shop_a')), 'cus_EntA',
                'the service role reads the Stripe ids');

-- deleting a shop removes its billing row
select tests.as_superuser();
select tests.fx_set('shop_c', tests.make_shop('owner-c@test.local', 'shop-c', 'Shop C'));
select tests.as_superuser();
select tests.eq((select count(*) from public.shop_billing where shop_id = tests.fx('shop_c')), 1::bigint, 'a new shop has its row');
delete from public.shops where id = tests.fx('shop_c');
select tests.eq((select count(*) from public.shop_billing where shop_id = tests.fx('shop_c')), 0::bigint, 'and it goes with the shop');
