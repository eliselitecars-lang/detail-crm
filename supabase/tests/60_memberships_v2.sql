-- 60 money: memberships v2 (P-23, 0069) — weekly billing, usage limits
-- counted from job lines (auto-assignment, validation, period roll-over,
-- cancelled jobs free a use), price_services_core with uses, online
-- bookings of a linked client, the public join page and
-- membership_join_prepare (matching / trust, retries, PT429), the joined
-- notification, the portal list and access check, membership_usage, RLS.
\ir fixtures/two_shops.psql
\ir fixtures/40_booking_setup.psql

select ((now() at time zone 'America/Chicago')::date + 30)::text as d \gset

-- ============================================================ weekly billing
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.membership_plans (shop_id, name, price_cents, interval, interval_count, included_service_ids,
                                     included_uses_per_period, online_joinable, terms, sort)
  values (tests.fx('shop_a'), 'Wash club', 4000, 'month', 1, array[tests.fx('svc_wash')], 2, true, 'Cancel any time.', 1)
  returning tests.fx_set('plan_wash', id);
insert into public.membership_plans (shop_id, name, price_cents, interval, interval_count, included_service_ids, discount_bps, online_joinable)
  values (tests.fx('shop_a'), 'Weekly wash', 1500, 'week', 2, array[tests.fx('svc_wash')], 1000, true)
  returning tests.fx_set('plan_week', id);
insert into public.membership_plans (shop_id, name, price_cents, included_service_ids, included_uses_per_period)
  values (tests.fx('shop_a'), 'Staff only plan', 9900, array[tests.fx('svc_a'), tests.fx('svc_wash')], 1)
  returning tests.fx_set('plan_one', id);
select tests.throws($$insert into public.membership_plans (shop_id, name, price_cents, interval, interval_count)
                      values (tests.fx('shop_a'), 'Too slow', 100, 'week', 5)$$, '23514', 'a weekly plan bills every 1-4 weeks');
select tests.throws($$insert into public.membership_plans (shop_id, name, price_cents, included_uses_per_period)
                      values (tests.fx('shop_a'), 'Zero', 100, 0)$$, '23514', 'a usage limit is 1-100 (or none)');
select tests.fx_set('mem_week', (public.create_membership(tests.fx('plan_week'), tests.fx('cust_a2'))).id);
select tests.eq((select concat_ws('/', interval, interval_count, status) from public.memberships where id = tests.fx('mem_week')),
                'week/2/incomplete', 'a weekly membership copies its terms');
select tests.as_service();
select public.sync_stripe_subscription(tests.fx('shop_a'), 'sub_week', 'active', '2025-07-01Z', false, tests.fx('mem_week'),
                                       '2025-06-17Z', 'price_week2', 1500, 'week', 2);
select tests.eq((select concat_ws('/', status, interval, interval_count) from public.memberships where id = tests.fx('mem_week')),
                'active/week/2', 'the webhook syncs weekly subscriptions');
select tests.throws_like($$select public.sync_stripe_subscription(tests.fx('shop_a'), 'sub_week', 'active', null, false, null, now(), null, 1500, 'week', 13)$$,
                         '22023', '%invalid billing terms%', 'at most 12 weeks');
select tests.as_superuser();
select tests.throws($$update public.memberships set interval_count = 13 where id = tests.fx('mem_week')$$, '23514',
                    'the memberships CHECK agrees');

-- ============================================================ usage limits (counted per billing period)
-- (memberships inserted directly here carry created_by like staff-created
-- ones: created_by null marks an online join)
insert into public.memberships (shop_id, plan_id, customer_id, status, current_period_end, created_by)
  values (tests.fx('shop_a'), tests.fx('plan_wash'), tests.fx('cust_a'), 'active', '2025-07-15 05:00Z', tests.fx('u_manager_a')) returning tests.fx_set('mem_wash', id);
select tests.eq(public.membership_period_bounds(tests.fx('mem_wash'), '2025-06-20Z'), tstzrange('2025-06-15 05:00Z', '2025-07-15 05:00Z'),
                'the current period ends at current_period_end');
select tests.eq(public.membership_period_bounds(tests.fx('mem_wash'), '2025-07-20Z'), tstzrange('2025-07-15 05:00Z', '2025-08-15 05:00Z'),
                'later dates fall in later periods');
