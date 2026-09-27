-- 00 foundation: business-hours opening/closing times that fall inside a DST
-- spring-forward gap or a fall-back's repeated hour (wall_clock_instant +
-- get_available_slots + create_online_booking).
-- Regressions:
-- * a closing time inside the gap (02:30 on a night that goes 01:59 -> 03:00)
--   used to resolve to 03:30 on the new clock, so slots after closing were
--   offered (and create_online_booking, which re-checks with the same
--   function, accepted them); an opening time inside the gap opened an hour
--   late (the 03:00 slot was lost);
-- * the fall-back twin: a closing time inside the repeated hour (01:30 on a
--   night that goes 01:59 CDT -> 01:00 CST) closed at its SECOND reading
--   (01:30 CST), so slots running while the clock showed 01:30-01:59 CDT —
--   after closing on any reading — were offered and booked; an opening time
--   there opened at the second reading, so the first pass was never offered.
\ir fixtures/two_shops.psql

select tests.as_superuser();
set local timezone = 'UTC';
-- create_online_booking (0042) re-validates with get_available_slots; its
-- checks here run when that migration is present
select to_regproc('public.create_online_booking') is not null as with_booking \gset

-- ------------------------------------------------------------ wall_clock_instant
select tests.eq(public.wall_clock_instant('2025-06-09 08:00', 'America/Chicago'), '2025-06-09 13:00Z'::timestamptz,
                'an existing local time converts as usual');
select tests.eq(public.wall_clock_instant('2025-03-09 01:59:59', 'America/Chicago'), '2025-03-09 07:59:59Z'::timestamptz,
                'the last second before the jump is unchanged');
select tests.eq(public.wall_clock_instant('2025-03-09 02:30', 'America/Chicago'), '2025-03-09 08:00Z'::timestamptz,
                'Chicago 02:30 (gap) resolves to the jump (03:00 CDT), not 03:30 CDT');
select tests.eq(public.wall_clock_instant('2025-03-09 02:00', 'America/Chicago'), '2025-03-09 08:00Z'::timestamptz,
                'the first nonexistent minute resolves to the jump');
select tests.eq(public.wall_clock_instant('2025-03-09 02:30:00.5', 'America/Chicago'), '2025-03-09 08:00Z'::timestamptz,
                'fractional seconds inside the gap resolve to the jump');
select tests.eq(public.wall_clock_instant('2025-03-09 03:00', 'America/Chicago'), '2025-03-09 08:00Z'::timestamptz,
                'the first local time after the gap is the jump itself');
-- fall-back: a local time that happens twice means its first occurrence
select tests.eq(public.wall_clock_instant('2025-11-02 01:30', 'America/Chicago'), '2025-11-02 06:30Z'::timestamptz,
                'Chicago 01:30 on the fall-back night is 01:30 CDT (first pass), not Postgres'' 01:30 CST');
select tests.ok(('2025-11-02 01:30'::timestamp at time zone 'America/Chicago') = '2025-11-02 07:30Z'::timestamptz,
                'control: Postgres alone reads it as 01:30 CST');
select tests.eq(public.wall_clock_instant('2025-11-02 01:00', 'America/Chicago'), '2025-11-02 06:00Z'::timestamptz,
                'the first repeated minute resolves to its first pass');
select tests.eq(public.wall_clock_instant('2025-11-02 01:59:59.5', 'America/Chicago'), '2025-11-02 06:59:59.5Z'::timestamptz,
                'fractional seconds at the end of the repeated hour: first pass');
select tests.eq(public.wall_clock_instant('2025-11-02 00:59:59', 'America/Chicago'), '2025-11-02 05:59:59Z'::timestamptz,
                'the last second before the repeated hour is unchanged');
select tests.eq(public.wall_clock_instant('2025-11-02 02:00', 'America/Chicago'), '2025-11-02 08:00Z'::timestamptz,
                'the first local time after the repeated hour is unchanged');
select tests.eq(public.wall_clock_instant('2025-04-06 02:30', 'Australia/Sydney'), '2025-04-05 15:30Z'::timestamptz,
                'Sydney 02:30 on the first Sunday of April is 02:30 AEDT (first pass)');
select tests.eq(public.wall_clock_instant('2025-04-06 01:45', 'Australia/Lord_Howe'), '2025-04-05 14:45Z'::timestamptz,
                'a 30-minute fall-back (Lord Howe 02:00 -> 01:30): first pass');
