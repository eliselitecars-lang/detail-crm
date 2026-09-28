-- 50 sched: recurring series edits, regressions (0051) —
--   * a technician's internal note (the one job column besides status an
--     assigned technician may write) does not detach the visit: a later
--     rule change moves it with the rest of the series (no second visit in
--     its week), an in-place series edit keeps the note, and a later change
--     of the series' internal-notes default does not overwrite it; a
--     manager's internal note still detaches ("this job only");
--   * a deleted (skipped) visit that had been edited on its own records its
--     RULE date, so a later rule change (which renumbers the series and
--     resets skipped_seqs) never re-creates it, whether it was still on its
--     rule date or moved to another day;
--   * a rule change with no edit point keeps an every-N cadence's phase when
--     the next visit was moved into an off-week / off-month: the result is
--     the same as with p_from_job_id = that visit;
--   * roles and shops: technicians cannot edit the series, another shop's
--     technician cannot write the note, shop B is untouched.
\ir fixtures/two_shops.psql

select tests.as_superuser();
-- a Monday 14..20 days ahead (shop-local, America/Chicago)
create function pg_temp.m0() returns date language sql stable as $$
  select d from (select ((now() at time zone 'America/Chicago')::date + 14 + i) as d from generate_series(0, 6) i) x
   where extract(dow from d) = 1
$$;
-- the 15th of a month 45..75 days ahead
create function pg_temp.f15() returns date language sql stable as $$
  select (date_trunc('month', (now() at time zone 'America/Chicago')::date + 45)::date + 14)
$$;
create function pg_temp.occ(p_series uuid, p_seq integer) returns uuid language sql stable as $$
  select id from public.jobs where series_id = p_series and series_seq = p_seq
$$;
create function pg_temp.on_day(p_series uuid, p_d date) returns bigint language sql stable as $$
  select count(*) from public.jobs
   where series_id = p_series and (scheduled_start at time zone 'America/Chicago')::date = p_d
$$;
create function pg_temp.in_week(p_series uuid, p_monday date) returns bigint language sql stable as $$
  select count(*) from public.jobs
   where series_id = p_series and (scheduled_start at time zone 'America/Chicago')::date between p_monday - 1 and p_monday + 5
$$;
create function pg_temp.days(p_series uuid) returns date[] language sql stable as $$
  select coalesce(array_agg((scheduled_start at time zone 'America/Chicago')::date order by scheduled_start), '{}')
    from public.jobs where series_id = p_series
$$;
create function pg_temp.weekly(p_extra jsonb default '{}') returns jsonb language sql stable as $$
  select jsonb_build_object('customer_id', tests.fx('cust_a'), 'vehicle_id', tests.fx('veh_a'), 'freq', 'week',
                            'by_weekday', jsonb_build_array(1), 'local_start', '09:00', 'start_date', pg_temp.m0()::text,
                            'template_lines', jsonb_build_array(jsonb_build_object('service_id', tests.fx('svc_a')))) || p_extra
$$;
grant execute on function pg_temp.m0(), pg_temp.f15(), pg_temp.occ(uuid, integer), pg_temp.on_day(uuid, date),
  pg_temp.in_week(uuid, date), pg_temp.days(uuid), pg_temp.weekly(jsonb) to authenticated, service_role;

-- ============================================================ #1 a technician's field note
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('ser1', (public.create_job_series(tests.fx('shop_a'), pg_temp.weekly(jsonb_build_object(
          'internal_notes', 'Bring the ladder',
          'assignee_member_ids', jsonb_build_array(tests.fx('m_tech_a'))))) ->> 'series_id')::uuid);
select tests.fx_set('v1_3', pg_temp.occ(tests.fx('ser1'), 3));
select tests.fx_set('v1_4', pg_temp.occ(tests.fx('ser1'), 4));
select tests.fx_set('v1_5', pg_temp.occ(tests.fx('ser1'), 5));
select tests.eq(pg_temp.on_day(tests.fx('ser1'), pg_temp.m0() + 14), 1::bigint, 'visit 3 is on the Monday two weeks in');

