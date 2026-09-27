-- 40 integration: online-booking hardening regressions
--   * a stranger-minted booking (someone else's email typed into the public
--     form) reveals neither the on-file customer name (through the attached
--     form) nor the on-file vehicle (year / trim / color); untrusted bookings
--     never reuse the matched customer's vehicle, trusted ones still do
--   * technicians cannot cancel their jobs through the customer token RPC
--   * starts_at without a UTC offset is shop-local wall time (never the
--     session's UTC); nonexistent / ambiguous local times are refused
--   * the slot grid does not depend on the searched date range (open hours
--     running across midnight for days, or around the clock), so every
--     offered slot can be booked
\ir fixtures/two_shops.psql
\ir fixtures/40_booking_setup.psql

update public.booking_settings set max_concurrent_jobs = 100 where shop_id = tests.fx('shop_a');
insert into public.form_templates (shop_id, name, body, attach_to)
values (tests.fx('shop_a'), 'Waiver', 'I agree', 'online_booking');
update public.vehicles set trim = 'Sport', color = 'Rallye Red' where id = tests.fx('veh_a');  -- Alice's 2021 Honda Civic

-- ============================================================ stranger-minted booking for alice@example.com
select tests.as_service();  -- untrusted public booking (no signed-in user), fixed clock
create temp table r as
  select public.create_online_booking('shop-a', pg_temp.booking(jsonb_build_object(
    'customer', jsonb_build_object('first_name', 'Mallory', 'email', 'alice@example.com'),
    'vehicle', jsonb_build_object('make', 'Honda', 'model', 'Civic', 'category_id', tests.fx('cat_car_a')))),
    '2025-06-01 12:00Z') as res;
select tests.as_superuser();
select tests.fx_set('m_job', (select id from public.jobs where public_token = (select (res ->> 'job_token')::uuid from r)));
select tests.eq((select customer_id from public.jobs where id = tests.fx('m_job')), tests.fx('cust_a'),
                'the booking still lands on the matched customer (SPEC: upsert by email)');
select tests.ok((select vehicle_id <> tests.fx('veh_a') from public.jobs where id = tests.fx('m_job')),
                'an untrusted booking does not reuse the matched customer''s vehicle');
select tests.ok((select v.customer_id = tests.fx('cust_a') and v.year is null and v.trim is null and v.color is null
                        and v.make = 'Honda' and v.model = 'Civic' and v.category_id = tests.fx('cat_car_a')
                   from public.vehicles v join public.jobs j on j.vehicle_id = v.id where j.id = tests.fx('m_job')),
                'it creates a vehicle from the submitted fields only');
select tests.ok((select year = 2021 and trim = 'Sport' and color = 'Rallye Red' from public.vehicles where id = tests.fx('veh_a')),
                'the on-file vehicle is untouched');
grant select on r to anon, authenticated;

select tests.as_anon();
create temp table b as select public.public_get_booking((select (res ->> 'job_token')::uuid from r)) as doc;
create temp table f as select public.public_get_form(((select doc from b) #>> '{forms,0,token}')::uuid) as doc;
select tests.eq((select doc #>> '{forms,0,title}' from b), 'Waiver', 'the online-booking waiver is attached and listed');
select tests.eq((select doc #>> '{customer,first_name}' from f), null::text,
                'public form reached through a stranger-minted booking token must not reveal the on-file customer name');
select tests.ok((select doc::text not like '%Alice%' and doc::text not like '%Anders%' from f), 'no on-file name anywhere in the form');
select tests.ok((select doc ? 'customer' from f), 'the customer key stays (null) for a stable document shape');
select tests.eq((select doc #>> '{job,vehicle}' from f), 'Honda Civic', 'the form shows only the submitted vehicle');
select tests.eq((select doc #>> '{vehicle,year}' from b), null::text, 'stranger-minted booking must not reveal the on-file vehicle year');
select tests.ok((select (doc -> 'vehicle')::text not like '%Rallye Red%' and (doc -> 'vehicle')::text not like '%Sport%' from b),
                'nor its trim or color');
select tests.ok((select doc::text not like '%Rallye%' and doc::text not like '%Sport%' from b),
                'nothing on file about the vehicle anywhere on the booking page (line labels included)');

-- only the signed-in client linked to the customer sees the name on the form
select tests.as_superuser();
select tests.fx_set('u_alice', tests.create_user('alice@example.com'));
update public.customers set portal_user_id = tests.fx('u_alice') where id = tests.fx('cust_a');
select tests.fx_set('m_form_tok', (select public_token from public.form_submissions where job_id = tests.fx('m_job')));
select tests.as_anon();
select tests.eq(public.public_get_form(tests.fx('m_form_tok')) -> 'customer', 'null'::jsonb, 'anon: still no name');
select tests.authenticate_as(tests.fx('u_outsider'));
select tests.eq(public.public_get_form(tests.fx('m_form_tok')) -> 'customer', 'null'::jsonb, 'another signed-in user: no name');
select tests.authenticate_as(tests.fx('u_owner_b'));
select tests.eq(public.public_get_form(tests.fx('m_form_tok')) -> 'customer', 'null'::jsonb, 'another shop''s owner: no name');
select tests.authenticate_as(tests.fx('u_alice'));
select tests.eq(public.public_get_form(tests.fx('m_form_tok')) -> 'customer',
                '{"first_name": "Alice", "last_name": "Anders", "company": null}'::jsonb,
                'the linked client sees their own name on the form');

-- a trusted (linked, confirmed) client still reuses their vehicle
select tests.as_superuser();
create temp table live as
  select to_char(min(s.starts_at) at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') as starts_at
  from public.get_available_slots('shop-a', array[tests.fx('svc_a')], tests.fx('cat_car_a'),
                                  (now() at time zone 'America/Chicago')::date + 3,
                                  (now() at time zone 'America/Chicago')::date + 3) s;
grant select on live to authenticated;
select tests.authenticate_as(tests.fx('u_alice'));
create temp table t as select public.create_online_booking('shop-a', pg_temp.booking(jsonb_build_object(
    'customer', jsonb_build_object('first_name', 'Alice', 'email', 'alice@example.com'),
    'vehicle', jsonb_build_object('make', 'honda', 'model', 'civic', 'year', 2021),
    'starts_at', (select starts_at from live)))) as res;
select tests.eq((public.public_get_booking((select (res ->> 'job_token')::uuid from t)) -> 'vehicle'),
                '{"year": 2021, "make": "Honda", "model": "Civic", "trim": "Sport", "color": "Rallye Red"}'::jsonb,
                'the linked client''s booking reuses and shows their own vehicle');
select tests.as_superuser();
select tests.eq((select vehicle_id from public.jobs where public_token = (select (res ->> 'job_token')::uuid from t)), tests.fx('veh_a'),
                'trusted booking: same vehicle row');

-- cross-shop: the same email in shop B is a different customer; nothing from shop A shows
insert into public.customers (shop_id, first_name, email) values (tests.fx('shop_b'), 'Beatrice', 'bea@example.com')
  returning tests.fx_set('cust_bea', id);
insert into public.vehicles (shop_id, customer_id, year, make, model, color)
  values (tests.fx('shop_b'), tests.fx('cust_bea'), 2019, 'Mazda', 'CX-5', 'Soul Red');
select tests.as_service();
create temp table rb as
  select public.create_online_booking('shop-b', pg_temp.booking(jsonb_build_object(
    'customer', jsonb_build_object('first_name', 'Mallory', 'email', 'bea@example.com'),
    'vehicle', jsonb_build_object('make', 'Mazda', 'model', 'CX-5'),
    'service_ids', jsonb_build_array(tests.fx('svc_b')))), '2025-06-01 12:00Z') as res;
select tests.eq((public.public_get_booking((select (res ->> 'job_token')::uuid from rb)) -> 'vehicle'),
                '{"year": null, "make": "Mazda", "model": "CX-5", "trim": null, "color": null}'::jsonb,
                'shop B: an untrusted booking shows only what was submitted');

-- ============================================================ technicians and the customer cancel RPC
select tests.as_superuser();
update public.jobs set scheduled_start = now() + interval '10 days', scheduled_end = now() + interval '10 days 2 hours'
 where id in (tests.fx('job_a'), tests.fx('job_a2'));
create temp table tok as
  select id, public_token from public.jobs where id in (tests.fx('job_a'), tests.fx('job_a2'));
grant select on tok to authenticated, anon;
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$update public.jobs set status = 'cancelled' where id = tests.fx('job_a')$$, '42501',
                    'technician cannot cancel directly');
select tests.throws_like($$select public.public_cancel_booking((select public_token from tok where id = tests.fx('job_a')), 'tech did it')$$,
                         '42501', '%only owners, admins and managers%',
                         'technician cannot cancel an assigned job through the customer token RPC');
select tests.authenticate_as(tests.fx('u_tech2_a'));
select tests.throws($$select public.public_cancel_booking((select public_token from tok where id = tests.fx('job_a2')))$$, '42501',
                    'nor can the other technician on theirs');
select tests.as_superuser();
select tests.eq((select count(*) from public.jobs where id in (tests.fx('job_a'), tests.fx('job_a2')) and status = 'cancelled'),
                0::bigint, 'both jobs still active');
select tests.eq((select count(*) from public.notifications where kind = 'booking_cancelled'), 0::bigint, 'no cancellation notified');
-- a technician who is the job customer's linked client may cancel their own booking
update public.customers set portal_user_id = tests.fx('u_tech2_a') where id = tests.fx('cust_a2');
select tests.authenticate_as(tests.fx('u_tech2_a'));
select tests.eq(public.public_cancel_booking((select public_token from tok where id = tests.fx('job_a2')), 'my own car')
                  #>> '{booking,status}', 'cancelled', 'a technician may cancel their OWN booking as its linked client');
-- managers+ may cancel anyway; a member of another shop is just a token holder
select tests.as_superuser();
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a3'), 'scheduled', now() + interval '10 days', now() + interval '10 days 1 hour')
  returning tests.fx_set('tok_m', public_token);
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a3'), 'scheduled', now() + interval '11 days', now() + interval '11 days 1 hour')
  returning tests.fx_set('tok_x', public_token);
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(public.public_cancel_booking(tests.fx('tok_m')) #>> '{booking,status}', 'cancelled', 'a manager may');
select tests.authenticate_as(tests.fx('u_tech_b'));
select tests.eq(public.public_cancel_booking(tests.fx('tok_x')) #>> '{booking,status}', 'cancelled',
                'shop B''s technician is not staff of shop A: an ordinary token holder');

-- ============================================================ starts_at without an offset
select tests.as_service();
create temp table n1 as
  select public.create_online_booking('shop-a', pg_temp.booking(jsonb_build_object(
    'starts_at', '2025-06-09T15:00:00', 'customer', jsonb_build_object('first_name', 'Nia', 'email', 'nia@example.com'))),
    '2025-06-01 12:00Z') as r;
select tests.as_superuser();
select tests.eq((select scheduled_start from public.jobs where public_token = (select (r ->> 'job_token')::uuid from n1)),
                '2025-06-09 20:00Z'::timestamptz, 'naive starts_at is shop-local 15:00 CDT (20:00Z), never 15:00 UTC');
select tests.as_service();
create temp table n2 as
  select public.create_online_booking('shop-a', pg_temp.booking(jsonb_build_object(
    'starts_at', '2025-01-13 10:00', 'customer', jsonb_build_object('first_name', 'Nia', 'email', 'nia2@example.com'))),
    '2025-01-01 12:00Z') as r;
select tests.as_superuser();
select tests.eq((select scheduled_start from public.jobs where public_token = (select (r ->> 'job_token')::uuid from n2)),
                '2025-01-13 16:00Z'::timestamptz, 'winter: naive 10:00 is CST (UTC-6), space separator and no seconds accepted');
create function pg_temp.booked_start(p_starts text, p_email text) returns timestamptz language plpgsql as $$
declare
  r jsonb := public.create_online_booking('shop-a', pg_temp.booking(jsonb_build_object('starts_at', p_starts,
               'customer', jsonb_build_object('first_name', 'Oz', 'email', p_email))), '2025-06-01 12:00Z');
begin
  return (select j.scheduled_start from public.jobs j where j.public_token = (r ->> 'job_token')::uuid);
end
$$;
grant execute on function pg_temp.booked_start(text, text) to service_role;
select tests.as_service();
select tests.eq(pg_temp.booked_start('2025-06-10T11:00:00-05:00', 'oz1@example.com'), '2025-06-10 16:00Z'::timestamptz,
                'an explicit offset is honoured');
select tests.eq(pg_temp.booked_start('2025-06-10 17:00:00.000+00', 'oz2@example.com'), '2025-06-10 17:00Z'::timestamptz,
                'Postgres timestamptz text (fraction, short offset) is accepted');
select tests.eq(pg_temp.booked_start('2025-06-10T18:00:00z', 'oz3@example.com'), '2025-06-10 18:00Z'::timestamptz,
                'lower-case z');
select tests.eq(pg_temp.booked_start('2025-06-10T19:00:00+0000', 'oz4@example.com'), '2025-06-10 19:00Z'::timestamptz,
                'basic-format offset');
select tests.throws_like($$select public.create_online_booking('shop-a', pg_temp.booking('{"starts_at": "2025-06-09T15:00:00 America/Chicago"}'),
                           '2025-06-01 12:00Z')$$, '22023', '%ISO-8601%', 'zone names are not ISO-8601 offsets');
select tests.throws_like($$select public.create_online_booking('shop-a', pg_temp.booking('{"starts_at": "2025-06-09T15:00:00 PST"}'),
                           '2025-06-01 12:00Z')$$, '22023', '%ISO-8601%', 'nor are abbreviations');
select tests.throws_like($$select public.create_online_booking('shop-a', pg_temp.booking('{"starts_at": "2025-02-30T10:00:00"}'),
                           '2025-01-01 12:00Z')$$, '22023', '%ISO-8601%', 'impossible dates');
select tests.throws_like($$select public.create_online_booking('shop-a', pg_temp.booking('{"starts_at": "2025-06-09"}'),
                           '2025-06-01 12:00Z')$$, '22023', '%ISO-8601%', 'a date alone');
select tests.throws_like($$select public.create_online_booking('shop-a', pg_temp.booking('{"starts_at": "2025-03-09T02:30:00"}'),
                           '2025-02-20 12:00Z')$$, '22023', '%does not exist%', 'spring-forward gap time without offset');
select tests.throws_like($$select public.create_online_booking('shop-a', pg_temp.booking('{"starts_at": "2025-11-02T01:30:00"}'),
                           '2025-10-20 12:00Z')$$, '22023', '%occurs twice%', 'fall-back ambiguous time without offset');
-- the helper itself (service_role only)
select tests.eq(public.booking_parse_start('2025-11-02T01:30:00-05:00', 'America/Chicago'), '2025-11-02 06:30Z'::timestamptz,
                'first 01:30 (CDT) with its offset');
select tests.eq(public.booking_parse_start('2025-11-02T01:30:00-06:00', 'America/Chicago'), '2025-11-02 07:30Z'::timestamptz,
                'second 01:30 (CST) with its offset');
select tests.eq(public.booking_parse_start('2025-11-02T00:30:00', 'America/Chicago'), '2025-11-02 05:30Z'::timestamptz,
                'unambiguous time on the fall-back day');
select tests.eq(public.booking_parse_start('2025-03-09T03:00:00', 'America/Chicago'), '2025-03-09 08:00Z'::timestamptz,
                'first real time after the spring-forward gap');
select tests.eq(public.booking_parse_start('2025-06-09T15:00:00', 'Asia/Kolkata'), '2025-06-09 09:30Z'::timestamptz,
                'half-hour zones');
select tests.as_anon();
select tests.throws($$select public.booking_parse_start('2025-06-09T15:00:00', 'UTC')$$, '42501', 'internal helper: anon cannot call it');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.throws($$select public.booking_parse_start('2025-06-09T15:00:00', 'UTC')$$, '42501', 'nor authenticated');

-- ============================================================ range-independent slot grid
select tests.as_superuser();
delete from public.business_hours where shop_id = tests.fx('shop_a');
insert into public.business_hours (shop_id, weekday, opens_at, closes_at) values
  (tests.fx('shop_a'), 5, '08:00', '24:00'), (tests.fx('shop_a'), 6, '00:00', '24:00'), (tests.fx('shop_a'), 0, '00:00', '18:00');
update public.booking_settings set slot_interval_minutes = 45, max_concurrent_jobs = 10 where shop_id = tests.fx('shop_a');
-- local 'HH24:MI' starts on a shop-local date, from a given search range
create function pg_temp.local_slots(p_day date, p_from date, p_to date, p_services uuid[] default null) returns text[]
language sql as $$
  select coalesce(array_agg(to_char(s.starts_at at time zone 'America/Chicago', 'HH24:MI') order by s.starts_at), '{}')
  from public.get_available_slots('shop-a', coalesce(p_services, array[tests.fx('svc_a')]), tests.fx('cat_car_a'),
                                  p_from, p_to, '2025-06-01 12:00Z') s
  where (s.starts_at at time zone 'America/Chicago')::date = p_day
$$;
select tests.eq(pg_temp.local_slots('2025-06-15', '2025-06-13', '2025-06-15'), pg_temp.local_slots('2025-06-15', '2025-06-15', '2025-06-15'),
                'weekend stretch: Sunday''s grid is the same for a Fri-Sun and a Sunday-only search');
select tests.eq(pg_temp.local_slots('2025-06-15', '2025-06-14', '2025-06-20'), pg_temp.local_slots('2025-06-15', '2025-06-15', '2025-06-15'),
                'and for a Sat-Fri search');
select tests.eq((pg_temp.local_slots('2025-06-15', '2025-06-15', '2025-06-15'))[1:3], array['00:30', '01:15', '02:00'],
                'anchored at the stretch''s real opening (Fri 08:00 + 54 x 45 min = Sun 00:30), not at a midnight');
select tests.eq((pg_temp.local_slots('2025-06-13', '2025-06-13', '2025-06-13'))[1:2], array['08:00', '08:45'], 'Friday opens at 08:00');
select tests.eq((pg_temp.local_slots('2025-06-15', '2025-06-15', '2025-06-15'))[array_length(pg_temp.local_slots('2025-06-15', '2025-06-15', '2025-06-15'), 1)],
                '15:30', 'the last Sunday start still ends (2 h) by 18:00');
create temp table offered as
  select min(starts_at) as s from public.get_available_slots('shop-a', array[tests.fx('svc_a')], tests.fx('cat_car_a'),
                                                          '2025-06-13', '2025-06-15', '2025-06-01 12:00Z')
   where (starts_at at time zone 'America/Chicago')::date = '2025-06-15';
grant select on offered to service_role;
select tests.as_service();
select tests.lives(format($f$select public.create_online_booking('shop-a', pg_temp.booking(jsonb_build_object('starts_at', %L,
                             'customer', jsonb_build_object('first_name', 'Wes', 'email', 'wes@example.com'))), '2025-06-01 12:00Z')$f$,
                          (select s from offered)::text), 'a slot offered by a Fri-Sun search can be booked');

-- open around the clock, 50-minute grid: anchored at each local midnight
select tests.as_superuser();
delete from public.business_hours where shop_id = tests.fx('shop_a');
insert into public.business_hours (shop_id, weekday, opens_at, closes_at)
  select tests.fx('shop_a'), d, '00:00', '24:00' from generate_series(0, 6) d;
update public.booking_settings set slot_interval_minutes = 50 where shop_id = tests.fx('shop_a');
select tests.eq(pg_temp.local_slots('2025-06-15', '2025-06-10', '2025-06-20'), pg_temp.local_slots('2025-06-15', '2025-06-15', '2025-06-15'),
                '24/7: the same grid whatever the range');
select tests.eq((pg_temp.local_slots('2025-06-15', '2025-06-15', '2025-06-15'))[1:2], array['00:00', '00:50'], '24/7: grid starts at local midnight');
select tests.eq(cardinality(pg_temp.local_slots('2025-06-15', '2025-06-15', '2025-06-15')), 29, '24/7: 00:00 .. 23:20 (29 starts)');
select tests.eq((pg_temp.local_slots('2025-06-15', '2025-06-15', '2025-06-15'))[29], '23:20',
                '24/7: a late start may run past midnight (the shop never closes)');
select tests.eq(cardinality(pg_temp.local_slots('2026-03-08', '2026-03-08', '2026-03-08')), 28,
                '24/7 on the spring-forward day: the 02:xx start does not exist, never duplicated');
create temp table offered2 as
  select s.starts_at as s from public.get_available_slots('shop-a', array[tests.fx('svc_a')], tests.fx('cat_car_a'),
                                                         '2025-06-12', '2025-06-16', '2025-06-01 12:00Z') s
   where (s.starts_at at time zone 'America/Chicago') = '2025-06-15 13:20';
grant select on offered2 to service_role;
select tests.as_service();
select tests.lives(format($f$select public.create_online_booking('shop-a', pg_temp.booking(jsonb_build_object('starts_at', %L,
                             'customer', jsonb_build_object('first_name', 'Wes', 'email', 'wes2@example.com'))), '2025-06-01 12:00Z')$f$,
                          (select s from offered2)::text), 'a 24/7 slot offered by a multi-day search can be booked');

-- long bookings (more than a day) see every job they would overlap
select tests.as_superuser();
update public.booking_settings set slot_interval_minutes = 60, max_concurrent_jobs = 1 where shop_id = tests.fx('shop_a');
insert into public.services (shop_id, name, duration_minutes, online_bookable) values (tests.fx('shop_a'), 'Coating Cure', 1440, true)
  returning tests.fx_set('svc_day', id);
insert into public.services (shop_id, name, duration_minutes, online_bookable) values (tests.fx('shop_a'), 'Coating Prep', 600, true)
  returning tests.fx_set('svc_prep', id);
insert into public.service_prices (shop_id, service_id, price_cents) values
  (tests.fx('shop_a'), tests.fx('svc_day'), 100000), (tests.fx('shop_a'), tests.fx('svc_prep'), 50000);
-- a job two local days later at 03:00-04:00 CDT (2025-06-17 08:00Z)
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a3'), 'scheduled', '2025-06-17 08:00Z', '2025-06-17 09:00Z');
select tests.ok(not ('20:00' = any (pg_temp.local_slots('2025-06-15', '2025-06-15', '2025-06-15',
                                                        array[tests.fx('svc_day'), tests.fx('svc_prep')]))),
                'a 34-hour booking starting Sun 20:00 (until Tue 06:00) would overlap the Tue 03:00 job: not offered');
select tests.ok('17:00' = any (pg_temp.local_slots('2025-06-15', '2025-06-15', '2025-06-15', array[tests.fx('svc_day'), tests.fx('svc_prep')])),
                'one ending exactly at 03:00 Tuesday is offered');
select tests.eq(pg_temp.local_slots('2025-06-15', '2025-06-15', '2025-06-15', array[tests.fx('svc_day'), tests.fx('svc_prep')]),
                pg_temp.local_slots('2025-06-15', '2025-06-10', '2025-06-20', array[tests.fx('svc_day'), tests.fx('svc_prep')]),
                'long bookings: same answer for any range');
