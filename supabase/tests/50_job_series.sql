-- 50 sched: recurring job series (P-1, 0051) — rule expansion (weekly with
-- interval, month day clamping, nth / last weekday, 5th-weekday skip), DST,
-- generation horizon, limits, idempotent cron generation, "this and
-- following" edits that keep confirmed / detached / invoiced / paid /
-- completed occurrences, end / delete, access per role, cross-shop ids,
-- client guards on jobs.series_*.
\ir fixtures/two_shops.psql

select tests.as_superuser();
-- local helpers
create function pg_temp.series_json(p jsonb default '{}') returns jsonb language sql stable as $$
  select jsonb_build_object('customer_id', tests.fx('cust_a'), 'vehicle_id', tests.fx('veh_a'), 'freq', 'week',
                            'local_start', '09:00',
                            'template_lines', jsonb_build_array(jsonb_build_object('service_id', tests.fx('svc_a')))) || p
$$;
create function pg_temp.local_today() returns date language sql stable as $$
  select (now() at time zone 'America/Chicago')::date
$$;
create function pg_temp.occ(p_series uuid, p_seq integer) returns uuid language sql stable as $$
  select id from public.jobs where series_id = p_series and series_seq = p_seq
$$;
grant execute on function pg_temp.series_json(jsonb), pg_temp.local_today(), pg_temp.occ(uuid, integer)
  to authenticated, service_role;

-- ============================================================ rule expansion (preview)
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq((select array_agg(to_char(starts_at at time zone 'UTC', 'MM-DD HH24:MI') order by seq)
                   from public.job_series_preview(tests.fx('shop_a'),
                          pg_temp.series_json(jsonb_build_object('interval', 2, 'by_weekday', jsonb_build_array(4, 1),
                                                                 'start_date', '2025-06-02', 'duration_minutes', 60)), 6)),
                array['06-02 14:00', '06-05 14:00', '06-16 14:00', '06-19 14:00', '06-30 14:00', '07-03 14:00'],
                'weekly Mon+Thu every 2nd week, 09:00 CDT');
select tests.eq((select array_agg(seq order by seq) from public.job_series_preview(tests.fx('shop_a'),
                   pg_temp.series_json(jsonb_build_object('start_date', '2025-06-02')), 3)),
                array[1, 2, 3], 'preview numbers occurrences from 1');
select tests.eq((select array_agg(to_char(starts_at at time zone 'America/Chicago', 'YYYY-MM-DD') order by seq)
                   from public.job_series_preview(tests.fx('shop_a'),
                          pg_temp.series_json(jsonb_build_object('freq', 'month', 'month_day', 31,
                                                                 'start_date', '2025-01-31')), 5)),
                array['2025-01-31', '2025-02-28', '2025-03-31', '2025-04-30', '2025-05-31'],
                'day 31 falls back to the last day of shorter months (Feb, Apr)');
select tests.eq((select array_agg(to_char(starts_at at time zone 'America/Chicago', 'YYYY-MM-DD') order by seq)
                   from public.job_series_preview(tests.fx('shop_a'),
                          pg_temp.series_json(jsonb_build_object('freq', 'month', 'start_date', '2024-02-29')), 3)),
                array['2024-02-29', '2024-03-29', '2024-04-29'], 'monthly defaults to the start date''s day');
select tests.eq((select array_agg(to_char(starts_at at time zone 'America/Chicago', 'YYYY-MM-DD') order by seq)
                   from public.job_series_preview(tests.fx('shop_a'),
                          pg_temp.series_json(jsonb_build_object('freq', 'month', 'month_nth', 5, 'month_weekday', 5,
                                                                 'start_date', '2025-01-01')), 4)),
                array['2025-01-31', '2025-05-30', '2025-08-29', '2025-10-31'],
                '5th Friday: months without one are skipped');
select tests.eq((select array_agg(to_char(starts_at at time zone 'America/Chicago', 'YYYY-MM-DD') order by seq)
                   from public.job_series_preview(tests.fx('shop_a'),
                          pg_temp.series_json(jsonb_build_object('freq', 'month', 'month_nth', -1, 'month_weekday', 1,
                                                                 'start_date', '2025-01-01')), 3)),
                array['2025-01-27', '2025-02-24', '2025-03-31'], 'last Monday of the month');
select tests.eq((select array_agg(to_char(starts_at at time zone 'America/Chicago', 'YYYY-MM-DD') order by seq)
                   from public.job_series_preview(tests.fx('shop_a'),
                          pg_temp.series_json(jsonb_build_object('freq', 'month', 'interval', 3, 'month_nth', 2,
                                                                 'month_weekday', 2, 'start_date', '2025-01-01')), 3)),
                array['2025-01-14', '2025-04-08', '2025-07-08'], 'every 3rd month on the 2nd Tuesday');
select tests.eq((select ends_at - starts_at from public.job_series_preview(tests.fx('shop_a'),
                   pg_temp.series_json(jsonb_build_object('start_date', '2025-06-02')), 1)),
                interval '120 minutes', 'duration defaults to the services'' duration');
select tests.eq((select count(*) from public.job_series_preview(tests.fx('shop_a'),
                   pg_temp.series_json(jsonb_build_object('start_date', '2025-06-02', 'until_date', '2025-06-20')), 100)),
                3::bigint, 'until_date bounds the preview');
