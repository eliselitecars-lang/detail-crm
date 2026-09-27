-- 00 foundation: get_available_slots — business hours, split/merged
-- intervals, blocked times, buffer, capacity, lead time, max days ahead,
-- validation, DST (America/Chicago spring-forward and fall-back), anon access.
-- Shop A is in America/Chicago; results are compared in UTC.
\ir fixtures/two_shops.psql

select tests.as_superuser();
-- slots as 'MM-DD HH24:MI' (UTC), ordered
create function pg_temp.slots(p_from date, p_to date, p_services uuid[], p_now timestamptz,
                              p_cat uuid default null, p_slug text default 'shop-a')
returns text[] language sql as $$
  select coalesce(array_agg(to_char(s.starts_at at time zone 'UTC', 'MM-DD HH24:MI') order by s.starts_at), '{}')
  from public.get_available_slots(p_slug, p_services, p_cat, p_from, p_to, p_now) s
$$;
grant execute on function pg_temp.slots(date, date, uuid[], timestamptz, uuid, text) to anon, authenticated;

update public.booking_settings
   set enabled = true, slot_interval_minutes = 60, lead_time_minutes = 0, max_days_ahead = 60,
       buffer_minutes = 0, max_concurrent_jobs = 1
 where shop_id = tests.fx('shop_a');
-- Mondays 08:00-17:00; Tuesdays split 08-12 & 13-17; Wednesdays adjacent 08-12 & 12-17
insert into public.business_hours (shop_id, weekday, opens_at, closes_at) values
  (tests.fx('shop_a'), 1, '08:00', '17:00'),
  (tests.fx('shop_a'), 2, '08:00', '12:00'), (tests.fx('shop_a'), 2, '13:00', '17:00'),
  (tests.fx('shop_a'), 3, '08:00', '12:00'), (tests.fx('shop_a'), 3, '12:00', '17:00');
insert into public.services (shop_id, name, kind, duration_minutes, online_bookable) values
  (tests.fx('shop_a'), 'Engine Bay', 'addon', 30, true) returning tests.fx_set('addon_a', id);
insert into public.services (shop_id, name, duration_minutes, online_bookable) values
  (tests.fx('shop_a'), 'One Hour', 60, true) returning tests.fx_set('hour_a', id);
insert into public.services (shop_id, name, duration_minutes, online_bookable) values
  (tests.fx('shop_a'), 'Three Hours', 180, true) returning tests.fx_set('three_a', id);

-- ------------------------------------------------------------ basics (Monday 2025-06-09, CDT = UTC-5)
select tests.eq(pg_temp.slots('2025-06-09', '2025-06-09', array[tests.fx('svc_a')], '2025-06-01 12:00Z'),
                array['06-09 13:00', '06-09 14:00', '06-09 15:00', '06-09 16:00', '06-09 17:00', '06-09 18:00', '06-09 19:00', '06-09 20:00'],
                '120-min service: 08:00..15:00 local on the hour; must end by 17:00');
select tests.eq(pg_temp.slots('2025-06-10', '2025-06-10', array[tests.fx('svc_a')], '2025-06-01 12:00Z'),
                array['06-10 13:00', '06-10 14:00', '06-10 15:00', '06-10 18:00', '06-10 19:00', '06-10 20:00'],
                'split hours: a slot must fit inside one open interval (lunch gap respected)');
select tests.eq(cardinality(pg_temp.slots('2025-06-11', '2025-06-11', array[tests.fx('svc_a')], '2025-06-01 12:00Z')), 8,
                'adjacent intervals merge: 11:00-13:00 across the 12:00 boundary is offered');
select tests.eq(pg_temp.slots('2025-06-12', '2025-06-12', array[tests.fx('svc_a')], '2025-06-01 12:00Z'), '{}'::text[],
                'no business-hours row = closed');
select tests.eq(cardinality(pg_temp.slots('2025-06-09', '2025-06-09', array[tests.fx('svc_a'), tests.fx('addon_a')], '2025-06-01 12:00Z')), 7,
                'durations add up (150 min): last start 14:00');
