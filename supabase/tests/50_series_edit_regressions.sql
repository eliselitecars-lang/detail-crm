-- 50 sched: recurring series edits, regressions (0051) —
--   * the edit point is a date: after a rule change, a "this and following"
--     edit from a kept occurrence (or with no edit point) never touches the
--     visits dated before it, and the new rule starts at the earliest
--     upcoming visit;
--   * max_occurrences counts visits: a rule change with a later occurrence
--     kept moves the remaining visits instead of dropping them, whether the
--     kept visit is off the new rule (held_dates) or on it;
--   * an edit that leaves a visit on its date updates it IN PLACE: the booking
--     link already texted keeps working and the appointment reminder is not
--     sent again; a time change keeps the job too;
--   * "this job only" edits made through the API (line items added, removed
--     or repriced, notes, a discount or a coupon, assignees) detach the
--     visit, so a later series edit keeps it; a technician's internal note
--     does not detach it (the in-place edit keeps the note); the series
--     RPCs' own writes detach nothing;
--   * end_job_series never moves the end of a series later and never makes
--     the cron create more visits;
--   * roles and shops: the new internal helpers are not callable by API
--     roles, technicians and other shops cannot edit, shop B is untouched.
\ir fixtures/two_shops.psql
\ir fixtures/50_ranges.psql

select tests.as_superuser();
-- a Monday 14..20 days ahead (shop-local, America/Chicago)
create function pg_temp.m0() returns date language sql stable as $$
  select d from (select ((now() at time zone 'America/Chicago')::date + 14 + i) as d from generate_series(0, 6) i) x
   where extract(dow from d) = 1
$$;
create function pg_temp.occ(p_series uuid, p_seq integer) returns uuid language sql stable as $$
  select id from public.jobs where series_id = p_series and series_seq = p_seq
$$;
create function pg_temp.on_day(p_series uuid, p_d date) returns bigint language sql stable as $$
  select count(*) from public.jobs
   where series_id = p_series and (scheduled_start at time zone 'America/Chicago')::date = p_d
$$;
create function pg_temp.weekly(p_extra jsonb default '{}') returns jsonb language sql stable as $$
  select jsonb_build_object('customer_id', tests.fx('cust_a'), 'vehicle_id', tests.fx('veh_a'), 'freq', 'week',
                            'local_start', '09:00', 'start_date', pg_temp.m0()::text,
                            'template_lines', jsonb_build_array(jsonb_build_object('service_id', tests.fx('svc_a')))) || p_extra
$$;
create function pg_temp.ordinal_gaps(p_series uuid) returns bigint language sql stable as $$
  select count(*) from (select series_seq, row_number() over (order by scheduled_start) as rn
                          from public.jobs where series_id = p_series) x
   where x.series_seq <> x.rn
$$;
grant execute on function pg_temp.m0(), pg_temp.occ(uuid, integer), pg_temp.on_day(uuid, date), pg_temp.weekly(jsonb),
                          pg_temp.ordinal_gaps(uuid)
  to authenticated, service_role, anon;

-- ============================================================ #1 the edit point is a date
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('ser1', (public.create_job_series(tests.fx('shop_a'), pg_temp.weekly()) ->> 'series_id')::uuid);
update public.jobs set status = 'confirmed' where series_id = tests.fx('ser1') and series_seq = 4;
select tests.fx_set('s1_kept', pg_temp.occ(tests.fx('ser1'), 4));
-- from visit 1: Mondays -> Wednesdays (visit 4, confirmed, stays on its Monday)
select tests.eq(public.update_job_series(tests.fx('ser1'), '{"by_weekday": [3]}', pg_temp.occ(tests.fx('ser1'), 1)) ->> 'kept',
                '1', 'Mondays -> Wednesdays from visit 1: the confirmed visit 4 is kept');
select tests.as_superuser();
select tests.ok((select (scheduled_start at time zone 'America/Chicago')::date = pg_temp.m0() + 21 and series_seq = 4
                   from public.jobs where id = tests.fx('s1_kept')),
                'the kept Monday holds its date and its place in the numbering (three Wednesdays before it)');
