-- 60 money: the booking wizard's coupon preview (public_validate_coupon,
-- 0062) prices a signed-in member exactly as create_online_booking (sched
-- 0054) prices their booking: membership-included services at 0 while the
-- membership has uses left in the billing period of the booking's start
-- (p_starts_at), vehicle-scoped memberships for the saved vehicle the
-- booking names (p_vehicle_id). So the preview's totals and its
-- minimum-subtotal check equal the booked job's. Anonymous visitors and
-- signed-in users who are nobody's portal login keep catalog prices; a
-- saved vehicle that is not the caller's is PT404 (as the booking); a bad
-- start is 22023; another shop's slug never sees shop A's vehicles.
\ir fixtures/two_shops.psql
\ir fixtures/40_booking_setup.psql

select tests.as_superuser();
-- Wash club includes the Exterior Wash (1 visit per period); the current
-- period ends in 20 days: shop-local day +3 / +4 are in it, +25 in the next
insert into public.membership_plans (shop_id, name, price_cents, interval, interval_count, included_service_ids,
                                     included_uses_per_period)
  values (tests.fx('shop_a'), 'Wash club', 4000, 'month', 1, array[tests.fx('svc_wash')], 1)
  returning tests.fx_set('plan', id);
select tests.fx_set('u_alice', tests.create_user('alice@example.com'));
update public.customers set portal_user_id = tests.fx('u_alice') where id = tests.fx('cust_a');
insert into public.memberships (shop_id, plan_id, customer_id, status, current_period_end, created_by)
  values (tests.fx('shop_a'), tests.fx('plan'), tests.fx('cust_a'), 'active', now() + interval '20 days', tests.fx('u_manager_a'))
  returning tests.fx_set('mem', id);
insert into public.coupons (shop_id, code, kind, value, min_subtotal_cents)
  values (tests.fx('shop_a'), 'MIN220', 'fixed', 1000, 22000);
select tests.fx_set('u_nobody', tests.create_user('nobody@example.com'));

select ((now() at time zone 'America/Chicago')::date + 3)::text as d,
       ((now() at time zone 'America/Chicago')::date + 4)::text as d4,
       ((now() at time zone 'America/Chicago')::date + 25)::text as d25 \gset

create function pg_temp.pv(p_code text, p_vehicle uuid default null, p_start text default null) returns jsonb language sql as $$
  select public.public_validate_coupon('shop-a', p_code, array[tests.fx('svc_a'), tests.fx('svc_wash')], tests.fx('cat_car_a'),
                                       now(), null, null, p_vehicle, p_start)
$$;
create function pg_temp.book(p_code text, p_start text) returns jsonb language sql as $$
  select public.create_online_booking('shop-a', pg_temp.booking(jsonb_build_object(
           'customer', jsonb_build_object('first_name', 'Alice', 'email', 'alice@example.com'),
           'vehicle', jsonb_build_object('id', tests.fx('veh_a')),
           'service_ids', jsonb_build_array(tests.fx('svc_a'), tests.fx('svc_wash')),
           'coupon_code', p_code, 'starts_at', p_start)))
$$;
create function pg_temp.t(p jsonb) returns text language sql as $$
  select concat_ws('/', p ->> 'subtotal_cents', p ->> 'discount_cents', p ->> 'tax_cents', p ->> 'total_cents')
$$;
create function pg_temp.jt(p_token uuid) returns text language sql security definer as $$
  select concat_ws('/', subtotal_cents, discount_cents, tax_cents, total_cents) from public.jobs where public_token = p_token
$$;
create function pg_temp.check_coupons() returns void language plpgsql as $$
begin
  set constraints public.jobs_zz_money_coupon_check immediate;
  set constraints public.jobs_zz_money_coupon_check deferred;
end $$;
grant execute on function pg_temp.pv(text, uuid, text), pg_temp.book(text, text), pg_temp.t(jsonb), pg_temp.jt(uuid),
                          pg_temp.check_coupons()
  to anon, authenticated, service_role;

-- ============================================================ the finding: member preview = booked job
select tests.authenticate_as(tests.fx('u_alice'));
select public.public_validate_coupon('shop-a', 'SAVE10', array[tests.fx('svc_a'), tests.fx('svc_wash')], tests.fx('cat_car_a'), now())
  as prev \gset
