-- 60 money: membership visits follow the JOB (0069
-- jobs_zz_money_membership_uses). Uses are counted by the job's customer,
-- vehicle, status and scheduled start, so a job update that changes one of
-- them re-validates the job's membership lines (22023, the update fails):
--   * a reschedule into another billing period (or a cancelled / no-show job
--     counting again) may not exceed the plan's included visits;
--   * a job moved to another customer (or a vehicle-scoped visit moved to
--     another vehicle) may not keep the previous membership's free line.
-- Same-period reschedules, cancellations, other status changes, ended
-- memberships, unlimited plans and customer merges are let through. Roles
-- (owner / admin / manager / service_role alike), shop isolation.
\ir fixtures/two_shops.psql
\ir fixtures/40_booking_setup.psql

select tests.as_superuser();
-- a 1-visit-per-month wash club whose current period ends in 20 days:
-- now + 2 / 3 days are in the current period, now + 25 / 27 days in the next
insert into public.membership_plans (shop_id, name, price_cents, interval, interval_count, included_service_ids,
                                     included_uses_per_period)
  values (tests.fx('shop_a'), 'Wash club', 4000, 'month', 1, array[tests.fx('svc_wash')], 1)
  returning tests.fx_set('plan', id);
insert into public.memberships (shop_id, plan_id, customer_id, status, current_period_end, created_by)
  values (tests.fx('shop_a'), tests.fx('plan'), tests.fx('cust_a'), 'active', now() + interval '20 days', tests.fx('u_manager_a'))
  returning tests.fx_set('mem', id);

create function pg_temp.job(p_customer uuid, p_vehicle uuid, p_days integer) returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into public.jobs (shop_id, customer_id, vehicle_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), p_customer, p_vehicle, now() + make_interval(days => p_days),
          now() + make_interval(days => p_days, hours => 1))
  returning id into v;
  insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents)
  values (tests.fx('shop_a'), v, tests.fx('svc_wash'), 'Wash', 0);
  return v;
end $$;
grant execute on function pg_temp.job(uuid, uuid, integer) to authenticated, service_role;

create function pg_temp.move(p_job uuid, p_days integer) returns void language sql as $$
  update public.jobs set scheduled_start = now() + make_interval(days => p_days),
                         scheduled_end = now() + make_interval(days => p_days, hours => 1)
   where id = p_job
$$;
grant execute on function pg_temp.move(uuid, integer) to authenticated, service_role;

select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('j1', pg_temp.job(tests.fx('cust_a'), tests.fx('veh_a'), 2));
select tests.fx_set('j2', pg_temp.job(tests.fx('cust_a'), tests.fx('veh_a'), 25));
select tests.eq((select count(*) from public.job_line_items where membership_id = tests.fx('mem')), 2::bigint,
                'one free visit in each period');

-- ============================================================ reschedule into a used-up period
select tests.throws_like($$select pg_temp.move(tests.fx('j2'), 3)$$, '22023', '%no membership visits left%',
                         'moving the next period''s free visit into this (used-up) period fails');
select tests.throws_like($$select pg_temp.move(tests.fx('j2'), 3)$$, '22023', '%Wash club includes 1 per period%',
                         'naming the plan and its limit');
select tests.as_superuser();
select tests.ok(public.membership_uses_in_period(tests.fx('mem'), now() + interval '3 days') <= 1,
                'a 1-visit plan never has 2 free visits in one period');
select tests.eq((select scheduled_start from public.jobs where id = tests.fx('j2')), now() + interval '25 days',
                'the job stayed where it was');
-- every writer hits the same rule
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.throws($$select pg_temp.move(tests.fx('j2'), 3)$$, '22023', 'owner: refused as well');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.throws($$select pg_temp.move(tests.fx('j2'), 3)$$, '22023', 'admin: refused as well');
select tests.as_service();
select tests.throws($$select pg_temp.move(tests.fx('j2'), 3)$$, '22023', 'service_role (edge functions): refused as well');