select tests.eq(public.membership_period_bounds(tests.fx('mem_wash'), '2025-05-01Z'), tstzrange('2025-04-15 05:00Z', '2025-05-15 05:00Z'),
                'earlier dates in earlier ones');
create function pg_temp.wash_job(p_start timestamptz, p_price bigint default 0, p_membership uuid default null) returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a'), p_start, p_start + interval '1 hour') returning id into v;
  insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents, membership_id)
  values (tests.fx('shop_a'), v, tests.fx('svc_wash'), 'Exterior Wash', p_price, p_membership);
  return v;
end $$;
grant execute on function pg_temp.wash_job(timestamptz, bigint, uuid) to authenticated;
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('wj1', pg_temp.wash_job('2025-06-20 15:00Z'));
select tests.eq((select membership_id from public.job_line_items where job_id = tests.fx('wj1')), tests.fx('mem_wash'),
                'a free included line uses the membership automatically');
select tests.fx_set('wj2', pg_temp.wash_job('2025-06-25 15:00Z'));
select tests.as_superuser();
select tests.eq(public.membership_uses_in_period(tests.fx('mem_wash'), '2025-06-20Z'), 2, 'two uses this period');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('wj3', pg_temp.wash_job('2025-06-30 15:00Z'));
select tests.eq((select membership_id from public.job_line_items where job_id = tests.fx('wj3')), null::uuid,
                'the limit is reached: no membership on a third one');
select tests.throws_like($$select pg_temp.wash_job('2025-07-01 15:00Z', 0, tests.fx('mem_wash'))$$, '22023', '%no membership visits left%',
                         'nor when given explicitly');
select tests.lives($$select pg_temp.wash_job('2025-07-16 15:00Z', 0, tests.fx('mem_wash'))$$, 'the next period has uses again');
update public.jobs set status = 'cancelled' where id = tests.fx('wj2');
select tests.fx_set('wj4', pg_temp.wash_job('2025-07-02 15:00Z'));
select tests.eq((select membership_id from public.job_line_items where job_id = tests.fx('wj4')), tests.fx('mem_wash'),
                'a cancelled job frees its use');
select tests.fx_set('wj5', pg_temp.wash_job('2025-06-21 15:00Z', 5000));
select tests.eq((select membership_id from public.job_line_items where job_id = tests.fx('wj5')),
                null::uuid, 'a paid line never uses a membership automatically');
-- validation of a supplied membership
select tests.throws_like($$insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents, membership_id)
                           values (tests.fx('shop_a'), tests.fx('job_a2'), tests.fx('svc_wash'), 'W', 0, tests.fx('mem_wash'))$$,
                         '22023', '%another customer%', 'another customer''s membership');
select tests.throws_like($$insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents, membership_id)
                           values (tests.fx('shop_a'), tests.fx('wj1'), tests.fx('svc_a'), 'Full', 0, tests.fx('mem_wash'))$$,
                         '22023', '%does not include this service%', 'a service the plan does not include');
select tests.as_superuser();
update public.memberships set status = 'past_due' where id = tests.fx('mem_week');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws_like($$insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents, membership_id)
                           values (tests.fx('shop_a'), tests.fx('job_a2'), tests.fx('svc_wash'), 'W', 0, tests.fx('mem_week'))$$,
                         '22023', '%not active%', 'a past-due membership is not used');
select tests.as_superuser();
insert into public.memberships (shop_id, plan_id, customer_id, vehicle_id, status, created_by)
  values (tests.fx('shop_a'), tests.fx('plan_one'), tests.fx('cust_a'), tests.fx('veh_a'), 'active', tests.fx('u_manager_a')) returning tests.fx_set('mem_veh', id);
insert into public.vehicles (shop_id, customer_id, make, model) values (tests.fx('shop_a'), tests.fx('cust_a'), 'Kia', 'Soul')
  returning tests.fx_set('veh_other', id);
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws_like($$insert into public.job_line_items (shop_id, job_id, service_id, vehicle_id, name, unit_price_cents, membership_id)
                           values (tests.fx('shop_a'), tests.fx('wj1'), tests.fx('svc_a'), tests.fx('veh_other'), 'Full', 0, tests.fx('mem_veh'))$$,
                         '22023', '%covers another vehicle%', 'a vehicle-scoped membership covers its vehicle only');