select tests.eq((select held_dates from public.job_series where id = tests.fx('ser1')), array[pg_temp.m0() + 21],
                'its date is held off the new rule');
select tests.eq(pg_temp.ordinal_gaps(tests.fx('ser1')), 0::bigint, 'numbers follow the date order');
create temp table s1_before as
  select id, notes from public.jobs where series_id = tests.fx('ser1')
   and scheduled_start < (select scheduled_start from public.jobs where id = tests.fx('s1_kept'));
grant select on s1_before to authenticated;
select tests.eq((select count(*) from s1_before), 3::bigint, 'three Wednesdays before the kept Monday');
-- "this and following" from the confirmed visit, notes only
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.lives($$select public.update_job_series(tests.fx('ser1'), '{"notes": "use the side gate"}', tests.fx('s1_kept'))$$,
                   'a notes edit from the kept visit on');
select tests.as_superuser();
select tests.eq((select count(*) from public.jobs where series_id = tests.fx('ser1')
                   and scheduled_start < (select scheduled_start from public.jobs where id = tests.fx('s1_kept'))),
                3::bigint, 'the three Wednesday visits BEFORE the edited visit are untouched');
select tests.eq((select count(*) from public.jobs j join s1_before b on b.id = j.id
                  where j.notes is not distinct from b.notes), 3::bigint, '... the same jobs, without the new notes');
select tests.ok((select bool_and(notes = 'use the side gate') from public.jobs where series_id = tests.fx('ser1')
                   and scheduled_start > (select scheduled_start from public.jobs where id = tests.fx('s1_kept'))),
                'the visits after it got the notes');
select tests.eq((select notes from public.jobs where id = tests.fx('s1_kept')), null::text, 'the kept visit itself is untouched');

-- variant: no edit point after the rule change (Wednesdays -> Thursdays)
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('ser1b', (public.create_job_series(tests.fx('shop_a'), pg_temp.weekly()) ->> 'series_id')::uuid);
update public.jobs set status = 'confirmed' where series_id = tests.fx('ser1b') and series_seq = 4;
select public.update_job_series(tests.fx('ser1b'), '{"by_weekday": [3]}', pg_temp.occ(tests.fx('ser1b'), 1));
select tests.lives($$select public.update_job_series(tests.fx('ser1b'), '{"by_weekday": [4]}')$$,
                   'Wednesdays -> Thursdays with no edit point');
select tests.as_superuser();
select tests.eq(pg_temp.on_day(tests.fx('ser1b'), pg_temp.m0() + 3), 1::bigint,
                'the new rule starts at the earliest upcoming visit: the first Thursday exists');
select tests.eq(pg_temp.on_day(tests.fx('ser1b'), pg_temp.m0() + 10) + pg_temp.on_day(tests.fx('ser1b'), pg_temp.m0() + 17),
                2::bigint, '... and so do the Thursdays before the kept Monday');
select tests.eq((select count(*) from public.jobs where series_id = tests.fx('ser1b')
                   and extract(dow from scheduled_start at time zone 'America/Chicago') = 3), 0::bigint, 'no Wednesday is left');
select tests.eq(pg_temp.on_day(tests.fx('ser1b'), pg_temp.m0() + 21), 1::bigint, 'the kept Monday is still there');
select tests.eq(pg_temp.ordinal_gaps(tests.fx('ser1b')), 0::bigint, 'numbers follow the date order');

-- ============================================================ #2 max_occurrences counts visits
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('ser2', (public.create_job_series(tests.fx('shop_a'), pg_temp.weekly('{"max_occurrences": 6}')) ->> 'series_id')::uuid);
select tests.eq((select count(*) from public.jobs where series_id = tests.fx('ser2')), 6::bigint, 'six visits');
update public.jobs set status = 'confirmed' where series_id = tests.fx('ser2') and series_seq = 6;
select tests.fx_set('s2_last', pg_temp.occ(tests.fx('ser2'), 6));
select tests.eq(public.update_job_series(tests.fx('ser2'), '{"by_weekday": [3]}', pg_temp.occ(tests.fx('ser2'), 2)),
                '{"updated": true, "deleted": 4, "created": 4, "changed": 0, "kept": 1}'::jsonb,
                'Monday -> Wednesday from visit 2: visits 2-5 move, visit 6 is kept');
