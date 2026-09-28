-- 110 memberships (0111): paid_through is the end of the last period the
-- member paid for. When a renewal fails (past_due: Stripe has already moved
-- current_period_end to the end of the unpaid period), the included visits
-- booked from the start of the unpaid period on are charged the catalog
-- price; a later cancel keeps that cutoff; visits of the paid period stay
-- included.
\ir fixtures/two_shops.psql
\ir fixtures/40_booking_setup.psql

select tests.as_superuser();
update public.booking_settings set max_days_ahead = 120, auto_confirm = true where shop_id = tests.fx('shop_a');
insert into public.membership_plans (shop_id, name, price_cents, interval, interval_count, included_service_ids, included_uses_per_period)
  values (tests.fx('shop_a'), 'Wash club', 1500, 'week', 1, array[tests.fx('svc_wash')], 1) returning tests.fx_set('plan', id);
select tests.fx_set('u_alice', tests.create_user('alice@example.com'));
update public.customers set portal_user_id = tests.fx('u_alice') where id = tests.fx('cust_a');
-- one week paid (started 4 days ago): the period ends in 3 days
insert into public.memberships (shop_id, plan_id, customer_id, status, current_period_end, started_at, created_by, stripe_subscription_id)
  values (tests.fx('shop_a'), tests.fx('plan'), tests.fx('cust_a'), 'active', now() + interval '3 days', now() - interval '4 days',
          tests.fx('u_manager_a'), 'sub_test1')
  returning tests.fx_set('mem', id);
select ((now() at time zone 'America/Chicago')::date + 1)::text as d1,
       ((now() at time zone 'America/Chicago')::date + 5)::text as d5,
       ((now() at time zone 'America/Chicago')::date + 12)::text as d12 \gset
create function pg_temp.book(p_day text) returns jsonb language sql as $$
  select public.create_online_booking('shop-a', pg_temp.booking(jsonb_build_object(
           'customer', jsonb_build_object('first_name', 'Alice', 'email', 'alice@example.com'),
           'vehicle', jsonb_build_object('id', tests.fx('veh_a')),
           'service_ids', jsonb_build_array(tests.fx('svc_wash')), 'starts_at', p_day || 'T10:00:00')))
$$;
grant execute on function pg_temp.book(text) to authenticated;
create function pg_temp.total(p_token text) returns bigint language sql as $$
  select total_cents from public.jobs where public_token = p_token::uuid
$$;
create function pg_temp.paid_through() returns timestamptz language sql as $$
  select paid_through from public.memberships where id = tests.fx('mem')
$$;
create function pg_temp.notes(p_title text) returns bigint language sql as $$
  select count(*) from public.notifications where shop_id = tests.fx('shop_a') and title = p_title
$$;

select tests.eq(pg_temp.paid_through(), now() + interval '3 days', 'active: paid through its period end');

-- a visit in the paid week, one in the next week, one in the week after: all included while renewing
select tests.authenticate_as(tests.fx('u_alice'));
select pg_temp.book(:'d1') ->> 'job_token' as t1 \gset
select pg_temp.book(:'d5') ->> 'job_token' as t5 \gset
select pg_temp.book(:'d12') ->> 'job_token' as t12 \gset
select tests.as_superuser();
select tests.eq(array[pg_temp.total(:'t1'), pg_temp.total(:'t5'), pg_temp.total(:'t12')], array[0, 0, 0]::bigint[],
                'all three included while the membership renews');

-- ============================================================ the renewal fails
-- Stripe moves the period on to the end of the unpaid week and marks it past_due
select tests.as_service();
select (public.sync_stripe_subscription(tests.fx('shop_a'), 'sub_test1', 'past_due', now() + interval '10 days', false, null, now())).status;
select tests.as_superuser();
select tests.eq((select current_period_end from public.memberships where id = tests.fx('mem')), now() + interval '10 days',
                'current_period_end is the unpaid period''s end');
select tests.eq(pg_temp.paid_through(), now() + interval '3 days', 'past_due: paid through the start of the unpaid week');
select tests.eq(pg_temp.total(:'t1'), 0::bigint, 'the visit in the paid week stays included');
select tests.eq(array[pg_temp.total(:'t5'), pg_temp.total(:'t12')], array[5500, 5500]::bigint[],
                'the visits from the unpaid week on are charged the catalog price (5000 + 10% tax)');
select tests.eq((select count(*) from public.job_line_items li join public.jobs j on j.id = li.job_id
                  where j.public_token in (:'t5'::uuid, :'t12'::uuid) and li.membership_id is not null), 0::bigint,
                'and no longer use the membership');
select tests.eq(pg_temp.notes('Membership payment failed: booked visits after the paid period need paying'), 3::bigint,
                'owners, admins and managers are told');
select tests.ok((select body like '%paid through%' and body like '%Now charged at the catalog price: Job #%'
                   from public.notifications where shop_id = tests.fx('shop_a')
                    and title like 'Membership payment failed%' limit 1), 'naming the jobs');

