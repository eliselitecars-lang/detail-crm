-- 50 sched: calendar event kinds (P-17, 0050/0052) — kind rules, capacity
-- flag defaults, recurrence validation and expansion (DST, month ends,
-- count / until), calendar_events v2 columns, technician redaction,
-- cross-shop customers, internal helper privileges.
\ir fixtures/two_shops.psql

select tests.as_superuser();
create function pg_temp.occ_starts(p_block uuid, p_from timestamptz, p_to timestamptz) returns text[]
language sql stable as $$
  select coalesce(array_agg(to_char(o.starts_at at time zone 'America/Chicago', 'YYYY-MM-DD HH24:MI') order by o.starts_at), '{}')
  from public.blocked_time_occurrences(tests.fx('shop_a'), p_from, p_to) o where o.block_id = p_block
$$;

-- ============================================================ kinds & validation (manager writes)
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.blocked_times (shop_id, starts_at, ends_at, reason)
  values (tests.fx('shop_a'), '2025-06-02 13:00Z', '2025-06-02 14:00Z', 'Team training')
  returning tests.fx_set('bt_closed', id);
select tests.ok((select kind = 'closed' and affects_capacity from public.blocked_times where id = tests.fx('bt_closed')),
                'a shop-wide block defaults to closed (takes capacity)');
insert into public.blocked_times (shop_id, member_id, starts_at, ends_at, reason)
  values (tests.fx('shop_a'), tests.fx('m_tech2_a'), '2025-06-02 20:00Z', '2025-06-02 22:00Z', 'Doctor appointment')
  returning tests.fx_set('bt_off', id);
select tests.ok((select kind = 'time_off' and affects_capacity from public.blocked_times where id = tests.fx('bt_off')),
                'a member''s block (callers that predate kinds) is stored as time off');
insert into public.blocked_times (shop_id, kind, title, color, starts_at, ends_at)
  values (tests.fx('shop_a'), 'meeting', '  Weekly huddle  ', '#1A2B3C', '2025-06-02 14:00Z', '2025-06-02 14:30Z')
  returning tests.fx_set('bt_meet', id);
select tests.ok((select title = 'Weekly huddle' and not affects_capacity from public.blocked_times where id = tests.fx('bt_meet')),
                'meetings default to not taking capacity; titles are trimmed');
insert into public.blocked_times (shop_id, kind, title, customer_id, starts_at, ends_at)
  values (tests.fx('shop_a'), 'consultation', 'Coating consult - Alice', tests.fx('cust_a'), '2025-06-02 19:00Z', '2025-06-02 19:30Z')
  returning tests.fx_set('bt_consult', id);
insert into public.blocked_times (shop_id, member_id, kind, title, starts_at, ends_at)
  values (tests.fx('shop_a'), tests.fx('m_tech_a'), 'reminder', 'Order supplies', '2025-06-02 22:00Z', '2025-06-02 22:15Z')
  returning tests.fx_set('bt_own', id);
select tests.throws_like($$insert into public.blocked_times (shop_id, kind, starts_at, ends_at)
                           values (tests.fx('shop_a'), 'time_off', '2025-06-03 13:00Z', '2025-06-03 14:00Z')$$,
                         '23514', '%team member%', 'time off needs a member');
select tests.throws_like($$insert into public.blocked_times (shop_id, kind, customer_id, starts_at, ends_at)
                           values (tests.fx('shop_a'), 'meeting', tests.fx('cust_a'), '2025-06-03 13:00Z', '2025-06-03 14:00Z')$$,
                         '23514', '%consultations and reminders%', 'only consultations/reminders name a customer');
select tests.throws($$insert into public.blocked_times (shop_id, kind, customer_id, starts_at, ends_at)
                      values (tests.fx('shop_a'), 'consultation', tests.fx('cust_b'), '2025-06-03 13:00Z', '2025-06-03 14:00Z')$$,
                    '23503', 'composite FK: another shop''s customer');
