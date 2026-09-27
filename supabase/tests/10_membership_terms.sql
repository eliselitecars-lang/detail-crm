-- 10 money: each membership records the terms it is billed (price, interval,
-- Stripe price). A plan price change detaches the plan's Stripe price, so
-- existing subscribers keep paying the old price: staff and the portal must
-- show that price, not the plan's current one.
\ir fixtures/two_shops.psql

-- the portal checks need 0043 (scripts/test_db.sh --ranges)
select to_regprocedure('public.portal_overview()') is not null as has_portal \gset

select tests.fx_set('u_alice', tests.create_user('alice@example.com'));

-- ============================================================ the repro
select tests.as_superuser();
insert into public.membership_plans (shop_id, name, price_cents, stripe_product_id, stripe_price_id)
  values (tests.fx('shop_a'), 'Gold', 5000, 'prod_1', 'price_old') returning tests.fx_set('plan', id);
select tests.as_service();
insert into public.memberships (shop_id, plan_id, customer_id, status, stripe_subscription_id, current_period_end)
  values (tests.fx('shop_a'), tests.fx('plan'), tests.fx('cust_a'), 'active', 'sub_1', '2025-07-01Z')
  returning tests.fx_set('mem_sub1', id);
select tests.eq((select concat_ws('/', price_cents, interval, interval_count, stripe_price_id) from public.memberships where id = tests.fx('mem_sub1')),
                '5000/month/1/price_old', 'a membership inserted with a subscription records the plan''s terms and Stripe price');
select tests.authenticate_as(tests.fx('u_owner_a'));
update public.membership_plans set price_cents = 6000 where id = tests.fx('plan');
select tests.eq((select stripe_price_id from public.membership_plans where id = tests.fx('plan')), null::text, 'price detached; sub_1 keeps billing 5000');
select tests.eq((select concat_ws('/', price_cents, interval, interval_count, stripe_price_id) from public.memberships where id = tests.fx('mem_sub1')),
                '5000/month/1/price_old', 'staff read the price the member is billed');
\if :has_portal
select tests.authenticate_as(tests.fx('u_alice'));
select public.portal_claim_customers();
select tests.eq((select (m ->> 'price_cents')::bigint from jsonb_array_elements(public.portal_overview() -> 'memberships') m),
                5000::bigint, 'the member is shown the price they are billed');
select tests.eq((select concat_ws('/', m ->> 'interval', m ->> 'interval_count') from jsonb_array_elements(public.portal_overview() -> 'memberships') m),
                'month/1', 'and the interval they are billed');
\endif

-- ============================================================ create_membership snapshots; unlinked memberships follow the plan
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('mem_open', (public.create_membership(tests.fx('plan'), tests.fx('cust_a2'))).id);
select tests.eq((select concat_ws('/', price_cents, interval, interval_count, coalesce(stripe_price_id, '-')) from public.memberships where id = tests.fx('mem_open')),
                '6000/month/1/-', 'a new membership records the plan''s current terms; no Stripe price before checkout');
update public.membership_plans set price_cents = 6500, interval = 'year' where id = tests.fx('plan');
select tests.eq((select concat_ws('/', price_cents, interval, interval_count) from public.memberships where id = tests.fx('mem_open')),
                '6500/year/1', 'a membership that has not checked out yet follows the plan (its checkout charges the new terms)');
select tests.eq((select concat_ws('/', price_cents, interval, interval_count) from public.memberships where id = tests.fx('mem_sub1')),
                '5000/month/1', 'a linked membership keeps what its subscription bills');
update public.membership_plans set name = 'Gold Plus' where id = tests.fx('plan');
select tests.eq((select price_cents from public.memberships where id = tests.fx('mem_open')), 6500::bigint, 'cosmetic plan edits change nothing');

-- staff cannot rewrite the recorded terms
select tests.throws_like($$update public.memberships set price_cents = 1 where id = tests.fx('mem_open')$$, '42501', '%billing fields%',
                         'staff cannot change a membership''s price');
select tests.throws_like($$update public.memberships set interval = 'month', interval_count = 2 where id = tests.fx('mem_open')$$, '42501', '%billing fields%',
                         'nor its interval');
select tests.throws_like($$update public.memberships set stripe_price_id = 'price_forged' where id = tests.fx('mem_open')$$, '42501', '%billing fields%',
                         'nor its Stripe price');

-- ============================================================ sync_stripe_subscription records Stripe's actual price
select tests.as_service();
select tests.eq((select concat_ws('/', status, price_cents, interval, interval_count, stripe_price_id)
                   from public.sync_stripe_subscription(tests.fx('shop_a'), 'sub_open', 'active', '2026-01-01Z', false, tests.fx('mem_open'),
                                                        '2025-06-01Z', 'price_checkout', 6000, 'month', 1)),
                'active/6000/month/1/price_checkout',
                'linking records the price the checkout actually charged (the plan changed while the link was open)');
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.membership_plans set price_cents = 7000 where id = tests.fx('plan');
select tests.eq((select price_cents from public.memberships where id = tests.fx('mem_open')), 6000::bigint,
                'once linked it no longer follows the plan');
