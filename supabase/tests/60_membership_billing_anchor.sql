-- 60 money: membership billing periods follow Stripe's cycle (0069
-- membership_period_bounds). Periods are counted FORWARD from the billing
-- anchor (started_at = Stripe's start_date when current_period_end is on its
-- cycle), in UTC, so a billing day of the 29th-31st keeps its day where the
-- month has it (Jan 31 -> Feb 28 -> Mar 31 -> Apr 30), a renewal never
-- re-buckets visits already booked, and a visit is counted against the
-- period Stripe billed it in. Covers leap years, 30th anchors, weekly and
-- yearly cycles, a moved anchor (period end off the start's cycle), no
-- period end yet, the session time zone, usage / pricing, roles and shop
-- isolation.
\ir fixtures/two_shops.psql

create function pg_temp.b(p_m uuid, p_at timestamptz) returns tstzrange language sql as $$
  select public.membership_period_bounds(p_m, p_at)
$$;
create function pg_temp.mem(p_plan uuid, p_cust uuid, p_start timestamptz, p_end timestamptz,
                            p_interval public.membership_interval default 'month', p_count integer default 1)
returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into public.memberships (shop_id, plan_id, customer_id, status, started_at, current_period_end)
  select pl.shop_id, pl.id, p_cust, 'active', p_start, p_end
    from public.membership_plans pl where pl.id = p_plan
  returning id into v;
  -- the billing terms Stripe reports (inserts copy the plan's)
  update public.memberships set interval = p_interval, interval_count = p_count where id = v;
  return v;
end
$$;

select tests.as_superuser();
insert into public.membership_plans (shop_id, name, price_cents, interval, interval_count, included_service_ids, included_uses_per_period)
  values (tests.fx('shop_a'), 'Club', 4000, 'month', 1, array[tests.fx('svc_a')], 1) returning tests.fx_set('plan', id);
insert into public.membership_plans (shop_id, name, price_cents, interval, interval_count, included_service_ids, included_uses_per_period)
  values (tests.fx('shop_a'), 'Club 2', 4000, 'month', 1, array[tests.fx('svc_a')], 1) returning tests.fx_set('plan2', id);
insert into public.membership_plans (shop_id, name, price_cents, interval, interval_count, included_service_ids, included_uses_per_period)
  values (tests.fx('shop_a'), 'Club 3', 4000, 'month', 1, array[tests.fx('svc_a')], 1) returning tests.fx_set('plan3', id);
insert into public.membership_plans (shop_id, name, price_cents, interval, interval_count, included_service_ids, included_uses_per_period)
  values (tests.fx('shop_b'), 'B club', 4000, 'month', 1, array[tests.fx('svc_b')], 1) returning tests.fx_set('plan_b', id);

-- ============================================================ billing day 31 (the finding)
-- Stripe: Jan 31 -> Feb 28 -> Mar 31 -> Apr 30; the March period is [Feb 28, Mar 31)
insert into public.memberships (shop_id, plan_id, customer_id, status, current_period_end, started_at, created_by)
  values (tests.fx('shop_a'), tests.fx('plan'), tests.fx('cust_a'), 'active', '2025-03-31 12:00+00', '2025-01-31 12:00+00', tests.fx('u_manager_a'))
  returning tests.fx_set('mem', id);
select tests.eq(pg_temp.b(tests.fx('mem'), '2025-03-30 15:00+00'), tstzrange('2025-02-28 12:00+00', '2025-03-31 12:00+00', '[)'),
                'the current period ends at current_period_end and starts at the previous renewal (Feb 28)');
select tests.eq(pg_temp.b(tests.fx('mem'), '2025-02-10 00:00+00'), tstzrange('2025-01-31 12:00+00', '2025-02-28 12:00+00', '[)'),
                'the first period is [Jan 31, Feb 28)');
select tests.eq(pg_temp.b(tests.fx('mem'), '2025-02-28 12:00+00'), tstzrange('2025-02-28 12:00+00', '2025-03-31 12:00+00', '[)'),
                'a boundary instant opens the next period');
select tests.eq(pg_temp.b(tests.fx('mem'), '2025-05-15 00:00+00'), tstzrange('2025-04-30 12:00+00', '2025-05-31 12:00+00', '[)'),
                'future periods keep the 31st where the month has it');
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.jobs (shop_id, customer_id, vehicle_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('veh_a'), '2025-03-30 15:00+00', '2025-03-30 16:00+00') returning tests.fx_set('job_mar', id);
insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('job_mar'), tests.fx('svc_a'), 'Detail', 0);
select tests.eq((select membership_id from public.job_line_items where job_id = tests.fx('job_mar')), tests.fx('mem'),
                'Mar 30 visit uses the March period');
select tests.eq(public.membership_usage(tests.fx('mem'), '2025-03-15 00:00+00') - 'uses_per_period',
                jsonb_build_object('uses_this_period', 1, 'period_start', '2025-02-28T12:00:00+00:00'::timestamptz,
                                   'period_end', '2025-03-31T12:00:00+00:00'::timestamptz),
                'usage reports Stripe''s March period');

-- Stripe renews on Mar 31: the April period is [Mar 31, Apr 30)
select tests.as_superuser();
update public.memberships set current_period_end = '2025-04-30 12:00+00' where id = tests.fx('mem');
select tests.eq(pg_temp.b(tests.fx('mem'), '2025-04-15 12:00+00'), tstzrange('2025-03-31 12:00+00', '2025-04-30 12:00+00', '[)'),
                'April period starts at the renewal');
select tests.eq(pg_temp.b(tests.fx('mem'), '2025-03-30 15:00+00'), tstzrange('2025-02-28 12:00+00', '2025-03-31 12:00+00', '[)'),
                'the renewal does not re-bucket the March visit');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq((public.membership_usage(tests.fx('mem'), '2025-04-15 12:00+00') ->> 'uses_this_period')::integer, 0,
                'the March visit does not use up April');
insert into public.jobs (shop_id, customer_id, vehicle_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('veh_a'), '2025-04-15 15:00+00', '2025-04-15 16:00+00') returning tests.fx_set('job_apr', id);
select tests.lives($$insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents, membership_id)
                     values (tests.fx('shop_a'), tests.fx('job_apr'), tests.fx('svc_a'), 'Detail', 0, tests.fx('mem'))$$,
                   'the paid-for April visit can be used');