select tests.throws($$insert into public.blocked_times (shop_id, kind, color, starts_at, ends_at)
                      values (tests.fx('shop_a'), 'other', 'red', '2025-06-03 13:00Z', '2025-06-03 14:00Z')$$,
                    '23514', 'color must be #RRGGBB');
select tests.throws($$insert into public.blocked_times (shop_id, kind, title, starts_at, ends_at)
                      values (tests.fx('shop_a'), 'other', repeat('x', 121), '2025-06-03 13:00Z', '2025-06-03 14:00Z')$$,
                    '23514', 'title <= 120');
update public.blocked_times set affects_capacity = null where id = tests.fx('bt_meet');
select tests.eq((select affects_capacity from public.blocked_times where id = tests.fx('bt_meet')), false,
                'a null capacity flag is refilled from the kind');
update public.blocked_times set member_id = null where id = tests.fx('bt_own');
select tests.eq((select kind::text from public.blocked_times where id = tests.fx('bt_own')), 'reminder',
                'events may move between a member and the whole shop');
update public.blocked_times set member_id = tests.fx('m_tech_a') where id = tests.fx('bt_own');
select tests.throws($$update public.blocked_times set member_id = null where id = tests.fx('bt_off')$$, '23514',
                    'time off cannot become shop-wide');
select tests.throws($$update public.blocked_times set kind = 'meeting' where id = tests.fx('bt_consult')$$, '23514',
                    'a customer-linked consultation cannot become a meeting');

-- recurrence validation (CHECK -> 23514)
select tests.ok(public.calendar_recurrence_valid('{"freq": "week", "interval": 2, "by_weekday": [1, 3], "count": 10}'), 'valid weekly rule');
select tests.ok(public.calendar_recurrence_valid('{"freq": "day", "until_date": "2025-12-31"}'), 'valid daily rule');
select tests.ok(public.calendar_recurrence_valid(null), 'no rule');
select tests.ok(not public.calendar_recurrence_valid('{"freq": "year"}'), 'unknown freq');
select tests.ok(not public.calendar_recurrence_valid('{"freq": "day", "interval": 0}'), 'interval >= 1');
select tests.ok(not public.calendar_recurrence_valid('{"freq": "day", "interval": 13}'), 'interval <= 12');
select tests.ok(not public.calendar_recurrence_valid('{"freq": "day", "by_weekday": [1]}'), 'by_weekday only for weekly');
select tests.ok(not public.calendar_recurrence_valid('{"freq": "week", "by_weekday": [1, 1]}'), 'weekdays distinct');
select tests.ok(not public.calendar_recurrence_valid('{"freq": "week", "by_weekday": [7]}'), 'weekdays 0..6');
select tests.ok(not public.calendar_recurrence_valid('{"freq": "week", "by_weekday": []}'), 'weekdays not empty');
select tests.ok(not public.calendar_recurrence_valid('{"freq": "day", "count": 501}'), 'count <= 500');
select tests.ok(not public.calendar_recurrence_valid('{"freq": "day", "until_date": "2025-02-30"}'), 'real until date');
select tests.ok(not public.calendar_recurrence_valid('{"freq": "day", "until_date": "2025-12-31", "count": 3}'), 'until or count, not both');
select tests.ok(not public.calendar_recurrence_valid('{"freq": "day", "extra": 1}'), 'no unknown keys');
select tests.ok(not public.calendar_recurrence_valid('[]'), 'must be an object');
select tests.throws($$insert into public.blocked_times (shop_id, recurrence, starts_at, ends_at)
                      values (tests.fx('shop_a'), '{"freq": "hourly"}', '2025-06-03 13:00Z', '2025-06-03 14:00Z')$$,
                    '23514', 'an invalid recurrence is rejected by the table');

