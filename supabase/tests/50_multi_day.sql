-- 50 sched: multi-day online bookings (P-17, 0053/0054) — a booking longer
-- than the opening it starts in continues at the next openings (split hours,
-- closed days), ends_at is the wrap end, the local-day limit, closures and
-- capacity over the whole span, and create_online_booking storing the wrap
-- end. Shop A (America/Chicago) is open 08:00-17:00 every day (9 hours) on a
-- 60-minute grid (40_booking_setup). Trusted session: today = 2025-06-01.
\ir fixtures/two_shops.psql
\ir fixtures/40_booking_setup.psql

select tests.as_superuser();
insert into public.services (shop_id, name, duration_minutes, online_bookable) values (tests.fx('shop_a'), 'Ceramic Coating', 720, true)
  returning tests.fx_set('svc_coat', id);
insert into public.service_prices (shop_id, service_id, price_cents) values (tests.fx('shop_a'), tests.fx('svc_coat'), 120000);
-- 'start->end' in local time, e.g. '08->Tue 11:00'
create function pg_temp.spans(p_day date) returns text language sql as $$
  select coalesce(string_agg(to_char(s.starts_at at time zone 'America/Chicago', 'HH24') || '->'
                             || to_char(s.ends_at at time zone 'America/Chicago', 'Dy HH24:MI'), ',' order by s.starts_at), '')
  from public.public_booking_slots('shop-a', array[tests.fx('svc_coat')], p_day, p_day, null, 'shop', null, '2025-06-01 12:00Z') s
$$;

select tests.eq(pg_temp.spans('2025-06-09'), '', 'without multi-day bookings a 12-hour service never fits a 9-hour day');
update public.booking_settings set allow_multi_day = true where shop_id = tests.fx('shop_a');
select tests.eq(pg_temp.spans('2025-06-09'),
                '08->Tue 11:00,09->Tue 12:00,10->Tue 13:00,11->Tue 14:00,12->Tue 15:00,13->Tue 16:00,14->Tue 17:00',
                'two local days: the work continues at the next opening; later starts would need a third day');
select tests.eq((select count(*) from public.public_booking_slots('shop-a', array[tests.fx('svc_wash')], '2025-06-09', '2025-06-09',
                   null, 'shop', null, '2025-06-01 12:00Z')), 9::bigint, 'bookings that fit are unchanged');
update public.booking_settings set slot_interval_minutes = 30 where shop_id = tests.fx('shop_a');
select tests.eq((select max(to_char(s.starts_at at time zone 'America/Chicago', 'HH24:MI'))
                   from public.public_booking_slots('shop-a', array[tests.fx('svc_wash')], '2025-06-09', '2025-06-09',
                                                    null, 'shop', null, '2025-06-01 12:00Z') s), '16:00',
                'a service that fits a day never wraps: no 16:30 start finishing the next morning');
update public.booking_settings set slot_interval_minutes = 60 where shop_id = tests.fx('shop_a');
update public.booking_settings set multi_day_max_days = 3 where shop_id = tests.fx('shop_a');
select tests.eq(pg_temp.spans('2025-06-09'),
                '08->Tue 11:00,09->Tue 12:00,10->Tue 13:00,11->Tue 14:00,12->Tue 15:00,13->Tue 16:00,14->Tue 17:00,15->Wed 09:00,16->Wed 10:00',
                'three local days allowed');
select tests.throws($$update public.booking_settings set multi_day_max_days = 8 where shop_id = tests.fx('shop_a')$$, '23514',
                    'at most 7 days');
select tests.throws($$update public.booking_settings set multi_day_max_days = 1 where shop_id = tests.fx('shop_a')$$, '23514',
                    'at least 2 days');

-- split hours on Tuesday (08-12, 13-17): the wrap skips the lunch gap
delete from public.business_hours where shop_id = tests.fx('shop_a') and weekday = 2;
insert into public.business_hours (shop_id, weekday, opens_at, closes_at) values
  (tests.fx('shop_a'), 2, '08:00', '12:00'), (tests.fx('shop_a'), 2, '13:00', '17:00');
select tests.eq(split_part(pg_temp.spans('2025-06-09'), ',', 3), '10->Tue 14:00',
                '10:00 Monday: 7h Monday + 4h Tuesday morning + 1h after lunch');
select tests.eq(split_part(pg_temp.spans('2025-06-09'), ',', 1), '08->Tue 11:00', '08:00 Monday: 3h Tuesday morning');
-- a closed Wednesday is skipped; the local-day limit counts calendar days
delete from public.business_hours where shop_id = tests.fx('shop_a') and weekday = 3;
select tests.eq(pg_temp.spans('2025-06-09'),
                '08->Tue 11:00,09->Tue 12:00,10->Tue 14:00,11->Tue 15:00,12->Tue 16:00,13->Tue 17:00',
                'Monday 14:00 would end Thursday (4 local days): not offered');