select tests.as_superuser();
select tests.eq((select count(*) from public.jobs where series_id = tests.fx('ser2')), 6::bigint,
                'still six visits: visits 2-5 moved to Wednesday, visit 6 kept');
select tests.eq((select array_agg(extract(dow from scheduled_start at time zone 'America/Chicago')::integer order by series_seq)
                   from public.jobs where series_id = tests.fx('ser2')), array[1, 3, 3, 3, 3, 1],
                'Monday, four Wednesdays, the kept Monday');
select tests.eq((select series_seq from public.jobs where id = tests.fx('s2_last')), 6, 'the kept visit is visit 6 of 6');
select tests.ok((select seq_offset = 1 and held_dates = array[pg_temp.m0() + 35] and max_occurrences = 6
                   from public.job_series where id = tests.fx('ser2')), 'one visit before the edit point; the kept date is held');
select tests.as_service();
select tests.lives($$select public.generate_series_jobs(now() + interval '120 days')$$, 'the cron runs');
select tests.eq((select count(*) from public.jobs where series_id = tests.fx('ser2')), 6::bigint, 'the cron adds no seventh visit');
-- a later max_occurrences counts the same way
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.lives($$select public.update_job_series(tests.fx('ser2'), '{"max_occurrences": 8}')$$, 'raise the limit to 8');
select tests.as_superuser();
select tests.eq((select count(*) from public.jobs where series_id = tests.fx('ser2')), 8::bigint, 'eight visits');
select tests.eq((select array_agg((scheduled_start at time zone 'America/Chicago')::date - pg_temp.m0() order by series_seq)
                   from public.jobs where series_id = tests.fx('ser2')), array[0, 9, 16, 23, 30, 35, 37, 44],
                'the two new visits follow the kept Monday on Wednesdays');
select tests.eq(pg_temp.ordinal_gaps(tests.fx('ser2')), 0::bigint, 'numbers follow the date order');

-- a kept visit ON a date of the new rule counts once (Mon -> Mon + Wed, max 6)
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('ser2b', (public.create_job_series(tests.fx('shop_a'), pg_temp.weekly('{"max_occurrences": 6}')) ->> 'series_id')::uuid);
update public.jobs set status = 'confirmed' where series_id = tests.fx('ser2b') and series_seq = 3;
select tests.lives($$select public.update_job_series(tests.fx('ser2b'), '{"by_weekday": [1, 3]}', pg_temp.occ(tests.fx('ser2b'), 2))$$,
                   'Monday -> Monday + Wednesday from visit 2');
select tests.as_superuser();
select tests.eq((select count(*) from public.jobs where series_id = tests.fx('ser2b')), 6::bigint, 'exactly six visits');
select tests.eq((select array_agg((scheduled_start at time zone 'America/Chicago')::date - pg_temp.m0() order by series_seq)
                   from public.jobs where series_id = tests.fx('ser2b')), array[0, 7, 9, 14, 16, 21],
                'visit 1, then Mondays and Wednesdays (the kept Monday is one of them)');
select tests.eq((select held_dates from public.job_series where id = tests.fx('ser2b')), '{}'::date[],
                'nothing held: the kept Monday is on the new rule');

-- ============================================================ #3 in place: the texted link and the reminder log survive
select tests.as_superuser();
update public.booking_settings set enabled = true where shop_id = tests.fx('shop_a');
insert into public.platform_config (key, value) values ('app_base_url', 'https://app.example.test')
  on conflict (key) do update set value = excluded.value;
insert into public.shop_sms_numbers (phone_number, shop_id) values ('+12055550100', tests.fx('shop_a'));
update public.shops set sms_from_number = '+12055550100' where id = tests.fx('shop_a');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('ser3', (public.create_job_series(tests.fx('shop_a'), pg_temp.weekly()) ->> 'series_id')::uuid);
select tests.as_superuser();
select tests.fx_set('occ1', pg_temp.occ(tests.fx('ser3'), 1));
create temp table t_old as select id, number, public_token, scheduled_start from public.jobs where id = tests.fx('occ1');
grant select on t_old to authenticated, service_role, anon;
select tests.as_service();
select tests.ok(public.enqueue_due_automations((select scheduled_start - interval '24 hours' from t_old)) > 0,
                'reminder queued for occurrence 1');