select tests.eq(cardinality(pg_temp.slots('2025-06-09', '2025-06-09', array[tests.fx('svc_a'), tests.fx('svc_a')], '2025-06-01 12:00Z')), 8,
                'duplicate service ids are counted once');
select tests.as_superuser();
insert into public.service_prices (shop_id, service_id, vehicle_category_id, price_cents, duration_minutes)
  values (tests.fx('shop_a'), tests.fx('svc_a'), tests.fx('cat_car_a'), 18000, 60);
select tests.eq(cardinality(pg_temp.slots('2025-06-09', '2025-06-09', array[tests.fx('svc_a')], '2025-06-01 12:00Z', tests.fx('cat_car_a'))), 9,
                'category duration override (60 min) is used');
select tests.eq((select ends_at - starts_at from public.get_available_slots('shop-a', array[tests.fx('svc_a')], tests.fx('cat_car_a'),
                  '2025-06-09', '2025-06-09', '2025-06-01 12:00Z') limit 1), interval '60 minutes', 'ends_at = start + duration');
select tests.eq(cardinality(pg_temp.slots('2025-06-09', '2025-06-09', array[tests.fx('svc_a')], '2025-06-01 12:00Z', null, 'SHOP-A')), 8,
                'slug lookup is case-insensitive');
update public.booking_settings set slot_interval_minutes = 30 where shop_id = tests.fx('shop_a');
select tests.eq(cardinality(pg_temp.slots('2025-06-09', '2025-06-09', array[tests.fx('svc_a')], '2025-06-01 12:00Z')), 15,
                '30-minute grid: 08:00..15:00 = 15 starts');
update public.booking_settings set slot_interval_minutes = 60 where shop_id = tests.fx('shop_a');

-- ------------------------------------------------------------ existing jobs, buffer, capacity (Monday 2025-06-02)
-- job_a 10:00-12:00 local, job_a2 13:00-14:00 local
select tests.eq(pg_temp.slots('2025-06-02', '2025-06-02', array[tests.fx('svc_a')], '2025-06-01 12:00Z'),
                array['06-02 13:00', '06-02 19:00', '06-02 20:00'], 'existing jobs block overlapping slots');
update public.booking_settings set buffer_minutes = 30 where shop_id = tests.fx('shop_a');
select tests.eq(pg_temp.slots('2025-06-02', '2025-06-02', array[tests.fx('svc_a')], '2025-06-01 12:00Z'),
                array['06-02 20:00'], 'buffer widens existing jobs on both sides');
update public.booking_settings set buffer_minutes = 0, max_concurrent_jobs = 2 where shop_id = tests.fx('shop_a');
select tests.eq(cardinality(pg_temp.slots('2025-06-02', '2025-06-02', array[tests.fx('svc_a')], '2025-06-01 12:00Z')), 8,
                'capacity 2: single existing jobs no longer block');
update public.booking_settings set max_concurrent_jobs = 1 where shop_id = tests.fx('shop_a');
update public.jobs set status = 'cancelled' where id = tests.fx('job_a2');
update public.jobs set status = 'no_show' where id = tests.fx('job_a');
select tests.eq(cardinality(pg_temp.slots('2025-06-02', '2025-06-02', array[tests.fx('svc_a')], '2025-06-01 12:00Z')), 8,
                'cancelled and no-show jobs free their time');
select tests.as_superuser();
update public.jobs set status = 'scheduled' where id in (tests.fx('job_a'), tests.fx('job_a2'));
select tests.eq(cardinality(pg_temp.slots('2025-06-02', '2025-06-02', array[tests.fx('svc_a')], '2025-06-01 12:00Z')), 3,
                'reinstated jobs block again');

-- capacity is measured at every instant, not by counting overlaps:
-- Wednesday 2025-06-11: X 10:00-11:00 and Y 12:00-13:00 local never overlap each other.
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end) values
  (tests.fx('shop_a'), tests.fx('cust_a3'), '2025-06-11 15:00Z', '2025-06-11 16:00Z'),
  (tests.fx('shop_a'), tests.fx('cust_a3'), '2025-06-11 17:00Z', '2025-06-11 18:00Z');