select tests.eq(public.wall_clock_instant('2025-11-02 00:00', 'America/Havana'), '2025-11-02 04:00Z'::timestamptz,
                'a fall-back to local midnight (Havana 01:00 -> 00:00): a 24:00 closing is the first midnight');
select tests.eq(public.wall_clock_instant('2025-04-05 23:30', 'America/Santiago'), '2025-04-06 02:30Z'::timestamptz,
                'a fall-back from midnight to 23:00 (Santiago): first pass of the repeated 23:30');
select tests.eq(public.wall_clock_instant('2025-10-05 02:30', 'Australia/Sydney'), '2025-10-04 16:00Z'::timestamptz,
                'Sydney 02:30 (gap) resolves to the 02:00 AEST jump');
select tests.eq(public.wall_clock_instant('2025-10-05 02:15', 'Australia/Lord_Howe'), '2025-10-04 15:30Z'::timestamptz,
                'a 30-minute gap (Lord Howe 02:00 -> 02:30) resolves to its jump');
select tests.eq(public.wall_clock_instant('2025-09-07 00:30', 'America/Santiago'), '2025-09-07 04:00Z'::timestamptz,
                'a gap at local midnight (Santiago) resolves to its jump');
select tests.eq(public.wall_clock_instant('2011-12-30 12:00', 'Pacific/Apia'), '2011-12-30 10:00Z'::timestamptz,
                'a skipped calendar day (Apia 2011-12-30) resolves to the jump');
select tests.ok(public.wall_clock_instant(null, 'America/Chicago') is null, 'null in, null out');

select tests.as_anon();
select tests.throws($$select public.wall_clock_instant('2025-03-09 02:30', 'America/Chicago')$$, '42501',
                    'anon cannot call the internal helper');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.throws($$select public.wall_clock_instant('2025-03-09 02:30', 'America/Chicago')$$, '42501',
                    'authenticated cannot call the internal helper');
select tests.as_service();
select tests.eq(public.wall_clock_instant('2025-03-09 02:30', 'America/Chicago'), '2025-03-09 08:00Z'::timestamptz,
                'service_role may call the helper');

-- ------------------------------------------------------------ slots: shop A (America/Chicago)
select tests.as_superuser();
-- local 'HH24:MI-HH24:MI' of each slot on the given day, ordered
create function pg_temp.local_slots(p_slug text, p_service uuid, p_day date, p_now timestamptz, p_tz text)
returns text[] language sql as $$
  select coalesce(array_agg(to_char(s.starts_at at time zone p_tz, 'HH24:MI') || '-' ||
                            to_char(s.ends_at at time zone p_tz, 'HH24:MI') order by s.starts_at), '{}')
  from public.get_available_slots(p_slug, array[p_service], p_day, p_day, null, p_now) s
$$;
grant execute on function pg_temp.local_slots(text, uuid, date, timestamptz, text) to anon, authenticated, service_role;
-- UTC 'HH24:MI-HH24:MI' of each slot starting in [p_from, p_to] (unambiguous on fall-back nights)
create function pg_temp.utc_slots(p_slug text, p_service uuid, p_from date, p_to date, p_now timestamptz)
returns text[] language sql as $$
  select coalesce(array_agg(to_char(s.starts_at at time zone 'UTC', 'HH24:MI') || '-' ||
                            to_char(s.ends_at at time zone 'UTC', 'HH24:MI') order by s.starts_at), '{}')
  from public.get_available_slots(p_slug, array[p_service], p_from, p_to, null, p_now) s
$$;
grant execute on function pg_temp.utc_slots(text, uuid, date, date, timestamptz) to anon, authenticated, service_role;

update public.booking_settings
   set enabled = true, slot_interval_minutes = 30, lead_time_minutes = 0, max_days_ahead = 60,
       buffer_minutes = 0, max_concurrent_jobs = 1
 where shop_id = tests.fx('shop_a');
-- Sundays open 00:00-02:30 local
insert into public.business_hours (shop_id, weekday, opens_at, closes_at)
  values (tests.fx('shop_a'), 0, '00:00', '02:30') returning tests.fx_set('bh_sun_a', id);
insert into public.services (shop_id, name, duration_minutes, online_bookable) values
  (tests.fx('shop_a'), 'Half Hour', 30, true) returning tests.fx_set('half_a', id);