select tests.eq((select count(*) from public.job_series_preview(tests.fx('shop_a'),
                   pg_temp.series_json(jsonb_build_object('start_date', '2025-06-02', 'max_occurrences', 4)), 100)),
                4::bigint, 'max_occurrences bounds the preview');
select tests.eq((select to_char(min(starts_at) at time zone 'America/Chicago', 'YYYY-MM-DD')
                   from public.job_series_preview(tests.fx('shop_a'),
                          pg_temp.series_json(jsonb_build_object('start_date', '2025-06-03', 'by_weekday', jsonb_build_array(1))), 1)),
                '2025-06-09', 'a start date off the rule starts at the next matching day');

-- ------------------------------------------------------------ validation
select tests.throws_like($$select * from public.job_series_preview(tests.fx('shop_a'), pg_temp.series_json('{"freq": "day", "start_date": "2025-06-02"}'))$$,
                         '22023', '%freq%', 'freq must be week or month');
select tests.throws_like($$select * from public.job_series_preview(tests.fx('shop_a'), pg_temp.series_json('{"start_date": "2025-06-02", "color": "red"}'))$$,
                         '22023', '%unknown%color%', 'unknown keys are rejected');
select tests.throws_like($$select * from public.job_series_preview(tests.fx('shop_a'), pg_temp.series_json('{"start_date": "2025-02-30"}'))$$,
                         '22023', '%start_date%', 'invalid date');
select tests.throws_like($$select * from public.job_series_preview(tests.fx('shop_a'), pg_temp.series_json('{"start_date": "2025-06-02", "local_start": "25:00"}'))$$,
                         '22023', '%local_start%', 'invalid time');
select tests.throws_like($$select * from public.job_series_preview(tests.fx('shop_a'), pg_temp.series_json('{"start_date": "2025-06-02", "interval": 13}'))$$,
                         '22023', '%interval%', 'interval 1..12');
select tests.throws_like($$select * from public.job_series_preview(tests.fx('shop_a'), pg_temp.series_json('{"start_date": "2025-06-02", "by_weekday": [7]}'))$$,
                         '22023', '%weekday%', 'weekdays 0..6');
select tests.throws_like($$select * from public.job_series_preview(tests.fx('shop_a'), pg_temp.series_json('{"freq": "month", "month_mode": "nth_weekday", "month_nth": 2, "start_date": "2025-06-02"}'))$$,
                         '22023', '%month_weekday%', 'nth weekday needs the weekday');
select tests.throws_like($$select * from public.job_series_preview(tests.fx('shop_a'), pg_temp.series_json('{"start_date": "2025-06-02", "month_nth": 0}'))$$,
                         '22023', '%month_nth%', 'month_nth 0 is not a position');
select tests.throws_like($$select * from public.job_series_preview(tests.fx('shop_a'), pg_temp.series_json('{"start_date": "2025-06-02", "until_date": "2025-06-01"}'))$$,
                         '22023', '%until_date%', 'until before start');
select tests.throws_like($$select * from public.job_series_preview(tests.fx('shop_a'), pg_temp.series_json('{"start_date": "2025-06-02", "duration_minutes": 10}'))$$,
                         '22023', '%duration_minutes%', 'at least 15 minutes');
select tests.throws_like($$select * from public.job_series_preview(tests.fx('shop_a'), pg_temp.series_json('{"start_date": "2025-06-02"}'), 101)$$,
                         '22023', '%p_count%', 'preview count capped at 100');
select tests.throws_like($$select * from public.job_series_preview(tests.fx('shop_a'), '{"freq": "week", "local_start": "09:00"}')$$,
                         '22023', '%start_date%', 'start_date required');
select tests.throws_like($$select public.create_job_series(tests.fx('shop_a'), pg_temp.series_json('{"start_date": "2025-06-02"}') - 'template_lines')$$,
                         '22023', '%template_lines%', 'template_lines required on create');
select tests.throws_like($$select public.create_job_series(tests.fx('shop_a'), pg_temp.series_json('{"start_date": "2025-06-02", "template_lines": []}'))$$,
                         '22023', '%template_lines%', 'at least one template line');
select tests.throws_like($$select public.create_job_series(tests.fx('shop_a'), pg_temp.series_json(jsonb_build_object('start_date', '2025-06-02', 'template_lines', jsonb_build_array(jsonb_build_object('service_id', tests.fx('svc_a'), 'quantity', 0)))))$$,
                         '22023', '%quantity%', 'quantity must be positive');
select tests.throws_like($$select public.create_job_series(tests.fx('shop_a'), pg_temp.series_json('{"start_date": "2025-06-02"}') - 'customer_id')$$,
                         '22023', '%customer_id%', 'customer required on create');
select tests.throws_like($$select public.create_job_series(tests.fx('shop_a'), pg_temp.series_json(jsonb_build_object('start_date', '2025-06-02', 'vehicle_id', tests.fx('veh_a2'))))$$,
                         '22023', '%vehicle%', 'the vehicle must be the customer''s');

-- ------------------------------------------------------------ cross-shop ids
select tests.throws($$select public.create_job_series(tests.fx('shop_a'), pg_temp.series_json(jsonb_build_object('start_date', '2025-06-02', 'customer_id', tests.fx('cust_b'), 'vehicle_id', null)))$$,
                    'P0002', 'another shop''s customer is not found');
select tests.throws($$select public.create_job_series(tests.fx('shop_a'), pg_temp.series_json(jsonb_build_object('start_date', '2025-06-02', 'vehicle_id', tests.fx('veh_b'))))$$,
                    '22023', 'another shop''s vehicle is rejected');