update public.booking_settings set max_concurrent_jobs = 2 where shop_id = tests.fx('shop_a');
select tests.ok('06-11 15:00' = any (pg_temp.slots('2025-06-11', '2025-06-11', array[tests.fx('three_a')], '2025-06-01 12:00Z')),
                'capacity 2: a 10:00-13:00 slot spanning two non-overlapping jobs is available');
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end) values
  (tests.fx('shop_a'), tests.fx('cust_a3'), '2025-06-11 15:30Z', '2025-06-11 16:30Z');
select tests.eq(pg_temp.slots('2025-06-11', '2025-06-11', array[tests.fx('three_a')], '2025-06-01 12:00Z'),
                array['06-11 16:00', '06-11 17:00', '06-11 18:00', '06-11 19:00'],
                'capacity 2: starts 08:00-10:00 cover the 10:30-11:00 double-booked window and are removed');
update public.booking_settings set max_concurrent_jobs = 1 where shop_id = tests.fx('shop_a');

-- ------------------------------------------------------------ blocked times (Monday 2025-06-09)
insert into public.blocked_times (shop_id, starts_at, ends_at, reason)
  values (tests.fx('shop_a'), '2025-06-09 17:00Z', '2025-06-09 18:00Z', 'Staff meeting');
insert into public.blocked_times (shop_id, member_id, starts_at, ends_at, reason)
  values (tests.fx('shop_a'), tests.fx('m_tech_a'), '2025-06-09 13:00Z', '2025-06-09 22:00Z', 'Vacation');
select tests.eq(pg_temp.slots('2025-06-09', '2025-06-09', array[tests.fx('svc_a')], '2025-06-01 12:00Z'),
                array['06-09 13:00', '06-09 14:00', '06-09 15:00', '06-09 18:00', '06-09 19:00', '06-09 20:00'],
                'shop-wide block removes overlapping slots; a member''s personal block does not');
select tests.as_superuser();
delete from public.blocked_times where shop_id = tests.fx('shop_a');

-- ------------------------------------------------------------ lead time & max days ahead
update public.booking_settings set lead_time_minutes = 60 where shop_id = tests.fx('shop_a');
select tests.eq(pg_temp.slots('2025-06-09', '2025-06-09', array[tests.fx('svc_a')], '2025-06-09 14:10Z'),
                array['06-09 16:00', '06-09 17:00', '06-09 18:00', '06-09 19:00', '06-09 20:00'],
                'lead time: nothing before now + 60 min (09:10 local -> first 11:00)');
update public.booking_settings set lead_time_minutes = 0, max_days_ahead = 7 where shop_id = tests.fx('shop_a');
select tests.eq(pg_temp.slots('2025-06-09', '2025-06-09', array[tests.fx('svc_a')], '2025-06-01 12:00Z'), '{}'::text[],
                'max_days_ahead 7 from Sunday 06-01 excludes Monday 06-09');
update public.booking_settings set max_days_ahead = 8 where shop_id = tests.fx('shop_a');
select tests.eq(cardinality(pg_temp.slots('2025-06-09', '2025-06-09', array[tests.fx('svc_a')], '2025-06-01 12:00Z')), 8,
                'max_days_ahead 8 includes Monday 06-09');
select tests.eq(pg_temp.slots('2025-05-01', '2025-05-31', array[tests.fx('svc_a')], '2025-06-01 12:00Z'), '{}'::text[],
                'dates before today return nothing');
update public.booking_settings set max_days_ahead = 60 where shop_id = tests.fx('shop_a');
select tests.eq((select count(*) from public.get_available_slots('shop-a', array[tests.fx('svc_a')], null, '2025-06-01', '2025-08-01',
                                                                  '2025-06-01 12:00Z')) > 0, true,
                '62-day range (inclusive) is allowed');