select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$update public.jobs set internal_notes = 'dog in yard, use side gate' where id = tests.fx('v1_3')$$),
                1::bigint, 'the assigned technician saves a field note');
select tests.eq(tests.row_count($$update public.jobs set internal_notes = 'code 4411' where id = tests.fx('v1_5')$$),
                1::bigint, '... and another on visit 5');
select tests.throws($$update public.jobs set notes = 'x' where id = tests.fx('v1_3')$$, '42501',
                    'the technician still cannot change anything else');
select tests.throws($$select public.update_job_series(tests.fx('ser1'), '{"by_weekday": [3]}')$$, '42501',
                    'nor edit the series');
select tests.ok((select not series_detached from public.jobs where id = tests.fx('v1_3')),
                'the field note does not detach the visit');
select tests.authenticate_as(tests.fx('u_owner_b'));
select tests.eq(tests.row_count($$update public.jobs set internal_notes = 'B' where id = tests.fx('v1_4')$$), 0::bigint,
                'another shop cannot write the note (RLS)');

-- a manager's own internal note on visit 4 is a "this job only" edit
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.jobs set internal_notes = 'Manager: bring the wax' where id = tests.fx('v1_4');
select tests.ok((select series_detached from public.jobs where id = tests.fx('v1_4')), 'a manager''s internal note detaches');

-- an in-place edit (new start time) and a new internal-notes default
select tests.eq((public.update_job_series(tests.fx('ser1'), '{"local_start": "10:00", "internal_notes": "Bring both ladders"}',
                                          pg_temp.occ(tests.fx('ser1'), 1)) ->> 'kept')::integer, 1,
                'only the manager-detached visit is kept');
select tests.as_superuser();
select tests.eq((select internal_notes from public.jobs where id = tests.fx('v1_3')), 'dog in yard, use side gate',
                'the field note survives the in-place edit');
select tests.eq((select (scheduled_start at time zone 'America/Chicago')::time from public.jobs where id = tests.fx('v1_3')),
                '10:00'::time, '... and the noted visit took the new time');
select tests.eq((select internal_notes from public.jobs where id = tests.fx('v1_5')), 'code 4411', 'so does visit 5''s');
select tests.eq((select internal_notes from public.jobs where id = pg_temp.occ(tests.fx('ser1'), 2)), 'Bring both ladders',
                'an un-noted visit takes the new default');
select tests.eq((select internal_notes from public.jobs where id = tests.fx('v1_4')), 'Manager: bring the wax',
                'the detached visit keeps the manager''s note');

-- the rule changes from visit 1 on: Mondays -> Wednesdays
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.lives($$select public.update_job_series(tests.fx('ser1'), '{"by_weekday": [3]}', pg_temp.occ(tests.fx('ser1'), 1))$$,
                   'Mondays -> Wednesdays');
select tests.as_superuser();
select tests.eq(pg_temp.in_week(tests.fx('ser1'), pg_temp.m0() + 14), 1::bigint,
                'one visit in visit 3''s week after moving the series to Wednesdays');
select tests.eq(pg_temp.on_day(tests.fx('ser1'), pg_temp.m0() + 16), 1::bigint, '... on the Wednesday');
select tests.eq(pg_temp.on_day(tests.fx('ser1'), pg_temp.m0() + 14), 0::bigint, '... not on the old Monday');
select tests.ok(not exists (select 1 from public.jobs where id = tests.fx('v1_3')), 'the noted Monday visit moved with the series');
select tests.eq(pg_temp.in_week(tests.fx('ser1'), pg_temp.m0() + 21), 2::bigint,
                'visit 4''s week: the manager-detached Monday is kept beside the new Wednesday (this job only)');