select pg_temp.book('SAVE10', :'d' || 'T10:00:00') as ob \gset
select tests.as_superuser();
select tests.eq((:'prev'::jsonb ->> 'total_cents')::bigint, (:'ob'::jsonb ->> 'total_cents')::bigint,
                'the signed-in member''s coupon preview total equals the booked job total');
select tests.eq(pg_temp.t(:'prev'::jsonb), '20000/2000/1800/19800', 'the wash is included: 20000 subtotal, 10% off, 10% tax');
select tests.eq(pg_temp.jt((:'ob'::jsonb ->> 'job_token')::uuid), pg_temp.t(:'prev'::jsonb), 'every total matches the job''s');
select tests.eq((select membership_id from public.job_line_items li join public.jobs j on j.id = li.job_id
                  where j.public_token = (:'ob'::jsonb ->> 'job_token')::uuid and li.service_id = tests.fx('svc_wash')),
                tests.fx('mem'), 'the booked wash is the membership visit');

-- ============================================================ everyone else: catalog prices
select tests.as_anon();
select tests.eq(pg_temp.t(pg_temp.pv('SAVE10')), '25000/2500/2250/24750', 'anonymous visitor: catalog prices');
select tests.authenticate_as(tests.fx('u_nobody'));
select tests.eq(pg_temp.t(pg_temp.pv('SAVE10')), '25000/2500/2250/24750', 'a signed-in user linked to no customer: catalog prices');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(pg_temp.t(pg_temp.pv('SAVE10')), '25000/2500/2250/24750', 'staff previewing the wizard: catalog prices');

-- ============================================================ uses left in the booking's period
-- the day-3 booking used this period's one visit
select tests.authenticate_as(tests.fx('u_alice'));
select tests.eq(pg_temp.t(pg_temp.pv('SAVE10')), '25000/2500/2250/24750',
                'no start given: counted now — this period is used up, the wash is charged');
select tests.eq(pg_temp.t(pg_temp.pv('SAVE10', null, :'d4' || 'T10:00:00')), '25000/2500/2250/24750',
                'a start in this period: charged');
select tests.eq(pg_temp.t(pg_temp.pv('SAVE10', null, :'d25' || 'T10:00:00')), '20000/2000/1800/19800',
                'a start in the next period (local wall time): included again');
select tests.eq(pg_temp.t(pg_temp.pv('SAVE10', null, to_char(now() + interval '25 days', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))),
                '20000/2000/1800/19800', 'an ISO start with an offset works too');
select pg_temp.book('SAVE10', :'d25' || 'T10:00:00') as ob25 \gset
select tests.as_superuser();
select tests.eq(pg_temp.jt((:'ob25'::jsonb ->> 'job_token')::uuid), '20000/2000/1800/19800',
                'and the booking in that period agrees');

-- ============================================================ minimum subtotal: same verdict as the booking
select tests.authenticate_as(tests.fx('u_alice'));
select tests.eq(pg_temp.pv('MIN220', null, :'d25' || 'T11:00:00') ->> 'valid', 'true',
                'next period is used up again (the day-25 booking): 25000 >= 22000, the coupon applies');