insert into public.jobs (shop_id, customer_id, vehicle_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('veh_a'), '2025-04-29 15:00+00', '2025-04-29 16:00+00') returning tests.fx_set('job_apr2', id);
select tests.throws_like($$insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents, membership_id)
                           values (tests.fx('shop_a'), tests.fx('job_apr2'), tests.fx('svc_a'), 'Detail', 0, tests.fx('mem'))$$,
                         '22023', '%no membership visits left%', 'a second April visit is still over the limit');
select tests.eq((public.price_services(tests.fx('shop_a'), tests.fx('cust_a'), array[tests.fx('svc_a')]) -> 'lines' -> 0 ->> 'membership_id'),
                tests.fx('mem')::text, 'staff pricing at now() (a later period) still includes the service');
-- a reschedule from Mar 30 to Mar 31 11:00 (still before the 12:00 renewal) stays in March
select tests.lives($$update public.jobs set scheduled_start = '2025-03-31 11:00+00', scheduled_end = '2025-03-31 11:30+00'
                     where id = tests.fx('job_mar')$$, 'reschedule inside the March period');
-- moving it past the renewal puts it in April, which is used up
select tests.throws_like($$update public.jobs set scheduled_start = '2025-03-31 12:00+00', scheduled_end = '2025-03-31 13:00+00'
                           where id = tests.fx('job_mar')$$, '22023', '%no membership visits left%',
                         'rescheduling onto the renewal instant counts in April');

