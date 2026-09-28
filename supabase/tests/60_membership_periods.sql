-- 60 money: membership usage limits are counted in the billing period of the
-- VISIT (P-23, 0069 price_services_core p_starts_at + create_online_booking,
-- sched 0054): future bookings beyond the limit are charged, a visit in a
-- later period with uses left is free although the current period is used
-- up, the free line names its membership (the trigger re-checks the use);
-- and lines a membership visit used never block deleting a service or a
-- vehicle (ON DELETE SET NULL passes job_line_items_61_membership_use), nor
-- edits of lines whose membership has ended. Isolation and role checks.
\ir fixtures/two_shops.psql
\ir fixtures/40_booking_setup.psql

select tests.as_superuser();
-- a 1-visit-per-month wash club; the current period ends in 5 days, so the
-- next one is [now + 5 days, now + 5 days + 1 month)
insert into public.membership_plans (shop_id, name, price_cents, interval, interval_count, included_service_ids,
                                     included_uses_per_period)
  values (tests.fx('shop_a'), 'Wash club', 4000, 'month', 1, array[tests.fx('svc_wash')], 1)
  returning tests.fx_set('plan', id);
select tests.fx_set('u_alice', tests.create_user('alice@example.com'));
update public.customers set portal_user_id = tests.fx('u_alice') where id = tests.fx('cust_a');
insert into public.memberships (shop_id, plan_id, customer_id, status, current_period_end, created_by)
  values (tests.fx('shop_a'), tests.fx('plan'), tests.fx('cust_a'), 'active', now() + interval '5 days', tests.fx('u_manager_a'))
  returning tests.fx_set('mem', id);

-- shop-local days: +2 is in the current period, +12 / +13 in the next one
select ((now() at time zone 'America/Chicago')::date + 2)::text as d_now,
       ((now() at time zone 'America/Chicago')::date + 12)::text as d1,
       ((now() at time zone 'America/Chicago')::date + 13)::text as d2 \gset

create function pg_temp.book(p_day text) returns jsonb language sql as $$
  select public.create_online_booking('shop-a', pg_temp.booking(jsonb_build_object(
           'customer', jsonb_build_object('first_name', 'Alice', 'email', 'alice@example.com'),
           'vehicle', jsonb_build_object('id', tests.fx('veh_a')),
           'service_ids', jsonb_build_array(tests.fx('svc_wash')), 'starts_at', p_day || 'T10:00:00')))
$$;
grant execute on function pg_temp.book(text) to authenticated;

create function pg_temp.lines(p_tokens uuid[]) returns jsonb language sql as $$
  select coalesce(jsonb_agg(jsonb_build_array(li.unit_price_cents, li.membership_id is not null) order by j.scheduled_start), '[]')
    from public.job_line_items li join public.jobs j on j.id = li.job_id
   where j.public_token = any (p_tokens)
$$;

