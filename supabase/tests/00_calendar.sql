-- 00 foundation: calendar_events — full details for managers+, anonymous
-- busy blocks for technicians on jobs not assigned to them, blocked times,
-- range validation, membership checks.
\ir fixtures/two_shops.psql

select tests.as_superuser();
insert into public.blocked_times (shop_id, starts_at, ends_at, reason)
  values (tests.fx('shop_a'), '2025-06-02 13:00Z', '2025-06-02 14:00Z', 'Team training');
insert into public.blocked_times (shop_id, member_id, starts_at, ends_at, reason)
  values (tests.fx('shop_a'), tests.fx('m_tech2_a'), '2025-06-02 20:00Z', '2025-06-02 22:00Z', 'Doctor appointment');
insert into public.blocked_times (shop_id, member_id, starts_at, ends_at, reason)
  values (tests.fx('shop_a'), tests.fx('m_tech_a'), '2025-06-02 22:00Z', '2025-06-02 23:00Z', 'School pickup');
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a3'), 'cancelled', '2025-06-02 16:00Z', '2025-06-02 17:00Z')
  returning tests.fx_set('job_cancelled', id);
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a3'), '2025-07-02 16:00Z', '2025-07-02 17:00Z')
  returning tests.fx_set('job_later', id);

-- ------------------------------------------------------------ managers+
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq((select count(*) from public.calendar_events(tests.fx('shop_a'), '2025-06-02', '2025-06-03')), 5::bigint,
                'manager: 2 jobs + 3 blocked times (cancelled hidden, out-of-range hidden)');
select tests.eq((select count(*) from public.calendar_events(tests.fx('shop_a'), '2025-06-02', '2025-06-03', true)), 6::bigint,
                'include_cancelled shows cancelled jobs');
select tests.eq((select customer_name || ' / ' || vehicle_label || ' / ' || title
                   from public.calendar_events(tests.fx('shop_a'), '2025-06-02', '2025-06-03') where id = tests.fx('job_a')),
                'Alice Anders / 2021 Honda Civic / Alice Anders — Full Detail', 'manager gets full job details');
select tests.eq((select assigned_member_ids from public.calendar_events(tests.fx('shop_a'), '2025-06-02', '2025-06-03') where id = tests.fx('job_a')),
                array[tests.fx('m_tech_a')], 'assigned members listed');
select tests.eq((select job_number from public.calendar_events(tests.fx('shop_a'), '2025-06-02', '2025-06-03') where id = tests.fx('job_a')),
                1001::bigint, 'job number present');
select tests.eq((select string_agg(title, ',' order by starts_at) from public.calendar_events(tests.fx('shop_a'), '2025-06-02', '2025-06-03')
                  where event_type = 'blocked_time'), 'Team training,Doctor appointment,School pickup', 'managers see all block reasons');
select tests.ok((select bool_and(not is_busy_block) from public.calendar_events(tests.fx('shop_a'), '2025-06-02', '2025-06-03')
                  where event_type = 'job'), 'no busy blocks for managers');
select tests.eq((select array_agg(event_type order by starts_at, event_type) from public.calendar_events(tests.fx('shop_a'), '2025-06-02', '2025-06-03')),
                array['blocked_time', 'job', 'job', 'blocked_time', 'blocked_time'], 'events ordered by start');
select tests.eq((select count(*) from public.calendar_events(tests.fx('shop_a'), '2025-06-02 15:30Z', '2025-06-02 15:45Z')), 1::bigint,
                'overlap semantics: a window inside a job returns it');
select tests.eq((select count(*) from public.calendar_events(tests.fx('shop_a'), '2025-06-02 17:00Z', '2025-06-02 18:00Z')), 0::bigint,
                'half-open ranges: a job ending at p_from is excluded');

-- ------------------------------------------------------------ technicians
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq((select count(*) from public.calendar_events(tests.fx('shop_a'), '2025-06-02', '2025-06-03') where event_type = 'job'), 2::bigint,
                'technician sees every job in range (busy time)');
select tests.ok((select not is_busy_block and customer_name = 'Alice Anders' and job_number = 1001
                   from public.calendar_events(tests.fx('shop_a'), '2025-06-02', '2025-06-03') where id = tests.fx('job_a')),
                'assigned job has full details');
select tests.ok((select is_busy_block and customer_id is null and customer_name is null and vehicle_id is null and vehicle_label is null
                        and title is null and job_number is null and location_type is null and service_address is null
                   from public.calendar_events(tests.fx('shop_a'), '2025-06-02', '2025-06-03') where id = tests.fx('job_a2')),
                'unassigned job is an anonymous busy block');
select tests.eq((select assigned_member_ids from public.calendar_events(tests.fx('shop_a'), '2025-06-02', '2025-06-03') where id = tests.fx('job_a2')),
                array[tests.fx('m_tech2_a')], 'busy blocks still show who is busy');
select tests.eq((select string_agg(coalesce(title, '<hidden>'), ',' order by starts_at)
                   from public.calendar_events(tests.fx('shop_a'), '2025-06-02', '2025-06-03') where event_type = 'blocked_time'),
                'Team training,<hidden>,School pickup', 'technicians see shop-wide and own block reasons only');
-- the busy block leaks nothing the tech could not otherwise read
select tests.eq(tests.row_count($$select * from public.jobs where id = tests.fx('job_a2')$$), 0::bigint,
                'the busy block''s job row itself stays unreadable');

-- ------------------------------------------------------------ denial paths
select tests.throws($$select * from public.calendar_events(tests.fx('shop_b'), '2025-06-02', '2025-06-03')$$, '42501',
                    'technician of A cannot read B''s calendar');
select tests.authenticate_as(tests.fx('u_owner_b'));
select tests.throws($$select * from public.calendar_events(tests.fx('shop_a'), '2025-06-02', '2025-06-03')$$, '42501',
                    'owner of B cannot read A''s calendar');
select tests.eq((select array_agg(id) from public.calendar_events(tests.fx('shop_b'), '2025-06-02', '2025-06-03')),
                array[tests.fx('job_b')], 'owner of B sees only B''s events');
select tests.authenticate_as(tests.fx('u_outsider'));
select tests.throws($$select * from public.calendar_events(tests.fx('shop_a'), '2025-06-02', '2025-06-03')$$, '42501', 'outsider denied');
select tests.as_anon();
select tests.throws($$select * from public.calendar_events(tests.fx('shop_a'), '2025-06-02', '2025-06-03')$$, '42501', 'anon cannot execute');
select tests.as_superuser();
update public.shop_members set active = false where id = tests.fx('m_tech_a');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$select * from public.calendar_events(tests.fx('shop_a'), '2025-06-02', '2025-06-03')$$, '42501', 'inactive member denied');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$select * from public.calendar_events(tests.fx('shop_a'), '2025-06-03', '2025-06-02')$$, '22023', 'to must be after from');
select tests.throws($$select * from public.calendar_events(tests.fx('shop_a'), '2025-06-01', '2025-09-03')$$, '22023', 'range capped at 93 days');
select tests.lives($$select * from public.calendar_events(tests.fx('shop_a'), '2025-06-01', '2025-09-02')$$, '93-day range allowed');