-- ============================================================ other month-end anchors
select tests.as_superuser();
-- day 30: Jan 30 -> Feb 28 -> Mar 30
select pg_temp.mem(tests.fx('plan2'), tests.fx('cust_a2'), '2025-01-30 08:00+00', '2025-02-28 08:00+00') as m30 \gset
select tests.eq(pg_temp.b(:'m30', '2025-02-01'), tstzrange('2025-01-30 08:00+00', '2025-02-28 08:00+00', '[)'), 'day 30: [Jan 30, Feb 28)');
select tests.eq(pg_temp.b(:'m30', '2025-03-10'), tstzrange('2025-02-28 08:00+00', '2025-03-30 08:00+00', '[)'), 'day 30: [Feb 28, Mar 30)');
update public.memberships set current_period_end = '2025-03-30 08:00+00' where id = :'m30';
select tests.eq(pg_temp.b(:'m30', '2025-03-10'), tstzrange('2025-02-28 08:00+00', '2025-03-30 08:00+00', '[)'), 'day 30: unchanged after renewal');
-- leap year: Jan 31 2024 -> Feb 29 -> Mar 31
select pg_temp.mem(tests.fx('plan3'), tests.fx('cust_a3'), '2024-01-31 00:00+00', '2024-02-29 00:00+00') as mleap \gset
select tests.eq(pg_temp.b(:'mleap', '2024-02-29 00:00+00'), tstzrange('2024-02-29 00:00+00', '2024-03-31 00:00+00', '[)'), 'leap: [Feb 29, Mar 31)');
select tests.eq(pg_temp.b(:'mleap', '2025-02-15'), tstzrange('2025-01-31 00:00+00', '2025-02-28 00:00+00', '[)'), 'next year: [Jan 31, Feb 28)');
delete from public.memberships where id in (:'m30', :'mleap');

-- quarterly (3 months) anchored on Nov 30: Nov 30 -> Feb 28 -> May 30
select pg_temp.mem(tests.fx('plan2'), tests.fx('cust_a2'), '2024-11-30 00:00+00', '2025-05-30 00:00+00', 'month', 3) as mq \gset
select tests.eq(pg_temp.b(:'mq', '2025-03-01'), tstzrange('2025-02-28 00:00+00', '2025-05-30 00:00+00', '[)'), 'quarterly: [Feb 28, May 30)');
select tests.eq(pg_temp.b(:'mq', '2025-01-01'), tstzrange('2024-11-30 00:00+00', '2025-02-28 00:00+00', '[)'), 'quarterly: [Nov 30, Feb 28)');
delete from public.memberships where id = :'mq';

-- yearly on Feb 29: Feb 28 in common years, Feb 29 again in 2028
select pg_temp.mem(tests.fx('plan2'), tests.fx('cust_a2'), '2024-02-29 10:00+00', '2026-02-28 10:00+00', 'year', 1) as my \gset
select tests.eq(pg_temp.b(:'my', '2026-01-01'), tstzrange('2025-02-28 10:00+00', '2026-02-28 10:00+00', '[)'), 'yearly: [2025-02-28, 2026-02-28)');
select tests.eq(pg_temp.b(:'my', '2028-03-01'), tstzrange('2028-02-29 10:00+00', '2029-02-28 10:00+00', '[)'), 'yearly: 2028 keeps Feb 29');
delete from public.memberships where id = :'my';

-- weekly (every 2 weeks) — exact 14-day steps
select pg_temp.mem(tests.fx('plan2'), tests.fx('cust_a2'), '2025-03-03 17:30+00', '2025-04-14 17:30+00', 'week', 2) as mw \gset
select tests.eq(pg_temp.b(:'mw', '2025-04-01'), tstzrange('2025-03-31 17:30+00', '2025-04-14 17:30+00', '[)'), 'bi-weekly current period');
select tests.eq(pg_temp.b(:'mw', '2025-03-10'), tstzrange('2025-03-03 17:30+00', '2025-03-17 17:30+00', '[)'), 'bi-weekly first period');
delete from public.memberships where id = :'mw';