-- technicians cannot write events (RLS unchanged)
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$insert into public.blocked_times (shop_id, member_id, kind, starts_at, ends_at)
                      values (tests.fx('shop_a'), tests.fx('m_tech_a'), 'time_off', '2025-06-05 13:00Z', '2025-06-05 14:00Z')$$,
                    '42501', 'technicians cannot add calendar events');

-- ============================================================ recurrence expansion
select tests.authenticate_as(tests.fx('u_manager_a'));
-- weekly Monday 09:00-10:00 local across spring forward (2025-03-09)
insert into public.blocked_times (shop_id, kind, title, recurrence, starts_at, ends_at)
  values (tests.fx('shop_a'), 'meeting', 'Monday standup', '{"freq": "week", "count": 3}',
          '2025-03-03 15:00Z', '2025-03-03 16:00Z') returning tests.fx_set('bt_weekly', id);
select tests.as_superuser();
select tests.eq(pg_temp.occ_starts(tests.fx('bt_weekly'), '2025-03-01', '2025-04-01'),
                array['2025-03-03 09:00', '2025-03-10 09:00', '2025-03-17 09:00'],
                'weekly across spring forward keeps 09:00 local; count includes the original');
select tests.eq((select array_agg(ends_at - starts_at) from public.blocked_time_occurrences(tests.fx('shop_a'), '2025-03-01', '2025-04-01')
                  where block_id = tests.fx('bt_weekly')),
                array[interval '1 hour', interval '1 hour', interval '1 hour'], 'each occurrence keeps its wall-clock length');
select tests.eq(pg_temp.occ_starts(tests.fx('bt_weekly'), '2025-03-10 14:30Z', '2025-03-10 15:00Z'),
                array['2025-03-10 09:00'], 'only occurrences overlapping the window');
-- a block spanning the fall-back night keeps its local end (8 wall hours = 9 real)
insert into public.blocked_times (shop_id, kind, recurrence, starts_at, ends_at)
  values (tests.fx('shop_a'), 'closed', '{"freq": "day", "until_date": "2025-11-02"}',
          '2025-10-31 03:00Z', '2025-10-31 11:00Z') returning tests.fx_set('bt_night', id);
select tests.eq((select array_agg(to_char(starts_at at time zone 'America/Chicago', 'MM-DD HH24:MI') || '-' ||
                                  to_char(ends_at at time zone 'America/Chicago', 'HH24:MI') || '/' || (ends_at - starts_at)::text
                                  order by starts_at)
                   from public.blocked_time_occurrences(tests.fx('shop_a'), '2025-10-30', '2025-11-05') where block_id = tests.fx('bt_night')),
                array['10-30 22:00-06:00/08:00:00', '10-31 22:00-06:00/08:00:00', '11-01 22:00-06:00/09:00:00', '11-02 22:00-06:00/08:00:00'],
                'daily 22:00-06:00: the fall-back night lasts 9 real hours; until_date bounds the start date');
-- weekly Mon + Wed every 2nd week
insert into public.blocked_times (shop_id, kind, recurrence, starts_at, ends_at)
  values (tests.fx('shop_a'), 'other', '{"freq": "week", "interval": 2, "by_weekday": [1, 3], "until_date": "2025-06-30"}',
          '2025-06-02 14:00Z', '2025-06-02 15:00Z') returning tests.fx_set('bt_biweekly', id);
select tests.eq(pg_temp.occ_starts(tests.fx('bt_biweekly'), '2025-06-01', '2025-08-01'),
                array['2025-06-02 09:00', '2025-06-04 09:00', '2025-06-16 09:00', '2025-06-18 09:00', '2025-06-30 09:00'],
                'Mon + Wed every 2nd week');
-- monthly on the 31st: last day in shorter months
insert into public.blocked_times (shop_id, kind, recurrence, starts_at, ends_at)
  values (tests.fx('shop_a'), 'closed', '{"freq": "month", "count": 4}', '2025-01-31 16:00Z', '2025-01-31 18:00Z')
  returning tests.fx_set('bt_month', id);