-- ============================================================ pricing counts the visit's period
select tests.as_service();
select tests.eq((public.price_services_core(tests.fx('shop_a'), tests.fx('cust_a'), null, array[tests.fx('svc_wash')],
                                            tests.fx('veh_a'), true, now() + interval '12 days') #> '{lines,0}')
                  - array['service_id', 'name', 'kind', 'taxable', 'duration_minutes', 'membership_id', 'note'],
                '{"catalog_price_cents": 5000, "unit_price_cents": 0, "membership_included": true, "uses_remaining": 0}'::jsonb,
                'a visit next period: included, the period''s last use');
select tests.eq(public.price_services_core(tests.fx('shop_a'), tests.fx('cust_a'), null, array[tests.fx('svc_wash')],
                                           tests.fx('veh_a'), true) #>> '{lines,0,unit_price_cents}', '0',
                'without a start: the current period (6-argument callers unchanged)');

-- ============================================================ two bookings in the same future period
select tests.authenticate_as(tests.fx('u_alice'));
select pg_temp.book(:'d1') as ob1 \gset
select pg_temp.book(:'d2') as ob2 \gset
select tests.as_superuser();
select tests.eq(public.membership_uses_in_period(tests.fx('mem'), now() + interval '12 days'), 1,
                'one use recorded in the next period');
select tests.eq(public.membership_uses_in_period(tests.fx('mem'), now()), 0, 'none in the current period');
select tests.eq(pg_temp.lines(array[(:'ob1'::jsonb ->> 'job_token')::uuid, (:'ob2'::jsonb ->> 'job_token')::uuid]),
                '[[0, true], [5000, false]]'::jsonb,
                'a 1-visit plan: the first visit of the period is free, the second is charged');
select tests.eq((:'ob2'::jsonb ->> 'total_cents')::bigint, 5500::bigint, 'the second booking''s total: 5000 + 10% tax');
select tests.eq((select li.description from public.job_line_items li join public.jobs j on j.id = li.job_id
                  where j.public_token = (:'ob2'::jsonb ->> 'job_token')::uuid),
                'Membership visits used for this period', 'and says why');

-- ============================================================ the reverse: current period used up
-- a staff visit takes the current period's use; the next period still has none left (ob1)
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.jobs (shop_id, customer_id, vehicle_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('veh_a'), now() + interval '1 day', now() + interval '1 day 1 hour')
  returning tests.fx_set('job_staff', id);
insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('job_staff'), tests.fx('svc_wash'), 'Wash', 0);
select tests.eq((select membership_id from public.job_line_items where job_id = tests.fx('job_staff')), tests.fx('mem'),
                'the staff visit uses the current period');
-- cancel ob1 (frees next period's use), then book in the current and the next period
select tests.as_superuser();
update public.jobs set status = 'cancelled' where public_token = (:'ob1'::jsonb ->> 'job_token')::uuid;
select tests.authenticate_as(tests.fx('u_alice'));
select pg_temp.book(:'d_now') as ob3 \gset
select tests.as_superuser();
select tests.eq(pg_temp.lines(array[(:'ob3'::jsonb ->> 'job_token')::uuid]), '[[5000, false]]'::jsonb,
                'a visit in the used-up current period is charged');
-- a visit in the next period (which has a use again) is free although the current one is used up
select tests.as_service();
select tests.eq(public.price_services_core(tests.fx('shop_a'), tests.fx('cust_a'), null, array[tests.fx('svc_wash')],
                                           tests.fx('veh_a'), true, now() + interval '12 days') #>> '{lines,0,unit_price_cents}',
                '0', 'the next period has its use back once ob1 is cancelled');
select tests.eq(public.price_services_core(tests.fx('shop_a'), tests.fx('cust_a'), null, array[tests.fx('svc_wash')],
                                           tests.fx('veh_a'), true, now() + interval '2 days') #>> '{lines,0,unit_price_cents}',
                '5000', 'while the current period has none');

-- ============================================================ a free line names its membership; the trigger re-checks
select tests.as_superuser();
select tests.eq((select li.membership_id from public.job_line_items li join public.jobs j on j.id = li.job_id
                  where j.public_token = (:'ob1'::jsonb ->> 'job_token')::uuid), tests.fx('mem'),
                'the online booking wrote the membership on its free line');
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.jobs (shop_id, customer_id, vehicle_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('veh_a'), now() + interval '2 days', now() + interval '2 days 1 hour')
  returning tests.fx_set('job_full', id);
select tests.throws_like($$insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents, membership_id)
                           values (tests.fx('shop_a'), tests.fx('job_full'), tests.fx('svc_wash'), 'Wash', 0, tests.fx('mem'))$$,
                         '22023', '%no membership visits left%',
                         'a line naming a membership whose period is used up is refused (what a racing booking hits)');

-- ============================================================ shop B cannot use shop A's membership
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.throws($$insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents, membership_id)
                      values (tests.fx('shop_b'), tests.fx('job_b'), tests.fx('svc_b'), 'Wash', 0, tests.fx('mem'))$$,
                    '23503', 'another shop''s membership (composite FK)');