select pg_temp.pv('MIN220', null, to_char(now() + interval '60 days', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')) as pmin \gset
select tests.eq(:'pmin'::jsonb ->> 'valid', 'false', 'a period with a use left: 20000 < 22000, the coupon does not apply');
select tests.ok(:'pmin'::jsonb ->> 'message' like '%at least%', 'with the minimum-subtotal reason');
select tests.eq(pg_temp.t(:'pmin'::jsonb), '20000/0/2000/22000', 'the undiscounted totals are the member''s');
select ((now() at time zone 'America/Chicago')::date + 60)::text as d60 \gset
select pg_temp.book('MIN220', :'d60' || 'T10:00:00') as obmin \gset
select tests.throws_like($$select pg_temp.check_coupons()$$, '22023', '%at least%',
                         'and the booking with it is refused at commit, as previewed');
select tests.as_anon();
select tests.eq(pg_temp.pv('MIN220') ->> 'valid', 'true', 'for a visitor at catalog prices the same coupon applies');

-- ============================================================ vehicle-scoped memberships and the saved vehicle
select tests.as_superuser();
insert into public.membership_plans (shop_id, name, price_cents, interval, interval_count, included_service_ids)
  values (tests.fx('shop_a'), 'Detail club', 9000, 'month', 1, array[tests.fx('svc_a')]) returning tests.fx_set('plan_v', id);
insert into public.memberships (shop_id, plan_id, customer_id, vehicle_id, status, current_period_end, created_by)
  values (tests.fx('shop_a'), tests.fx('plan_v'), tests.fx('cust_a'), tests.fx('veh_a'), 'active', now() + interval '20 days',
          tests.fx('u_manager_a'));
select tests.authenticate_as(tests.fx('u_alice'));
select tests.eq(pg_temp.t(pg_temp.pv('SAVE10', null, :'d4' || 'T12:00:00')), '25000/2500/2250/24750',
                'without the saved vehicle a vehicle-scoped membership does not apply');
select pg_temp.pv('SAVE10', tests.fx('veh_a'), :'d4' || 'T12:00:00') as pveh \gset
select tests.eq(pg_temp.t(:'pveh'::jsonb), '5000/500/450/4950', 'with it, the car''s detail is included (the wash is used up)');
select pg_temp.book('SAVE10', :'d4' || 'T12:00:00') as obv \gset
select tests.as_superuser();
select tests.eq(pg_temp.jt((:'obv'::jsonb ->> 'job_token')::uuid), pg_temp.t(:'pveh'::jsonb),
                'the booking for that vehicle and time has exactly the previewed totals');

-- the saved vehicle's category wins over the form's (as the booking)
update public.vehicles set category_id = tests.fx('cat_truck_a') where id = tests.fx('veh_a2');
update public.customers set portal_user_id = tests.fx('u_alice') where id = tests.fx('cust_a2');
select tests.authenticate_as(tests.fx('u_alice'));
select tests.eq(pg_temp.pv('SAVE10', tests.fx('veh_a2')) ->> 'subtotal_cents', '30000',
                'a truck on file: truck prices (25000 + 5000), whatever category the form sent');
select tests.as_superuser();
update public.customers set portal_user_id = null where id = tests.fx('cust_a2');

-- ============================================================ vehicles that are not the caller's, bad input
select tests.authenticate_as(tests.fx('u_alice'));
select tests.throws_like($$select pg_temp.pv('SAVE10', tests.fx('veh_a2'))$$, 'PT404', 'vehicle not found',
                         'another customer''s vehicle: not found (as the booking)');
select tests.throws($$select pg_temp.pv('SAVE10', tests.fx('veh_b'))$$, 'PT404', 'another shop''s vehicle: not found');
select tests.throws($$select pg_temp.pv('SAVE10', gen_random_uuid())$$, 'PT404', 'an unknown vehicle: not found');
select tests.throws_like($$select pg_temp.pv('SAVE10', null, 'next tuesday')$$, '22023', '%starts_at%',
                         'a start that is not a date and time');
select tests.throws($$select public.public_validate_coupon('shop-b', 'SAVE10', array[tests.fx('svc_b')], null, now(), null, null,
                                                           tests.fx('veh_a'))$$,
                    'PT404', 'shop B''s preview never resolves shop A''s vehicle');
select tests.as_anon();
select tests.throws($$select pg_temp.pv('SAVE10', tests.fx('veh_a'))$$, 'PT404', 'anonymous: a saved vehicle is not found');
select tests.authenticate_as(tests.fx('u_nobody'));
select tests.throws($$select pg_temp.pv('SAVE10', tests.fx('veh_a'))$$, 'PT404', 'a signed-in stranger: not found either');

-- ============================================================ grants
select tests.as_superuser();
select tests.ok(has_function_privilege('anon', 'public.public_validate_coupon(text, text, uuid[], uuid, timestamptz, uuid, public.location_type, uuid, text)', 'execute')
                and has_function_privilege('authenticated', 'public.public_validate_coupon(text, text, uuid[], uuid, timestamptz, uuid, public.location_type, uuid, text)', 'execute')
                and to_regprocedure('public.public_validate_coupon(text, text, uuid[], uuid, timestamptz, uuid, public.location_type)') is null,
                'one public_validate_coupon: anon and authenticated may call it');