select tests.as_service();
select tests.eq((select concat_ws('/', price_cents, stripe_price_id)
                   from public.sync_stripe_subscription(tests.fx('shop_a'), 'sub_open', 'active', '2026-02-01Z', false, null, '2025-07-01Z')),
                '6000/price_checkout', 'a sync without terms keeps the recorded ones');
select tests.eq((select concat_ws('/', price_cents, interval, interval_count, stripe_price_id)
                   from public.sync_stripe_subscription(tests.fx('shop_a'), 'sub_open', 'active', '2026-02-01Z', false, null, '2025-07-02Z',
                                                        'price_dash', 12000, 'month', 24)),
                '12000/month/24/price_dash', 'a price changed in Stripe (even beyond the plan form''s range) is recorded');
select tests.throws_like($$select public.sync_stripe_subscription(tests.fx('shop_a'), 'sub_open', 'active', null, false, null, '2025-07-03Z',
                                                                   null, 5000, null, null)$$, '22023', '%together%',
                         'terms are all or nothing');
select tests.throws_like($$select public.sync_stripe_subscription(tests.fx('shop_a'), 'sub_open', 'active', null, false, null, '2025-07-03Z',
                                                                   null, 0, 'month', 1)$$, '22023', '%invalid billing terms%',
                         'a zero price is rejected');
select tests.throws_like($$select public.sync_stripe_subscription(tests.fx('shop_a'), 'sub_open', 'active', null, false, null, '2025-07-03Z',
                                                                   null, 5000, 'year', 4)$$, '22023', '%invalid billing terms%',
                         'intervals beyond Stripe''s limits are rejected');
select tests.throws_like($$select public.sync_stripe_subscription(tests.fx('shop_a'), 'sub_open', 'active', null, false, null, '2025-07-03Z',
                                                                   'plan_legacy', null, null, null)$$, '22023', '%price id%',
                         'malformed Stripe price ids are rejected');
select tests.eq((select concat_ws('/', price_cents, stripe_price_id) from public.memberships where id = tests.fx('mem_open')),
                '12000/price_dash', 'rejected syncs change nothing');
select tests.throws($$insert into public.memberships (shop_id, plan_id, customer_id, price_cents, interval, interval_count)
                      values (tests.fx('shop_a'), tests.fx('plan'), tests.fx('cust_a3'), 100, 'year', 4)$$, '23514',
                    'the recorded interval must be one Stripe can bill');
insert into public.memberships (shop_id, plan_id, customer_id, price_cents, interval, interval_count)
  values (tests.fx('shop_a'), tests.fx('plan'), tests.fx('cust_a3'), 4200, 'month', 3) returning tests.fx_set('mem_given', id);
select tests.eq((select concat_ws('/', price_cents, interval, interval_count) from public.memberships where id = tests.fx('mem_given')),
                '4200/month/3', 'trusted code may supply complete terms');

-- ============================================================ denial + isolation
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$select public.sync_stripe_subscription(tests.fx('shop_a'), 'sub_open', 'active', null, false, null, now(),
                                                               'price_x', 1, 'month', 1)$$, '42501', 'staff cannot sync terms');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$select price_cents from public.memberships$$), 0::bigint, 'technicians see no membership prices');
select tests.as_anon();
select tests.throws($$select price_cents from public.memberships$$, '42501', 'anon has no access');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq(tests.row_count($$select price_cents from public.memberships where shop_id = tests.fx('shop_a')$$), 0::bigint,
                'shop B cannot read shop A''s membership prices');
insert into public.membership_plans (shop_id, name, price_cents) values (tests.fx('shop_b'), 'B plan', 3000) returning tests.fx_set('plan_b', id);
select tests.fx_set('mem_b', (public.create_membership(tests.fx('plan_b'), tests.fx('cust_b'))).id);
update public.membership_plans set price_cents = 3500 where id = tests.fx('plan_b');
select tests.eq((select price_cents from public.memberships where id = tests.fx('mem_b')), 3500::bigint, 'shop B''s open membership follows its plan');
select tests.as_superuser();
select tests.eq((select price_cents from public.memberships where id = tests.fx('mem_sub1')), 5000::bigint,
                'a plan change in shop B never touches shop A''s memberships');
select tests.throws($$insert into public.memberships (shop_id, plan_id, customer_id) values (tests.fx('shop_a'), tests.fx('plan_b'), tests.fx('cust_a'))$$,
                    '23503', 'a membership cannot take terms from another shop''s plan');
