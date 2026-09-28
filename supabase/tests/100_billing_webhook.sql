-- 100 billing: the service-role RPCs of the `billing` / `billing-webhook`
-- functions — billing_checkout_context, billing_link_customer (idempotent,
-- conflicts), billing_apply_subscription (validation, unknown customer,
-- plan by price, trial_used, out-of-order and equal-time events, canceled
-- keeps the period end, which subscription may replace the current one,
-- cross-shop subscription), billing_payment_failed (owner-only neutral
-- notification, no pile-up, stale events), access for API roles.
\ir fixtures/two_shops.psql

select tests.as_service();
select public.set_billing_config(true, 14);
select tests.fx_set('plan_m', public.billing_upsert_plan('price_WhM', 'prod_Wh', 'Standard', null, 4900, 'usd', 'month', 1, null,
                                                         '{}', 0, true));

create function pg_temp.row_a() returns public.shop_billing language sql as $$
  select * from public.shop_billing where shop_id = tests.fx('shop_a') $$;
create function pg_temp.apply(p_customer text, p_sub text, p_price text, p_status text, p_at timestamptz,
                              p_trial timestamptz default null, p_period timestamptz default '2099-01-01Z',
                              p_cancel boolean default false) returns jsonb language sql as $$
  select public.billing_apply_subscription(p_customer, p_sub, p_price, p_status, p_trial, p_period, p_cancel, p_at) $$;
grant execute on function pg_temp.row_a(), pg_temp.apply(text, text, text, text, timestamptz, timestamptz, timestamptz, boolean)
  to authenticated, service_role;

-- ============================================================ access
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.throws($$select public.billing_checkout_context(tests.fx('shop_a'), tests.fx('u_owner_a'))$$, '42501', 'owners cannot call checkout context');
select tests.throws($$select public.billing_link_customer(tests.fx('shop_a'), 'cus_Mine')$$, '42501', 'nor link a customer');
select tests.throws($$select pg_temp.apply('cus_Mine', 'sub_Mine', null, 'active', now())$$, '42501', 'nor apply a subscription');
select tests.throws($$select public.billing_payment_failed('cus_Mine', now())$$, '42501', 'nor raise a payment failure');
select tests.as_anon();
select tests.throws($$select public.billing_checkout_context(tests.fx('shop_a'), null)$$, '42501', 'anon neither');

-- ============================================================ checkout context
select tests.as_service();
select tests.eq(public.billing_checkout_context(tests.fx('shop_a'), tests.fx('u_owner_a')),
                jsonb_build_object('is_owner', true, 'shop_name', 'Shop A', 'owner_email', 'owner-a@test.local',
                                   'stripe_customer_id', null, 'has_live_subscription', false,
                                   'trial_end', now() + interval '14 days', 'billing_enabled', true),
                'owner: every documented field, the in-app trial to carry over');
select tests.eq(public.billing_checkout_context(tests.fx('shop_a'), tests.fx('u_admin_a')) -> 'is_owner', 'false'::jsonb, 'an admin is not the owner');
select tests.eq(public.billing_checkout_context(tests.fx('shop_a'), null) -> 'is_owner', 'false'::jsonb, 'nobody is not the owner');
select tests.eq(public.billing_checkout_context(tests.fx('shop_a'), tests.fx('u_owner_b')) -> 'is_owner', 'false'::jsonb,
                'another shop''s owner is not the owner');
select tests.throws($$select public.billing_checkout_context(gen_random_uuid(), null)$$, 'P0002', 'unknown shop');
update public.shop_billing set trial_ends_at = now() - interval '1 minute' where shop_id = tests.fx('shop_b');
select tests.eq(public.billing_checkout_context(tests.fx('shop_b'), tests.fx('u_owner_b')) -> 'trial_end', 'null'::jsonb,
                'a trial that ended is not carried over');

-- ============================================================ linking the platform customer
select tests.throws($$select public.billing_link_customer(tests.fx('shop_a'), 'cust_1')$$, '22023', 'a Stripe customer id is required');
select tests.throws($$select public.billing_link_customer(gen_random_uuid(), 'cus_WhA')$$, 'P0002', 'unknown shop');
select tests.lives($$select public.billing_link_customer(tests.fx('shop_a'), 'cus_WhA')$$, 'link');
select tests.lives($$select public.billing_link_customer(tests.fx('shop_a'), 'cus_WhA')$$, 'linking again is a no-op');
select tests.eq(public.billing_checkout_context(tests.fx('shop_a'), tests.fx('u_owner_a')) ->> 'stripe_customer_id', 'cus_WhA',
                'the context reuses the linked customer');
select tests.throws_like($$select public.billing_link_customer(tests.fx('shop_b'), 'cus_WhA')$$, '23505', '%another shop%',
                         'a customer belongs to one shop');
select tests.throws_like($$select public.billing_link_customer(tests.fx('shop_a'), 'cus_Other')$$, '23505', '%already linked%',
                         'a linked shop is never silently moved to another customer');
select tests.lives($$select public.billing_link_customer(tests.fx('shop_b'), 'cus_WhB')$$, 'shop B gets its own');