select tests.ok(exists (select 1 from public.jobs where id = tests.fx('v1_4')), '... the detached visit itself is kept');
select tests.eq(pg_temp.in_week(tests.fx('ser1'), pg_temp.m0() + 28), 1::bigint, 'visit 5''s week: one visit');
select tests.eq((select count(*) from public.jobs j where j.series_id = tests.fx('ser1') and j.internal_notes = 'Bring both ladders'
                   and (j.scheduled_start at time zone 'America/Chicago')::date = pg_temp.m0() + 16
                   and (j.scheduled_start at time zone 'America/Chicago')::time = '10:00'), 1::bigint,
                'the new Wednesday carries the series defaults');
select tests.eq((select count(*) from (select series_seq from public.jobs where series_id = tests.fx('ser1')
                                         group by series_seq having count(*) > 1) x), 0::bigint, 'visit numbers stay unique');

-- ============================================================ #2 a detached visit's skip survives a renumbering
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('ser2', (public.create_job_series(tests.fx('shop_a'), pg_temp.weekly(
          jsonb_build_object('local_start', '13:00'))) ->> 'series_id')::uuid);
-- visit 3: a note (detaches, same date), then the customer skips that week
update public.jobs set notes = 'gate code 1234' where id = pg_temp.occ(tests.fx('ser2'), 3);
select tests.ok((select series_detached from public.jobs where id = pg_temp.occ(tests.fx('ser2'), 3)), 'the note detached visit 3');
delete from public.jobs where id = pg_temp.occ(tests.fx('ser2'), 3);
-- visit 5: moved to the Thursday (detaches), then deleted
update public.jobs set scheduled_start = scheduled_start + interval '3 days', scheduled_end = scheduled_end + interval '3 days'
 where id = pg_temp.occ(tests.fx('ser2'), 5);
delete from public.jobs where id = pg_temp.occ(tests.fx('ser2'), 5);
select tests.as_superuser();
select tests.ok((select skipped_seqs = '{3,5}' and skipped_dates = array[pg_temp.m0() + 14, pg_temp.m0() + 28]
                   from public.job_series where id = tests.fx('ser2')),
                'both skips record the number and the rule date (not the Thursday visit 5 was moved to)');
select tests.eq(pg_temp.on_day(tests.fx('ser2'), pg_temp.m0() + 14), 0::bigint, 'visit 3 skipped');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.lives($$select public.update_job_series(tests.fx('ser2'), '{"by_weekday": [1, 3]}', pg_temp.occ(tests.fx('ser2'), 2))$$,
                   'add Wednesdays from visit 2');
select tests.as_superuser();
select tests.eq(pg_temp.on_day(tests.fx('ser2'), pg_temp.m0() + 14), 0::bigint,
                'the visit staff deleted is not re-created by a later series edit');
select tests.eq(pg_temp.on_day(tests.fx('ser2'), pg_temp.m0() + 28), 0::bigint, '... nor the moved-then-deleted one''s Monday');
select tests.eq(pg_temp.on_day(tests.fx('ser2'), pg_temp.m0() + 31), 0::bigint, '... nor anything on the Thursday it had moved to');
select tests.eq(pg_temp.on_day(tests.fx('ser2'), pg_temp.m0() + 16), 1::bigint, 'that week''s new Wednesday is generated');
select tests.eq(pg_temp.on_day(tests.fx('ser2'), pg_temp.m0() + 21), 1::bigint, 'the Mondays around it stay');
select tests.ok((select skipped_seqs = '{}' and pg_temp.m0() + 14 = any (skipped_dates) and pg_temp.m0() + 28 = any (skipped_dates)
                   from public.job_series where id = tests.fx('ser2')),
                'the renumbering reset the numbers but kept both dates');
-- and again, the other way (a later rule change still does not bring them back)
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.lives($$select public.update_job_series(tests.fx('ser2'), '{"by_weekday": [1]}')$$, 'back to Mondays only');
select tests.as_superuser();
select tests.eq(pg_temp.on_day(tests.fx('ser2'), pg_temp.m0() + 14) + pg_temp.on_day(tests.fx('ser2'), pg_temp.m0() + 28), 0::bigint,
                'the skipped Mondays stay skipped');