-- membership_usage (staff)
select tests.eq(public.membership_usage(tests.fx('mem_wash'), '2025-06-20Z') - 'period_start' - 'period_end',
                '{"uses_per_period": 2, "uses_this_period": 2}'::jsonb,
                'usage: the cancelled job no longer counts; the freed use was taken by the 07-02 job');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$select public.membership_usage(tests.fx('mem_wash'))$$, '42501', 'technicians: no membership data');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.throws($$select public.membership_usage(tests.fx('mem_wash'))$$, 'P0002', 'other shops: not found');

-- ============================================================ price_services_core with uses
select tests.as_superuser();
insert into public.memberships (shop_id, plan_id, customer_id, status, current_period_end, created_by)
  values (tests.fx('shop_a'), tests.fx('plan_one'), tests.fx('cust_a3'), 'active', now() + interval '10 days', tests.fx('u_manager_a')) returning tests.fx_set('mem_one', id);
select tests.authenticate_as(tests.fx('u_manager_a'));
create temp table pr as select public.price_services(tests.fx('shop_a'), tests.fx('cust_a3'), array[tests.fx('svc_a'), tests.fx('svc_wash')]) as p;
select tests.eq((select jsonb_agg(jsonb_build_array(l ->> 'name', l -> 'unit_price_cents', l -> 'membership_included', l ->> 'membership_id',
                                                    l -> 'uses_remaining', l ->> 'note') order by o)
                   from pr, jsonb_array_elements(p -> 'lines') with ordinality as t(l, o)),
                jsonb_build_array(jsonb_build_array('Full Detail', 0, true, tests.fx('mem_one'), 0, 'Included with your Staff only plan membership'),
                                  jsonb_build_array('Exterior Wash', 5000, false, null, 0, 'Membership visits used for this period')),
                'the one visit covers the first included service; the second is priced from the catalog');
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a3'), now() + interval '1 day', now() + interval '1 day 1 hour') returning tests.fx_set('j_used', id);
insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('j_used'), tests.fx('svc_a'), 'Full Detail', 0);
select tests.eq((select l -> 'unit_price_cents' from jsonb_array_elements(
                   public.price_services(tests.fx('shop_a'), tests.fx('cust_a3'), array[tests.fx('svc_a')]) -> 'lines') l),
                '20000'::jsonb, 'once used this period, the service is priced from the catalog');

-- ============================================================ an online booking of the linked client
select tests.as_superuser();
select tests.fx_set('u_alice', tests.create_user('alice@example.com'));
update public.customers set portal_user_id = tests.fx('u_alice') where id = tests.fx('cust_a');
insert into public.memberships (shop_id, plan_id, customer_id, status, started_at, created_by)
  values (tests.fx('shop_a'), tests.fx('plan_week'), tests.fx('cust_a'), 'active', now() - interval '1 day', tests.fx('u_manager_a')) returning tests.fx_set('mem_alice_week', id);
select tests.authenticate_as(tests.fx('u_alice'));
select public.create_online_booking('shop-a', pg_temp.booking(jsonb_build_object(
         'customer', jsonb_build_object('first_name', 'Alice', 'email', 'alice@example.com'),
         'vehicle', jsonb_build_object('id', tests.fx('veh_a')),
         'service_ids', jsonb_build_array(tests.fx('svc_wash')),
         'starts_at', :'d' || 'T10:00:00'))) as ob \gset
select tests.as_superuser();
select tests.ok((select li.unit_price_cents = 0 and li.membership_id is not null
                 from public.job_line_items li join public.jobs j on j.id = li.job_id
                 where j.public_token = (:'ob'::jsonb ->> 'job_token')::uuid), 'the member''s online booking is free and uses the membership');

-- ============================================================ the public join page
select tests.as_anon();
select public.public_membership_plans('shop-a') as pub \gset
select tests.eq((select jsonb_agg(p ->> 'name' order by o) from jsonb_array_elements(:'pub'::jsonb -> 'plans') with ordinality as t(p, o)),
                '["Weekly wash", "Wash club"]'::jsonb, 'only active plans offered online (by sort, then name)');
select tests.eq((:'pub'::jsonb -> 'plans' -> 1) - 'id',
                '{"name": "Wash club", "description": null, "price_cents": 4000, "interval": "month", "interval_count": 1,
                  "included_services": ["Exterior Wash"], "discount_bps": 0, "uses_per_period": 2, "vehicle_scoped": false,
                  "terms": "Cancel any time."}'::jsonb, 'curated plan keys');