select tests.as_superuser();
update public.messages set status = 'sent', sent_at = (select scheduled_start - interval '24 hours' from t_old)
 where job_id = tests.fx('occ1') and template_key = 'appointment_reminder';
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(public.update_job_series(tests.fx('ser3'), '{"notes": "gate code 1234"}', tests.fx('occ1')) ->> 'deleted', '0',
                'a notes-only series edit deletes nothing');
select tests.as_anon();
select tests.lives(format('select public.public_get_booking(%L::uuid)', (select public_token from t_old)),
                   'the booking link already texted for occurrence 1 still opens');
select tests.as_service();
select tests.eq(public.enqueue_due_automations((select scheduled_start - interval '23 hours' from t_old)), 0,
                'no second reminder for the same appointment after a notes-only series edit');
select tests.as_superuser();
select tests.ok((select j.number = o.number and j.notes = 'gate code 1234' from public.jobs j join t_old o on o.id = j.id),
                'the same job (same number) carries the new notes');
-- a time change keeps the job as well (it is simply rescheduled)
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(public.update_job_series(tests.fx('ser3'), '{"local_start": "10:00"}', tests.fx('occ1')) ->> 'deleted', '0',
                'a new start time deletes nothing');
select tests.as_superuser();
select tests.ok((select public_token = (select public_token from t_old)
                        and to_char(scheduled_start at time zone 'America/Chicago', 'HH24:MI') = '10:00'
                   from public.jobs where id = tests.fx('occ1')), 'the same job, link unchanged, moved to 10:00');
select tests.ok((select bool_and(to_char(scheduled_start at time zone 'America/Chicago', 'HH24:MI') = '10:00'
                                 and scheduled_end - scheduled_start = interval '120 minutes')
                   from public.jobs where series_id = tests.fx('ser3')),
                'every visit at 10:00 local (DST or not), for the series'' duration');
select tests.eq((select count(*) from public.jobs where series_id = tests.fx('ser3') and series_detached), 0::bigint,
                'the series'' own in-place writes detach nothing');
-- a rule change keeps the visits the new rule also produces
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.lives($$select public.update_job_series(tests.fx('ser3'), '{"by_weekday": [1, 4]}', tests.fx('occ1'))$$,
                   'Monday -> Monday + Thursday');
select tests.as_superuser();
select tests.ok(exists (select 1 from public.jobs j join t_old o on o.public_token = j.public_token
                         where j.series_id = tests.fx('ser3')), 'the first Monday''s link survives a rule change that keeps its date');

-- in-place edits announce like bulk generation: once, not per visit
-- (the job_rescheduled / job_assigned notifications are comms 0080-0082)
\if :has_comms
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('ser3n', (public.create_job_series(tests.fx('shop_a'), pg_temp.weekly(jsonb_build_object(
          'max_occurrences', 6, 'assignee_member_ids', jsonb_build_array(tests.fx('m_tech_a'))))) ->> 'series_id')::uuid);
select tests.eq((public.update_job_series(tests.fx('ser3n'), '{"local_start": "11:00"}') ->> 'changed')::integer, 6,
                'six visits moved to 11:00 in place');
select tests.as_superuser();
select tests.eq((select count(*) from public.notifications n join public.jobs j on j.id = n.job_id
                  where j.series_id = tests.fx('ser3n') and n.kind = 'job_rescheduled'
                    and n.user_id = tests.fx('u_tech_a')), 1::bigint,
                'the assigned technician is told once, not once per visit');
select tests.eq((select current_setting('detailcrm.series_bulk_edit', true)), '', 'the bulk-edit marker is cleared afterwards');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.lives($$select public.update_job_series(tests.fx('ser3n'),
                       jsonb_build_object('assignee_member_ids', jsonb_build_array(tests.fx('m_tech_a'), tests.fx('m_tech2_a'))))$$,
                   'add a second technician to every visit');