-- a detached visit deleted after a rule change: its date in the NEW numbering
select tests.fx_set('ser2_v', (select id from public.jobs where series_id = tests.fx('ser2')
                                 and (scheduled_start at time zone 'America/Chicago')::date = pg_temp.m0() + 35));
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.jobs set internal_notes = 'm' where id = tests.fx('ser2_v');
delete from public.jobs where id = tests.fx('ser2_v');
select tests.as_superuser();
select tests.ok((select pg_temp.m0() + 35 = any (skipped_dates) from public.job_series where id = tests.fx('ser2')),
                'a detached visit''s rule date is found in the current numbering');

-- a detached visit numbered before start_date (kept, off the rule) records no date
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('ser2b', (public.create_job_series(tests.fx('shop_a'), pg_temp.weekly(
          jsonb_build_object('local_start', '15:00'))) ->> 'series_id')::uuid);
update public.jobs set scheduled_start = scheduled_start - interval '3 days', scheduled_end = scheduled_end - interval '3 days'
 where id = pg_temp.occ(tests.fx('ser2b'), 1);   -- moved to the Friday before (kept by the next edit)
select tests.lives($$select public.update_job_series(tests.fx('ser2b'), '{"by_weekday": [2]}', pg_temp.occ(tests.fx('ser2b'), 2))$$,
                   'Tuesdays from visit 2');
select tests.ok((select series_seq <= js.seq_offset from public.jobs j join public.job_series js on js.id = j.series_id
                  where j.id = pg_temp.occ(tests.fx('ser2b'), 1)), 'visit 1 is numbered before the new start');
select tests.as_superuser();
create temp table ser2b_before as select skipped_dates from public.job_series where id = tests.fx('ser2b');
select tests.authenticate_as(tests.fx('u_manager_a'));
delete from public.jobs where id = pg_temp.occ(tests.fx('ser2b'), 1);
select tests.as_superuser();
select tests.eq((select skipped_dates from public.job_series where id = tests.fx('ser2b')),
                (select skipped_dates from ser2b_before),
                'no date is recorded for a detached visit the rule does not number');

-- ============================================================ #3 no edit point: the cadence keeps its phase
-- two identical every-2-weeks Monday series; visit 1 of each moved to the Friday before
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('ser3a', (public.create_job_series(tests.fx('shop_a'), pg_temp.weekly(
          jsonb_build_object('interval', 2, 'local_start', '07:00'))) ->> 'series_id')::uuid);
select tests.fx_set('ser3b', (public.create_job_series(tests.fx('shop_a'), pg_temp.weekly(
          jsonb_build_object('interval', 2, 'local_start', '07:00'))) ->> 'series_id')::uuid);
update public.jobs set scheduled_start = scheduled_start - interval '3 days', scheduled_end = scheduled_end - interval '3 days'
 where id in (pg_temp.occ(tests.fx('ser3a'), 1), pg_temp.occ(tests.fx('ser3b'), 1));
select tests.lives($$select public.update_job_series(tests.fx('ser3a'), '{"by_weekday": [2]}', null)$$,
                   'Tuesdays, no edit point');
select tests.lives($$select public.update_job_series(tests.fx('ser3b'), '{"by_weekday": [2]}', pg_temp.occ(tests.fx('ser3b'), 1))$$,
                   'Tuesdays from visit 1');
select tests.as_superuser();
select tests.eq(pg_temp.on_day(tests.fx('ser3a'), pg_temp.m0() + 8), 0::bigint,
                'biweekly cadence kept: nothing in the off-week of the original rule (m0+8)');
select tests.eq(pg_temp.on_day(tests.fx('ser3a'), pg_temp.m0() + 1) + pg_temp.on_day(tests.fx('ser3a'), pg_temp.m0() + 15)
                  + pg_temp.on_day(tests.fx('ser3a'), pg_temp.m0() + 29), 3::bigint, 'the Tuesdays land in the on-weeks');