select tests.throws($$select public.public_membership_plans('nope')$$, 'PT404', 'unknown shop');
select tests.throws($$select public.membership_join_prepare('shop-a', gen_random_uuid(), '{}')$$, '42501', 'join prepare is service_role only');

select tests.as_service();
create function pg_temp.join_payload(p_email text, p_extra jsonb default '{}') returns jsonb language sql as $$
  select jsonb_build_object('customer', jsonb_build_object('first_name', 'Jo', 'last_name', 'Joiner', 'email', p_email,
                                                           'phone', '205-555-0177', 'sms_opt_in', true),
                            'vehicle', jsonb_build_object('year', 2022, 'make', 'Mazda', 'model', 'CX-5')) || p_extra
$$;
select public.membership_join_prepare('shop-a', tests.fx('plan_wash'), pg_temp.join_payload('jo@example.com')) as j1 \gset
select tests.as_superuser();
select tests.ok((select c.source = 'online_booking' and c.lifecycle = 'lead' and c.phone = '+12055550177' and c.phone_unverified
                        and not c.sms_opt_in and not c.email_opt_in
                        and m.status = 'incomplete' and m.created_by is null and v.make = 'Mazda'
                 from public.memberships m
                 join public.customers c on c.id = m.customer_id
                 join public.vehicles v on v.id = m.vehicle_id
                 where m.id = (:'j1'::jsonb ->> 'membership_id')::uuid),
                'a new customer (unverified phone; a lead without consent until paid, 0110) with the vehicle and an incomplete membership');
select tests.eq(:'j1'::jsonb ->> 'email', 'jo@example.com', 'returns the email for Checkout');
select tests.as_service();
select tests.eq((public.membership_join_prepare('shop-a', tests.fx('plan_wash'), pg_temp.join_payload('JO@example.com')) ->> 'membership_id'),
                :'j1'::jsonb ->> 'membership_id', 'a retried join reuses the never-billed membership');
-- an existing customer is matched and never modified
select public.membership_join_prepare('shop-a', tests.fx('plan_wash'),
         pg_temp.join_payload('alice@example.com', '{"customer":{"first_name":"Mallory","email":"alice@example.com","phone":"+12055550101"}}')) as j2 \gset
select tests.eq((:'j2'::jsonb ->> 'customer_id')::uuid, tests.fx('cust_a'), 'matched by email');
select tests.as_superuser();
select tests.eq((select first_name from public.customers where id = tests.fx('cust_a')), 'Alice', 'and left unchanged');
select tests.as_service();
select tests.throws_like($$select public.membership_join_prepare('shop-a', tests.fx('plan_one'), pg_temp.join_payload('x@example.com'))$$,
                         '55000', '%not available online%', 'a plan not offered online');
select tests.throws($$select public.membership_join_prepare('shop-b', tests.fx('plan_wash'), pg_temp.join_payload('x@example.com'))$$,
                    '55000', 'another shop''s plan');
select tests.throws($$select public.membership_join_prepare('shop-a', tests.fx('plan_wash'), '{"customer":{"first_name":"X","email":"bad"}}')$$,
                    '22023', 'invalid email');
select tests.throws($$select public.membership_join_prepare('shop-a', tests.fx('plan_wash'), '{"customer":{"email":"n@example.com"}}')$$,
                    '22023', 'first name required');
select tests.throws($$select public.membership_join_prepare('shop-a', tests.fx('plan_wash'), '{"customer":{"first_name":"N","email":"n@example.com"},"vehicle":{"make":"Kia"}}')$$,
                    '22023', 'a vehicle needs its model');
select tests.throws($$select public.membership_join_prepare('nope', tests.fx('plan_wash'), '{}')$$, 'PT404', 'unknown shop');
-- abuse limit: 3 online joins per email per day
select public.membership_join_prepare('shop-a', tests.fx('plan_week'), pg_temp.join_payload('jo@example.com'));
select public.membership_join_prepare('shop-a', tests.fx('plan_week'), pg_temp.join_payload('jo@example.com', '{"vehicle":{"make":"Ford","model":"Focus"}}'));
select tests.throws($$select public.membership_join_prepare('shop-a', tests.fx('plan_week'), pg_temp.join_payload('jo@example.com', '{"vehicle":{"make":"VW","model":"Golf"}}'))$$,
                    'PT429', 'a fourth sign-up for one email within a day is refused');

