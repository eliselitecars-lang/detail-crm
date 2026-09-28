-- 100 (0108): a membership covers only visits it will be paid for. A
-- renewing member books included visits in later periods for free; once the
-- membership is ending (cancel_at_period_end) or cancelled, its free visits
-- after the paid period are charged the catalog price (billed / unpriced
-- ones are listed for managers), new bookings after the end are priced,
-- and staff cannot attach or move a membership visit past the end.
\ir fixtures/two_shops.psql
\ir fixtures/40_booking_setup.psql

select tests.as_superuser();
update public.booking_settings set max_days_ahead = 120, auto_confirm = true where shop_id = tests.fx('shop_a');
insert into public.membership_plans (shop_id, name, price_cents, interval, interval_count, included_service_ids, included_uses_per_period)
  values (tests.fx('shop_a'), 'Wash club', 1500, 'week', 1, array[tests.fx('svc_wash')], 1) returning tests.fx_set('plan', id);
select tests.fx_set('u_alice', tests.create_user('alice@example.com'));
update public.customers set portal_user_id = tests.fx('u_alice') where id = tests.fx('cust_a');
-- one week paid: the period ends in 3 days
insert into public.memberships (shop_id, plan_id, customer_id, status, current_period_end, started_at, created_by)
  values (tests.fx('shop_a'), tests.fx('plan'), tests.fx('cust_a'), 'active', now() + interval '3 days', now() - interval '4 days',
          tests.fx('u_manager_a'))
  returning tests.fx_set('mem', id);
select ((now() at time zone 'America/Chicago')::date + 1)::text as d1,
       ((now() at time zone 'America/Chicago')::date + 5)::text as d5,
       ((now() at time zone 'America/Chicago')::date + 12)::text as d12,
       ((now() at time zone 'America/Chicago')::date + 19)::text as d19,
       ((now() at time zone 'America/Chicago')::date + 26)::text as d26 \gset
create function pg_temp.book(p_day text) returns jsonb language sql as $$
  select public.create_online_booking('shop-a', pg_temp.booking(jsonb_build_object(
           'customer', jsonb_build_object('first_name', 'Alice', 'email', 'alice@example.com'),
           'vehicle', jsonb_build_object('id', tests.fx('veh_a')),
           'service_ids', jsonb_build_array(tests.fx('svc_wash')), 'starts_at', p_day || 'T10:00:00')))
$$;
grant execute on function pg_temp.book(text) to authenticated;
create function pg_temp.job(p_token text) returns public.jobs language sql as $$
  select * from public.jobs where public_token = p_token::uuid
$$;
create function pg_temp.member_lines(p_token text) returns bigint language sql as $$
  select count(*) from public.job_line_items li join public.jobs j on j.id = li.job_id
   where j.public_token = p_token::uuid and li.membership_id is not null
$$;

-- ============================================================ a renewing member books ahead
select tests.authenticate_as(tests.fx('u_alice'));
select pg_temp.book(:'d5') ->> 'job_token' as t5 \gset
select pg_temp.book(:'d12') ->> 'job_token' as t12 \gset
select pg_temp.book(:'d19') ->> 'job_token' as t19 \gset
select tests.as_superuser();
select tests.eq((select array_agg((pg_temp.job(t)).total_cents order by t) from unnest(array[:'t5', :'t12', :'t19']) t),
                array[0, 0, 0]::bigint[], 'a renewing membership covers one included visit in each later period');
-- the visit two weeks out is invoiced up front
select tests.fx_set('job12', (pg_temp.job(:'t12')).id);
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.fx_set('inv12', (public.create_invoice_from_job(tests.fx('job12'))).id);

-- ============================================================ the member cancels at period end
select tests.as_superuser();
update public.memberships set cancel_at_period_end = true where id = tests.fx('mem');
select tests.eq((select jsonb_build_array((pg_temp.job(:'t5')).total_cents, pg_temp.member_lines(:'t5'),
                                          (pg_temp.job(:'t19')).total_cents, pg_temp.member_lines(:'t19'))),
                '[5500, 0, 5500, 0]'::jsonb,
                'visits after the paid period lose the membership and are charged the catalog price (plus tax)');
select tests.eq((select array_agg(li.unit_price_cents) from public.job_line_items li where li.job_id = (pg_temp.job(:'t5')).id),
                array[5000]::bigint[], 'the line carries the catalog price');
select tests.eq(jsonb_build_array((pg_temp.job(:'t12')).total_cents, pg_temp.member_lines(:'t12')), '[0, 1]'::jsonb,
                'an invoiced visit keeps its billed price (0097)');
select tests.eq((select count(*) from public.notifications
                  where shop_id = tests.fx('shop_a') and kind = 'general' and customer_id = tests.fx('cust_a')
                    and title = 'Membership ending: booked visits after it need paying'
                    and body like '%Wash club membership, paid through%'
                    and body like '%Now charged at the catalog price: Job #' || (pg_temp.job(:'t5')).number || ', Job #' || (pg_temp.job(:'t19')).number || '.%'
                    and body like '%already invoiced (void the invoice to reprice): Job #' || (pg_temp.job(:'t12')).number || '.%'),
                3::bigint, 'owner, admin and manager are told which visits changed and which are invoiced');