-- ------------------------------------------------------------ validation
select tests.throws_like($$select * from public.get_available_slots('shop-a', array[tests.fx('svc_a')], null, '2025-06-01', '2025-08-02', '2025-06-01 12:00Z')$$,
                         '22023', '%62 days%', '63-day range rejected');
select tests.throws($$select * from public.get_available_slots('shop-a', array[tests.fx('svc_a')], null, '2025-06-09', '2025-06-08', '2025-06-01 12:00Z')$$,
                    '22023', 'to before from');
select tests.throws($$select * from public.get_available_slots('shop-a', '{}', null, '2025-06-09', '2025-06-09', '2025-06-01 12:00Z')$$,
                    '22023', 'no services');
select tests.throws($$select * from public.get_available_slots('shop-a', null, null, '2025-06-09', '2025-06-09', '2025-06-01 12:00Z')$$,
                    '22023', 'null services');
select tests.throws($$select * from public.get_available_slots('no-such-shop', array[tests.fx('svc_a')], null, '2025-06-09', '2025-06-09', '2025-06-01 12:00Z')$$,
                    'P0002', 'unknown shop');
select tests.throws_like($$select * from public.get_available_slots('shop-a', array[tests.fx('svc_b')], null, '2025-06-09', '2025-06-09', '2025-06-01 12:00Z')$$,
                         '22023', '%not available%', 'another shop''s service rejected');
select tests.throws_like($$select * from public.get_available_slots('shop-a', array[tests.fx('svc_a')], tests.fx('cat_car_b'), '2025-06-09', '2025-06-09', '2025-06-01 12:00Z')$$,
                         '22023', '%vehicle category%', 'another shop''s vehicle category rejected');
select tests.throws($$select * from public.get_available_slots('shop-a', array[gen_random_uuid()], null, '2025-06-09', '2025-06-09', '2025-06-01 12:00Z')$$,
                    '22023', 'unknown service rejected');
update public.services set active = false where id = tests.fx('addon_a');
select tests.throws($$select * from public.get_available_slots('shop-a', array[tests.fx('svc_a'), tests.fx('addon_a')], null, '2025-06-09', '2025-06-09', '2025-06-01 12:00Z')$$,
                    '22023', 'inactive service rejected');
update public.services set active = true, online_bookable = false where id = tests.fx('addon_a');
select tests.throws($$select * from public.get_available_slots('shop-a', array[tests.fx('addon_a')], null, '2025-06-09', '2025-06-09', '2025-06-01 12:00Z')$$,
                    '22023', 'non-bookable service rejected');
update public.services set online_bookable = true, archived_at = now() where id = tests.fx('addon_a');
select tests.throws($$select * from public.get_available_slots('shop-a', array[tests.fx('addon_a')], null, '2025-06-09', '2025-06-09', '2025-06-01 12:00Z')$$,
                    '22023', 'archived service rejected');
update public.services set duration_minutes = 0, archived_at = null where id = tests.fx('addon_a');
select tests.throws_like($$select * from public.get_available_slots('shop-a', array[tests.fx('addon_a')], null, '2025-06-09', '2025-06-09', '2025-06-01 12:00Z')$$,
                         '22023', '%no duration%', 'zero total duration rejected');
select tests.throws_like($$select * from public.get_available_slots('shop-b', array[tests.fx('svc_b')], null, '2025-06-09', '2025-06-09', '2025-06-01 12:00Z')$$,
                         '55000', '%not enabled%', 'disabled online booking rejected');

-- ------------------------------------------------------------ DST in America/Chicago
-- Sundays: 00:00-06:00 (crosses the 02:00 transition) and 08:00-10:00.
insert into public.business_hours (shop_id, weekday, opens_at, closes_at) values
  (tests.fx('shop_a'), 0, '00:00', '06:00'), (tests.fx('shop_a'), 0, '08:00', '10:00');
