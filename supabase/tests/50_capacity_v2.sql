-- 50 sched: online capacity v2 (P-17, 0053/0054) — get_available_slots
-- unchanged, shop-wide events that take capacity, recurring closures,
-- capacity per location type, member availability (time off, bookable
-- flag, absences starting mid-slot), category weekdays, the bookable guard,
-- and create_online_booking honouring all of it. Shop A (America/Chicago)
-- is open 08:00-17:00 every day on a 60-minute grid (40_booking_setup).
-- Trusted session (p_now honoured): today = Sunday 2025-06-01.
\ir fixtures/two_shops.psql
\ir fixtures/40_booking_setup.psql

select tests.as_superuser();
-- slot starts on a local day as 'HH24' (local), for a location type
create function pg_temp.hours(p_day date, p_services uuid[], p_loc public.location_type default null)
returns text language sql as $$
  select coalesce(string_agg(to_char(s.starts_at at time zone 'America/Chicago', 'HH24'), ',' order by s.starts_at), '')
  from public.public_booking_slots('shop-a', p_services, p_day, p_day, null, p_loc, null, '2025-06-01 12:00Z') s
$$;
create function pg_temp.wash() returns uuid[] language sql as $$ select array[tests.fx('svc_wash')] $$;

-- ============================================================ defaults: identical to get_available_slots
select tests.eq(pg_temp.hours('2025-06-09', pg_temp.wash()), '08,09,10,11,12,13,14,15,16', 'Monday: nine 60-minute starts');
select tests.eq((select array_agg(s.starts_at order by s.starts_at) from public.public_booking_slots('shop-a', array[tests.fx('svc_a')],
                   '2025-06-01', '2025-06-30', tests.fx('cat_truck_a'), null, null, '2025-06-01 12:00Z') s),
                (select array_agg(s.starts_at order by s.starts_at) from public.get_available_slots('shop-a', array[tests.fx('svc_a')],
                   '2025-06-01', '2025-06-30', tests.fx('cat_truck_a'), '2025-06-01 12:00Z') s),
                'get_available_slots = public_booking_slots without location or link');
select tests.eq((select array_agg(s.ends_at order by s.starts_at) from public.public_booking_slots('shop-a', array[tests.fx('svc_a')],
                   '2025-06-09', '2025-06-09', tests.fx('cat_truck_a'), 'shop', null, '2025-06-01 12:00Z') s),
                (select array_agg(s.ends_at order by s.starts_at) from public.get_available_slots('shop-a', array[tests.fx('svc_a')],
                   '2025-06-09', '2025-06-09', tests.fx('cat_truck_a'), '2025-06-01 12:00Z') s),
                'per-location limits unset: a location type changes nothing');

-- ============================================================ shop-wide events
insert into public.blocked_times (shop_id, kind, title, starts_at, ends_at)
  values (tests.fx('shop_a'), 'meeting', 'Supplier visit', '2025-06-09 15:00Z', '2025-06-09 16:00Z')
  returning tests.fx_set('ev_meet', id);
select tests.eq(pg_temp.hours('2025-06-09', pg_temp.wash()), '08,09,10,11,12,13,14,15,16',
                'a meeting that does not take capacity changes nothing');
update public.blocked_times set affects_capacity = true where id = tests.fx('ev_meet');
select tests.eq(pg_temp.hours('2025-06-09', pg_temp.wash()), '08,09,11,12,13,14,15,16',
                'capacity 1: a meeting that takes capacity fills 10:00');
update public.booking_settings set max_concurrent_jobs = 2 where shop_id = tests.fx('shop_a');
select tests.eq(pg_temp.hours('2025-06-09', pg_temp.wash()), '08,09,10,11,12,13,14,15,16',
                'capacity 2: the meeting is one busy unit');
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a3'), '2025-06-09 15:30Z', '2025-06-09 16:30Z');
select tests.eq(pg_temp.hours('2025-06-09', pg_temp.wash()), '08,09,11,12,13,14,15,16',
                'meeting (10-11) + a job (10:30-11:30) = 2 units at 10:30: 10:00 is full');