-- ============================================================ what is let through
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.lives($$select pg_temp.move(tests.fx('j2'), 27)$$, 'a reschedule inside its own period');
select tests.lives($$select pg_temp.move(tests.fx('j1'), 3)$$, 'the current period''s visit moves inside its period');
select tests.lives($$update public.jobs set status = 'confirmed' where id = tests.fx('j1')$$,
                   'status changes of a counted job are not re-checked');
select tests.lives($$update public.jobs set notes = 'Gate code 1234' where id = tests.fx('j1')$$, 'nor unrelated edits');
-- cancelling frees the use; the next period's visit may then move in
select tests.lives($$update public.jobs set status = 'cancelled', cancel_reason = 'Sick' where id = tests.fx('j1')$$,
                   'cancelling frees this period''s visit');
select tests.lives($$select pg_temp.move(tests.fx('j2'), 4)$$, 'so the other visit may move into this period');
select tests.eq((select count(*) from public.job_line_items li join public.jobs j on j.id = li.job_id
                  where li.membership_id = tests.fx('mem') and j.id = tests.fx('j2')), 1::bigint,
                'and keeps its free line');
-- ... but the cancelled job cannot come back while that would exceed the plan
select tests.throws_like($$update public.jobs set status = 'scheduled' where id = tests.fx('j1')$$, '22023',
                         '%no membership visits left%', 'un-cancelling a visit into a used-up period fails');
select tests.lives($$update public.jobs set status = 'scheduled', scheduled_start = now() + interval '26 days',
                                           scheduled_end = now() + interval '26 days 1 hour'
                     where id = tests.fx('j1')$$,
                   'un-cancelling it into a period with a use left works');
select tests.as_superuser();
select tests.eq(public.membership_uses_in_period(tests.fx('mem'), now() + interval '26 days'), 1,
                'which then holds exactly its one visit');
select tests.authenticate_as(tests.fx('u_manager_a'));
-- no-show counts nothing, like cancelled
select tests.lives($$update public.jobs set status = 'no_show' where id = tests.fx('j2')$$, 'a no-show frees its visit');
select tests.lives($$select pg_temp.move(tests.fx('j1'), 5)$$, 'so another visit may take this period');
select tests.throws_like($$update public.jobs set status = 'scheduled' where id = tests.fx('j2')$$, '22023',
                         '%no membership visits left%', 'and the no-show cannot count again on top of it');

-- a membership that is not active grants nothing new: its lines (history)
-- never block a reschedule
select tests.as_superuser();
update public.memberships set status = 'past_due' where id = tests.fx('mem');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.lives($$update public.jobs set status = 'scheduled' where id = tests.fx('j2')$$,
                   'lines of a membership that is not active are not re-counted');
select tests.as_superuser();
update public.memberships set status = 'active' where id = tests.fx('mem');
update public.jobs set status = 'cancelled', cancel_reason = 'Reset' where id in (tests.fx('j1'), tests.fx('j2'));

-- an unlimited plan never blocks
insert into public.membership_plans (shop_id, name, price_cents, interval, interval_count, included_service_ids)
  values (tests.fx('shop_a'), 'Unlimited', 9000, 'month', 1, array[tests.fx('svc_a')])
  returning tests.fx_set('plan_u', id);
insert into public.memberships (shop_id, plan_id, customer_id, status, current_period_end, created_by)
  values (tests.fx('shop_a'), tests.fx('plan_u'), tests.fx('cust_a2'), 'active', now() + interval '20 days', tests.fx('u_manager_a'))
  returning tests.fx_set('mem_u', id);
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.jobs (shop_id, customer_id, vehicle_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a2'), tests.fx('veh_a2'), now() + interval '2 days', now() + interval '2 days 1 hour'),
         (tests.fx('shop_a'), tests.fx('cust_a2'), tests.fx('veh_a2'), now() + interval '25 days', now() + interval '25 days 1 hour');
insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents)
  select tests.fx('shop_a'), j.id, tests.fx('svc_a'), 'Detail', 0 from public.jobs j
   where j.customer_id = tests.fx('cust_a2') and j.scheduled_start > now();
