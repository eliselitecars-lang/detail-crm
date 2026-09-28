-- 60 money: the booking wizard's coupon preview (public_validate_coupon,
-- 0062) prices the shop's auto-applied fees (0068) for the booking's
-- location type exactly as the booked job carries them: totals, discount
-- eligibility (fee lines have no service), the minimum-subtotal check, the
-- default location type, archived / inactive fees, another shop's fees.
\ir fixtures/two_shops.psql
\ir fixtures/40_booking_setup.psql

select tests.as_superuser();
insert into public.shop_fees (shop_id, name, amount_cents, taxable, auto_apply, sort)
  values (tests.fx('shop_a'), 'Trip charge', 1500, true, 'both', 1) returning tests.fx_set('f_trip', id);
insert into public.shop_fees (shop_id, name, amount_cents, taxable, auto_apply, sort)
  values (tests.fx('shop_a'), 'Mobile setup', 2000, false, 'mobile', 2) returning tests.fx_set('f_mobile', id);
insert into public.shop_fees (shop_id, name, amount_cents, auto_apply, archived_at)
  values (tests.fx('shop_a'), 'Old fee', 999, 'both', now());
insert into public.shop_fees (shop_id, name, amount_cents, auto_apply, active)
  values (tests.fx('shop_a'), 'Paused fee', 777, 'both', false);
insert into public.shop_fees (shop_id, name, amount_cents, auto_apply)
  values (tests.fx('shop_b'), 'B fee', 3000, 'both');
insert into public.coupons (shop_id, code, kind, value, service_ids)
  values (tests.fx('shop_a'), 'WASHHALF', 'percent', 5000, array[tests.fx('svc_wash')]);
insert into public.coupons (shop_id, code, kind, value, min_subtotal_cents)
  values (tests.fx('shop_a'), 'MIN60', 'fixed', 1000, 6000) returning tests.fx_set('cp_min', id);

select ((now() at time zone 'America/Chicago')::date + 12)::text as d1,
       ((now() at time zone 'America/Chicago')::date + 13)::text as d2,
       ((now() at time zone 'America/Chicago')::date + 14)::text as d3 \gset

create function pg_temp.pv(p_code text, p_loc public.location_type default null) returns jsonb language sql as $$
  select public.public_validate_coupon('shop-a', p_code, array[tests.fx('svc_wash')], tests.fx('cat_car_a'), now(), null, p_loc)
$$;
create function pg_temp.book(p_code text, p_day text, p_loc jsonb default '{"type": "shop"}') returns jsonb language sql as $$
  select public.create_online_booking('shop-a', pg_temp.booking(jsonb_build_object(
           'service_ids', jsonb_build_array(tests.fx('svc_wash')), 'coupon_code', p_code, 'location', p_loc,
           'starts_at', p_day || 'T10:00:00')))
$$;
create function pg_temp.t(p jsonb) returns text language sql as $$
  select concat_ws('/', p ->> 'subtotal_cents', p ->> 'discount_cents', p ->> 'tax_cents', p ->> 'total_cents')
$$;
grant execute on function pg_temp.pv(text, public.location_type), pg_temp.book(text, text, jsonb), pg_temp.t(jsonb)
  to anon, authenticated;

-- ============================================================ preview = booked job
select tests.as_anon();
select pg_temp.pv('SAVE10') as pv \gset
-- wash 5000 + trip 1500 = 6500; 10% of everything = 650; tax 10% of 5850 = 585
select tests.eq(pg_temp.t(:'pv'::jsonb), '6500/650/585/6435', 'the preview includes the shop-location fee (null = shop here)');
select pg_temp.book('SAVE10', :'d1') as ob \gset
select tests.eq((:'ob'::jsonb ->> 'total_cents')::bigint, (:'pv'::jsonb ->> 'total_cents')::bigint,
                'the coupon preview total the customer sees equals the booked job total');
select tests.as_superuser();
select tests.eq((select concat_ws('/', subtotal_cents, discount_cents, tax_cents, total_cents) from public.jobs
                  where public_token = (:'ob'::jsonb ->> 'job_token')::uuid), '6500/650/585/6435', 'line for line');

-- ============================================================ location type
select tests.as_anon();
-- mobile: + setup 2000 (not taxable): 8500; 10% = 850; taxable share of the discount round(850 * 6500 / 8500) = 650
select tests.eq(pg_temp.t(pg_temp.pv('SAVE10', 'mobile')), '8500/850/585/8235', 'mobile adds the mobile-only fee');
select tests.eq(pg_temp.t(pg_temp.pv('SAVE10', 'shop')), '6500/650/585/6435', 'shop does not');
select pg_temp.book('SAVE10', :'d2', '{"type": "mobile", "address_line1": "9 Elm St", "city": "Birmingham", "postal_code": "35203"}') as obm \gset
select tests.eq((:'obm'::jsonb ->> 'total_cents')::bigint, 8235::bigint, 'the mobile booking matches its preview');

-- ============================================================ eligibility: fee lines have no service
-- a coupon for the wash only: 50% of 5000; the trip fee is not discounted
select tests.eq(pg_temp.t(pg_temp.pv('WASHHALF')), '6500/2500/400/4400', 'a service-limited coupon never discounts a fee');
select tests.eq(pg_temp.pv('WASHHALF') -> 'eligible_service_ids', jsonb_build_array(tests.fx('svc_wash')),
                'and names the discounted services only');

-- ============================================================ minimum subtotal counts the fee (as the booking does)
select tests.eq(pg_temp.pv('MIN60') ->> 'valid', 'true', 'wash 5000 + trip 1500 reaches a 60.00 minimum');
select pg_temp.book('MIN60', :'d3') as obmin \gset
select tests.eq((:'obmin'::jsonb ->> 'total_cents')::bigint, (pg_temp.pv('MIN60') ->> 'total_cents')::bigint,
                'and the booking accepts it at the previewed total');
select tests.as_superuser();
update public.shop_fees set active = false where id = tests.fx('f_trip');
select tests.as_anon();
select pg_temp.pv('MIN60') as pvmin \gset
select tests.eq((:'pvmin'::jsonb ->> 'valid') || ' ' || (:'pvmin'::jsonb ->> 'message'),
                'false this coupon needs a subtotal of at least $60.00', 'without the fee the minimum is not reached');
select tests.eq(pg_temp.t(:'pvmin'::jsonb), '5000/0/500/5500', 'an invalid code still shows the undiscounted totals (fees included)');
select tests.eq(pg_temp.t(pg_temp.pv('NOPE', 'mobile')), '7000/0/500/7500', 'unknown code: the mobile fee is still priced');

-- ============================================================ other shops, roles
-- shop B's fee never reaches shop A's preview (covered above: only A's fees), and B's own preview has it
select public.public_validate_coupon('shop-b', 'NOPE', array[tests.fx('svc_b')]) as pvb \gset
select tests.eq((:'pvb'::jsonb ->> 'subtotal_cents')::bigint, 8000::bigint, 'shop B: its own fee (5000 + 3000)');
select tests.authenticate_as(tests.fx('u_outsider'));
select tests.eq(pg_temp.t(pg_temp.pv('SAVE10', 'mobile')), '7000/700/450/6750', 'signed-in visitors get the same preview');
select tests.as_superuser();
select tests.ok(has_function_privilege('anon', 'public.public_validate_coupon(text, text, uuid[], uuid, timestamptz, uuid, public.location_type, uuid, text)', 'execute')
                and (select count(*) from pg_proc where proname = 'public_validate_coupon') = 1,
                'one signature, open to anon');
