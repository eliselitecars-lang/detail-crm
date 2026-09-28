-- 100 billing (0103): a lapsed shop takes no new business through its
-- other public pages and staff sales either — lead forms (no customer, no
-- submission, no lead_received auto-reply), the membership join page
-- (no plans; membership_join_prepare 55000 before creating anything),
-- online gift card sales (offer disabled; gift_card_order_prepare 55000),
-- staff create_membership and issue_gift_card (PT402) — while store credit
-- a referral earns on a finished job still issues. An active shop works as
-- before, and renewing brings everything back.
\ir fixtures/two_shops.psql

select tests.as_superuser();
insert into public.lead_forms (shop_id, name, auto_reply, notify_staff, ask_vehicle, ask_message)
  values (tests.fx('shop_a'), 'Quick contact', true, true, false, false) returning tests.fx_set('form', id);
select tests.fx_set('tok', (select token from public.lead_forms where id = tests.fx('form')));
insert into public.membership_plans (shop_id, name, price_cents, interval, interval_count, online_joinable)
  values (tests.fx('shop_a'), 'Club', 4000, 'month', 1, true) returning tests.fx_set('club', id);
update public.gift_card_settings set online_enabled = true, allow_custom_amount = true, min_custom_cents = 1000,
                                     max_custom_cents = 50000
 where shop_id = tests.fx('shop_a');

create function pg_temp.lead(p_n integer) returns jsonb language sql as $$
  select public.public_submit_lead(tests.fx('tok'), jsonb_build_object('first_name', 'Lee', 'email', 'lead' || p_n || '@example.com')) $$;
create function pg_temp.join_(p_n integer) returns jsonb language sql as $$
  select public.membership_join_prepare('shop-a', tests.fx('club'),
           jsonb_build_object('customer', jsonb_build_object('first_name', 'Jo', 'email', 'jo' || p_n || '@example.com'))) $$;
create function pg_temp.gift(p_n integer) returns jsonb language sql as $$
  select public.gift_card_order_prepare('shop-a', jsonb_build_object('amount_cents', 5000,
           'purchaser', jsonb_build_object('name', 'Pat', 'email', 'pat' || p_n || '@example.com'),
           'recipient', jsonb_build_object('email', 'sam' || p_n || '@example.com'))) $$;
-- the referral reward runs in the completing staff member's context
-- (jobs_money_referral_reward): the same internal call, as that member
create function pg_temp.issue_via(p_via text) returns jsonb language sql security definer as $$
  select public.gift_card_issue_core(tests.fx('shop_a'), 'credit', 2000, null, p_via, null, tests.fx('cust_a'),
                                     null, null, null, null, null, 'test') $$;
grant execute on function pg_temp.lead(integer) to anon, authenticated;
grant execute on function pg_temp.join_(integer), pg_temp.gift(integer) to service_role;
grant execute on function pg_temp.issue_via(text) to authenticated;
create function pg_temp.counts() returns jsonb language sql as $$
  select jsonb_build_object(
    'customers', (select count(*) from public.customers where shop_id = tests.fx('shop_a')),
    'leads', (select count(*) from public.lead_submissions where shop_id = tests.fx('shop_a')),
    'auto_replies', (select count(*) from public.messages where shop_id = tests.fx('shop_a') and template_key = 'lead_received'),
    'memberships', (select count(*) from public.memberships where shop_id = tests.fx('shop_a')),
    'gift_orders', (select count(*) from public.gift_card_orders where shop_id = tests.fx('shop_a')),
    'gift_cards', (select count(*) from public.gift_cards where shop_id = tests.fx('shop_a'))) $$;