-- ============================================================ anchor moved / no period end
-- a trial (start Jan 10, billing anchored on Jan 15): the period end is not
-- on the start's cycle, so periods step from the period end
select pg_temp.mem(tests.fx('plan2'), tests.fx('cust_a2'), '2025-01-10 09:00+00', '2025-03-15 09:00+00') as mt \gset
select tests.eq(pg_temp.b(:'mt', '2025-03-01'), tstzrange('2025-02-15 09:00+00', '2025-03-15 09:00+00', '[)'), 'moved anchor: [end - 1 month, end)');
select tests.eq(pg_temp.b(:'mt', '2025-01-12'), tstzrange('2024-12-15 09:00+00', '2025-01-15 09:00+00', '[)'), 'moved anchor: earlier periods step from the end');
-- a started_at a few seconds off the cycle is not the anchor either
update public.memberships set started_at = '2025-01-15 09:00:03+00' where id = :'mt';
select tests.eq(pg_temp.b(:'mt', '2025-03-01'), tstzrange('2025-02-15 09:00+00', '2025-03-15 09:00+00', '[)'), 'exact cycle match required');
-- started after the period end (bad data): the period end anchors
update public.memberships set started_at = '2025-04-01 00:00+00' where id = :'mt';
select tests.eq(pg_temp.b(:'mt', '2025-03-01'), tstzrange('2025-02-15 09:00+00', '2025-03-15 09:00+00', '[)'), 'start after end: end anchors');
-- no period end yet: forward from started_at
update public.memberships set current_period_end = null, started_at = '2025-01-31 12:00+00' where id = :'mt';
select tests.eq(pg_temp.b(:'mt', '2025-04-01'), tstzrange('2025-03-31 12:00+00', '2025-04-30 12:00+00', '[)'), 'no period end: forward from started_at');
select tests.eq(pg_temp.b(:'mt', null), null::tstzrange, 'null instant: null');
select tests.eq(public.membership_period_bounds(gen_random_uuid(), now()), null::tstzrange, 'unknown membership: null');
delete from public.memberships where id = :'mt';

-- ============================================================ session time zone does not matter
set local timezone = 'Pacific/Auckland';
select tests.eq(pg_temp.b(tests.fx('mem'), '2025-04-15 12:00+00'), tstzrange('2025-03-31 12:00+00', '2025-04-30 12:00+00', '[)'),
                'UTC calendar arithmetic whatever the session time zone (Auckland)');
set local timezone = 'America/Los_Angeles';
select tests.eq(pg_temp.b(tests.fx('mem'), '2025-03-30 15:00+00'), tstzrange('2025-02-28 12:00+00', '2025-03-31 12:00+00', '[)'),
                'UTC calendar arithmetic whatever the session time zone (Los Angeles)');
set local timezone = 'UTC';

-- ============================================================ roles and isolation
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$select public.membership_usage(tests.fx('mem'))$$, '42501', 'technicians cannot see usage');
select tests.throws($$select public.membership_period_bounds(tests.fx('mem'), now())$$, '42501', 'the bounds helper is internal');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.throws($$select public.membership_usage(tests.fx('mem'))$$, 'P0002', 'another shop''s manager sees nothing');
select tests.as_superuser();
select pg_temp.mem(tests.fx('plan_b'), tests.fx('cust_b'), '2025-01-31 12:00+00', '2025-04-30 12:00+00') as mb \gset
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq(public.membership_usage(:'mb', '2025-04-15 12:00+00') ->> 'period_start', '2025-03-31T12:00:00+00:00',
                'shop B uses the same cycle rules for its own membership');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws(format($$select public.membership_usage(%L)$$, :'mb'), 'P0002', 'and shop A cannot read it');