-- ordinary Sunday (CST, UTC-6)
select tests.eq(pg_temp.slots('2025-03-02', '2025-03-02', array[tests.fx('hour_a')], '2025-02-20 00:00Z'),
                array['03-02 06:00', '03-02 07:00', '03-02 08:00', '03-02 09:00', '03-02 10:00', '03-02 11:00',
                      '03-02 14:00', '03-02 15:00'], 'standard-time Sunday');
-- spring forward 2025-03-09: 02:00 local does not exist; 6 wall hours are 5 real hours
select tests.eq(pg_temp.slots('2025-03-09', '2025-03-09', array[tests.fx('hour_a')], '2025-02-20 00:00Z'),
                array['03-09 06:00', '03-09 07:00', '03-09 08:00', '03-09 09:00', '03-09 10:00',
                      '03-09 13:00', '03-09 14:00'],
                'spring-forward: 02:00 skipped, no duplicates, 08:00 local is now UTC-5');
update public.booking_settings set slot_interval_minutes = 30 where shop_id = tests.fx('shop_a');
select tests.eq((select array_agg(to_char(starts_at at time zone 'America/Chicago', 'HH24:MI') order by starts_at)
                   from public.get_available_slots('shop-a', array[tests.fx('hour_a')], null, '2025-03-09', '2025-03-09', '2025-02-20 00:00Z')
                  where starts_at < '2025-03-09 12:00Z'),
                array['00:00', '00:30', '01:00', '01:30', '03:00', '03:30', '04:00', '04:30', '05:00'],
                'spring-forward 30-min grid: 02:00 and 02:30 never offered');
update public.booking_settings set slot_interval_minutes = 60 where shop_id = tests.fx('shop_a');
-- fall back 2025-11-02: 01:00 local happens twice; offered once, no duplicates
select tests.eq(pg_temp.slots('2025-11-02', '2025-11-02', array[tests.fx('hour_a')], '2025-10-20 00:00Z'),
                array['11-02 05:00', '11-02 07:00', '11-02 08:00', '11-02 09:00', '11-02 10:00', '11-02 11:00',
                      '11-02 14:00', '11-02 15:00'],
                'fall-back: 00:00 CDT then 01:00..05:00 CST (01:00 once), 08:00 local is now UTC-6');
select tests.eq((select count(*) = count(distinct starts_at) from public.get_available_slots('shop-a', array[tests.fx('hour_a')], null,
                  '2025-11-01', '2025-11-03', '2025-10-20 00:00Z')), true, 'no duplicate slots across the fall-back weekend');
select tests.eq((select count(distinct to_char(starts_at at time zone 'America/Chicago', 'YYYY-MM-DD HH24:MI'))
                   = count(*) from public.get_available_slots('shop-a', array[tests.fx('hour_a')], null,
                  '2025-11-01', '2025-11-03', '2025-10-20 00:00Z')), true, 'no duplicate local wall times either');

-- ------------------------------------------------------------ midnight-spanning hours merge (Fri 20-24 + Sat 00-02)
insert into public.business_hours (shop_id, weekday, opens_at, closes_at) values
  (tests.fx('shop_a'), 5, '20:00', '24:00'), (tests.fx('shop_a'), 6, '00:00', '02:00');
select tests.eq((select array_agg(to_char(starts_at at time zone 'America/Chicago', 'HH24:MI') order by starts_at)
                   from public.get_available_slots('shop-a', array[tests.fx('three_a')], null, '2025-06-13', '2025-06-13', '2025-06-01 12:00Z')),
                array['20:00', '21:00', '22:00', '23:00'], 'a 3-hour slot may run past midnight into Saturday''s hours');

-- ------------------------------------------------------------ callers & the request clock
-- p_now is honoured only for trusted callers (service_role, direct sessions);
-- API requests (anon/authenticated) always use the server clock, so a caller
-- cannot list past dates and read the gaps as a map of past appointments.
-- (The file runs in one transaction, so now() is constant throughout.)
select tests.as_superuser();
-- the first Monday at least 2 days after today (shop-local): a real future
-- weekday (US DST changes happen on Sundays), within max_days_ahead (60)
create function pg_temp.next_monday() returns date language sql stable as $$
  select min(d)::date
  from generate_series((now() at time zone 'America/Chicago')::date + 2,
                       (now() at time zone 'America/Chicago')::date + 8, interval '1 day') d
  where extract(dow from d) = 1