-- ============================================================ applying subscriptions
select tests.throws($$select pg_temp.apply('cus_WhA', 'si_1', null, 'active', now())$$, '22023', 'subscription id shape');
select tests.throws($$select pg_temp.apply('cus_WhA', 'sub_1', 'plan_1', 'active', now())$$, '22023', 'price id shape');
select tests.throws($$select pg_temp.apply('cus_WhA', 'sub_1', null, 'none', now())$$, '22023', '"none" is not a Stripe status');
select tests.throws($$select pg_temp.apply('cus_WhA', 'sub_1', null, null, now())$$, '22023', 'a status is required');
select tests.throws($$select pg_temp.apply('cus_WhA', 'sub_1', null, 'active', null)$$, '22023', 'the event time is required');
select tests.throws($$select pg_temp.apply('customer', 'sub_1', null, 'active', now())$$, '22023', 'customer id shape');
select tests.eq(pg_temp.apply('cus_Unknown', 'sub_1', null, 'active', now()), '{"shop_id": null, "applied": false}'::jsonb,
                'an unknown customer is not ours');

-- checkout completed with the carried-over trial
select tests.eq(pg_temp.apply('cus_WhA', 'sub_1', 'price_WhM', 'trialing', '2026-01-01 10:00:00Z', now() + interval '14 days',
                              now() + interval '14 days'),
                jsonb_build_object('shop_id', tests.fx('shop_a'), 'applied', true), 'trialing subscription applied');
select tests.ok((select status = 'trialing' and plan_id = tests.fx('plan_m') and stripe_subscription_id = 'sub_1' and trial_used
                        and trial_ends_at = now() + interval '14 days' and current_period_end = now() + interval '14 days'
                        and not cancel_at_period_end and last_event_at = '2026-01-01 10:00:00Z'
                   from pg_temp.row_a()), 'row: status, plan by price, trial used, dates, event time');
select tests.ok((public.billing_checkout_context(tests.fx('shop_a'), tests.fx('u_owner_a')) -> 'has_live_subscription')::boolean
                and public.billing_checkout_context(tests.fx('shop_a'), tests.fx('u_owner_a')) -> 'trial_end' = 'null'::jsonb,
                'context: a live subscription; the trial was used');

-- out of order: an older event never rolls the shop back
select tests.eq(pg_temp.apply('cus_WhA', 'sub_1', 'price_WhM', 'incomplete', '2026-01-01 09:59:59Z'),
                jsonb_build_object('shop_id', tests.fx('shop_a'), 'applied', false), 'an older event is ignored');
select tests.eq((select status from pg_temp.row_a()), 'trialing', 'status unchanged');
-- same second: applied (the webhook re-reads the current state)
select tests.eq(pg_temp.apply('cus_WhA', 'sub_1', 'price_WhM', 'active', '2026-01-01 10:00:00Z', null, '2020-02-01Z')
                  -> 'applied', 'true'::jsonb, 'an event of the same second is applied');
select tests.ok((select status = 'active' and trial_used and trial_ends_at = now() + interval '14 days'
                        and current_period_end = '2020-02-01Z' from pg_temp.row_a()),
                'active: trial_used stays, trial end kept when the event has none');
select tests.eq(pg_temp.apply('cus_WhA', 'sub_1', 'price_WhM', 'active', '2026-01-02Z', null, '2020-02-01Z', true) -> 'applied',
                'true'::jsonb, 'cancellation scheduled');
select tests.ok((select cancel_at_period_end from pg_temp.row_a()), 'cancel_at_period_end recorded');
select tests.eq(pg_temp.apply('cus_WhA', 'sub_1', 'price_Unknown9', 'active', '2026-01-03Z', null, '2020-02-01Z') -> 'applied',
                'true'::jsonb, 'an unknown price is still applied');
select tests.ok((select plan_id is null and status = 'active' and not cancel_at_period_end from pg_temp.row_a()),
                'unknown price: no plan, status applied, cancellation withdrawn');

-- subscription deleted: canceled, the period end kept
select tests.eq(pg_temp.apply('cus_WhA', 'sub_1', 'price_WhM', 'canceled', '2026-01-04Z', null, null) -> 'applied', 'true'::jsonb,
                'deletion applied');
select tests.ok((select status = 'canceled' and current_period_end = '2020-02-01Z' and not cancel_at_period_end
                        and plan_id = tests.fx('plan_m') and last_event_at = '2026-01-04Z' from pg_temp.row_a()),
                'canceled keeps current_period_end');
select tests.eq((select s.state from public.shop_billing_standing(tests.fx('shop_a')) s), 'lapsed',
                'its period (Feb 2020) is over: lapsed');
select tests.eq(pg_temp.apply('cus_WhA', 'sub_1', 'price_WhM', 'canceled', '2026-01-04Z', null, '2099-01-01Z') -> 'applied',
                'true'::jsonb, 'a canceled subscription whose period runs on');
select tests.eq((select s.state || '/' || s.reason from public.shop_billing_standing(tests.fx('shop_a')) s), 'active/period_remaining',
                'keeps the shop active until the period ends');