update public.booking_settings set buffer_minutes = 60 where shop_id = tests.fx('shop_a');
select tests.eq(pg_temp.hours('2025-06-09', pg_temp.wash()), '08,09,11,12,13,14,15,16',
                'the buffer widens jobs, not events: 11:00 stays open (the meeting ended at 11:00)');
update public.booking_settings set max_concurrent_jobs = 1 where shop_id = tests.fx('shop_a');
select tests.eq(pg_temp.hours('2025-06-09', pg_temp.wash()), '08,13,14,15,16',
                'capacity 1: the job buffered to 09:30-12:30 and the meeting fill 09:00-12:00');
update public.booking_settings set buffer_minutes = 0, max_concurrent_jobs = 1 where shop_id = tests.fx('shop_a');
delete from public.jobs where shop_id = tests.fx('shop_a') and scheduled_start = '2025-06-09 15:30Z';
delete from public.blocked_times where id = tests.fx('ev_meet');

-- recurring closure: every Monday 12:00-13:00 local
insert into public.blocked_times (shop_id, kind, title, recurrence, starts_at, ends_at)
  values (tests.fx('shop_a'), 'closed', 'Lunch', '{"freq": "week"}', '2025-06-02 17:00Z', '2025-06-02 18:00Z')
  returning tests.fx_set('ev_lunch', id);
select tests.eq(pg_temp.hours('2025-06-09', pg_temp.wash()), '08,09,10,11,13,14,15,16', 'recurring closure on Monday');
select tests.eq(pg_temp.hours('2025-06-16', pg_temp.wash()), '08,09,10,11,13,14,15,16', '... and the next Monday');
select tests.eq(pg_temp.hours('2025-06-10', pg_temp.wash()), '08,09,10,11,12,13,14,15,16', 'Tuesday unaffected');
select tests.eq(pg_temp.hours('2025-06-09', array[tests.fx('svc_a')]), '08,09,10,13,14,15',
                'a 2-hour service cannot straddle the closure');
update public.blocked_times set affects_capacity = false where id = tests.fx('ev_lunch');
select tests.eq(pg_temp.hours('2025-06-09', pg_temp.wash()), '08,09,10,11,13,14,15,16', 'a closure always blocks');
delete from public.blocked_times where id = tests.fx('ev_lunch');