select tests.throws_like($$select public.create_job_series(tests.fx('shop_a'), pg_temp.series_json(jsonb_build_object('start_date', '2025-06-02', 'resource_id', tests.fx('res_b'))))$$,
                         '22023', '%resource%', 'another shop''s resource is rejected');
select tests.throws_like($$select public.create_job_series(tests.fx('shop_a'), pg_temp.series_json(jsonb_build_object('start_date', '2025-06-02', 'template_lines', jsonb_build_array(jsonb_build_object('service_id', tests.fx('svc_b'))))))$$,
                         '22023', '%not available%', 'another shop''s service is rejected');
select tests.throws_like($$select public.create_job_series(tests.fx('shop_a'), pg_temp.series_json(jsonb_build_object('start_date', '2025-06-02', 'assignee_member_ids', jsonb_build_array(tests.fx('m_tech_b')))))$$,
                         '22023', '%team members%', 'another shop''s member cannot be assigned');
select tests.as_superuser();
select tests.throws($$insert into public.job_series (shop_id, customer_id, freq, by_weekday, start_date, local_start, duration_minutes, template_lines)
                      values (tests.fx('shop_a'), tests.fx('cust_b'), 'week', '{1}', '2025-06-02', '09:00', 60,
                              jsonb_build_array(jsonb_build_object('service_id', tests.fx('svc_a'), 'quantity', 1)))$$,
                    '23503', 'composite FK: a series cannot reference another shop''s customer');

-- ============================================================ DST (America/Chicago, past dates)
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('ser_dst', (public.create_job_series(tests.fx('shop_a'), pg_temp.series_json(jsonb_build_object(
          'by_weekday', jsonb_build_array(1), 'start_date', '2025-03-03', 'until_date', '2025-03-10'))) ->> 'series_id')::uuid);
select tests.eq((select array_agg(to_char(scheduled_start at time zone 'UTC', 'MM-DD HH24:MI') order by series_seq)
                   from public.jobs where series_id = tests.fx('ser_dst')),
                array['03-03 15:00', '03-10 14:00'], 'spring forward: 09:00 local stays 09:00 (CST -> CDT)');
select tests.eq((select array_agg(to_char(scheduled_start at time zone 'America/Chicago', 'HH24:MI') order by series_seq)
                   from public.jobs where series_id = tests.fx('ser_dst')),
                array['09:00', '09:00'], 'local wall time kept');
select tests.fx_set('ser_dst2', (public.create_job_series(tests.fx('shop_a'), pg_temp.series_json(jsonb_build_object(
          'by_weekday', jsonb_build_array(1), 'start_date', '2025-10-27', 'until_date', '2025-11-03'))) ->> 'series_id')::uuid);
select tests.eq((select array_agg(to_char(scheduled_start at time zone 'UTC', 'MM-DD HH24:MI') order by series_seq)
                   from public.jobs where series_id = tests.fx('ser_dst2')),
                array['10-27 14:00', '11-03 15:00'], 'fall back: 09:00 local stays 09:00 (CDT -> CST)');
-- 02:30 on the spring-forward Sunday does not exist: Postgres reads it with
-- the pre-transition offset (= 03:30 CDT, one hour later)
select tests.fx_set('ser_gap', (public.create_job_series(tests.fx('shop_a'), pg_temp.series_json(jsonb_build_object(
          'by_weekday', jsonb_build_array(0), 'local_start', '02:30', 'start_date', '2025-03-02',
          'until_date', '2025-03-16'))) ->> 'series_id')::uuid);
select tests.eq((select array_agg(to_char(scheduled_start at time zone 'America/Chicago', 'MM-DD HH24:MI') order by series_seq)
                   from public.jobs where series_id = tests.fx('ser_gap')),
                array['03-02 02:30', '03-09 03:30', '03-16 02:30'], 'a nonexistent local start resolves one hour later');
select tests.eq((select count(*) from public.job_series_preview(tests.fx('shop_a'), pg_temp.series_json(jsonb_build_object(
                   'by_weekday', jsonb_build_array(0), 'local_start', '02:30', 'start_date', '2025-03-02',
                   'until_date', '2025-03-16'))) p
                  join public.jobs j on j.series_id = tests.fx('ser_gap') and j.series_seq = p.seq
                                    and j.scheduled_start = p.starts_at and j.scheduled_end = p.ends_at),
                3::bigint, 'preview matches generation exactly');

-- ============================================================ occurrences are ordinary jobs
select tests.fx_set('ser_a', (public.create_job_series(tests.fx('shop_a'), pg_temp.series_json(jsonb_build_object(
          'start_date', '2025-06-02', 'max_occurrences', 3, 'resource_id', tests.fx('res_a'),
          'notes', 'Side gate', 'internal_notes', 'Bring ladder',
          'assignee_member_ids', jsonb_build_array(tests.fx('m_tech_a')),
          'template_lines', jsonb_build_array(jsonb_build_object('service_id', tests.fx('svc_a'), 'quantity', 2))))) ->> 'series_id')::uuid);
select tests.eq((select count(*) from public.jobs where series_id = tests.fx('ser_a')), 3::bigint, 'max_occurrences: 3 jobs');
select tests.ok((select bool_and(status = 'scheduled' and source = 'staff' and resource_id = tests.fx('res_a')
                                 and notes = 'Side gate' and internal_notes = 'Bring ladder' and vehicle_id = tests.fx('veh_a')
                                 and customer_id = tests.fx('cust_a') and not series_detached)
                   from public.jobs where series_id = tests.fx('ser_a')), 'occurrences carry the series defaults');