insert into public.service_prices (shop_id, service_id, price_cents) values (tests.fx('shop_a'), tests.fx('half_a'), 5000);
insert into public.services (shop_id, name, duration_minutes, online_bookable) values
  (tests.fx('shop_a'), 'One Hour', 60, true) returning tests.fx_set('hour_a', id);
insert into public.service_prices (shop_id, service_id, price_cents) values (tests.fx('shop_a'), tests.fx('hour_a'), 9000);

-- ordinary Sunday: 02:30 exists, last 30-min start 02:00
select tests.eq(pg_temp.local_slots('shop-a', tests.fx('half_a'), '2025-03-02', '2025-02-20 00:00Z', 'America/Chicago'),
                array['00:00-00:30', '00:30-01:00', '01:00-01:30', '01:30-02:00', '02:00-02:30'],
                'ordinary Sunday: open until 02:30');
-- the reported repro: nothing may end after the jump (08:00Z)
select tests.eq((select array_agg(to_char(starts_at at time zone 'America/Chicago', 'HH24:MI TZ') order by starts_at)
                   from public.get_available_slots('shop-a', array[tests.fx('half_a')], '2025-03-09', '2025-03-09', null, '2025-03-01 00:00Z')
                  where ends_at > '2025-03-09 08:00Z'),
                null::text[],
                'spring-forward: no slot may end after the wall clock has passed the 02:30 closing');
select tests.eq(pg_temp.local_slots('shop-a', tests.fx('half_a'), '2025-03-09', '2025-03-01 00:00Z', 'America/Chicago'),
                array['00:00-00:30', '00:30-01:00', '01:00-01:30', '01:30-03:00'],
                'spring-forward: closed from the jump; the 01:30 slot ends at the jump (03:00 CDT), 03:00 is not offered');
select tests.eq(pg_temp.local_slots('shop-a', tests.fx('hour_a'), '2025-03-09', '2025-03-01 00:00Z', 'America/Chicago'),
                array['00:00-01:00', '00:30-01:30', '01:00-03:00'],
                'spring-forward: a start whose service would run past the jump is not offered (01:30 + 60 min)');
-- the day after is an ordinary Monday: nothing leaks from the Sunday
select tests.eq(pg_temp.local_slots('shop-a', tests.fx('half_a'), '2025-03-10', '2025-03-01 00:00Z', 'America/Chicago'),
                '{}'::text[], 'closed Monday stays closed');

-- opening inside the gap: open from the jump (03:00 CDT), grid anchored there
delete from public.business_hours where id = tests.fx('bh_sun_a');
insert into public.business_hours (shop_id, weekday, opens_at, closes_at) values (tests.fx('shop_a'), 0, '02:30', '05:00');
select tests.eq(pg_temp.local_slots('shop-a', tests.fx('half_a'), '2025-03-09', '2025-03-01 00:00Z', 'America/Chicago'),
                array['03:00-03:30', '03:30-04:00', '04:00-04:30', '04:30-05:00'],
                'spring-forward: opening at 02:30 (gap) opens at the jump, so 03:00 is offered');
select tests.eq(pg_temp.local_slots('shop-a', tests.fx('half_a'), '2025-03-02', '2025-02-20 00:00Z', 'America/Chicago'),
                array['02:30-03:00', '03:00-03:30', '03:30-04:00', '04:00-04:30', '04:30-05:00'],
                'ordinary Sunday: opens at 02:30');
select tests.eq(pg_temp.local_slots('shop-a', tests.fx('hour_a'), '2025-03-09', '2025-03-01 00:00Z', 'America/Chicago'),
                array['03:00-04:00', '03:30-04:30', '04:00-05:00'],
                'spring-forward: 60-minute service from the jump');

-- hours entirely inside the gap never open
delete from public.business_hours where shop_id = tests.fx('shop_a') and weekday = 0;
insert into public.business_hours (shop_id, weekday, opens_at, closes_at) values (tests.fx('shop_a'), 0, '02:00', '02:45');
select tests.eq(pg_temp.local_slots('shop-a', tests.fx('half_a'), '2025-03-09', '2025-03-01 00:00Z', 'America/Chicago'),
                '{}'::text[], 'hours that lie wholly inside the gap never open');