select tests.eq(pg_temp.occ_starts(tests.fx('bt_month'), '2025-01-01', '2025-12-31'),
                array['2025-01-31 10:00', '2025-02-28 10:00', '2025-03-31 10:00', '2025-04-30 10:00'],
                'monthly on the 31st falls back to the last day; count 4');
-- every 3rd day, open-ended: a window far from the start still expands
insert into public.blocked_times (shop_id, kind, recurrence, starts_at, ends_at)
  values (tests.fx('shop_a'), 'other', '{"freq": "day", "interval": 3}', '2025-01-01 18:00Z', '2025-01-01 19:00Z')
  returning tests.fx_set('bt_every3', id);
select tests.eq(pg_temp.occ_starts(tests.fx('bt_every3'), '2025-12-24', '2025-12-31'),
                array['2025-12-24 12:00', '2025-12-27 12:00', '2025-12-30 12:00'], 'open-ended rule, far window');

-- ============================================================ calendar_events v2
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.jobs set service_lat = 33.5, service_lng = -86.8, service_address_line1 = '1 Elm St' where id = tests.fx('job_a2');
select tests.eq((select count(*) from public.calendar_events(tests.fx('shop_a'), '2025-06-02', '2025-06-03')), 8::bigint,
                'manager: 2 jobs + 5 single events + the biweekly event''s Monday occurrence');
select tests.eq((select event_kind from public.calendar_events(tests.fx('shop_a'), '2025-06-02', '2025-06-03') where id = tests.fx('job_a')),
                'job', 'jobs are event_kind job');
select tests.eq((select event_kind || '/' || color || '/' || title from public.calendar_events(tests.fx('shop_a'), '2025-06-02', '2025-06-03')
                  where id = tests.fx('bt_meet')), 'meeting/#1A2B3C/Weekly huddle', 'event kind, color and title');
select tests.eq((select title from public.calendar_events(tests.fx('shop_a'), '2025-06-02', '2025-06-03') where id = tests.fx('bt_closed')),
                'Team training', 'the reason is the title of an untitled block');
select tests.eq((select customer_id::text || '/' || customer_name from public.calendar_events(tests.fx('shop_a'), '2025-06-02', '2025-06-03')
                  where id = tests.fx('bt_consult')), tests.fx('cust_a')::text || '/Alice Anders', 'managers see the consult''s customer');
select tests.eq((select service_lat::text || ',' || service_lng::text from public.calendar_events(tests.fx('shop_a'), '2025-06-02', '2025-06-03')
                  where id = tests.fx('job_a2')), '33.5,-86.8', 'service coordinates for the full view');
select tests.eq((select count(*) from public.calendar_events(tests.fx('shop_a'), '2025-06-01', '2025-07-01') where id = tests.fx('bt_biweekly')),
                5::bigint, 'recurring events appear once per occurrence with the block id');
select tests.ok((select bool_and(is_busy_block and job_number is null and status is null)
                   from public.calendar_events(tests.fx('shop_a'), '2025-06-02', '2025-06-03') where event_type = 'blocked_time'),
                'blocked times stay busy blocks');

-- technicians
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq((select count(*) from public.calendar_events(tests.fx('shop_a'), '2025-06-02', '2025-06-03')), 8::bigint,
                'technician sees the same busy time');
select tests.ok((select customer_id is null and customer_name is null and title is null
                   from public.calendar_events(tests.fx('shop_a'), '2025-06-02', '2025-06-03') where id = tests.fx('bt_consult')),
                'technician: a customer-linked event shows no customer and no title');
select tests.eq((select title from public.calendar_events(tests.fx('shop_a'), '2025-06-02', '2025-06-03') where id = tests.fx('bt_own')),
                'Order supplies', 'technician: own event title');