select tests.eq((select array_agg(subtotal_cents order by series_seq) from public.jobs where series_id = tests.fx('ser_a')),
                array[40000::bigint, 40000, 40000], 'lines priced from the catalog x quantity');
select tests.eq((select sum(quantity) from public.job_line_items li join public.jobs j on j.id = li.job_id
                  where j.series_id = tests.fx('ser_a')), 6.00::numeric, 'template quantity copied');
select tests.eq((select ends_at - starts_at from public.calendar_events(tests.fx('shop_a'), '2025-06-02', '2025-06-03')
                  where id = pg_temp.occ(tests.fx('ser_a'), 1)), interval '240 minutes', 'duration = 2 x 120 min');
select tests.eq((select count(*) from public.job_assignments ja join public.jobs j on j.id = ja.job_id
                  where j.series_id = tests.fx('ser_a') and ja.member_id = tests.fx('m_tech_a')), 3::bigint,
                'assignees on every occurrence');
select tests.eq((select series_id from public.calendar_events(tests.fx('shop_a'), '2025-06-02', '2025-06-03')
                  where id = pg_temp.occ(tests.fx('ser_a'), 1)), tests.fx('ser_a'), 'calendar shows the series');
select tests.eq((select count(*) from public.job_series where id = tests.fx('ser_a')), 1::bigint, 'manager reads the series');
select tests.as_superuser();
select tests.throws($$insert into public.jobs (shop_id, customer_id, series_id, series_seq, scheduled_start, scheduled_end)
                      values (tests.fx('shop_b'), tests.fx('cust_b'), tests.fx('ser_a'), 99, now(), now() + interval '1 hour')$$,
                    '23503', 'composite FK: a job cannot join another shop''s series');
select tests.throws($$update public.jobs set series_seq = 2 where id = pg_temp.occ(tests.fx('ser_a'), 3)$$,
                    '23505', 'occurrence numbers are unique per series');
select tests.throws($$update public.jobs set series_seq = null where id = pg_temp.occ(tests.fx('ser_a'), 3)$$,
                    '23514', 'series_id and series_seq go together');
select tests.authenticate_as(tests.fx('u_manager_a'));

-- technicians: occurrences as jobs, never the series
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq((select count(*) from public.jobs where series_id = tests.fx('ser_a')), 3::bigint,
                'assigned technician reads the occurrences');
select tests.eq(tests.row_count('select * from public.job_series'), 0::bigint, 'technicians read no series rows');
select tests.throws($$select public.create_job_series(tests.fx('shop_a'), pg_temp.series_json('{"start_date": "2025-06-02"}'))$$,
                    '42501', 'technician cannot create');
select tests.throws($$select * from public.job_series_preview(tests.fx('shop_a'), pg_temp.series_json('{"start_date": "2025-06-02"}'))$$,
                    '42501', 'technician cannot preview');
select tests.throws($$select public.update_job_series(tests.fx('ser_a'), '{"notes": "x"}')$$, '42501', 'technician cannot update');
select tests.throws($$select public.end_job_series(tests.fx('ser_a'), '2025-06-03')$$, '42501', 'technician cannot end');
select tests.throws($$select public.delete_job_series(tests.fx('ser_a'))$$, '42501', 'technician cannot delete');
select tests.throws($$select public.generate_series_jobs()$$, '42501', 'technician cannot run the generator');
select tests.throws($$update public.jobs set series_detached = true where id = pg_temp.occ(tests.fx('ser_a'), 1)$$, '42501',
                    'technicians cannot change series columns');

-- other shops, outsiders, anon
select tests.authenticate_as(tests.fx('u_owner_b'));
select tests.eq(tests.row_count('select * from public.job_series where shop_id = tests.fx(''shop_a'')'), 0::bigint,
                'owner of B reads none of A''s series');
select tests.throws($$select public.update_job_series(tests.fx('ser_a'), '{"notes": "x"}')$$, 'P0002', 'another shop''s series is not found');
select tests.throws($$select public.end_job_series(tests.fx('ser_a'), '2025-06-03')$$, 'P0002', 'end: not found');
select tests.throws($$select public.delete_job_series(tests.fx('ser_a'))$$, 'P0002', 'delete: not found');
select tests.throws($$select public.create_job_series(tests.fx('shop_a'), pg_temp.series_json('{"start_date": "2025-06-02"}'))$$,
                    '42501', 'owner of B cannot create in A');
select tests.authenticate_as(tests.fx('u_outsider'));
select tests.throws($$select * from public.job_series_preview(tests.fx('shop_a'), pg_temp.series_json('{"start_date": "2025-06-02"}'))$$,
                    '42501', 'outsider cannot preview');
select tests.as_anon();
select tests.throws($$select public.create_job_series(tests.fx('shop_a'), '{}')$$, '42501', 'anon cannot execute');
select tests.throws($$select public.generate_series_jobs()$$, '42501', 'anon cannot run the generator');

-- ------------------------------------------------------------ client guards on jobs.series_*
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws_like($$insert into public.jobs (shop_id, customer_id, series_id, series_seq)
                           values (tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('ser_a'), 99)$$,
                         '42501', '%series%', 'a client cannot put a job in a series');