select tests.as_superuser();
select tests.eq((select count(*) from public.job_assignments ja join public.jobs j on j.id = ja.job_id
                  where j.series_id = tests.fx('ser3n') and ja.member_id = tests.fx('m_tech2_a')), 6::bigint,
                'every visit gets the second technician in place');
select tests.eq((select count(*) from public.notifications n join public.jobs j on j.id = n.job_id
                  where j.series_id = tests.fx('ser3n') and n.kind = 'job_assigned'
                    and n.user_id = tests.fx('u_tech2_a')), 1::bigint, 'the new technician is told once');
-- a single visit moved by hand is still announced
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.jobs set scheduled_start = scheduled_start + interval '1 hour', scheduled_end = scheduled_end + interval '1 hour'
 where id = pg_temp.occ(tests.fx('ser3n'), 3);
select tests.as_superuser();
select tests.eq((select count(*) from public.notifications n where n.job_id = pg_temp.occ(tests.fx('ser3n'), 3)
                   and n.kind = 'job_rescheduled' and n.user_id = tests.fx('u_tech_a')), 1::bigint,
                'a visit moved on its own still notifies its technician');
\endif

-- ============================================================ #4 "this job only" edits detach the visit
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('ser4', (public.create_job_series(tests.fx('shop_a'), pg_temp.weekly()) ->> 'series_id')::uuid);
select tests.fx_set('o4_2', pg_temp.occ(tests.fx('ser4'), 2));
select tests.fx_set('o4_3', pg_temp.occ(tests.fx('ser4'), 3));
select tests.fx_set('o4_4', pg_temp.occ(tests.fx('ser4'), 4));
select tests.fx_set('o4_5', pg_temp.occ(tests.fx('ser4'), 5));
select tests.fx_set('o4_6', pg_temp.occ(tests.fx('ser4'), 6));
select tests.fx_set('o4_7', pg_temp.occ(tests.fx('ser4'), 7));
select tests.fx_set('o4_8', pg_temp.occ(tests.fx('ser4'), 8));
-- visit 3: an extra (and a note) for this visit only
insert into public.job_line_items (shop_id, job_id, name, quantity, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('o4_3'), 'Pet hair removal', 1, 4500);
select tests.ok((select series_detached from public.jobs where id = tests.fx('o4_3')), 'adding a line detaches the visit');
update public.jobs set notes = 'Customer asked for pet hair removal this time' where id = tests.fx('o4_3');
-- visit 2: its line repriced; visit 4: its line removed
update public.job_line_items set unit_price_cents = 15000 where job_id = tests.fx('o4_2');
select tests.ok((select series_detached from public.jobs where id = tests.fx('o4_2')), 'repricing a line detaches the visit');
delete from public.job_line_items where job_id = tests.fx('o4_4');
select tests.ok((select series_detached from public.jobs where id = tests.fx('o4_4')), 'removing a line detaches the visit');
-- visit 5: a manual discount; visit 6: an extra assignee
update public.jobs set discount_kind = 'fixed', discount_value = 2500 where id = tests.fx('o4_5');
select tests.ok((select series_detached from public.jobs where id = tests.fx('o4_5')), 'a manual discount detaches the visit');
insert into public.job_assignments (shop_id, job_id, member_id) values (tests.fx('shop_a'), tests.fx('o4_6'), tests.fx('m_tech_a'));
select tests.ok((select series_detached from public.jobs where id = tests.fx('o4_6')), 'changing the assignees detaches the visit');
-- visit 7: the assigned technician leaves an internal note
insert into public.job_assignments (shop_id, job_id, member_id) values (tests.fx('shop_a'), tests.fx('o4_7'), tests.fx('m_tech_a'));
select tests.as_superuser();
update public.jobs set series_detached = false where id = tests.fx('o4_7');   -- (reset: only the note is under test)
select tests.authenticate_as(tests.fx('u_tech_a'));
update public.jobs set internal_notes = 'Dog in the yard' where id = tests.fx('o4_7');
select tests.as_superuser();
select tests.eq((select internal_notes from public.jobs where id = tests.fx('o4_7')), 'Dog in the yard', 'the technician''s note is saved');
select tests.ok((select not series_detached from public.jobs where id = tests.fx('o4_7')),
                'a technician''s internal note does not detach the visit (technicians cannot change the schedule)');