select tests.eq((select count(*) from public.job_line_items where membership_id = tests.fx('mem_u')), 2::bigint,
                'unlimited plan: both visits free');
select tests.lives($$update public.jobs set scheduled_start = now() + interval '3 days', scheduled_end = now() + interval '3 days 1 hour'
                     where customer_id = tests.fx('cust_a2') and scheduled_start > now() + interval '24 days'$$,
                   'and both may share a period');

-- ============================================================ customer / vehicle changes
select tests.as_superuser();
update public.membership_plans set included_uses_per_period = 2 where id = tests.fx('plan');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('j3', pg_temp.job(tests.fx('cust_a'), tests.fx('veh_a'), 6));
select tests.eq((select membership_id from public.job_line_items where job_id = tests.fx('j3')), tests.fx('mem'),
                'free visit on cust_a''s membership');
select tests.throws_like($$update public.jobs set customer_id = tests.fx('cust_a3'), vehicle_id = null where id = tests.fx('j3')$$,
                         '22023', '%previous customer''s membership%',
                         'a job with a free line on its customer''s membership cannot move to another customer');
select tests.as_superuser();
select tests.ok(not exists (select 1 from public.job_line_items li join public.memberships m on m.id = li.membership_id
                             join public.jobs j on j.id = li.job_id
                            where li.job_id = tests.fx('j3') and m.customer_id <> j.customer_id and li.unit_price_cents = 0),
                'a job moved to another customer must not keep a free line on the previous customer''s membership');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.throws($$update public.jobs set customer_id = tests.fx('cust_a3'), vehicle_id = null where id = tests.fx('j3')$$,
                    '22023', 'owner: refused as well');
select tests.as_service();
select tests.throws($$update public.jobs set customer_id = tests.fx('cust_a3'), vehicle_id = null where id = tests.fx('j3')$$,
                    '22023', 'service_role: refused as well');
-- the documented way out: take the membership off the line (it becomes an
-- ordinary priced line), then move the job
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.job_line_items set membership_id = null, unit_price_cents = 5000 where job_id = tests.fx('j3');
select tests.lives($$update public.jobs set customer_id = tests.fx('cust_a3'), vehicle_id = null where id = tests.fx('j3')$$,
                   'once the line is off the membership, the job moves');
select tests.as_superuser();
select tests.eq(public.membership_uses_in_period(tests.fx('mem'), now() + interval '6 days'), 0,
                'and cust_a''s period no longer counts that visit');

-- a merge moves the membership with the job: let through
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('j4', pg_temp.job(tests.fx('cust_a'), tests.fx('veh_a'), 7));
select tests.as_superuser();
select set_config('detailcrm.customer_merge', 'on', true);
select tests.lives($$update public.jobs set customer_id = tests.fx('cust_a3'), vehicle_id = null where id = tests.fx('j4')$$,
                   'during a customer merge (trusted context) the job moves with its membership line');
select set_config('detailcrm.customer_merge', '', true);
select tests.lives($$update public.jobs set customer_id = tests.fx('cust_a'), vehicle_id = tests.fx('veh_a') where id = tests.fx('j4')$$,
                   'back to the membership''s own customer: nothing to refuse');
-- ... but the merge flag does not help a client
select tests.authenticate_as(tests.fx('u_manager_a'));
select set_config('detailcrm.customer_merge', 'on', true);
select tests.throws($$update public.jobs set customer_id = tests.fx('cust_a3'), vehicle_id = null where id = tests.fx('j4')$$,
                    '22023', 'a client cannot claim the merge bypass');
select set_config('detailcrm.customer_merge', '', true);