select tests.throws_like($$update public.jobs set series_id = null where id = pg_temp.occ(tests.fx('ser_a'), 1)$$,
                         '42501', '%series%', 'a client cannot take a job out of its series');
select tests.throws($$update public.jobs set series_seq = 7 where id = pg_temp.occ(tests.fx('ser_a'), 1)$$, '42501',
                    'a client cannot renumber an occurrence');
select tests.throws($$update public.jobs set series_id = tests.fx('ser_dst') where id = tests.fx('job_a')$$, '42501',
                    'a client cannot attach an existing job');
update public.jobs set status = status where id = pg_temp.occ(tests.fx('ser_a'), 1);
select tests.ok(not (select series_detached from public.jobs where id = pg_temp.occ(tests.fx('ser_a'), 1)),
                'a write that changes nothing of the visit does not detach');
update public.jobs set scheduled_start = scheduled_start + interval '1 hour', scheduled_end = scheduled_end + interval '1 hour'
 where id = pg_temp.occ(tests.fx('ser_a'), 1);
select tests.ok((select series_detached from public.jobs where id = pg_temp.occ(tests.fx('ser_a'), 1)),
                'a direct reschedule detaches the occurrence');
update public.jobs set resource_id = null where id = pg_temp.occ(tests.fx('ser_a'), 2);
select tests.ok((select series_detached from public.jobs where id = pg_temp.occ(tests.fx('ser_a'), 2)),
                'changing the resource detaches it');
select tests.throws($$update public.jobs set series_detached = false where id = pg_temp.occ(tests.fx('ser_a'), 1)$$, '42501',
                    'a detached occurrence cannot be re-attached by a client');
select tests.eq((select series_seq from public.jobs where id = pg_temp.occ(tests.fx('ser_a'), 3)), 3,
                'series_seq readable');
select tests.ok(has_column_privilege('authenticated', 'public.jobs', 'series_id', 'SELECT')
                and has_column_privilege('authenticated', 'public.jobs', 'series_seq', 'SELECT')
                and has_column_privilege('authenticated', 'public.jobs', 'series_detached', 'SELECT'),
                'series columns granted to authenticated');
select tests.throws($$insert into public.job_series (shop_id, customer_id, freq, by_weekday, start_date, local_start, duration_minutes)
                      values (tests.fx('shop_a'), tests.fx('cust_a'), 'week', '{1}', '2025-06-02', '09:00', 60)$$,
                    '42501', 'series rows are RPC-only (no direct insert)');
select tests.throws($$update public.job_series set notes = 'x' where id = tests.fx('ser_a')$$, '42501',
                    'no direct update (privilege revoked)');
select tests.throws($$delete from public.job_series where id = tests.fx('ser_a')$$, '42501',
                    'no direct delete (privilege revoked)');

-- ============================================================ horizon (real clock: API callers get the server clock)
select tests.fx_set('ser_h', (public.create_job_series(tests.fx('shop_a'), pg_temp.series_json(jsonb_build_object(
          'start_date', to_char(pg_temp.local_today() + 1, 'YYYY-MM-DD')))) ->> 'series_id')::uuid);
select tests.eq((select generated_through from public.job_series where id = tests.fx('ser_h')), pg_temp.local_today() + 90,
                'weekly: generated through today + 90 days');
select tests.eq((select count(*) from public.jobs where series_id = tests.fx('ser_h')),
                (select count(*) from generate_series(pg_temp.local_today() + 1, pg_temp.local_today() + 90, interval '1 day') d
                  where extract(dow from d) = extract(dow from pg_temp.local_today() + 1)),
                'one job per week through the horizon');
select tests.fx_set('ser_y', (public.create_job_series(tests.fx('shop_a'), pg_temp.series_json(jsonb_build_object(
          'freq', 'month', 'interval', 12, 'start_date', to_char(pg_temp.local_today() + 1, 'YYYY-MM-DD')))) ->> 'series_id')::uuid);
select tests.eq((select count(*) from public.jobs where series_id = tests.fx('ser_y')), 3::bigint,
                'a yearly series still gets its first 3 occurrences');
select tests.ok((select generated_through >= pg_temp.local_today() + 700 from public.job_series where id = tests.fx('ser_y')),
                'horizon reaches the 3rd occurrence');

-- ============================================================ generate_series_jobs (service_role, idempotent)
select tests.as_service();
select tests.lives($$select public.generate_series_jobs(now() + interval '30 days')$$, 'cron run');
select tests.eq((select generated_through from public.job_series where id = tests.fx('ser_h')), pg_temp.local_today() + 120,
                'the cron extends the horizon with its clock');
create temp table cron_counts as
  select series_id, count(*) as n, count(distinct series_seq) as seqs from public.jobs
   where series_id in (tests.fx('ser_h'), tests.fx('ser_y'), tests.fx('ser_a')) group by series_id;
grant select on cron_counts to service_role;
select tests.eq(public.generate_series_jobs(now() + interval '30 days'), 0, 'a second run creates nothing');
select tests.eq((select array_agg(n order by series_id) from cron_counts),
                (select array_agg(c order by series_id) from (select series_id, count(*) as c from public.jobs
                   where series_id in (tests.fx('ser_h'), tests.fx('ser_y'), tests.fx('ser_a')) group by series_id) x),
                'no duplicates after the second run');