select tests.ok((select not series_detached from public.jobs where id = tests.fx('o4_8')), 'visit 8 is untouched');
-- later: an unrelated series-wide change from visit 1 on
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq((public.update_job_series(tests.fx('ser4'), jsonb_build_object('assignee_member_ids', jsonb_build_array(tests.fx('m_tech_a'))),
                                          pg_temp.occ(tests.fx('ser4'), 1)) ->> 'kept')::integer, 5,
                'the five visits edited on their own are kept');
select tests.as_superuser();
select tests.ok(exists (select 1 from public.job_line_items li join public.jobs j on j.id = li.job_id
                         where j.series_id = tests.fx('ser4') and j.series_seq = 3 and li.name = 'Pet hair removal'
                           and li.unit_price_cents = 4500),
                'the extra added to visit 3 alone survives a later series edit, with its price');
select tests.eq((select notes from public.jobs where id = tests.fx('o4_3')), 'Customer asked for pet hair removal this time',
                '... and so does its note');
select tests.eq((select unit_price_cents from public.job_line_items where job_id = tests.fx('o4_2')), 15000::bigint,
                'the repriced line keeps its price');
select tests.eq((select count(*) from public.job_line_items where job_id = tests.fx('o4_4')), 0::bigint, 'the removed line stays removed');
select tests.ok((select discount_kind = 'fixed' and discount_value = 2500 from public.jobs where id = tests.fx('o4_5')),
                'the manual discount stays');
select tests.eq((select internal_notes from public.jobs where id = tests.fx('o4_7')), 'Dog in the yard',
                'the technician''s note stays through the in-place series edit');
select tests.ok((select not series_detached from public.jobs where id = tests.fx('o4_7'))
                and exists (select 1 from public.job_assignments where job_id = tests.fx('o4_7') and member_id = tests.fx('m_tech_a')),
                '... and the noted visit took the series edit in place');
select tests.ok((select count(*) = 1 from public.job_assignments where job_id = tests.fx('o4_8') and member_id = tests.fx('m_tech_a')),
                'an untouched visit gets the new assignee (in place)');
select tests.ok((select not series_detached from public.jobs where id = tests.fx('o4_8')), '... and stays attached');
-- the series RPCs' writes are not "this job only" edits
select tests.eq((select count(*) from public.jobs where series_id = tests.fx('ser4') and series_detached), 5::bigint,
                'only the five visits edited on their own are detached');

-- ============================================================ #5 end_job_series never lengthens a series
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('ser5', (public.create_job_series(tests.fx('shop_a'), pg_temp.weekly(jsonb_build_object(
          'until_date', (pg_temp.m0() + 21)::text))) ->> 'series_id')::uuid);
select tests.eq((select count(*) from public.jobs where series_id = tests.fx('ser5')), 4::bigint, '4 visits');
select tests.eq(public.end_job_series(tests.fx('ser5'), pg_temp.m0() + 60), '{"deleted": 0, "kept": 0}'::jsonb,
                'ending after a date past the end changes nothing');
select tests.as_service();
select tests.lives($$select public.generate_series_jobs()$$, 'the cron runs');
select tests.as_superuser();
select tests.eq((select until_date from public.job_series where id = tests.fx('ser5')), pg_temp.m0() + 21,
                'ending a series never moves its end date later');
select tests.eq((select count(*) from public.jobs where series_id = tests.fx('ser5')), 4::bigint,
                'ending a series never creates more visits');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(public.end_job_series(tests.fx('ser5'), pg_temp.m0() + 8), '{"deleted": 2, "kept": 0}'::jsonb,
                'an earlier date still shortens it');
select tests.as_superuser();
select tests.ok((select until_date = pg_temp.m0() + 8 and active from public.job_series where id = tests.fx('ser5')),
                'until_date moves earlier; still active until then');