-- ============================================================ capacity per location type
update public.booking_settings set max_concurrent_jobs = 2, max_concurrent_mobile = 1 where shop_id = tests.fx('shop_a');
insert into public.jobs (shop_id, customer_id, location_type, service_address_line1, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a3'), 'mobile', '9 Oak St', '2025-06-09 15:00Z', '2025-06-09 16:00Z')
  returning tests.fx_set('job_mobile', id);
select tests.eq(pg_temp.hours('2025-06-09', pg_temp.wash(), 'mobile'), '08,09,11,12,13,14,15,16',
                'mobile: one mobile job at a time');
select tests.eq(pg_temp.hours('2025-06-09', pg_temp.wash(), 'shop'), '08,09,10,11,12,13,14,15,16',
                'in-shop bookings still fit (total capacity 2)');
select tests.eq(pg_temp.hours('2025-06-09', pg_temp.wash()), '08,09,10,11,12,13,14,15,16',
                'no location type (a shop offering both): the in-shop slots, no in-shop cap yet');
update public.booking_settings set max_concurrent_shop = 1 where shop_id = tests.fx('shop_a');
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a3'), '2025-06-09 18:00Z', '2025-06-09 19:00Z')
  returning tests.fx_set('job_shop', id);
select tests.eq(pg_temp.hours('2025-06-09', pg_temp.wash(), 'shop'), '08,09,10,11,12,14,15,16',
                'in-shop: one in-shop job at a time');
select tests.eq(pg_temp.hours('2025-06-09', pg_temp.wash(), 'mobile'), '08,09,11,12,13,14,15,16',
                'the in-shop job does not use mobile capacity');
update public.booking_settings set max_concurrent_jobs = 1 where shop_id = tests.fx('shop_a');
select tests.eq(pg_temp.hours('2025-06-09', pg_temp.wash(), 'mobile'), '08,09,11,12,14,15,16',
                'max_concurrent_jobs still caps everything');

-- create_online_booking uses the booking's location type
update public.booking_settings set max_concurrent_jobs = 2, max_concurrent_shop = null where shop_id = tests.fx('shop_a');
select tests.throws_like($$select public.create_online_booking('shop-a', pg_temp.booking(jsonb_build_object(
                             'service_ids', jsonb_build_array(tests.fx('svc_wash')), 'starts_at', '2025-06-09T15:00:00Z',
                             'location', jsonb_build_object('type', 'mobile', 'address_line1', '1 Pine St', 'city', 'Birmingham',
                                                            'postal_code', '35203'))), '2025-06-01 12:00Z')$$,
                         '23P01', '%no longer available%', 'a mobile booking in a full mobile slot is refused');
select tests.eq((public.create_online_booking('shop-a', pg_temp.booking(jsonb_build_object(
                   'service_ids', jsonb_build_array(tests.fx('svc_wash')), 'starts_at', '2025-06-09T15:00:00Z')),
                   '2025-06-01 12:00Z')) ->> 'status', 'requested', 'the same slot books in the shop');
update public.shops set business_type = 'fixed' where id = tests.fx('shop_a');
select tests.throws_like($$select * from public.public_booking_slots('shop-a', pg_temp.wash(), '2025-06-09', '2025-06-09', null,
                                                                      'mobile', null, '2025-06-01 12:00Z')$$,
                         '22023', '%mobile%', 'a fixed-location shop offers no mobile slots');
update public.shops set business_type = 'mobile' where id = tests.fx('shop_a');
select tests.throws_like($$select * from public.public_booking_slots('shop-a', pg_temp.wash(), '2025-06-09', '2025-06-09', null,
                                                                      'shop', null, '2025-06-01 12:00Z')$$,
                         '22023', '%only offers mobile%', 'a mobile-only shop offers no in-shop slots');
update public.shops set business_type = 'both' where id = tests.fx('shop_a');
delete from public.jobs where shop_id = tests.fx('shop_a') and (scheduled_start at time zone 'UTC')::date = '2025-06-09';
update public.booking_settings set max_concurrent_jobs = 1, max_concurrent_mobile = null where shop_id = tests.fx('shop_a');

-- ------------------------------------------------------------ no location type: the location a booking without one gets
-- ('mobile' for a mobile-only shop, else 'shop' - create_online_booking gives
-- a booking without a location the same one, so every slot listed without a
-- location type can be booked)
update public.shops set business_type = 'fixed' where id = tests.fx('shop_a');
update public.booking_settings set max_concurrent_jobs = 2, max_concurrent_shop = 1, max_concurrent_mobile = null
 where shop_id = tests.fx('shop_a');
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a3'), '2025-06-09 15:00Z', '2025-06-09 16:00Z');
select tests.eq(pg_temp.hours('2025-06-09', pg_temp.wash()), '08,09,11,12,13,14,15,16',
                'fixed shop, no location type: the in-shop cap applies');
select tests.eq(pg_temp.hours('2025-06-09', pg_temp.wash()), pg_temp.hours('2025-06-09', pg_temp.wash(), 'shop'),
                '... exactly as when asking for in-shop slots');
select tests.eq((select count(*) from public.get_available_slots('shop-a', pg_temp.wash(), '2025-06-09', '2025-06-09',
                                                                 null, '2025-06-01 12:00Z') s
                  where s.starts_at = '2025-06-09 15:00Z'), 0::bigint,
                'get_available_slots does not offer the full in-shop slot');
select tests.throws_like($$select public.create_online_booking('shop-a', pg_temp.booking(jsonb_build_object(
                             'service_ids', jsonb_build_array(tests.fx('svc_wash')), 'starts_at', '2025-06-09T15:00:00Z') - 'location'),
                             '2025-06-01 12:00Z')$$,
                         '23P01', '%no longer available%', '(which a booking without a location could not take)');
select tests.eq((public.create_online_booking('shop-a', pg_temp.booking(jsonb_build_object(
                   'service_ids', jsonb_build_array(tests.fx('svc_wash')), 'starts_at', '2025-06-09T16:00:00Z') - 'location'),
                   '2025-06-01 12:00Z')) ->> 'status', 'requested', 'an offered slot books without a location');
delete from public.jobs where shop_id = tests.fx('shop_a') and (scheduled_start at time zone 'UTC')::date = '2025-06-09';
update public.shops set business_type = 'mobile' where id = tests.fx('shop_a');
update public.booking_settings set max_concurrent_shop = null, max_concurrent_mobile = 1 where shop_id = tests.fx('shop_a');
insert into public.jobs (shop_id, customer_id, location_type, service_address_line1, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a3'), 'mobile', '9 Oak St', '2025-06-09 15:00Z', '2025-06-09 16:00Z');
select tests.eq(pg_temp.hours('2025-06-09', pg_temp.wash()), '08,09,11,12,13,14,15,16',
                'mobile-only shop, no location type: the mobile cap applies');
select tests.eq(pg_temp.hours('2025-06-09', pg_temp.wash()), pg_temp.hours('2025-06-09', pg_temp.wash(), 'mobile'),
                '... exactly as when asking for mobile slots');
select tests.throws_like($$select public.create_online_booking('shop-a', pg_temp.booking(jsonb_build_object(
                             'service_ids', jsonb_build_array(tests.fx('svc_wash')), 'starts_at', '2025-06-09T15:00:00Z',
                             'location', jsonb_build_object('type', 'mobile', 'address_line1', '1 Pine St', 'city', 'Birmingham',
                                                            'postal_code', '35203'))), '2025-06-01 12:00Z')$$,
                         '23P01', '%no longer available%', '(the booking is refused there too)');
update public.shops set business_type = 'both' where id = tests.fx('shop_a');
select tests.eq(pg_temp.hours('2025-06-09', pg_temp.wash()), '08,09,10,11,12,13,14,15,16',
                'a shop offering both, no location type: in-shop slots (the mobile cap does not apply)');
delete from public.jobs where shop_id = tests.fx('shop_a') and (scheduled_start at time zone 'UTC')::date = '2025-06-09';
-- a shop offering both, with an in-shop cap: get_available_slots (no location
-- type) must not list a slot that is full in the shop but not overall
update public.booking_settings set max_concurrent_jobs = 2, max_concurrent_shop = 1, max_concurrent_mobile = null
 where shop_id = tests.fx('shop_a');
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a3'), '2025-06-09 15:00Z', '2025-06-09 16:00Z');
select tests.eq(pg_temp.hours('2025-06-09', pg_temp.wash()), '08,09,11,12,13,14,15,16',
                'both, no location type: the in-shop cap applies');
select tests.eq(pg_temp.hours('2025-06-09', pg_temp.wash()), pg_temp.hours('2025-06-09', pg_temp.wash(), 'shop'),
                '... exactly as when asking for in-shop slots');
select tests.eq((select count(*) from public.get_available_slots('shop-a', pg_temp.wash(), '2025-06-09', '2025-06-09',
                                                                 null, '2025-06-01 12:00Z') s
                  where s.starts_at = '2025-06-09 15:00Z'), 0::bigint,
                'get_available_slots does not offer the slot that is full in the shop');
select tests.throws_like($$select public.create_online_booking('shop-a', pg_temp.booking(jsonb_build_object(
                             'service_ids', jsonb_build_array(tests.fx('svc_wash')), 'starts_at', '2025-06-09T15:00:00Z') - 'location'),
                             '2025-06-01 12:00Z')$$,
                         '23P01', '%no longer available%', '(a booking without a location is an in-shop booking and could not take it)');
select tests.ok((select bool_and(exists (
                   select 1 from public.get_available_slots('shop-a', pg_temp.wash(), '2025-06-09', '2025-06-09', null,
                                                            '2025-06-01 12:00Z') g where g.starts_at = s.starts_at))
                   from public.public_booking_slots('shop-a', pg_temp.wash(), '2025-06-09', '2025-06-09', null, 'shop', null,
                                                    '2025-06-01 12:00Z') s)
                and (select count(*) from public.get_available_slots('shop-a', pg_temp.wash(), '2025-06-09', '2025-06-09', null,
                                                                     '2025-06-01 12:00Z'))
                    = (select count(*) from public.public_booking_slots('shop-a', pg_temp.wash(), '2025-06-09', '2025-06-09', null,
                                                                        'shop', null, '2025-06-01 12:00Z')),
                'get_available_slots lists exactly the in-shop slots');
select tests.eq(pg_temp.hours('2025-06-09', pg_temp.wash(), 'mobile'), '08,09,10,11,12,13,14,15,16',
                'the booking page can still ask for mobile slots: 10:00 is open for a mobile visit');
select tests.eq((public.create_online_booking('shop-a', pg_temp.booking(jsonb_build_object(
                   'service_ids', jsonb_build_array(tests.fx('svc_wash')), 'starts_at', '2025-06-09T15:00:00Z',
                   'location', jsonb_build_object('type', 'mobile', 'address_line1', '1 Pine St', 'city', 'Birmingham',
                                                  'postal_code', '35203'))), '2025-06-01 12:00Z')) ->> 'status',
                'requested', 'and a mobile booking takes it');
select tests.eq((public.create_online_booking('shop-a', pg_temp.booking(jsonb_build_object(
                   'service_ids', jsonb_build_array(tests.fx('svc_wash')), 'starts_at', '2025-06-09T17:00:00Z') - 'location'),
                   '2025-06-01 12:00Z')) ->> 'status', 'requested', 'an offered slot books without a location');
delete from public.jobs where shop_id = tests.fx('shop_a') and (scheduled_start at time zone 'UTC')::date = '2025-06-09';
update public.booking_settings set max_concurrent_jobs = 1, max_concurrent_shop = null, max_concurrent_mobile = null
 where shop_id = tests.fx('shop_a');

-- ============================================================ member availability
update public.booking_settings set max_concurrent_jobs = 5, count_member_availability = true where shop_id = tests.fx('shop_a');
update public.shop_members set bookable = false
 where id in (tests.fx('m_owner_a'), tests.fx('m_admin_a'), tests.fx('m_manager_a'));
-- bookable: tech_a, tech2_a
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a3'), '2025-06-09 15:00Z', '2025-06-09 16:00Z');
select tests.eq(pg_temp.hours('2025-06-09', pg_temp.wash()), '08,09,10,11,12,13,14,15,16',
                'two bookable technicians, one job: still room');
insert into public.blocked_times (shop_id, member_id, kind, starts_at, ends_at)
  values (tests.fx('shop_a'), tests.fx('m_tech_a'), 'time_off', '2025-06-09 13:00Z', '2025-06-09 22:00Z')
  returning tests.fx_set('off_a', id);
select tests.eq(pg_temp.hours('2025-06-09', pg_temp.wash()), '08,09,11,12,13,14,15,16',
                'one technician off all day: the job at 10:00 uses the only one left');
insert into public.blocked_times (shop_id, member_id, kind, starts_at, ends_at)
  values (tests.fx('shop_a'), tests.fx('m_tech2_a'), 'meeting', '2025-06-09 18:30Z', '2025-06-09 19:30Z')
  returning tests.fx_set('meet_2', id);
select tests.eq(pg_temp.hours('2025-06-09', pg_temp.wash()), '08,09,11,12,13,14,15,16',
                'a member meeting that does not take capacity changes nothing');
update public.blocked_times set affects_capacity = true where id = tests.fx('meet_2');
select tests.eq(pg_temp.hours('2025-06-09', pg_temp.wash()), '08,09,11,12,15,16',
                'nobody left 13:30-14:30: slots overlapping the absence (13:00 starts before it) are gone');
update public.blocked_times set affects_capacity = false where id = tests.fx('meet_2');
update public.shop_members set active = false where id = tests.fx('m_tech2_a');
select tests.eq(pg_temp.hours('2025-06-09', pg_temp.wash()), '', 'inactive members do not count: nobody is available');
update public.shop_members set active = true where id = tests.fx('m_tech2_a');
update public.shop_members set bookable = true where id = tests.fx('m_manager_a');
select tests.eq(pg_temp.hours('2025-06-09', pg_temp.wash()), '08,09,10,11,12,13,14,15,16',
                'a bookable manager counts too');
update public.booking_settings set count_member_availability = false where shop_id = tests.fx('shop_a');
update public.shop_members set bookable = false where id in (tests.fx('m_tech_a'), tests.fx('m_tech2_a'), tests.fx('m_manager_a'));
select tests.eq(pg_temp.hours('2025-06-09', pg_temp.wash()), '08,09,10,11,12,13,14,15,16',
                'member availability off: the bookable flags are ignored');
update public.booking_settings set count_member_availability = true where shop_id = tests.fx('shop_a');
select tests.throws_like($$select public.create_online_booking('shop-a', pg_temp.booking(jsonb_build_object(
                             'service_ids', jsonb_build_array(tests.fx('svc_wash')), 'starts_at', '2025-06-09T14:00:00Z')),
                             '2025-06-01 12:00Z')$$,
                         '23P01', '%no longer available%', 'create_online_booking: nobody bookable, no booking');
update public.booking_settings set count_member_availability = false, max_concurrent_jobs = 1 where shop_id = tests.fx('shop_a');
update public.shop_members set bookable = true where shop_id = tests.fx('shop_a');
delete from public.jobs where shop_id = tests.fx('shop_a') and (scheduled_start at time zone 'UTC')::date = '2025-06-09';

-- ------------------------------------------------------------ bookable guard
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$update public.shop_members set bookable = false where id = tests.fx('m_tech_a')$$), 0::bigint,
                'managers cannot update other members at all (RLS)');