-- vehicle-scoped membership: the visit stays on that vehicle
select tests.as_superuser();
insert into public.vehicles (shop_id, customer_id, year, make, model)
  values (tests.fx('shop_a'), tests.fx('cust_a'), 2018, 'Honda', 'Fit') returning tests.fx_set('veh_a_2', id);
insert into public.membership_plans (shop_id, name, price_cents, interval, interval_count, included_service_ids)
  values (tests.fx('shop_a'), 'Engine club', 2000, 'month', 1, array[tests.fx('addon_engine')])
  returning tests.fx_set('plan_v', id);
insert into public.memberships (shop_id, plan_id, customer_id, vehicle_id, status, current_period_end, created_by)
  values (tests.fx('shop_a'), tests.fx('plan_v'), tests.fx('cust_a'), tests.fx('veh_a'), 'active', now() + interval '20 days',
          tests.fx('u_manager_a'))
  returning tests.fx_set('mem_v', id);
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.jobs (shop_id, customer_id, vehicle_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('veh_a'), now() + interval '8 days', now() + interval '8 days 1 hour')
  returning tests.fx_set('j5', id);
insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('j5'), tests.fx('addon_engine'), 'Engine', 0) returning tests.fx_set('l5', id);
select tests.eq((select membership_id from public.job_line_items where id = tests.fx('l5')), tests.fx('mem_v'),
                'the vehicle''s membership covers the visit');
select tests.throws_like($$update public.jobs set vehicle_id = tests.fx('veh_a_2') where id = tests.fx('j5')$$, '22023',
                         '%covers another vehicle%', 'the job cannot switch to another vehicle while the line relies on it');
update public.job_line_items set vehicle_id = tests.fx('veh_a') where id = tests.fx('l5');
select tests.lives($$update public.jobs set vehicle_id = tests.fx('veh_a_2') where id = tests.fx('j5')$$,
                   'a line that names the covered vehicle itself keeps it through a job vehicle change');

-- ============================================================ shop isolation
select tests.as_superuser();
insert into public.membership_plans (shop_id, name, price_cents, interval, interval_count, included_service_ids,
                                     included_uses_per_period)
  values (tests.fx('shop_b'), 'B club', 4000, 'month', 1, array[tests.fx('svc_b')], 1)
  returning tests.fx_set('plan_b', id);
insert into public.memberships (shop_id, plan_id, customer_id, status, current_period_end, created_by)
  values (tests.fx('shop_b'), tests.fx('plan_b'), tests.fx('cust_b'), 'active', now() + interval '20 days', tests.fx('u_manager_b'))
  returning tests.fx_set('mem_b', id);
select tests.authenticate_as(tests.fx('u_manager_b'));
insert into public.jobs (shop_id, customer_id, vehicle_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_b'), tests.fx('cust_b'), tests.fx('veh_b'), now() + interval '2 days', now() + interval '2 days 1 hour')
  returning tests.fx_set('jb', id);
insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents)
  values (tests.fx('shop_b'), tests.fx('jb'), tests.fx('svc_b'), 'Wash', 0);
select tests.eq((select membership_id from public.job_line_items where job_id = tests.fx('jb')), tests.fx('mem_b'),
                'shop B''s member gets their own visit');
select tests.lives($$update public.jobs set scheduled_start = now() + interval '3 days', scheduled_end = now() + interval '3 days 1 hour'
                     where id = tests.fx('jb')$$,
                   'shop A''s used-up periods never count against shop B');
select tests.eq(tests.row_count($$update public.jobs set scheduled_start = now() + interval '4 days' where id = tests.fx('j5')$$),
                0::bigint, 'and shop B cannot touch shop A''s jobs');

-- grants: the trigger function is not callable
select tests.as_superuser();
select tests.ok(not has_function_privilege('authenticated', 'public.jobs_money_membership_uses()', 'execute')
                and not has_function_privilege('anon', 'public.jobs_money_membership_uses()', 'execute'),
                'the trigger function is not executable by clients');