-- the same state again (webhook retry): nothing new
select tests.as_service();
select public.sync_stripe_subscription(tests.fx('shop_a'), 'sub_test1', 'past_due', now() + interval '10 days', false, null, now());
select tests.as_superuser();
select tests.eq(pg_temp.notes('Membership payment failed: booked visits after the paid period need paying'), 3::bigint,
                'a repeated past_due sync notifies nobody again');

-- no new free visit while past_due (only an active membership covers one)
select tests.authenticate_as(tests.fx('u_alice'));
select pg_temp.book(((now() at time zone 'America/Chicago')::date + 2)::text) ->> 'job_token' as t2 \gset
select tests.as_superuser();
select tests.eq(pg_temp.total(:'t2'), 5500::bigint, 'a booking while past_due is priced');

-- dunning gives up: Stripe cancels. The cutoff stays the start of the unpaid week
select tests.as_service();
select (public.sync_stripe_subscription(tests.fx('shop_a'), 'sub_test1', 'cancelled', now() + interval '10 days', false, null, now())).status;
select tests.as_superuser();
select tests.eq(pg_temp.paid_through(), now() + interval '3 days', 'cancelled: paid_through kept');
select tests.eq(array[pg_temp.total(:'t1'), pg_temp.total(:'t5'), pg_temp.total(:'t12')], array[0, 5500, 5500]::bigint[],
                'the paid week''s visit stays included; the unpaid ones stay charged');

-- ============================================================ past_due straight to cancelled, then a recovery
-- a second member (cust_a2), monthly: one paid month, then an unpaid renewal
insert into public.membership_plans (shop_id, name, price_cents, interval, interval_count, included_service_ids, included_uses_per_period)
  values (tests.fx('shop_a'), 'Monthly wash', 3000, 'month', 1, array[tests.fx('svc_wash')], 1) returning tests.fx_set('plan_m', id);
select now() - interval '20 days' as m_start,
       public.membership_add_periods(now() - interval '20 days', 'month', 1, 1) as m_end1,
       public.membership_add_periods(now() - interval '20 days', 'month', 1, 2) as m_end2 \gset
insert into public.memberships (shop_id, plan_id, customer_id, status, current_period_end, started_at, created_by, stripe_subscription_id)
  values (tests.fx('shop_a'), tests.fx('plan_m'), tests.fx('cust_a2'), 'active', :'m_end1', :'m_start',
          tests.fx('u_manager_a'), 'sub_test2')
  returning tests.fx_set('mem2', id);
select tests.eq((select paid_through from public.memberships where id = tests.fx('mem2')), :'m_end1'::timestamptz,
                'an active insert is paid through its period end');
-- the webhook first stores the renewal (still active, invoice not paid yet), then past_due
select tests.as_service();
select public.sync_stripe_subscription(tests.fx('shop_a'), 'sub_test2', 'active', :'m_end2', false, null, now());
select public.sync_stripe_subscription(tests.fx('shop_a'), 'sub_test2', 'past_due', :'m_end2', false, null, now());
select tests.as_superuser();
select tests.eq((select paid_through from public.memberships where id = tests.fx('mem2')), :'m_end1'::timestamptz,
                'past_due after an unpaid renewal: back to the start of the unpaid month (calendar month from the anchor)');
-- the retry succeeds: paid through the new period end again
select tests.as_service();
select public.sync_stripe_subscription(tests.fx('shop_a'), 'sub_test2', 'active', :'m_end2', false, null, now());
select tests.as_superuser();
select tests.eq((select paid_through = current_period_end from public.memberships where id = tests.fx('mem2')), true,
                'past_due -> active: paid through the period end');

-- ============================================================ server-maintained
select tests.authenticate_as(tests.fx('u_owner_a'));
update public.memberships set paid_through = now() + interval '1 year' where id = tests.fx('mem2');
select tests.as_superuser();
select tests.eq((select paid_through = current_period_end from public.memberships where id = tests.fx('mem2')), true,
                'staff cannot move paid_through');
select tests.as_superuser();
insert into public.memberships (shop_id, plan_id, customer_id, status, created_by)
  values (tests.fx('shop_a'), tests.fx('plan_m'), tests.fx('cust_a3'), 'incomplete', tests.fx('u_manager_a'))
  returning tests.fx_set('mem3', id);
select tests.eq((select paid_through from public.memberships where id = tests.fx('mem3')), null::timestamptz,
                'a membership never paid has no paid_through');
update public.memberships set status = 'cancelled' where id = tests.fx('mem3');
select tests.eq((select paid_through from public.memberships where id = tests.fx('mem3')), null::timestamptz,
                'and keeps none when it is cancelled unpaid');

-- membership_period_bounds is unchanged (it now reads through membership_period_bounds_of)
select tests.eq(public.membership_period_bounds(tests.fx('mem2'), now()),
                (select public.membership_period_bounds_of(started_at, current_period_end, created_at, interval, interval_count, now())
                   from public.memberships where id = tests.fx('mem2')), 'same bounds from the stored row');
select tests.ok(not has_function_privilege('authenticated',
                  'public.membership_period_bounds_of(timestamptz, timestamptz, timestamptz, public.membership_interval, integer, timestamptz)',
                  'execute'), 'the helper is internal');