select tests.throws_like($$update public.shop_members set bookable = false where id = tests.fx('m_manager_a')$$, '42501',
                         '%only owners and admins%', 'a manager cannot change their own bookable flag');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$update public.shop_members set bookable = false where id = tests.fx('m_tech_a')$$, '42501',
                    'members cannot change their own bookable flag');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.eq(tests.row_count($$update public.shop_members set bookable = false where id = tests.fx('m_tech_a')$$), 1::bigint,
                'admins can');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.eq(tests.row_count($$update public.shop_members set bookable = false where id = tests.fx('m_owner_a')$$), 1::bigint,
                'the owner can change their own');
select tests.eq(tests.row_count($$update public.shop_members set bookable = true where id = tests.fx('m_tech_b')$$), 0::bigint,
                'another shop''s members are untouched (RLS)');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$update public.shop_members set calendar_color = '#112233' where id = tests.fx('m_tech_a')$$), 1::bigint,
                'members still edit their own other fields');
select tests.as_superuser();
update public.shop_members set bookable = true where shop_id = tests.fx('shop_a');

-- ============================================================ category weekdays
update public.service_categories set bookable_weekdays = '{2,3}' where id = tests.fx('svc_cat_a');   -- Tue, Wed
select tests.eq(pg_temp.hours('2025-06-09', array[tests.fx('svc_a')]), '', 'Monday: the category is not bookable');
select tests.eq(pg_temp.hours('2025-06-10', array[tests.fx('svc_a')]), '08,09,10,11,12,13,14,15', 'Tuesday: bookable');
insert into public.services (shop_id, name, duration_minutes, online_bookable) values (tests.fx('shop_a'), 'Plain', 60, true)
  returning tests.fx_set('svc_plain', id);