select tests.eq((select title from public.calendar_events(tests.fx('shop_a'), '2025-06-02', '2025-06-03') where id = tests.fx('bt_off')),
                null::text, 'technician: another member''s time off stays private');
select tests.eq((select title from public.calendar_events(tests.fx('shop_a'), '2025-06-02', '2025-06-03') where id = tests.fx('bt_meet')),
                'Weekly huddle', 'technician: shop-wide event titles without a customer');
select tests.ok((select service_lat is null and service_lng is null and series_id is null
                   from public.calendar_events(tests.fx('shop_a'), '2025-06-02', '2025-06-03') where id = tests.fx('job_a2')),
                'technician: an unassigned job''s coordinates stay hidden');
select tests.throws($$select * from public.blocked_time_occurrences(tests.fx('shop_a'), '2025-06-01', '2025-07-01')$$, '42501',
                    'the expansion helper is internal');
select tests.authenticate_as(tests.fx('u_owner_b'));
select tests.eq((select count(*) from public.calendar_events(tests.fx('shop_b'), '2025-01-01', '2025-04-01')), 0::bigint,
                'shop B sees none of A''s events');
select tests.throws($$select * from public.calendar_events(tests.fx('shop_a'), '2025-06-02', '2025-06-03')$$, '42501',
                    'shop B cannot read A''s calendar');
select tests.as_anon();
select tests.throws($$select * from public.calendar_events(tests.fx('shop_a'), '2025-06-02', '2025-06-03')$$, '42501', 'anon denied');

-- deleting the customer keeps the consultation (customer cleared)
select tests.as_superuser();
insert into public.customers (shop_id, first_name) values (tests.fx('shop_a'), 'Walk-in') returning tests.fx_set('cust_tmp', id);
update public.blocked_times set customer_id = tests.fx('cust_tmp') where id = tests.fx('bt_consult');
delete from public.customers where id = tests.fx('cust_tmp');
select tests.ok((select customer_id is null and kind = 'consultation' from public.blocked_times where id = tests.fx('bt_consult')),
                'ON DELETE SET NULL (customer_id)');

-- ============================================================ technicians cannot read customer-linked rows from the table itself
select tests.as_superuser();
insert into public.blocked_times (shop_id, kind, starts_at, ends_at, title, reason, customer_id)
  values (tests.fx('shop_a'), 'consultation', '2030-01-10 15:00Z', '2030-01-10 16:00Z',
          'Consult: Jane Private 205-555-0199', 'Ceramic coating consult for Jane', tests.fx('cust_a3'))
  returning tests.fx_set('bt_leak_shop', id);
insert into public.blocked_times (shop_id, member_id, kind, starts_at, ends_at, title, reason, customer_id)
  values (tests.fx('shop_a'), tests.fx('m_tech_a'), 'reminder', '2030-01-10 17:00Z', '2030-01-10 17:30Z',
          'Call Jane back', 'Jane asked about PPF pricing', tests.fx('cust_a3'))
  returning tests.fx_set('bt_leak_own', id);
insert into public.blocked_times (shop_id, kind, starts_at, ends_at, title, reason)
  values (tests.fx('shop_a'), 'meeting', '2030-01-10 18:00Z', '2030-01-10 19:00Z', 'Team lunch', 'Pizza')
  returning tests.fx_set('bt_plain', id);
select tests.ok(exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'blocked_times'
                          and policyname = 'blocked_times_select_customer_redaction' and permissive = 'RESTRICTIVE'
                          and cmd = 'SELECT'),
                'a restrictive select policy guards customer-linked rows');

select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq((select count(*) from public.blocked_times
                  where shop_id = tests.fx('shop_a') and (customer_id is not null)), 0::bigint,
                'technicians read no customer-linked row (select *)');
select tests.eq((select count(*) from public.blocked_times where id in (tests.fx('bt_leak_shop'), tests.fx('bt_leak_own'))), 0::bigint,
                '... neither a shop-wide consultation nor their own reminder');