select tests.ok(not (public.billing_checkout_context(tests.fx('shop_a'), tests.fx('u_owner_a')) -> 'has_live_subscription')::boolean,
                'a canceled subscription is not live: the owner may check out again');

-- a new subscription replaces the ended one; ended / pending others never replace the current one
select tests.eq(pg_temp.apply('cus_WhA', 'sub_2', 'price_WhM', 'incomplete', '2026-01-05Z') -> 'applied', 'true'::jsonb,
                'a new checkout (incomplete) replaces the ended subscription');
select tests.eq(pg_temp.apply('cus_WhA', 'sub_2', 'price_WhM', 'active', '2026-01-06Z') -> 'applied', 'true'::jsonb, 'and activates');
select tests.eq(pg_temp.apply('cus_WhA', 'sub_1', 'price_WhM', 'canceled', '2026-01-07Z') -> 'applied', 'false'::jsonb,
                'a late event of the old, ended subscription is ignored');
select tests.eq(pg_temp.apply('cus_WhA', 'sub_3', 'price_WhM', 'incomplete', '2026-01-08Z') -> 'applied', 'false'::jsonb,
                'a pending subscription never replaces a live one');
select tests.ok((select stripe_subscription_id = 'sub_2' and status = 'active' and last_event_at = '2026-01-06Z' from pg_temp.row_a()),
                'the live subscription stays');
select tests.eq(pg_temp.apply('cus_WhA', 'sub_3', 'price_WhM', 'active', '2026-01-09Z') -> 'applied', 'true'::jsonb,
                'another live subscription (newest event) is applied');
select tests.throws_like($$select pg_temp.apply('cus_WhB', 'sub_3', 'price_WhM', 'active', '2026-01-10Z')$$, '23505', '%another shop%',
                         'a subscription cannot be applied to a second shop');
select tests.eq((select status from public.shop_billing where shop_id = tests.fx('shop_b')), 'none', 'shop B untouched');

-- ============================================================ payment failures
select tests.throws($$select public.billing_payment_failed('cus_Nobody', now())$$, 'P0002', 'unknown customer');
select pg_temp.apply('cus_WhA', 'sub_3', 'price_WhM', 'past_due', '2026-01-10Z');
select public.billing_payment_failed('cus_WhA', '2026-01-10Z');
select tests.as_superuser();
select tests.eq((select array_agg(n.user_id) from public.notifications n
                  where n.shop_id = tests.fx('shop_a') and n.kind = 'billing_payment_failed'),
                array[tests.fx('u_owner_a')], 'only the owner is notified');
select tests.eq((select title || ' | ' || body from public.notifications
                  where shop_id = tests.fx('shop_a') and kind = 'billing_payment_failed'),
                'Subscription payment problem | There''s a problem with this shop''s subscription payment.',
                'neutral App Store-safe wording');
select tests.ok((select job_id is null and customer_id is null and quote_id is null and invoice_id is null and pushed_at is null
                   from public.notifications where shop_id = tests.fx('shop_a') and kind = 'billing_payment_failed'),
                'no record links; queued for push');
select tests.as_service();
select public.billing_payment_failed('cus_WhA', '2026-01-13Z');
select tests.eq((select count(*) from public.notifications where shop_id = tests.fx('shop_a') and kind = 'billing_payment_failed'),
                1::bigint, 'a retry while the first is unread adds nothing');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.eq(tests.row_count($$update public.notifications set read_at = now() where kind = 'billing_payment_failed'$$), 1::bigint,
                'the owner sees and reads it');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.eq(tests.row_count($$select 1 from public.notifications where kind = 'billing_payment_failed'$$), 0::bigint,
                'admins are not sent it');
select tests.as_service();
select public.billing_payment_failed('cus_WhA', '2026-01-16Z');
select tests.eq((select count(*) from public.notifications where shop_id = tests.fx('shop_a') and kind = 'billing_payment_failed'),
                2::bigint, 'a later failure after it was read notifies again');
update public.notifications set read_at = now() where shop_id = tests.fx('shop_a') and kind = 'billing_payment_failed';
select pg_temp.apply('cus_WhA', 'sub_3', 'price_WhM', 'active', '2026-01-20Z');
select public.billing_payment_failed('cus_WhA', '2026-01-19Z');
select tests.eq((select count(*) from public.notifications where shop_id = tests.fx('shop_a') and kind = 'billing_payment_failed'),
                2::bigint, 'a stale failure after the subscription recovered is not sent');
select pg_temp.apply('cus_WhA', 'sub_3', 'price_WhM', 'past_due', '2026-01-25Z');
select public.billing_payment_failed('cus_WhA', '2026-01-24Z');
select tests.eq((select count(*) from public.notifications where shop_id = tests.fx('shop_a') and kind = 'billing_payment_failed'),
                3::bigint, 'an older failure while still past due is sent');
select tests.eq((select count(*) from public.notifications where shop_id = tests.fx('shop_b') and kind = 'billing_payment_failed'),
                0::bigint, 'shop B untouched');