insert into public.service_prices (shop_id, service_id, price_cents) values (tests.fx('shop_a'), tests.fx('svc_plain'), 1000);
select tests.eq(pg_temp.hours('2025-06-09', array[tests.fx('svc_plain')]), '08,09,10,11,12,13,14,15,16',
                'a service without a category is bookable every day');
select tests.eq(pg_temp.hours('2025-06-09', array[tests.fx('svc_plain'), tests.fx('svc_a')]), '',
                'a mixed booking follows the restricted category');
insert into public.service_categories (shop_id, name, bookable_weekdays) values (tests.fx('shop_a'), 'Ceramic', '{3,4}')
  returning tests.fx_set('cat_ceramic', id);
update public.services set category_id = tests.fx('cat_ceramic') where id = tests.fx('svc_plain');
select tests.eq(pg_temp.hours('2025-06-10', array[tests.fx('svc_plain'), tests.fx('svc_a')]), '',
                'two restricted categories: only their common weekdays (Wed)');
select tests.eq(pg_temp.hours('2025-06-11', array[tests.fx('svc_plain'), tests.fx('svc_a')]), '08,09,10,11,12,13,14',
                'Wednesday is allowed by both');
select tests.eq((select e -> 'bookable_weekdays' from jsonb_array_elements(public.public_booking_catalog('shop-a') -> 'service_categories') e
                  where e ->> 'id' = tests.fx('svc_cat_a')::text), '[2, 3]'::jsonb, 'the catalog tells the booking page');