select tests.eq((select count(*) from public.blocked_times where shop_id = tests.fx('shop_a')
                   and (title like '%Jane%' or reason like '%Jane%')), 0::bigint,
                'the free-text title / reason written about the customer never reaches them');
select tests.eq((select title from public.blocked_times where id = tests.fx('bt_plain')), 'Team lunch',
                'shop-wide events without a customer stay readable');
select tests.eq((select count(*) from public.calendar_events(tests.fx('shop_a'), '2030-01-10', '2030-01-11')
                  where event_type = 'blocked_time' and id in (tests.fx('bt_leak_shop'), tests.fx('bt_leak_own'))), 2::bigint,
                'calendar_events still shows both as busy time');
select tests.eq((select count(*) from public.calendar_events(tests.fx('shop_a'), '2030-01-10', '2030-01-11')
                  where event_type = 'blocked_time' and id = tests.fx('bt_leak_shop') and (title is not null or customer_id is not null)),
                0::bigint, 'calendar_events hides the title / customer of a customer-linked shop-wide event');
select tests.eq((select title || '|' || coalesce(customer_id::text, '-') from public.calendar_events(tests.fx('shop_a'), '2030-01-10', '2030-01-11')
                  where id = tests.fx('bt_leak_own')), 'Call Jane back|-',
                'their own customer-linked event: title only, never the customer');
select tests.eq(tests.row_count($$update public.blocked_times set title = 'x' where id = tests.fx('bt_leak_own')$$), 0::bigint,
                'technicians still cannot write events');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq((select count(*) from public.blocked_times
                  where id in (tests.fx('bt_leak_shop'), tests.fx('bt_leak_own')) and customer_id = tests.fx('cust_a3')), 2::bigint,
                'managers read customer-linked rows with the customer');
select tests.eq(tests.row_count($$update public.blocked_times set reason = 'Moved' where id = tests.fx('bt_leak_shop')$$), 1::bigint,
                'managers still edit them');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.eq((select count(*) from public.blocked_times where id = tests.fx('bt_leak_shop')), 1::bigint, 'admins read them');
select tests.authenticate_as(tests.fx('u_owner_b'));
select tests.eq((select count(*) from public.blocked_times where shop_id = tests.fx('shop_a')), 0::bigint,
                'another shop''s owner reads none of A''s events');
select tests.authenticate_as(tests.fx('u_tech_b'));
select tests.eq((select count(*) from public.blocked_times where shop_id = tests.fx('shop_a')), 0::bigint,
                'another shop''s technician reads none either');

-- ============================================================ a repeat never ends before its own block
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws_like($$insert into public.blocked_times (shop_id, kind, title, recurrence, starts_at, ends_at)
                           values (tests.fx('shop_a'), 'closed', 'Inventory', '{"freq": "week", "until_date": "2025-06-01"}',
                                   '2025-06-09 15:00Z', '2025-06-09 17:00Z')$$,
                         '23514', '%until_date%', 'until_date before the block''s start is rejected');
-- the local start date counts: 2025-06-10 02:00Z is still 2025-06-09 in Chicago
select tests.lives($$insert into public.blocked_times (shop_id, kind, title, recurrence, starts_at, ends_at)
                     values (tests.fx('shop_a'), 'closed', 'Late count', '{"freq": "day", "until_date": "2025-06-09"}',
                             '2025-06-10 02:00Z', '2025-06-10 03:00Z')$$,
                   'until_date equal to the local start date is fine (UTC date is already the next day)');
insert into public.blocked_times (shop_id, kind, title, recurrence, starts_at, ends_at)
  values (tests.fx('shop_a'), 'closed', 'Inventory', '{"freq": "week", "until_date": "2025-06-23"}',
          '2025-06-09 15:00Z', '2025-06-09 17:00Z')
  returning tests.fx_set('bt_until', id);