select tests.ok((select bool_and(n = seqs) from cron_counts), 'occurrence numbers are unique');
select tests.eq((select count(*) from public.jobs where series_id = tests.fx('ser_a')), 3::bigint,
                'the cron respects max_occurrences');
-- a job staff deleted is not re-created
select tests.as_superuser();
delete from public.jobs where id = pg_temp.occ(tests.fx('ser_h'), 2);
select tests.as_service();
select tests.lives($$select public.generate_series_jobs(now() + interval '60 days')$$, 'cron run again');
select tests.eq(pg_temp.occ(tests.fx('ser_h'), 2), null::uuid, 'a deleted occurrence is not generated again');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$select public.job_series_generate(tests.fx('ser_h'), now(), false)$$, '42501',
                    'the internal generator is not callable by API users');
select tests.throws($$select * from public.series_occurrence_dates(null::public.job_series, null, null, null)$$, '42501',
                    'the internal rule expander is not callable by API users');
select tests.as_superuser();
-- a series whose services disappeared is skipped without blocking the others
update public.services set archived_at = now() where id = tests.fx('svc_a');
select tests.as_service();
select tests.eq(public.generate_series_jobs(now() + interval '200 days'), 0,
                'nothing to generate when the only service is archived (WARNING, no error)');
select tests.as_superuser();
update public.services set archived_at = null where id = tests.fx('svc_a');

-- ============================================================ "this and following" + eligibility (future series)
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('ser_f', (public.create_job_series(tests.fx('shop_a'), pg_temp.series_json(jsonb_build_object(
          'start_date', to_char(pg_temp.local_today() + 7, 'YYYY-MM-DD'), 'max_occurrences', 8,
          'assignee_member_ids', jsonb_build_array(tests.fx('m_tech_a'))))) ->> 'series_id')::uuid);
select tests.eq((select count(*) from public.jobs where series_id = tests.fx('ser_f')), 8::bigint, '8 future occurrences');
-- #3 confirmed, #4 detached, #5 invoiced, #6 paid (deposit), #7 completed; #2 and #8 stay eligible
update public.jobs set status = 'confirmed' where id = pg_temp.occ(tests.fx('ser_f'), 3);
update public.jobs set scheduled_start = scheduled_start + interval '2 hours', scheduled_end = scheduled_end + interval '2 hours'
 where id = pg_temp.occ(tests.fx('ser_f'), 4);
select tests.lives($$select public.create_invoice_from_job(pg_temp.occ(tests.fx('ser_f'), 5))$$, 'invoice occurrence #5');
select tests.as_superuser();
insert into public.payments (shop_id, job_id, customer_id, kind, method, status, amount_cents, paid_at)
values (tests.fx('shop_a'), pg_temp.occ(tests.fx('ser_f'), 6), tests.fx('cust_a'), 'deposit', 'cash', 'succeeded', 1000, now());
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.jobs set status = 'completed' where id = pg_temp.occ(tests.fx('ser_f'), 7);
create temp table kept_ids as
  select series_seq, id from public.jobs where series_id = tests.fx('ser_f') and series_seq between 3 and 7;
grant select on kept_ids to authenticated;

select tests.eq(public.update_job_series(tests.fx('ser_f'), '{"local_start": "10:30", "notes": "New gate code"}',
                                         pg_temp.occ(tests.fx('ser_f'), 2)),
                '{"updated": true, "deleted": 0, "created": 0, "changed": 2, "kept": 5}'::jsonb,
                'from #2: eligible #2 and #8 updated in place, 5 kept');
select tests.eq((select count(*) from public.jobs j join kept_ids k on k.id = j.id and k.series_seq = j.series_seq), 5::bigint,
                'confirmed, detached, invoiced, paid and completed occurrences are the same jobs');
select tests.eq((select array_agg(to_char(scheduled_start at time zone 'America/Chicago', 'HH24:MI') order by series_seq)
                   from public.jobs where series_id = tests.fx('ser_f')),
                array['09:00', '10:30', '09:00', '11:00', '09:00', '09:00', '09:00', '10:30'],
                'updated occurrences use the new time; kept ones keep theirs');
select tests.eq((select notes from public.jobs where id = pg_temp.occ(tests.fx('ser_f'), 8)), 'New gate code', 'new defaults applied');
select tests.eq((select notes from public.jobs where id = pg_temp.occ(tests.fx('ser_f'), 1)), null::text,
                'the occurrence before the edit point is untouched');
select tests.eq((select count(*) from public.jobs where series_id = tests.fx('ser_f')), 8::bigint, 'still 8 occurrences (max)');
select tests.eq((select (series_seq, to_char(scheduled_start at time zone 'America/Chicago', 'YYYY-MM-DD'))::text
                   from public.jobs where series_id = tests.fx('ser_f') and series_seq = 2),
                (select (2, to_char(pg_temp.local_today() + 14, 'YYYY-MM-DD'))::text), '#2 keeps its date');
select tests.ok((select start_date = pg_temp.local_today() + 7 and seq_offset = 0 from public.job_series
                  where id = tests.fx('ser_f')), 'without a rule change the rule is not re-anchored');

-- rule change from #8: every 2 weeks; #8 is on the new rule and stays
select tests.eq(public.update_job_series(tests.fx('ser_f'), '{"interval": 2, "max_occurrences": 10}',
                                         pg_temp.occ(tests.fx('ser_f'), 8)),
                '{"updated": true, "deleted": 0, "created": 2, "changed": 1, "kept": 0}'::jsonb, 'rule change from #8');