select tests.eq(pg_temp.local_slots('shop-a', tests.fx('half_a'), '2025-03-02', '2025-02-20 00:00Z', 'America/Chicago'),
                array['02:00-02:30'], 'the same hours on an ordinary Sunday');

-- ------------------------------------------------------------ fall-back: closing inside the repeated hour
-- Saturday night shift: Sat 20:00-24:00 + Sun 00:00-01:30 (America/Chicago)
delete from public.business_hours where shop_id = tests.fx('shop_a');
insert into public.business_hours (shop_id, weekday, opens_at, closes_at) values
  (tests.fx('shop_a'), 6, '20:00', '24:00'), (tests.fx('shop_a'), 0, '00:00', '01:30');
insert into public.services (shop_id, name, duration_minutes, online_bookable) values
  (tests.fx('shop_a'), 'Two Hours', 120, true) returning tests.fx_set('two_a', id);
insert into public.service_prices (shop_id, service_id, price_cents) values (tests.fx('shop_a'), tests.fx('two_a'), 9000);

-- control: an ordinary Sunday closes at 01:30 CDT (06:30Z)
select tests.eq((select max(ends_at) from public.get_available_slots('shop-a', array[tests.fx('two_a')], '2025-10-25',
                   '2025-10-26', null, '2025-10-01Z')), '2025-10-26 06:30Z'::timestamptz,
                'ordinary night: nothing ends after the 01:30 closing');
-- the reported repro: 06:30Z-07:00Z the wall clock reads 01:30-01:59 CDT (after closing)
select tests.eq((select array_agg(to_char(starts_at at time zone 'UTC', 'HH24:MI') || '-' || to_char(ends_at at time zone 'UTC', 'HH24:MI') order by starts_at)
                   from public.get_available_slots('shop-a', array[tests.fx('two_a')], '2025-11-01', '2025-11-02', null, '2025-10-01Z')
                  where starts_at < '2025-11-02 07:00Z' and ends_at > '2025-11-02 06:30Z'),
                null::text[],
                'fall-back night: no slot may run while the clock shows 01:30-01:59 CDT (after closing)');
select tests.eq(pg_temp.utc_slots('shop-a', tests.fx('two_a'), '2025-11-01', '2025-11-02', '2025-10-01Z'),
                array['01:00-03:00', '01:30-03:30', '02:00-04:00', '02:30-04:30', '03:00-05:00', '03:30-05:30',
                      '04:00-06:00', '04:30-06:30'],
                'fall-back night: Saturday 20:00-23:30 CDT starts, the last one ends at the 01:30 CDT closing');
select tests.eq(pg_temp.utc_slots('shop-a', tests.fx('half_a'), '2025-11-02', '2025-11-02', '2025-10-01Z'),
                array['05:00-05:30', '05:30-06:00', '06:00-06:30'],
                'fall-back night, 30-min service: Sunday 00:00, 00:30, 01:00 CDT; nothing in the second pass');

-- the mirror: an opening inside the repeated hour opens at its first pass
delete from public.business_hours where shop_id = tests.fx('shop_a');
insert into public.business_hours (shop_id, weekday, opens_at, closes_at) values (tests.fx('shop_a'), 0, '01:30', '04:00');
select tests.eq(pg_temp.local_slots('shop-a', tests.fx('half_a'), '2025-10-26', '2025-10-01Z', 'America/Chicago'),
                array['01:30-02:00', '02:00-02:30', '02:30-03:00', '03:00-03:30', '03:30-04:00'],
                'ordinary Sunday: opens at 01:30');
select tests.eq(pg_temp.utc_slots('shop-a', tests.fx('half_a'), '2025-11-02', '2025-11-02', '2025-10-01Z'),
                array['06:30-07:00', '08:00-08:30', '08:30-09:00', '09:00-09:30', '09:30-10:00'],
                'fall-back: opening at 01:30 opens at 01:30 CDT (first pass), so 01:30 CDT is offered');

-- create_online_booking re-validates with the same rules
delete from public.business_hours where shop_id = tests.fx('shop_a');
insert into public.business_hours (shop_id, weekday, opens_at, closes_at) values
  (tests.fx('shop_a'), 6, '20:00', '24:00'), (tests.fx('shop_a'), 0, '00:00', '01:30');