-- a series without an end gets one
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('ser5b', (public.create_job_series(tests.fx('shop_a'), pg_temp.weekly()) ->> 'series_id')::uuid);
select tests.lives($$select public.end_job_series(tests.fx('ser5b'), pg_temp.m0() + 60)$$, 'end an open-ended series');
select tests.as_service();
select tests.lives($$select public.generate_series_jobs(now() + interval '200 days')$$, 'the cron runs later');
select tests.as_superuser();
select tests.eq((select count(*) from public.jobs where series_id = tests.fx('ser5b')
                   and (scheduled_start at time zone 'America/Chicago')::date > pg_temp.m0() + 60), 0::bigint,
                'no visit after the end');

-- ============================================================ roles and shops
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$select public.update_job_series(tests.fx('ser1'), '{"notes": "x"}')$$, '42501', 'a technician cannot edit');
select tests.throws($$select public.end_job_series(tests.fx('ser5b'), current_date)$$, '42501', 'a technician cannot end');
select tests.throws($$select * from public.job_series_lock_occurrence(pg_temp.occ(tests.fx('ser1'), 5), tests.fx('ser1'), now())$$,
                    '42501', 'the internal lock helper is not callable by technicians');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$select public.job_series_update_occurrence(null::public.job_series, pg_temp.occ(tests.fx('ser1'), 5),
                                                                 current_date, 'UTC', now(), true, true, null)$$,
                    '42501', 'the in-place updater is not callable by managers');
select tests.throws($$select public.job_series_write_lines(null::public.job_series, pg_temp.occ(tests.fx('ser1'), 5), '{}')$$,
                    '42501', 'the line writer is not callable by managers');
select tests.throws($$select public.job_series_write_assignees(null::public.job_series, pg_temp.occ(tests.fx('ser1'), 5))$$,
                    '42501', 'the assignee writer is not callable by managers');
select tests.throws($$select public.jobs_series_detach_on_child_edit()$$, '42501', 'the trigger function is not callable');
select tests.as_anon();
select tests.throws($$select * from public.job_series_lock_occurrence(gen_random_uuid(), gen_random_uuid(), now())$$, '42501',
                    'anon cannot call the lock helper');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.throws($$select public.update_job_series(tests.fx('ser2'), '{"by_weekday": [2]}')$$, 'P0002',
                    'another shop''s manager cannot see the series');
select tests.throws($$select public.end_job_series(tests.fx('ser2'), current_date)$$, 'P0002', '... nor end it');
select tests.as_superuser();
select tests.eq((select count(*) from public.jobs where series_id = tests.fx('ser2')), 8::bigint, 'the denied attempts changed nothing');
-- shop B: its own series, its own detach rule, untouched by shop A's edits
insert into public.service_prices (shop_id, service_id, price_cents) values (tests.fx('shop_b'), tests.fx('svc_b'), 5000);
select tests.authenticate_as(tests.fx('u_owner_b'));
select tests.fx_set('ser_b', (public.create_job_series(tests.fx('shop_b'), jsonb_build_object(
          'customer_id', tests.fx('cust_b'), 'freq', 'week', 'local_start', '09:00', 'start_date', pg_temp.m0()::text,
          'template_lines', jsonb_build_array(jsonb_build_object('service_id', tests.fx('svc_b'))))) ->> 'series_id')::uuid);
update public.jobs set notes = 'B only' where id = pg_temp.occ(tests.fx('ser_b'), 2);
select tests.ok((select series_detached from public.jobs where id = pg_temp.occ(tests.fx('ser_b'), 2)), 'shop B''s visit edit detaches it');
select tests.eq(public.update_job_series(tests.fx('ser_b'), '{"notes": "B series"}', pg_temp.occ(tests.fx('ser_b'), 1)) ->> 'kept', '1',
                'shop B''s series edit keeps its detached visit');
select tests.as_superuser();
select tests.eq((select count(*) from public.jobs where shop_id = tests.fx('shop_b') and series_id is not null
                   and series_id <> tests.fx('ser_b')), 0::bigint, 'shop B holds no occurrence of shop A''s series');
select tests.eq((select count(*) from public.jobs where shop_id = tests.fx('shop_a') and series_id = tests.fx('ser_b')), 0::bigint,
                'shop A holds none of shop B''s');