select tests.eq(pg_temp.spans('2025-06-10'),
                '08->Thu 12:00,09->Thu 13:00,10->Thu 14:00,11->Thu 15:00,13->Thu 16:00,14->Thu 17:00',
                'Tuesday starts skip the closed Wednesday (grid restarts after lunch; 12:00 is closing time)');
update public.booking_settings set multi_day_max_days = 4 where shop_id = tests.fx('shop_a');
select tests.eq(split_part(pg_temp.spans('2025-06-10'), ',', 8), '16->Fri 10:00', 'with 4 days a late Tuesday start ends Friday');
update public.booking_settings set multi_day_max_days = 2 where shop_id = tests.fx('shop_a');
insert into public.business_hours (shop_id, weekday, opens_at, closes_at) values (tests.fx('shop_a'), 3, '08:00', '17:00');
delete from public.business_hours where shop_id = tests.fx('shop_a') and weekday = 2;
insert into public.business_hours (shop_id, weekday, opens_at, closes_at) values (tests.fx('shop_a'), 2, '08:00', '17:00');

-- ============================================================ capacity and closures over the whole span
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a3'), '2025-06-10 14:00Z', '2025-06-10 15:00Z')   -- Tue 09:00-10:00
  returning tests.fx_set('job_tue', id);
select tests.eq(pg_temp.spans('2025-06-09'), '', 'capacity 1: a Tuesday 09:00 job blocks every Monday start that runs into it');
update public.booking_settings set max_concurrent_jobs = 2 where shop_id = tests.fx('shop_a');
select tests.eq(cardinality(string_to_array(pg_temp.spans('2025-06-09'), ',')), 7, 'capacity 2: all seven starts again');
update public.booking_settings set max_concurrent_jobs = 1 where shop_id = tests.fx('shop_a');
delete from public.jobs where id = tests.fx('job_tue');
insert into public.blocked_times (shop_id, kind, starts_at, ends_at)
  values (tests.fx('shop_a'), 'closed', '2025-06-10 20:00Z', '2025-06-10 22:00Z')              -- Tue 15:00-17:00
  returning tests.fx_set('closed_tue', id);
select tests.eq(pg_temp.spans('2025-06-09'), '08->Tue 11:00,09->Tue 12:00,10->Tue 13:00,11->Tue 14:00,12->Tue 15:00',
                'a Tuesday afternoon closure removes the starts that would still be working then');
delete from public.blocked_times where id = tests.fx('closed_tue');
-- an overnight closure blocks the whole span (the vehicle stays with the shop)
insert into public.blocked_times (shop_id, kind, starts_at, ends_at)
  values (tests.fx('shop_a'), 'closed', '2025-06-10 03:00Z', '2025-06-10 04:00Z')              -- Mon 22:00-23:00
  returning tests.fx_set('closed_night', id);
select tests.eq(pg_temp.spans('2025-06-09'), '', 'a closure overnight blocks every span across that night');
delete from public.blocked_times where id = tests.fx('closed_night');

-- a multi-day job already booked takes capacity over its whole span
update public.booking_settings set lead_time_minutes = 0 where shop_id = tests.fx('shop_a');
create temp table booked as
  select public.create_online_booking('shop-a', pg_temp.booking(jsonb_build_object(
           'service_ids', jsonb_build_array(tests.fx('svc_coat')), 'starts_at', '2025-06-09T08:00:00')),
           '2025-06-01 12:00Z') as r;
select tests.eq((select to_char(j.scheduled_start at time zone 'America/Chicago', 'Dy HH24:MI') || ' - ' ||
                        to_char(j.scheduled_end at time zone 'America/Chicago', 'Dy HH24:MI')
                   from public.jobs j join booked b on j.number = (b.r ->> 'job_number')::bigint and j.shop_id = tests.fx('shop_a')),
                'Mon 08:00 - Tue 11:00', 'create_online_booking stores the wrap end');
select tests.eq((select count(*) from public.public_booking_slots('shop-a', array[tests.fx('svc_wash')], '2025-06-09', '2025-06-10',
                   null, 'shop', null, '2025-06-01 12:00Z')), 6::bigint,
                'nothing else fits during the span (capacity 1): only Tuesday 11:00-16:00 starts remain');
select tests.throws_like($$select public.create_online_booking('shop-a', pg_temp.booking(jsonb_build_object(
                             'service_ids', jsonb_build_array(tests.fx('svc_coat')), 'starts_at', '2025-06-09T15:00:00')),
                             '2025-06-01 12:00Z')$$,
                         '23P01', '%no longer available%', 'a start that needs a third day is refused');
select tests.throws_like($$select public.create_online_booking('shop-a', pg_temp.booking(jsonb_build_object(
                             'service_ids', jsonb_build_array(tests.fx('svc_coat')), 'starts_at', '2025-06-09T17:00:00')),
                             '2025-06-01 12:00Z')$$,
                         '23P01', '%no longer available%', 'a start at closing time is never offered');