select tests.throws_like($$select public.create_online_booking('shop-a', pg_temp.booking(), '2025-06-01 12:00Z')$$,
                         '23P01', '%no longer available%', 'create_online_booking refuses a Monday for the category');
select tests.throws($$update public.service_categories set bookable_weekdays = '{7}' where id = tests.fx('svc_cat_a')$$, '23514',
                    'weekdays 0..6');
select tests.throws($$update public.service_categories set bookable_weekdays = '{1,1}' where id = tests.fx('svc_cat_a')$$, '23514',
                    'weekdays distinct');
select tests.throws($$update public.service_categories set bookable_weekdays = array[null]::smallint[] where id = tests.fx('svc_cat_a')$$,
                    '23514', 'no null weekdays');
update public.service_categories set bookable_weekdays = '{}' where id = tests.fx('svc_cat_a');
select tests.eq(pg_temp.hours('2025-06-10', array[tests.fx('svc_a')]), '', 'an empty set: never bookable online');
update public.service_categories set bookable_weekdays = null where id = tests.fx('svc_cat_a');
select tests.eq(pg_temp.hours('2025-06-09', array[tests.fx('svc_a')]), '08,09,10,11,12,13,14,15', 'null: every day again');

-- ============================================================ settings validation & privileges
select tests.throws($$update public.booking_settings set max_concurrent_mobile = 0 where shop_id = tests.fx('shop_a')$$, '23514',
                    'mobile capacity 1..100');