select tests.eq(pg_temp.days(tests.fx('ser3a')), pg_temp.days(tests.fx('ser3b')),
                'the same schedule with and without the edit point');
select tests.eq((select start_date from public.job_series where id = tests.fx('ser3a')), pg_temp.m0(),
                'the rule is re-anchored at its own date, not the moved visit''s');
select tests.eq(pg_temp.on_day(tests.fx('ser3a'), pg_temp.m0() - 3), 1::bigint, 'the moved visit is kept on its Friday');
select tests.eq((select series_seq from public.jobs where series_id = tests.fx('ser3a')
                   and (scheduled_start at time zone 'America/Chicago')::date = pg_temp.m0() + 1), 2,
                'the first new Tuesday is visit 2');

-- a visit 2 moved BEFORE an untouched visit 1: no edit point still reaches visit 1
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('ser3c', (public.create_job_series(tests.fx('shop_a'), pg_temp.weekly(
          jsonb_build_object('local_start', '17:00'))) ->> 'series_id')::uuid);
update public.jobs set scheduled_start = scheduled_start - interval '8 days', scheduled_end = scheduled_end - interval '8 days'
 where id = pg_temp.occ(tests.fx('ser3c'), 2);   -- to the Sunday before visit 1
select tests.fx_set('v3c_1', pg_temp.occ(tests.fx('ser3c'), 1));
select tests.lives($$select public.update_job_series(tests.fx('ser3c'), '{"by_weekday": [3]}')$$, 'Wednesdays, no edit point');
select tests.as_superuser();
select tests.ok(not exists (select 1 from public.jobs where id = tests.fx('v3c_1')), 'the untouched visit 1 moved with the rule');
select tests.eq(pg_temp.on_day(tests.fx('ser3c'), pg_temp.m0() + 2), 1::bigint, '... to that week''s Wednesday');
select tests.eq(pg_temp.on_day(tests.fx('ser3c'), pg_temp.m0() - 1), 1::bigint, 'the moved visit 2 is kept');

-- every 2 months: visit 1 moved into the month before
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('ser3m', (public.create_job_series(tests.fx('shop_a'), pg_temp.weekly(jsonb_build_object(
          'freq', 'month', 'interval', 2, 'by_weekday', null, 'month_day', 15, 'start_date', pg_temp.f15()::text,
          'local_start', '11:00'))) ->> 'series_id')::uuid);
select tests.eq(pg_temp.on_day(tests.fx('ser3m'), pg_temp.f15()), 1::bigint, 'monthly visit 1 on the 15th');
update public.jobs set scheduled_start = scheduled_start - interval '20 days', scheduled_end = scheduled_end - interval '20 days'
 where id = pg_temp.occ(tests.fx('ser3m'), 1);
select tests.lives($$select public.update_job_series(tests.fx('ser3m'), '{"month_day": 20}')$$, 'the 20th, no edit point');
select tests.as_superuser();
select tests.eq(pg_temp.on_day(tests.fx('ser3m'), pg_temp.f15() + 5), 1::bigint, 'the 20th of the on-month');
select tests.eq(pg_temp.on_day(tests.fx('ser3m'), (pg_temp.f15() + interval '1 month')::date + 5), 0::bigint,
                'nothing in the off-month');
select tests.eq(pg_temp.on_day(tests.fx('ser3m'), (pg_temp.f15() + interval '2 months')::date + 5), 1::bigint,
                'the next on-month');

-- ============================================================ shops
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.throws($$select public.update_job_series(tests.fx('ser1'), '{"by_weekday": [2]}')$$, 'P0002',
                    'another shop''s manager cannot see the series');
select tests.as_superuser();
select tests.eq((select count(*) from public.jobs where shop_id = tests.fx('shop_b') and series_id is not null), 0::bigint,
                'shop B holds no series occurrence');