select tests.eq((select array_agg((scheduled_start at time zone 'America/Chicago')::date - pg_temp.local_today() order by series_seq)
                   from public.jobs where series_id = tests.fx('ser_f') and series_seq >= 8),
                array[56, 70, 84], 'new rule anchored at #8''s date, every 2 weeks, up to 10 occurrences');
select tests.ok((select start_date = pg_temp.local_today() + 56 and seq_offset = 7 from public.job_series
                  where id = tests.fx('ser_f')), 'a rule change re-anchors the rule at the edited occurrence');
select tests.throws_like($$select public.update_job_series(tests.fx('ser_f'), '{"customer_id": "00000000-0000-0000-0000-000000000000"}')$$,
                         '22023', '%customer_id%', 'the customer is not editable');
select tests.throws_like($$select public.update_job_series(tests.fx('ser_f'), '{"notes": "x"}', tests.fx('job_a'))$$,
                         '22023', '%not an occurrence%', 'from_job must belong to the series');
select tests.throws($$select public.update_job_series(tests.fx('ser_f'), '{"vehicle_id": "00000000-0000-0000-0000-000000000000"}')$$,
                    '22023', 'unknown vehicle rejected');
-- null from_job: every occurrence that has not started, i.e. from #1 on
-- (#1 and #2 predate the re-anchored rule: they are updated on their own
-- dates)
create temp table dates_before as
  select series_seq, scheduled_start from public.jobs where series_id = tests.fx('ser_f');
grant select on dates_before to authenticated;
select tests.eq(public.update_job_series(tests.fx('ser_f'), '{"internal_notes": "All future"}'),
                '{"updated": true, "deleted": 0, "created": 0, "changed": 5, "kept": 5}'::jsonb, 'update without from_job');
select tests.eq((select count(*) from public.jobs where series_id = tests.fx('ser_f') and series_seq >= 2
                   and internal_notes = 'All future'), 4::bigint, 'the eligible future occurrences got the new default');
select tests.eq((select count(*) from public.jobs j join dates_before b on b.series_seq = j.series_seq
                  where j.series_id = tests.fx('ser_f')
                    and (j.scheduled_start at time zone 'America/Chicago')::date
                        = (b.scheduled_start at time zone 'America/Chicago')::date), 10::bigint,
                'a change without a rule change moves no occurrence to another day');
select tests.eq((select to_char(scheduled_start at time zone 'America/Chicago', 'HH24:MI') from public.jobs
                  where id = pg_temp.occ(tests.fx('ser_f'), 1)), '10:30',
                '#1 (updated in place) now uses the series'' current start time');

-- limits and services in a "this and following" edit (no rule change)
select tests.fx_set('ser_g', (public.create_job_series(tests.fx('shop_a'), pg_temp.series_json(jsonb_build_object(
          'start_date', to_char(pg_temp.local_today() + 7, 'YYYY-MM-DD'), 'max_occurrences', 5))) ->> 'series_id')::uuid);
select tests.eq(public.update_job_series(tests.fx('ser_g'), '{"max_occurrences": 3}'),
                '{"updated": true, "deleted": 2, "created": 0, "changed": 3, "kept": 0}'::jsonb, 'lowering max_occurrences drops #4 and #5');
select tests.eq((select array_agg(series_seq order by series_seq) from public.jobs where series_id = tests.fx('ser_g')),
                array[1, 2, 3], 'three occurrences left');
select tests.lives($$select public.update_job_series(tests.fx('ser_g'),
                     jsonb_build_object('template_lines', jsonb_build_array(jsonb_build_object('service_id', tests.fx('svc_a'), 'quantity', 1.5))))$$,
                   'change the services');
select tests.ok((select bool_and(scheduled_end - scheduled_start = interval '180 minutes' and subtotal_cents = 30000)
                   from public.jobs where series_id = tests.fx('ser_g')), 'duration recomputed (1.5 x 120 min), lines repriced');
select tests.eq((select duration_minutes from public.job_series where id = tests.fx('ser_g')), 180, 'series duration updated');
select tests.lives($$select public.update_job_series(tests.fx('ser_g'), '{"duration_minutes": 90}')$$, 'an explicit duration');
select tests.eq((select duration_minutes from public.job_series where id = tests.fx('ser_g')), 90, 'kept when given');
select tests.eq(public.update_job_series(tests.fx('ser_g'), jsonb_build_object('until_date', to_char(pg_temp.local_today() + 14, 'YYYY-MM-DD'))),
                '{"updated": true, "deleted": 1, "created": 0, "changed": 2, "kept": 0}'::jsonb, 'an earlier until_date drops #3');
select tests.eq(public.update_job_series(tests.fx('ser_g'), '{"until_date": null, "max_occurrences": 4}'),
                '{"updated": true, "deleted": 0, "created": 2, "changed": 2, "kept": 0}'::jsonb, 'extending the limits generates the missing ones');
select tests.throws_like($$select public.update_job_series(tests.fx('ser_g'), jsonb_build_object('until_date', to_char(pg_temp.local_today(), 'YYYY-MM-DD')))$$,
                         '22023', '%until_date%', 'until_date cannot precede the rule''s start');

-- ------------------------------------------------------------ end_job_series
select tests.eq(public.end_job_series(tests.fx('ser_f'), pg_temp.local_today() + 40),
                '{"deleted": 3, "kept": 2}'::jsonb, 'ending after day 40: #8-#10 removed, paid #6 and completed #7 kept');