select tests.throws($$update public.booking_settings set max_concurrent_shop = 101 where shop_id = tests.fx('shop_a')$$, '23514',
                    'shop capacity 1..100');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$update public.booking_settings set count_member_availability = true where shop_id = tests.fx('shop_a')$$),
                0::bigint, 'managers cannot change booking settings (RLS)');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.eq(tests.row_count($$update public.booking_settings set max_concurrent_mobile = 2 where shop_id = tests.fx('shop_a')$$),
                1::bigint, 'admins can');
select tests.eq(tests.row_count($$update public.service_categories set bookable_weekdays = '{1}' where id = tests.fx('svc_cat_a')$$),
                1::bigint, 'catalog editors set category weekdays');
select tests.throws($$select * from public.booking_slots_core(tests.fx('shop_a'), 60, '2025-06-09', '2025-06-09', now())$$, '42501',
                    'the slot engine is internal');
select tests.as_anon();
select tests.throws($$select * from public.booking_slots_core(tests.fx('shop_a'), 60, '2025-06-09', '2025-06-09', now())$$, '42501',
                    'anon cannot call the slot engine');
select tests.lives($$select * from public.public_booking_slots('shop-a', array[tests.fx('svc_wash')], current_date + 2, current_date + 3, null, 'shop')$$,
                   'anon may list public slots');
select tests.as_service();
select tests.throws_like($$select * from public.booking_slots_core(tests.fx('shop_a'), 0, '2025-06-09', '2025-06-09', now())$$, '22023',
                         '%duration%', 'core: a duration is required');
select tests.throws_like($$select * from public.booking_slots_core(tests.fx('shop_a'), 60, '2025-06-09', '2025-08-10', now())$$, '22023',
                         '%62 days%', 'core: range capped');
select tests.throws($$select * from public.booking_slots_core(gen_random_uuid(), 60, '2025-06-09', '2025-06-09', now())$$, 'P0002',
                    'core: unknown shop');
select tests.eq((select count(*) from public.booking_slots_core(tests.fx('shop_a'), 60, '2025-06-09', '2025-06-09', '2025-06-01 12:00Z', 'shop')),
                9::bigint, 'core: service_role may call it with a fixed clock');