select tests.as_anon();
select tests.throws($$select public.price_services_core(tests.fx('shop_a'), tests.fx('cust_a'), null, array[tests.fx('svc_wash')])$$,
                    '42501', 'price_services_core is internal (anon)');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.throws($$select public.price_services_core(tests.fx('shop_a'), tests.fx('cust_a'), null, array[tests.fx('svc_wash')],
                                                        null, true, now())$$,
                    '42501', 'and internal for signed-in users (even the owner)');

-- ============================================================ deleting a service / vehicle a membership visit used
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.membership_plans (shop_id, name, price_cents, included_service_ids)
  values (tests.fx('shop_a'), 'Detail club', 9000, array[tests.fx('svc_a')]) returning tests.fx_set('plan2', id);
select tests.as_superuser();
insert into public.memberships (shop_id, plan_id, customer_id, status, current_period_end, created_by)
  values (tests.fx('shop_a'), tests.fx('plan2'), tests.fx('cust_a2'), 'active', now() + interval '20 days', tests.fx('u_manager_a'))
  returning tests.fx_set('mem2', id);
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.jobs (shop_id, customer_id, vehicle_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a2'), tests.fx('veh_a2'), now() + interval '3 days', now() + interval '3 days 2 hours')
  returning tests.fx_set('job_m2', id);
insert into public.job_line_items (shop_id, job_id, service_id, vehicle_id, name, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('job_m2'), tests.fx('svc_a'), tests.fx('veh_a2'), 'Covered detail', 0)
  returning tests.fx_set('line_m2', id);
select tests.eq((select membership_id from public.job_line_items where id = tests.fx('line_m2')), tests.fx('mem2'),
                'setup: the free line uses the membership');
-- a client cannot clear the service of a membership line (depth 1: still checked)
select tests.throws_like($$update public.job_line_items set service_id = null where id = tests.fx('line_m2')$$,
                         '22023', '%does not include this service%', 'a staff edit clearing the service is still refused');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.lives($$delete from public.services where id = tests.fx('svc_a')$$,
                   'the owner can delete a service that a membership visit used');
select tests.as_superuser();
select tests.eq((select concat_ws('/', coalesce(service_id::text, 'none'), membership_id = tests.fx('mem2'), name, unit_price_cents)
                 from public.job_line_items where id = tests.fx('line_m2')),
                'none/t/Covered detail/0', 'the line keeps its snapshot and the use it recorded');
select tests.eq(public.membership_uses_in_period(tests.fx('mem2'), now() + interval '3 days'), 1, 'the use still counts');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.lives($$delete from public.vehicles where id = tests.fx('veh_a2')$$,
                   'and a vehicle that a membership visit used');
select tests.as_superuser();
select tests.eq((select concat_ws('/', coalesce(vehicle_id::text, 'none'), membership_id = tests.fx('mem2'))
                 from public.job_line_items where id = tests.fx('line_m2')), 'none/t', 'the vehicle link is cleared, the use kept');

-- ============================================================ lines of an ended membership are history
insert into public.services (shop_id, name, duration_minutes) values (tests.fx('shop_a'), 'Hand wax', 60)
  returning tests.fx_set('svc_wax', id);
update public.memberships set status = 'cancelled', cancelled_at = now() where id = tests.fx('mem');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.lives($$update public.job_line_items set service_id = tests.fx('svc_wax') where job_id = tests.fx('job_staff')$$,
                   'a line of a cancelled membership can still be edited');
select tests.eq((select membership_id from public.job_line_items where job_id = tests.fx('job_staff')), tests.fx('mem'),
                'it keeps its (historic) membership');
select tests.throws_like($$insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents, membership_id)
                           values (tests.fx('shop_a'), tests.fx('job_full'), tests.fx('svc_wash'), 'Wash', 0, tests.fx('mem'))$$,
                         '22023', '%not active%', 'but a cancelled membership cannot be attached to a new line');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$update public.job_line_items set name = 'x' where job_id = tests.fx('job_staff')$$), 0::bigint,
                'technicians cannot edit job lines');