select tests.eq((select count(*) from public.notifications n join public.shop_members m on m.user_id = n.user_id and m.shop_id = n.shop_id
                  where n.title like 'Membership ending%' and m.role = 'technician'), 0::bigint, 'technicians are not');

-- a new booking inside the paid period is still included; one after it is priced
select tests.authenticate_as(tests.fx('u_alice'));
select pg_temp.book(:'d1') ->> 'job_token' as t1 \gset
select pg_temp.book(:'d26') ->> 'job_token' as t26 \gset
select tests.as_superuser();
select tests.eq(jsonb_build_array((pg_temp.job(:'t1')).total_cents, pg_temp.member_lines(:'t1'),
                                  (pg_temp.job(:'t26')).total_cents, pg_temp.member_lines(:'t26')),
                '[0, 1, 5500, 0]'::jsonb, 'an ending membership covers visits before its end only');
select tests.as_service();
select tests.eq((select jsonb_build_array(l ->> 'membership_included', l ->> 'unit_price_cents')
                   from jsonb_array_elements((public.price_services_core(tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('cat_car_a'),
                                                                         array[tests.fx('svc_wash')], tests.fx('veh_a'), true,
                                                                         now() + interval '10 days')) -> 'lines') l),
                '["false", "5000"]'::jsonb, 'pricing a visit after the end: not included');

-- staff cannot attach the membership to a visit after the end, nor move an included visit past it
select tests.as_superuser();
select tests.fx_set('job26', (pg_temp.job(:'t26')).id), tests.fx_set('job1', (pg_temp.job(:'t1')).id);
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws_like(format($$insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents, membership_id)
                                  values (%L, %L, %L, 'Exterior Wash', 0, %L)$$,
                                tests.fx('shop_a'), tests.fx('job26'), tests.fx('svc_wash'), tests.fx('mem')),
                         '22023', '%membership ends before this visit%', 'attaching the ending membership after its end fails');
select tests.lives(format($$insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents)
                            values (%L, %L, %L, 'Exterior Wash', 0)$$,
                          tests.fx('shop_a'), tests.fx('job26'), tests.fx('svc_wash')),
                   'a free line after the end is not auto-assigned to the membership');
select tests.eq((select count(*) from public.job_line_items where job_id = tests.fx('job26') and membership_id is not null),
                0::bigint, '(no membership on it)');
select tests.throws_like(format($$update public.jobs set scheduled_start = scheduled_start + interval '9 days',
                                                          scheduled_end = scheduled_end + interval '9 days' where id = %L$$,
                                tests.fx('job1')),
                         '22023', '%Wash club membership ends on%', 'an included visit cannot move past the end');

-- ============================================================ the membership ends
select tests.as_superuser();
update public.memberships set status = 'cancelled', cancelled_at = now() where id = tests.fx('mem');
select tests.eq(jsonb_build_array((pg_temp.job(:'t1')).total_cents, pg_temp.member_lines(:'t1')), '[0, 1]'::jsonb,
                'the visit inside the paid period keeps its included price');
select tests.eq((select count(*) from public.notifications
                  where title = 'Membership ended: booked visits after it need paying' and body like '%Wash club membership%'
                    and body not like '%Now charged%' and body like '%already invoiced%'),
                3::bigint, 'the end lists the invoiced visit that still carries it');

-- ============================================================ a membership cancelled outright
insert into public.membership_plans (shop_id, name, price_cents, interval, interval_count, included_service_ids, included_uses_per_period)
  values (tests.fx('shop_a'), 'Monthly wash', 4000, 'month', 1, array[tests.fx('svc_wash')], 1) returning tests.fx_set('plan_m', id);
insert into public.memberships (shop_id, plan_id, customer_id, status, current_period_end, started_at, created_by)
  values (tests.fx('shop_a'), tests.fx('plan_m'), tests.fx('cust_a'), 'active', now() + interval '5 days', now() - interval '25 days',
          tests.fx('u_manager_a'))
  returning tests.fx_set('mem_m', id);
-- staff book next month's visit with the included wash at $0 (auto-assigned)
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.jobs (shop_id, customer_id, vehicle_id, status, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('veh_a'), 'scheduled', now() + interval '40 days', now() + interval '40 days 1 hour')
  returning tests.fx_set('job40', id);
insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('job40'), tests.fx('svc_wash'), 'Exterior Wash', 0);
select tests.as_superuser();
select public_token::text as t40 from public.jobs where id = tests.fx('job40') \gset
select tests.eq(pg_temp.member_lines(:'t40'), 1::bigint, 'the free line is assigned to the renewing membership');
select tests.eq((pg_temp.job(:'t40')).total_cents, 0::bigint, 'next month''s visit is included while the membership renews');
update public.memberships set status = 'cancelled', cancelled_at = now() where id = tests.fx('mem_m');
select tests.eq(jsonb_build_array((pg_temp.job(:'t40')).total_cents, pg_temp.member_lines(:'t40')), '[5500, 0]'::jsonb,
                'cancelling outright charges the visits after the paid period');
select tests.eq((select count(*) from public.notifications
                  where title = 'Membership ended: booked visits after it need paying' and body like '%Monthly wash membership%'
                    and body like '%Now charged at the catalog price: Job #%'),
                3::bigint, 'and managers are told');