\if :with_booking
select tests.throws($$select public.create_online_booking('shop-a', jsonb_build_object(
  'customer', jsonb_build_object('first_name', 'Night', 'email', 'night@example.com'),
  'vehicle', jsonb_build_object('make', 'Honda', 'model', 'Fit'),
  'service_ids', jsonb_build_array(tests.fx('two_a')),
  'starts_at', '2025-11-02T00:30:00-05:00'), '2025-10-01Z')$$, '23P01',
  'a 2-hour booking from 00:30 CDT runs until 01:30 CST, past the 01:30 closing');
select tests.eq((select (public.create_online_booking('shop-a', jsonb_build_object(
                   'customer', jsonb_build_object('first_name', 'Night', 'email', 'night@example.com'),
                   'vehicle', jsonb_build_object('make', 'Honda', 'model', 'Fit'),
                   'service_ids', jsonb_build_array(tests.fx('two_a')),
                   'starts_at', '2025-11-01T23:30:00-05:00'), '2025-10-01Z')) ->> 'status' is not null),
                true, 'a 2-hour booking from 23:30 CDT ends exactly at the 01:30 CDT closing and is accepted');
\endif

-- ------------------------------------------------------------ slots: shop B (Australia/Sydney) + isolation
update public.shops set timezone = 'Australia/Sydney' where id = tests.fx('shop_b');
update public.booking_settings
   set enabled = true, slot_interval_minutes = 30, lead_time_minutes = 0, max_days_ahead = 60,
       buffer_minutes = 0, max_concurrent_jobs = 1
 where shop_id = tests.fx('shop_b');
insert into public.business_hours (shop_id, weekday, opens_at, closes_at) values (tests.fx('shop_b'), 0, '00:00', '02:30');
insert into public.services (shop_id, name, duration_minutes, online_bookable) values
  (tests.fx('shop_b'), 'Half Hour', 30, true) returning tests.fx_set('half_b', id);
insert into public.service_prices (shop_id, service_id, price_cents) values (tests.fx('shop_b'), tests.fx('half_b'), 5000);

select tests.as_service();
select tests.eq(pg_temp.local_slots('shop-b', tests.fx('half_b'), '2025-10-05', '2025-09-20 00:00Z', 'Australia/Sydney'),
                array['00:00-00:30', '00:30-01:00', '01:00-01:30', '01:30-03:00'],
                'Sydney spring-forward (02:00 -> 03:00): closed from the jump, 03:00 not offered');
select tests.eq(pg_temp.local_slots('shop-b', tests.fx('half_b'), '2025-09-28', '2025-09-20 00:00Z', 'Australia/Sydney'),
                array['00:00-00:30', '00:30-01:00', '01:00-01:30', '01:30-02:00', '02:00-02:30'],
                'Sydney ordinary Sunday: open until 02:30');
-- Sydney fall-back (first Sunday of April, 03:00 AEDT -> 02:00 AEST): the
-- 02:30 closing is 02:30 AEDT (15:30Z), not 02:30 AEST (16:30Z)
select tests.eq(pg_temp.utc_slots('shop-b', tests.fx('half_b'), '2025-04-06', '2025-04-06', '2025-03-20 00:00Z'),
                array['13:00-13:30', '13:30-14:00', '14:00-14:30', '14:30-15:00', '15:00-15:30'],
                'Sydney fall-back: 00:00-02:00 AEDT starts, closed from 02:30 AEDT');
-- shop A's Sunday (00:00-01:30 after its Saturday night shift, Chicago) is
-- unaffected by shop B's hours and time zone, and vice versa
select tests.eq(pg_temp.local_slots('shop-a', tests.fx('half_a'), '2025-03-02', '2025-02-20 00:00Z', 'America/Chicago'),
                array['00:00-00:30', '00:30-01:00', '01:00-01:30'], 'shop A keeps its own hours and time zone');
select tests.throws_like($$select * from public.get_available_slots('shop-b', array[tests.fx('half_a')], '2025-10-05', '2025-10-05', null, '2025-09-20 00:00Z')$$,
                         '22023', '%not available%', 'shop A''s service cannot be booked through shop B');

-- the helper runs inside the SECURITY DEFINER RPC, so API callers need no
-- EXECUTE on it (anon always gets the server clock, hence a future date)
select tests.as_anon();
select tests.lives($$select * from public.get_available_slots('shop-b', array[tests.fx('half_b')], current_date + 7, current_date + 7, null, null)$$,
                   'anon can list slots although it cannot call wall_clock_instant directly');