select tests.throws_like($$update public.blocked_times set starts_at = '2025-06-30 15:00Z', ends_at = '2025-06-30 17:00Z'
                           where id = tests.fx('bt_until')$$,
                         '23514', '%until_date%', 'moving the block past its until_date is rejected');
select tests.throws_like($$update public.blocked_times set recurrence = '{"freq": "week", "until_date": "2025-06-08"}'
                           where id = tests.fx('bt_until')$$,
                         '23514', '%until_date%', 'an until_date moved before the start is rejected');
select tests.throws($$update public.blocked_times set recurrence = '{"freq": "week", "until_date": "2025-06-31"}'
                      where id = tests.fx('bt_until')$$,
                    '23514', 'a malformed until_date is still the recurrence CHECK''s error');
select tests.eq(tests.row_count($$update public.blocked_times set title = 'Stocktake' where id = tests.fx('bt_until')$$), 1::bigint,
                'unrelated edits are unaffected');
select tests.eq((select count(*) from public.calendar_events(tests.fx('shop_a'), '2025-06-08 00:00Z', '2025-06-30 00:00Z')
                  where id = tests.fx('bt_until')), 3::bigint, 'three weekly occurrences through until_date');
-- should the shop's time zone move the local start past until_date, the
-- original row is still occurrence 1
select tests.as_superuser();
update public.shops set timezone = 'Asia/Tokyo' where id = tests.fx('shop_a');
select tests.eq((select count(*) from public.blocked_time_occurrences(tests.fx('shop_a'), '2025-06-09 00:00Z', '2025-06-12 00:00Z')
                  where block_id = (select id from public.blocked_times where title = 'Late count')), 1::bigint,
                'the original block is always occurrence 1');
update public.shops set timezone = 'America/Chicago' where id = tests.fx('shop_a');

-- ============================================================ deleting the customer never un-redacts their event
-- blocked_times.names_customer is sticky: the ON DELETE SET NULL of the
-- customer link (e.g. an erasure request) must not hand technicians the
-- title and reason written about that customer.
select tests.as_superuser();
insert into public.customers (shop_id, first_name, last_name, phone)
  values (tests.fx('shop_a'), 'Carol', 'Privacy', '+12055550177') returning tests.fx_set('cust_priv', id);
insert into public.blocked_times (shop_id, kind, title, reason, customer_id, starts_at, ends_at)
  values (tests.fx('shop_a'), 'consultation', 'Consult Carol Privacy re: insurance claim', 'Call 205-555-0177',
          tests.fx('cust_priv'), '2030-02-03 15:00Z', '2030-02-03 15:30Z') returning tests.fx_set('bt_priv', id);
insert into public.blocked_times (shop_id, member_id, kind, title, reason, customer_id, starts_at, ends_at)
  values (tests.fx('shop_a'), tests.fx('m_tech2_a'), 'reminder', 'Call Carol back', 'Carol: 205-555-0177',
          tests.fx('cust_priv'), '2030-02-03 16:00Z', '2030-02-03 16:30Z') returning tests.fx_set('bt_priv_member', id);
select tests.ok((select bool_and(names_customer) from public.blocked_times where id in (tests.fx('bt_priv'), tests.fx('bt_priv_member'))),
                'naming a customer sets names_customer');
select tests.ok((select not names_customer from public.blocked_times where id = tests.fx('bt_plain')),
                'an event without a customer does not name one');
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.blocked_times (shop_id, kind, title, customer_id, names_customer, starts_at, ends_at)
  values (tests.fx('shop_a'), 'reminder', 'Carol follow-up', tests.fx('cust_priv'), false, '2030-02-04 15:00Z', '2030-02-04 15:30Z')
  returning tests.fx_set('bt_priv_forced', id);
select tests.ok((select names_customer from public.blocked_times where id = tests.fx('bt_priv_forced')),
                'a linked customer forces names_customer (an explicit false is ignored)');