$$;
grant execute on function pg_temp.next_monday() to anon, authenticated, service_role;
select tests.eq(cardinality(pg_temp.slots(pg_temp.next_monday(), pg_temp.next_monday(), array[tests.fx('svc_a')], now())), 8,
                'trusted session at the server clock: next Monday 08:00..15:00 local');
select tests.eq(pg_temp.slots(pg_temp.next_monday(), pg_temp.next_monday(), array[tests.fx('svc_a')], null),
                pg_temp.slots(pg_temp.next_monday(), pg_temp.next_monday(), array[tests.fx('svc_a')], now()),
                'a null p_now means the server clock');

select tests.as_service();
select tests.eq(pg_temp.slots('2025-06-02', '2025-06-02', array[tests.fx('svc_a')], '2025-06-01 12:00Z'),
                array['06-02 13:00', '06-02 19:00', '06-02 20:00'], 'service_role: p_now is honoured (fixed-clock previews)');

select tests.as_anon();
-- regression: a past p_now used to list the gaps around past jobs (3 slots on 06-02)
select tests.eq((select count(*) from public.get_available_slots('shop-a', array[tests.fx('svc_a')], tests.fx('cat_car_a'),
                   '2025-06-02', '2025-06-02', '2025-06-01 00:00Z')), 0::bigint,
                'anon cannot list (and thereby map the busy schedule of) past dates by supplying p_now');
select tests.eq(pg_temp.slots('2025-06-02', '2025-06-02', array[tests.fx('svc_a')], '2025-06-01 12:00Z'), '{}'::text[],
                'anon: a past p_now is ignored (no past slots)');
select tests.eq(pg_temp.slots(pg_temp.next_monday(), pg_temp.next_monday(), array[tests.fx('svc_a')], '2025-06-01 12:00Z'),
                pg_temp.slots(pg_temp.next_monday(), pg_temp.next_monday(), array[tests.fx('svc_a')], now()),
                'anon: whatever p_now is sent, future slots are computed from the server clock');
select tests.eq(cardinality(pg_temp.slots(pg_temp.next_monday(), pg_temp.next_monday(), array[tests.fx('svc_a')], now())), 8,
                'anon can list future slots');
select tests.eq(pg_temp.slots(pg_temp.next_monday() + 70, pg_temp.next_monday() + 70, array[tests.fx('svc_a')],
                              now() + interval '70 days'), '{}'::text[],
                'anon: a future p_now cannot stretch max_days_ahead (60) past the real today');
select tests.throws($$select public.effective_now(now())$$, '42501', 'anon cannot call the request clock directly');

select tests.authenticate_as(tests.fx('u_outsider'));
select tests.eq(cardinality(pg_temp.slots(pg_temp.next_monday(), pg_temp.next_monday(), array[tests.fx('svc_a')], now())), 8,
                'any signed-in user can list slots');
select tests.eq(pg_temp.slots('2025-06-02', '2025-06-02', array[tests.fx('svc_a')], '2025-06-01 12:00Z'), '{}'::text[],
                'signed-in outsider: a past p_now is ignored');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.eq(pg_temp.slots('2025-06-02', '2025-06-02', array[tests.fx('svc_a')], '2025-06-01 12:00Z'), '{}'::text[],
                'even the shop''s own staff get the server clock through the API (the calendar is their past view)');
select tests.throws($$select public.is_api_request()$$, '42501', 'authenticated cannot call is_api_request directly');

select tests.as_superuser();
select tests.eq(cardinality(pg_temp.slots(pg_temp.next_monday() + 70, pg_temp.next_monday() + 70, array[tests.fx('svc_a')],
                                          now() + interval '70 days')), 8,
                'trusted session: a future p_now moves today and max_days_ahead with it');