-- ============================================================ activation notifies managers (online joins only)
select public.sync_stripe_subscription(tests.fx('shop_a'), 'sub_jo', 'active', now() + interval '30 days', false,
                                       (:'j1'::jsonb ->> 'membership_id')::uuid);
select tests.as_superuser();
select tests.eq((select count(*) from public.notifications where shop_id = tests.fx('shop_a') and kind = 'membership_joined'),
                3::bigint, 'owners, admins and managers hear about the new member');
select tests.ok((select title like 'New member: Jo Joiner joined Wash club' and body = '$40.00 every month'
                 from public.notifications where shop_id = tests.fx('shop_a') and kind = 'membership_joined' limit 1), 'with who and what');
select tests.eq((select count(*) from public.notifications where shop_id = tests.fx('shop_a') and kind = 'membership_joined'
                    and customer_id = (:'j1'::jsonb ->> 'customer_id')::uuid), 3::bigint, 'linked to the customer');
select tests.ok((select c.lifecycle = 'customer' and c.sms_opt_in and not c.email_opt_in
                 from public.customers c where c.id = (:'j1'::jsonb ->> 'customer_id')::uuid),
                '0110: paid -> a customer, with the text consent the join asked for (and no email consent it did not ask for)');
select tests.as_service();
select public.sync_stripe_subscription(tests.fx('shop_a'), 'sub_week', 'active', null, false);
select tests.as_superuser();
select tests.eq((select count(*) from public.notifications where shop_id = tests.fx('shop_a') and kind = 'membership_joined'),
                3::bigint, 'staff-created memberships do not notify');

-- ============================================================ portal
select tests.authenticate_as(tests.fx('u_alice'));
select public.portal_memberships() as pm \gset
select tests.eq((select jsonb_agg(m ->> 'plan_name' order by m ->> 'plan_name') from jsonb_array_elements(:'pm'::jsonb) m),
                '["Staff only plan", "Wash club", "Weekly wash"]'::jsonb, 'the linked client sees their memberships (not the unbilled join)');
select tests.eq((select m - 'id' - 'current_period_end' from jsonb_array_elements(:'pm'::jsonb) m where m ->> 'plan_name' = 'Wash club'),
                '{"shop_name": "Shop A", "shop_slug": "shop-a", "plan_name": "Wash club", "status": "active", "price_cents": 4000,
                  "interval": "month", "interval_count": 1, "cancel_at_period_end": false, "uses_per_period": 2,
                  "uses_this_period": 0, "can_cancel": false}'::jsonb,
                'curated keys; no Stripe subscription -> nothing to cancel online');
select tests.authenticate_as(tests.fx('u_outsider'));
select tests.eq(public.portal_memberships(), '[]'::jsonb, 'another user sees none');
select tests.throws($$select public.portal_membership_access(tests.fx('mem_wash'), auth.uid())$$, '42501', 'the access check is service_role only');
select tests.as_anon();
select tests.throws($$select public.portal_memberships()$$, '42501', 'anon cannot call the portal');
select tests.as_service();
select tests.eq(public.portal_membership_access((:'j1'::jsonb ->> 'membership_id')::uuid, tests.fx('u_alice')), null::jsonb,
                'someone else''s membership: no access');
select tests.eq(public.portal_membership_access(tests.fx('mem_alice_week'), tests.fx('u_alice')) - 'shop_id',
                '{"stripe_subscription_id": null, "stripe_customer_id": null, "status": "active"}'::jsonb, 'the linked user gets the handles');
select tests.eq(public.portal_membership_access(tests.fx('mem_alice_week'), null), null::jsonb, 'no user, no access');

-- ============================================================ grants
select tests.as_superuser();
select tests.ok(not has_function_privilege('authenticated', 'public.create_membership_core(uuid, uuid, uuid)', 'execute')
                and not has_function_privilege('authenticated', 'public.membership_uses_in_period(uuid, timestamptz, uuid)', 'execute')
                and not has_function_privilege('anon', 'public.membership_join_prepare(text, uuid, jsonb, timestamptz, inet)', 'execute')
                and has_function_privilege('anon', 'public.public_membership_plans(text)', 'execute')
                and has_function_privilege('authenticated', 'public.portal_memberships()', 'execute')
                and not has_function_privilege('anon', 'public.portal_memberships()', 'execute'),
                'internal helpers, public plans, portal list');