select tests.eq((select array_agg(series_seq order by series_seq) from public.jobs where series_id = tests.fx('ser_f')
                   and (scheduled_start at time zone 'America/Chicago')::date > pg_temp.local_today() + 40),
                array[6, 7], 'only non-eligible later occurrences remain');
select tests.ok((select active and until_date = pg_temp.local_today() + 40 from public.job_series where id = tests.fx('ser_f')),
                'a future end date keeps the series active until then');
select tests.eq(public.end_job_series(tests.fx('ser_f'), pg_temp.local_today() + 20),
                '{"deleted": 0, "kept": 5}'::jsonb, 'confirmed, detached, invoiced, paid, completed after day 20 are kept');
select tests.eq(public.end_job_series(tests.fx('ser_f'), pg_temp.local_today()),
                '{"deleted": 2, "kept": 5}'::jsonb, 'ending today removes the eligible #1 and #2');
select tests.ok((select not active and ended_at is not null from public.job_series where id = tests.fx('ser_f')),
                'ending today deactivates the series');
select tests.throws_like($$select public.update_job_series(tests.fx('ser_f'), '{"notes": "x"}')$$, '22023', '%ended%',
                         'an ended series cannot be edited');
select tests.throws_like($$select public.end_job_series(tests.fx('ser_f'), current_date)$$, '22023', '%ended%',
                         'an ended series cannot be ended again');
select tests.as_service();
select tests.lives($$select public.generate_series_jobs(now() + interval '400 days')$$, 'cron after the end');
select tests.eq((select count(*) from public.jobs where series_id = tests.fx('ser_f')), 5::bigint,
                'an ended series generates nothing');

-- ------------------------------------------------------------ delete_job_series
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(public.delete_job_series(tests.fx('ser_f')), '{"deleted": 0, "kept": 5}'::jsonb, 'delete: kept jobs stay');
select tests.eq((select count(*) from public.jobs j join kept_ids k on k.id = j.id
                  where j.series_id is null and j.series_seq is null), 5::bigint,
                'kept occurrences become ordinary jobs (series_seq cleared with series_id)');
select tests.eq(tests.row_count($$select 1 from public.job_series where id = tests.fx('ser_f')$$), 0::bigint, 'series gone');

-- the customer's series blocks deleting the customer until it is removed
select tests.as_superuser();
insert into public.customers (shop_id, first_name) values (tests.fx('shop_a'), 'Solo') returning tests.fx_set('cust_solo', id);
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('ser_solo', (public.create_job_series(tests.fx('shop_a'), jsonb_build_object(
          'customer_id', tests.fx('cust_solo'), 'freq', 'week', 'local_start', '09:00',
          'start_date', to_char(pg_temp.local_today() + 3, 'YYYY-MM-DD'), 'max_occurrences', 2,
          'template_lines', jsonb_build_array(jsonb_build_object('service_id', tests.fx('svc_a'))))) ->> 'series_id')::uuid);
select tests.eq(public.delete_job_series(tests.fx('ser_solo')), '{"deleted": 2, "kept": 0}'::jsonb,
                'eligible occurrences are deleted with the series');
select tests.as_service();   -- 0125: deletes go through erase_customer (service role)
select tests.eq(tests.row_count($$delete from public.customers where id = tests.fx('cust_solo')$$), 1::bigint,
                'the customer can then be deleted');

-- ------------------------------------------------------------ send_confirmation
select tests.as_superuser();
insert into public.platform_config (key, value) values ('app_base_url', 'https://app.example.test')
on conflict (key) do update set value = excluded.value;
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('ser_c', (public.create_job_series(tests.fx('shop_a'), pg_temp.series_json(jsonb_build_object(
          'start_date', to_char(pg_temp.local_today() + 3, 'YYYY-MM-DD'), 'max_occurrences', 3,
          'send_confirmation', true))) ->> 'first_job_id')::uuid);
select tests.as_superuser();
select tests.eq((select count(*) from public.integration_events where event = 'booking_confirmed' and job_id = tests.fx('ser_c')),
                1::bigint, 'the first occurrence gets the booking confirmation');
select tests.eq((select count(*) from public.integration_events e join public.jobs j on j.id = e.job_id
                  where e.event = 'booking_confirmed' and j.series_id = (select series_id from public.jobs where id = tests.fx('ser_c'))),
                1::bigint, 'later occurrences get none');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws_like($$select public.create_job_series(tests.fx('shop_a'), pg_temp.series_json('{"start_date": "2025-06-02", "send_confirmation": "yes"}'))$$,
                         '22023', '%send_confirmation%', 'send_confirmation must be boolean');

-- ------------------------------------------------------------ customer merge bypass (P-20 contract)
select tests.as_superuser();
select set_config('detailcrm.customer_merge', 'on', true);
select tests.lives($$update public.job_series set customer_id = tests.fx('cust_a2')
                      where id = (select series_id from public.jobs where id = tests.fx('ser_c'))$$,
                   'a merge may move a series whose vehicle has not moved yet');
select set_config('detailcrm.customer_merge', '', true);
select tests.throws_like($$update public.job_series set customer_id = tests.fx('cust_a3')
                           where id = (select series_id from public.jobs where id = tests.fx('ser_c'))$$,
                         '22023', '%vehicle%', 'outside a merge the vehicle must belong to the customer');