select tests.eq(tests.row_count($$update public.blocked_times set names_customer = false where id = tests.fx('bt_priv_forced')$$),
                1::bigint, 'clearing the flag while the customer is linked ...');
select tests.ok((select names_customer from public.blocked_times where id = tests.fx('bt_priv_forced')), '... keeps it set');

select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq((select count(*) from public.blocked_times where id = tests.fx('bt_priv')), 0::bigint, 'tech cannot read it');
select tests.eq((select title from public.calendar_events(tests.fx('shop_a'), '2030-02-03', '2030-02-04') where id = tests.fx('bt_priv')),
                null, 'hidden from the tech');

-- the owner deletes the customer (erasure request); the events stay, unlinked
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.eq(tests.row_count($$delete from public.customers where id = tests.fx('cust_priv')$$), 1::bigint, 'the customer is deleted');
select tests.as_superuser();
select tests.ok((select bool_and(customer_id is null and names_customer) from public.blocked_times
                  where id in (tests.fx('bt_priv'), tests.fx('bt_priv_member'), tests.fx('bt_priv_forced'))),
                'the link is cleared (ON DELETE SET NULL) and names_customer stays set');

select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq((select title from public.calendar_events(tests.fx('shop_a'), '2030-02-03', '2030-02-04') where id = tests.fx('bt_priv')),
                null, 'after the customer is deleted the event title (their name) stays hidden from technicians');
select tests.eq((select count(*) from public.blocked_times
                  where id in (tests.fx('bt_priv'), tests.fx('bt_priv_member'), tests.fx('bt_priv_forced'))), 0::bigint,
                '... and the rows (the reason: their phone number) do not become readable');
select tests.eq((select count(*) from public.blocked_times where shop_id = tests.fx('shop_a')
                   and (title like '%Carol%' or reason like '%0177%')), 0::bigint, 'no text about the customer reaches them');
select tests.eq((select count(*) from public.calendar_events(tests.fx('shop_a'), '2030-02-03', '2030-02-05')
                  where id in (tests.fx('bt_priv'), tests.fx('bt_priv_member'), tests.fx('bt_priv_forced'))), 3::bigint,
                'the events still show as busy time');
select tests.authenticate_as(tests.fx('u_tech2_a'));
select tests.eq((select title from public.calendar_events(tests.fx('shop_a'), '2030-02-03', '2030-02-04') where id = tests.fx('bt_priv_member')),
                'Call Carol back', 'the member''s own event keeps its title for them');
select tests.eq((select count(*) from public.blocked_times where id = tests.fx('bt_priv_member')), 0::bigint,
                'but not the row (its reason)');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq((select title || ' / ' || reason from public.blocked_times where id = tests.fx('bt_priv')),
                'Consult Carol Privacy re: insurance claim / Call 205-555-0177', 'managers still read it');
select tests.eq((select title from public.calendar_events(tests.fx('shop_a'), '2030-02-03', '2030-02-04') where id = tests.fx('bt_priv')),
                'Consult Carol Privacy re: insurance claim', 'managers still see the title');
-- a manager may deliberately make the unlinked event shop-visible
select tests.eq(tests.row_count($$update public.blocked_times set names_customer = false, title = 'Consultation', reason = null
                                   where id = tests.fx('bt_priv')$$), 1::bigint, 'a manager clears it');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq((select title from public.blocked_times where id = tests.fx('bt_priv')), 'Consultation',
                'then technicians read it again');
select tests.eq(tests.row_count($$update public.blocked_times set names_customer = false where id = tests.fx('bt_priv_member')$$),
                0::bigint, 'technicians cannot clear the flag');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq((select count(*) from public.blocked_times where id in (tests.fx('bt_priv_member'), tests.fx('bt_priv_forced'))),
                0::bigint, 'another shop''s manager reads none of them');