-- ============================================================ billing on, shop A active: everything works
select tests.as_service();
select public.set_billing_config(true, 0);
update public.shop_billing set status = 'active', current_period_end = now() + interval '20 days' where shop_id = tests.fx('shop_a');
select tests.as_anon();
select tests.eq(public.public_get_lead_form(tests.fx('tok')) #>> '{form,name}', 'Quick contact', 'active: the lead form opens');
select tests.eq(pg_temp.lead(1) ->> 'ok', 'true', 'active: a lead is taken');
select tests.eq(jsonb_array_length(public.public_membership_plans('shop-a') -> 'plans'), 1, 'active: the plan is offered');
select tests.eq(public.public_gift_card_offer('shop-a') -> 'enabled', 'true'::jsonb, 'active: gift cards are sold online');
select tests.as_service();
select tests.ok(pg_temp.join_(1) ? 'membership_id', 'active: an online join is prepared');
select tests.ok(pg_temp.gift(1) ? 'order_id', 'active: a gift card order is prepared');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq((public.create_membership(tests.fx('club'), tests.fx('cust_a'))).status::text, 'incomplete',
                'active: staff sell a membership');
select tests.eq(public.issue_gift_card(tests.fx('shop_a'), 5000) ->> 'balance_cents', '5000', 'active: staff issue a gift card');
select tests.as_superuser();
select tests.eq(pg_temp.counts() - 'customers',
                '{"leads": 1, "auto_replies": 1, "memberships": 2, "gift_orders": 1, "gift_cards": 1}'::jsonb,
                'active: every sale was recorded (and the auto-reply queued)');

-- ============================================================ shop A lapses
select tests.as_service();
update public.shop_billing set status = 'canceled', current_period_end = now() - interval '1 day' where shop_id = tests.fx('shop_a');
select tests.ok(not public.shop_can_write(tests.fx('shop_a')), 'shop A is lapsed');
select tests.as_superuser();
create temp table before_lapse as select pg_temp.counts() as c;

-- lead forms: gone, like a form the shop turned off
select tests.as_anon();
select tests.throws_like($$select public.public_get_lead_form(tests.fx('tok'))$$, 'PT404', 'form not found',
                         'lapsed: the lead form is not found');
select tests.throws_like($$select pg_temp.lead(2)$$, 'PT404', 'form not found', 'lapsed: no lead is taken');
-- membership join page
select tests.eq(public.public_membership_plans('shop-a') - 'currency',
                '{"shop": {"name": "Shop A", "logo_path": null, "brand_color": null}, "plans": []}'::jsonb,
                'lapsed: the join page lists no plans (the shop still shows)');
select tests.throws($$select public.public_membership_plans('no-such-shop')$$, 'PT404', 'an unknown shop is still PT404');
select tests.as_service();
select tests.throws_like($$select pg_temp.join_(2)$$, '55000', 'this membership plan is not available online',
                         'lapsed: membership_join_prepare answers its 55000');
-- gift cards online
select tests.as_anon();
select tests.eq(public.public_gift_card_offer('shop-a') -> 'enabled', 'false'::jsonb, 'lapsed: gift cards are not sold online');
select tests.as_service();
select tests.throws_like($$select pg_temp.gift(2)$$, '55000', 'online gift card sales are not enabled for this shop',
                         'lapsed: gift_card_order_prepare answers its 55000');
select tests.throws($$select public.gift_card_order_prepare('no-such-shop', '{}'::jsonb)$$, 'PT404', 'unknown shop: PT404');
-- staff sales
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws_like($$select public.create_membership(tests.fx('club'), tests.fx('cust_a2'))$$, 'PT402',
                         'This shop''s subscription is inactive%', 'lapsed: staff cannot sell a membership');
select tests.throws($$select public.issue_gift_card(tests.fx('shop_a'), 5000)$$, 'PT402', 'nor issue a gift card');
select tests.throws($$select public.issue_gift_card(tests.fx('shop_a'), 5000, '{"email": "new@example.com"}', null, 'gift', null, true)$$,
                    'PT402', 'nor send one to a new recipient');
select tests.throws($$select pg_temp.issue_via('staff')$$, 'PT402', 'a staff-issued card is refused at the table too');
select tests.ok(pg_temp.issue_via('referral') ? 'gift_card_id', 'store credit a finished job earns (referral) still issues');
select tests.as_superuser();
select tests.eq(pg_temp.counts(), (select c from before_lapse) || '{"gift_cards": 2}'::jsonb,
                'nothing new while lapsed: no customer, lead, auto-reply, membership or order (only the referral credit)');

-- a membership or order prepared before the lapse is still an existing sale
select tests.as_service();
select tests.lives($$select public.membership_join_prepare_core('shop-a', tests.fx('club'),
                      jsonb_build_object('customer', jsonb_build_object('first_name', 'Jo', 'email', 'jo1@example.com')))$$,
                   'the internal body still answers for the service role (retry of an earlier join)');
select tests.as_anon();
select tests.throws($$select public.membership_join_prepare_core('shop-a', tests.fx('club'), '{}'::jsonb)$$, '42501',
                    'the internal functions are not public');
select tests.throws($$select public.gift_card_order_prepare_core('shop-a', '{}'::jsonb)$$, '42501', 'neither is the gift card one');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$select public.membership_join_prepare('shop-a', tests.fx('club'), '{}'::jsonb)$$, '42501',
                    'the wrapper stays service_role only');

-- ============================================================ renewing brings it back
select tests.as_service();
update public.shop_billing set status = 'active', current_period_end = now() + interval '30 days' where shop_id = tests.fx('shop_a');
select tests.as_anon();
select tests.eq(pg_temp.lead(3) ->> 'ok', 'true', 'renewed: leads again');
select tests.eq(jsonb_array_length(public.public_membership_plans('shop-a') -> 'plans'), 1, 'renewed: plans again');
select tests.eq(public.public_gift_card_offer('shop-a') -> 'enabled', 'true'::jsonb, 'renewed: gift cards again');
select tests.as_service();
select tests.ok(pg_temp.join_(3) ? 'membership_id', 'renewed: joins again');
select tests.ok(pg_temp.gift(3) ? 'order_id', 'renewed: orders again');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.lives($$select public.create_membership(tests.fx('club'), tests.fx('cust_a2'))$$, 'renewed: staff sell memberships');

-- ============================================================ billing off: never paused
select tests.as_service();
update public.shop_billing set status = 'canceled', current_period_end = now() - interval '1 day' where shop_id = tests.fx('shop_a');
select public.set_billing_config(false, 0);
select tests.as_anon();
select tests.eq(pg_temp.lead(4) ->> 'ok', 'true', 'billing off: a canceled shop still takes leads');
select tests.eq(public.public_gift_card_offer('shop-a') -> 'enabled', 'true'::jsonb, 'and sells gift cards');
