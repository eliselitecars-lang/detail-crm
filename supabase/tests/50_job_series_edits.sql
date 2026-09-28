-- 50 sched: recurring series edits, hardening (0051) —
--   * a rule change ("this and following") keeps a kept occurrence's date:
--     its date gets no second job, the occurrences are renumbered in date
--     order (series_seq stays the visit's ordinal) and every other date of
--     the new rule is generated; eligible occurrences the new rule also
--     produces stay the same jobs; occurrences before the edit point's date
--     are never touched;
--   * rule defaults (by_weekday / month_day) of a re-anchored rule come from
--     the edited occurrence's date, not the original start;
--   * skipped visits (jobs staff deleted) are never re-created: not by the
--     cron, not by an edit without a rule change, and a skipped date stays
--     skipped after a rule change; the series RPCs' own deletes are not
--     skips; a detached occurrence's delete skips its number only;
--   * the cron and edits never generate occurrences that already started
--     (after an archived customer, unpriceable services or a past edit
--     point), while create_job_series may still back-fill history;
--   * occurrences left on a voided grouped invoice (invoice_jobs ON DELETE
--     RESTRICT) are kept by update / end / delete_job_series instead of
--     failing with 23503;
--   * roles and shops: API deletes by a manager record the skip through the
--     definer trigger, technicians / other shops cannot touch the series,
--     the internal remover is not callable by API roles, and deleting a
--     whole shop with series and skipped visits works.
-- The concurrent confirm / reschedule vs edit races live in 50_sched_races.
\ir fixtures/two_shops.psql
\ir fixtures/50_ranges.psql

select tests.as_superuser();
-- a Monday 14..20 days ahead (shop-local, America/Chicago)
create function pg_temp.m0() returns date language sql stable as $$
  select d from (select ((now() at time zone 'America/Chicago')::date + 14 + i) as d from generate_series(0, 6) i) x
   where extract(dow from d) = 1
$$;
create function pg_temp.local_today() returns date language sql stable as $$
  select (now() at time zone 'America/Chicago')::date
$$;
create function pg_temp.occ(p_series uuid, p_seq integer) returns uuid language sql stable as $$
  select id from public.jobs where series_id = p_series and series_seq = p_seq
$$;
create function pg_temp.on_day(p_series uuid, p_d date) returns bigint language sql stable as $$
  select count(*) from public.jobs
   where series_id = p_series and (scheduled_start at time zone 'America/Chicago')::date = p_d
$$;
create function pg_temp.weekly(p_start date, p_extra jsonb default '{}') returns jsonb language sql stable as $$
  select jsonb_build_object('customer_id', tests.fx('cust_a'), 'vehicle_id', tests.fx('veh_a'), 'freq', 'week',
                            'by_weekday', jsonb_build_array(extract(dow from p_start)::integer),
                            'local_start', '09:00', 'start_date', p_start::text,
                            'template_lines', jsonb_build_array(jsonb_build_object('service_id', tests.fx('svc_a')))) || p_extra
$$;
grant execute on function pg_temp.m0(), pg_temp.local_today(), pg_temp.occ(uuid, integer), pg_temp.on_day(uuid, date),
                          pg_temp.weekly(date, jsonb)
  to authenticated, service_role;

-- ============================================================ rule change keeps a kept occurrence's date (Mon -> Mon+Wed)
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('ser_mw', (public.create_job_series(tests.fx('shop_a'), pg_temp.weekly(pg_temp.m0())) ->> 'series_id')::uuid);
update public.jobs set status = 'confirmed' where id = pg_temp.occ(tests.fx('ser_mw'), 2);
select tests.fx_set('mw_kept', pg_temp.occ(tests.fx('ser_mw'), 2));
select tests.fx_set('mw_first', pg_temp.occ(tests.fx('ser_mw'), 1));
select tests.lives($$select public.update_job_series(tests.fx('ser_mw'), '{"by_weekday": [1, 3]}',
                                                     pg_temp.occ(tests.fx('ser_mw'), 1))$$,
                   'Monday -> Monday + Wednesday from occurrence 1');
select tests.eq(pg_temp.on_day(tests.fx('ser_mw'), pg_temp.m0() + 7), 1::bigint,
                'only the kept confirmed job on the 2nd Monday (no double booking)');
select tests.eq((select id from public.jobs where series_id = tests.fx('ser_mw')
                   and (scheduled_start at time zone 'America/Chicago')::date = pg_temp.m0() + 7),
                tests.fx('mw_kept'), '... and it is the same job, still confirmed');
select tests.eq((select series_seq from public.jobs where id = tests.fx('mw_kept')), 3,
                'the kept job takes its place in date order (Mon #1, Wed #2, Mon #3)');
select tests.eq(pg_temp.on_day(tests.fx('ser_mw'), pg_temp.m0() + 2), 1::bigint, 'the first Wednesday gets its occurrence');
select tests.eq(pg_temp.on_day(tests.fx('ser_mw'), pg_temp.m0()), 1::bigint, 'the edited Monday is still there');
select tests.eq(pg_temp.occ(tests.fx('ser_mw'), 1), tests.fx('mw_first'),
                '... as the same job (the new rule also produces its date: updated in place)');
select tests.eq(pg_temp.on_day(tests.fx('ser_mw'), pg_temp.m0() + 9), 1::bigint, 'the second Wednesday too');
select tests.ok((select seq_offset = 0 and start_date = pg_temp.m0() and held_dates = '{}'
                   from public.job_series where id = tests.fx('ser_mw')),
                'no visit before the edit point (seq_offset 0); the kept Monday is on the new rule (nothing held)');
select tests.eq((select count(*) from (select series_seq, row_number() over (order by scheduled_start) as rn
                                         from public.jobs where series_id = tests.fx('ser_mw')) x
                  where x.series_seq <> x.rn), 0::bigint, 'occurrence numbers follow the date order: 1, 2, 3, ...');
select tests.eq((select count(*) - count(distinct (scheduled_start at time zone 'America/Chicago')::date)
                   from public.jobs where series_id = tests.fx('ser_mw')), 0::bigint, 'never two occurrences on one day');
select tests.ok((select bool_and(extract(dow from scheduled_start at time zone 'America/Chicago') in (1, 3))
                   from public.jobs where series_id = tests.fx('ser_mw')), 'every occurrence on a Monday or a Wednesday');
-- a second rule change keeps the numbering above every number in use
select tests.lives($$select public.update_job_series(tests.fx('ser_mw'), '{"by_weekday": [1]}',
                                                     pg_temp.occ(tests.fx('ser_mw'), 3))$$, 'back to Mondays');
select tests.eq(pg_temp.on_day(tests.fx('ser_mw'), pg_temp.m0() + 7), 1::bigint, 'the kept Monday is still single');
select tests.eq(pg_temp.on_day(tests.fx('ser_mw'), pg_temp.m0() + 2), 1::bigint,
                'the Wednesday BEFORE the edit point (the kept Monday) is untouched');
select tests.eq((select count(*) from public.jobs where series_id = tests.fx('ser_mw') and scheduled_start > now()
                   and (scheduled_start at time zone 'America/Chicago')::date > pg_temp.m0() + 7
                   and extract(dow from scheduled_start at time zone 'America/Chicago') = 3), 0::bigint,
                'the Wednesday occurrences from the edit point on are gone');
select tests.ok((select seq_offset = 2 and start_date = pg_temp.m0() + 7 from public.job_series where id = tests.fx('ser_mw')),
                'two visits before the edit point (seq_offset 2)');
select tests.eq((select series_seq from public.jobs where id = tests.fx('mw_kept')), 3, 'the kept Monday is still #3');
select tests.eq((select count(*) - count(distinct series_seq) from public.jobs where series_id = tests.fx('ser_mw')), 0::bigint,
                'occurrence numbers stay unique');

-- ============================================================ re-anchored defaults come from the edited occurrence
-- weekly -> monthly from occurrence 3: month_day = occurrence 3's day
select tests.fx_set('ser_wm', (public.create_job_series(tests.fx('shop_a'), pg_temp.weekly(pg_temp.m0())) ->> 'series_id')::uuid);
select tests.lives($$select public.update_job_series(tests.fx('ser_wm'), '{"freq": "month"}', pg_temp.occ(tests.fx('ser_wm'), 3))$$,
                   'weekly -> monthly from occurrence 3');
select tests.eq((select to_char(scheduled_start at time zone 'America/Chicago', 'YYYY-MM-DD') from public.jobs
                  where series_id = tests.fx('ser_wm') and series_seq = 3),
                to_char(pg_temp.m0() + 14, 'YYYY-MM-DD'), 'the re-anchored monthly rule starts on the edited occurrence''s date');
select tests.ok((select month_mode = 'day_of_month' and month_day = extract(day from pg_temp.m0() + 14)
                        and by_weekday = '{}' and start_date = pg_temp.m0() + 14
                   from public.job_series where id = tests.fx('ser_wm')),
                'month_day defaults to the edited occurrence''s day, not the original start''s');
select tests.eq((select to_char(scheduled_start at time zone 'America/Chicago', 'YYYY-MM-DD') from public.jobs
                  where series_id = tests.fx('ser_wm') and series_seq = 4),
                to_char((pg_temp.m0() + 14 + interval '1 month')::date, 'YYYY-MM-DD'), 'then monthly on that day');
select tests.eq((select array_agg(series_seq order by series_seq) from public.jobs
                  where series_id = tests.fx('ser_wm') and series_seq <= 3), array[1, 2, 3],
                'occurrences before the edit point are untouched');
-- monthly -> weekly from occurrence 2: by_weekday = occurrence 2's weekday
select tests.fx_set('ser_mo', (public.create_job_series(tests.fx('shop_a'), pg_temp.weekly(pg_temp.m0(), '{"freq": "month", "by_weekday": null}'))
                               ->> 'series_id')::uuid);
create temp table mo_d2 as
  select (scheduled_start at time zone 'America/Chicago')::date as d from public.jobs
   where series_id = tests.fx('ser_mo') and series_seq = 2;
grant select on mo_d2 to authenticated;
select tests.lives($$select public.update_job_series(tests.fx('ser_mo'), '{"freq": "week"}', pg_temp.occ(tests.fx('ser_mo'), 2))$$,
                   'monthly -> weekly from occurrence 2');
select tests.eq((select by_weekday from public.job_series where id = tests.fx('ser_mo')),
                (select array[extract(dow from d)::smallint] from mo_d2), 'by_weekday defaults to occurrence 2''s weekday');
select tests.eq((select (scheduled_start at time zone 'America/Chicago')::date from public.jobs
                  where series_id = tests.fx('ser_mo') and series_seq = 2), (select d from mo_d2),
                'occurrence 2 keeps its date under the weekly rule');
select tests.eq((select (scheduled_start at time zone 'America/Chicago')::date from public.jobs
                  where series_id = tests.fx('ser_mo') and series_seq = 3), (select d + 7 from mo_d2), 'then every week');
-- an explicit field in the patch still wins
select tests.fx_set('ser_ex', (public.create_job_series(tests.fx('shop_a'), pg_temp.weekly(pg_temp.m0())) ->> 'series_id')::uuid);
select tests.lives($$select public.update_job_series(tests.fx('ser_ex'), '{"freq": "month", "month_day": 5}', pg_temp.occ(tests.fx('ser_ex'), 3))$$,
                   'weekly -> monthly on the 5th');
select tests.eq((select month_day from public.job_series where id = tests.fx('ser_ex')), 5::smallint, 'an explicit month_day is kept');

-- ============================================================ skipped visits are never re-created
select tests.fx_set('ser_sk', (public.create_job_series(tests.fx('shop_a'), pg_temp.weekly(pg_temp.m0())) ->> 'series_id')::uuid);
-- the manager deletes week 3 through the API (the definer trigger records the skip)
select tests.eq(tests.row_count($$delete from public.jobs where id = pg_temp.occ(tests.fx('ser_sk'), 3)$$), 1::bigint,
                'a manager deletes week 3 (API)');
select tests.ok((select skipped_seqs = '{3}' and skipped_dates = array[pg_temp.m0() + 14] from public.job_series
                  where id = tests.fx('ser_sk')), 'the skipped number and date are recorded');
select tests.lives($$select public.update_job_series(tests.fx('ser_sk'), '{"local_start": "10:00"}', pg_temp.occ(tests.fx('ser_sk'), 1))$$,
                   'move the series to 10:00 from occurrence 1');
select tests.eq(pg_temp.occ(tests.fx('ser_sk'), 3), null::uuid, 'a job staff deleted is never re-created by an edit');
select tests.eq(pg_temp.on_day(tests.fx('ser_sk'), pg_temp.m0() + 14), 0::bigint, '... nor on its date');
select tests.ok((select bool_and(to_char(scheduled_start at time zone 'America/Chicago', 'HH24:MI') = '10:00')
                   from public.jobs where series_id = tests.fx('ser_sk')), 'the other occurrences moved to 10:00');
select tests.eq((select skipped_seqs from public.job_series where id = tests.fx('ser_sk')), '{3}'::integer[],
                'the RPC''s own deletes are not recorded as skips');
select tests.as_service();
select tests.lives($$select public.generate_series_jobs(now() + interval '30 days')$$, 'cron run');
select tests.eq(pg_temp.occ(tests.fx('ser_sk'), 3), null::uuid, 'nor by the cron');
select tests.authenticate_as(tests.fx('u_manager_a'));
-- a rule change clears the old numbering's skips but keeps the skipped date
select tests.lives($$select public.update_job_series(tests.fx('ser_sk'), '{"by_weekday": [1, 4]}', pg_temp.occ(tests.fx('ser_sk'), 1))$$,
                   'Monday -> Monday + Thursday');
select tests.eq(pg_temp.on_day(tests.fx('ser_sk'), pg_temp.m0() + 14), 0::bigint, 'the skipped Monday stays skipped under the new rule');
select tests.eq(pg_temp.on_day(tests.fx('ser_sk'), pg_temp.m0() + 17), 1::bigint, 'that week''s Thursday is generated');
select tests.ok((select skipped_seqs = '{}' and skipped_dates = array[pg_temp.m0() + 14] from public.job_series
                  where id = tests.fx('ser_sk')), 'skipped numbers reset with the numbering, the date is kept');
-- a detached occurrence deleted: its number and its rule date are skipped
-- (not the day it was moved to)
update public.jobs set scheduled_start = scheduled_start + interval '1 day', scheduled_end = scheduled_end + interval '1 day'
 where id = (select id from public.jobs where series_id = tests.fx('ser_sk')
               and (scheduled_start at time zone 'America/Chicago')::date = pg_temp.m0() + 21);
select tests.fx_set('sk_det', (select id from public.jobs where series_id = tests.fx('ser_sk') and series_detached));
select tests.eq(tests.row_count($$delete from public.jobs where id = tests.fx('sk_det')$$), 1::bigint, 'delete the detached occurrence');
select tests.ok((select skipped_dates = array[pg_temp.m0() + 14, pg_temp.m0() + 21]
                        and cardinality(skipped_seqs) = 1
                   from public.job_series where id = tests.fx('ser_sk')),
                'a detached occurrence''s delete records its number and rule date, not the day it was moved to');
select tests.lives($$select public.update_job_series(tests.fx('ser_sk'), '{"notes": "gate"}', pg_temp.occ(tests.fx('ser_sk'),
                     (select min(series_seq) from public.jobs where series_id = tests.fx('ser_sk'))))$$, 'another edit');
select tests.eq(pg_temp.on_day(tests.fx('ser_sk'), pg_temp.m0() + 21), 0::bigint, 'the detached, deleted visit is not re-created');

-- ------------------------------------------------------------ roles and shops
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$delete from public.jobs where series_id = tests.fx('ser_sk')$$), 0::bigint,
                'technicians cannot delete occurrences (RLS)');
select tests.throws($$select public.job_series_remove_occurrence(pg_temp.occ(tests.fx('ser_sk'), 4), tests.fx('ser_sk'), now())$$,
                    '42501', 'the internal remover is not callable by technicians');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$select public.job_series_remove_occurrence(pg_temp.occ(tests.fx('ser_sk'), 4), tests.fx('ser_sk'), now())$$,
                    '42501', '... nor by managers');
select tests.throws($$select public.jobs_series_record_skip()$$, '42501', 'the trigger function is not callable');
select tests.authenticate_as(tests.fx('u_owner_b'));
select tests.eq(tests.row_count($$delete from public.jobs where series_id = tests.fx('ser_sk')$$), 0::bigint,
                'another shop deletes nothing');
select tests.throws($$select public.update_job_series(tests.fx('ser_sk'), '{"notes": "x"}')$$, 'P0002', 'another shop''s series is not found');
select tests.as_anon();
select tests.throws($$select public.job_series_remove_occurrence(gen_random_uuid(), gen_random_uuid(), now())$$, '42501',
                    'anon cannot call the remover');
select tests.as_superuser();
select tests.eq((select skipped_dates from public.job_series where id = tests.fx('ser_sk')),
                array[pg_temp.m0() + 14, pg_temp.m0() + 21], 'nothing changed by the denied attempts');

-- ============================================================ no past occurrences after a pause
select tests.as_superuser();
create function pg_temp.m1() returns date language sql stable as $$
  select d from (select ((now() at time zone 'America/Chicago')::date + 7 + i) as d from generate_series(0, 6) i) x
   where extract(dow from d) = 1
$$;
grant execute on function pg_temp.m1() to authenticated, service_role;
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('ser_p', (public.create_job_series(tests.fx('shop_a'), pg_temp.weekly(pg_temp.m1())) ->> 'series_id')::uuid);
-- archived customer: the cron skips the series and its horizon does not move
select tests.as_superuser();
update public.customers set archived_at = now() where id = tests.fx('cust_a');
select tests.as_service();
select tests.lives($$select public.generate_series_jobs(now() + interval '60 days')$$, 'cron while the customer is archived');
select tests.as_superuser();
update public.customers set archived_at = null where id = tests.fx('cust_a');
select tests.as_service();
select tests.lives($$select public.generate_series_jobs(now() + interval '200 days')$$, 'cron 200 days later');
select tests.eq((select count(*) from public.jobs where series_id = tests.fx('ser_p') and status = 'scheduled'
                   and scheduled_start > now() + interval '100 days' and scheduled_start <= now() + interval '200 days'),
                0::bigint, 'the cron never generates occurrences that are already in the past');
select tests.ok((select count(*) >= 12 from public.jobs where series_id = tests.fx('ser_p')
                   and scheduled_start > now() + interval '200 days'), 'it generates ahead of its clock');
select tests.ok((select generated_through >= pg_temp.local_today() + 290 from public.job_series where id = tests.fx('ser_p')),
                'the horizon is measured from the cron''s clock');
select tests.eq((select count(*) - count(distinct series_seq) from public.jobs where series_id = tests.fx('ser_p')), 0::bigint,
                'numbers stay unique across the gap');
-- a series whose only service was archived resumes without back-filling
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('ser_p2', (public.create_job_series(tests.fx('shop_a'), pg_temp.weekly(pg_temp.m1())) ->> 'series_id')::uuid);
select tests.as_superuser();
update public.services set archived_at = now() where id = tests.fx('svc_a');
select tests.as_service();
select tests.lives($$select public.generate_series_jobs(now() + interval '120 days')$$, 'cron with nothing priceable');
select tests.as_superuser();
update public.services set archived_at = null where id = tests.fx('svc_a');
select tests.as_service();
select tests.lives($$select public.generate_series_jobs(now() + interval '150 days')$$, 'cron after the service is back');
select tests.eq((select count(*) from public.jobs where series_id = tests.fx('ser_p2')
                   and scheduled_start > now() + interval '91 days' and scheduled_start <= now() + interval '150 days'),
                0::bigint, 'the skipped stretch is not back-filled');
-- an edit from a past occurrence (with a rule change) does not back-fill the past
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('ser_hist', (public.create_job_series(tests.fx('shop_a'),
          pg_temp.weekly(pg_temp.local_today() - 28 - extract(dow from pg_temp.local_today() - 28)::integer + 1)) ->> 'series_id')::uuid);
select tests.ok((select count(*) >= 4 from public.jobs where series_id = tests.fx('ser_hist') and scheduled_start < now()),
                'create_job_series may still back-fill history (first generation)');
create temp table hist_before as
  select id from public.jobs where series_id = tests.fx('ser_hist') and scheduled_start < now();
grant select on hist_before to authenticated;
select tests.lives($$select public.update_job_series(tests.fx('ser_hist'), '{"by_weekday": [1, 3]}', pg_temp.occ(tests.fx('ser_hist'), 1))$$,
                   'rule change from the first (past) occurrence');
select tests.eq((select count(*) from public.jobs where series_id = tests.fx('ser_hist') and scheduled_start < now()),
                (select count(*) from hist_before), 'no new past occurrence');
select tests.eq((select count(*) from public.jobs j join hist_before h on h.id = j.id), (select count(*) from hist_before),
                'the past occurrences are kept as they were');
select tests.ok((select count(*) > 0 from public.jobs where series_id = tests.fx('ser_hist') and scheduled_start > now()
                   and extract(dow from scheduled_start at time zone 'America/Chicago') = 3), 'future Wednesdays generated');

-- ============================================================ occurrences on a voided grouped invoice
-- (grouped invoices: money 0063)
\if :has_money
select tests.fx_set('ser_v', (public.create_job_series(tests.fx('shop_a'), pg_temp.weekly(pg_temp.local_today() + 7)) ->> 'series_id')::uuid);
select tests.fx_set('v_o2', pg_temp.occ(tests.fx('ser_v'), 2));
select tests.fx_set('v_o3', pg_temp.occ(tests.fx('ser_v'), 3));
select tests.fx_set('inv_v', (public.create_invoice_from_jobs(tests.fx('cust_a'), array[tests.fx('v_o2'), tests.fx('v_o3')])).id);
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.eq((public.void_invoice(tests.fx('inv_v'), 'billed by mistake')).status::text, 'void', 'the grouped invoice is voided');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq((public.update_job_series(tests.fx('ser_v'), '{"notes": "gate code 1234"}'::jsonb) ->> 'kept')::integer, 2,
                'a this-and-following edit works; the two occurrences on the voided invoice are kept');
select tests.ok((select count(*) = 2 from public.jobs where id in (tests.fx('v_o2'), tests.fx('v_o3')) and series_id = tests.fx('ser_v')),
                'they are the same jobs, still in the series');
select tests.ok((select bool_and(notes = 'gate code 1234') from public.jobs where series_id = tests.fx('ser_v')
                   and id not in (tests.fx('v_o2'), tests.fx('v_o3'))), 'the other occurrences got the edit');
select tests.eq((select count(*) from public.invoice_jobs where invoice_id = tests.fx('inv_v')), 2::bigint,
                'the voided invoice keeps its history');
create temp table v_later as
  select count(*) as n from public.jobs
   where series_id = tests.fx('ser_v') and (scheduled_start at time zone 'America/Chicago')::date > pg_temp.local_today() + 8;
grant select on v_later to authenticated;
select tests.eq(public.end_job_series(tests.fx('ser_v'), pg_temp.local_today() + 8),
                (select jsonb_build_object('deleted', n - 2, 'kept', 2) from v_later),
                'ending the series works (occurrences on the voided invoice are kept)');
select tests.eq(public.delete_job_series(tests.fx('ser_v')), '{"deleted": 1, "kept": 2}'::jsonb, 'deleting the series works');
select tests.ok((select count(*) = 2 from public.jobs where id in (tests.fx('v_o2'), tests.fx('v_o3')) and series_id is null),
                'the kept occurrences become ordinary jobs');
\endif

-- ============================================================ deleting a shop with series and skipped visits
select tests.as_superuser();
insert into public.service_prices (shop_id, service_id, price_cents) values (tests.fx('shop_b'), tests.fx('svc_b'), 5000);
select tests.authenticate_as(tests.fx('u_owner_b'));
select tests.fx_set('ser_b', (public.create_job_series(tests.fx('shop_b'), jsonb_build_object(
          'customer_id', tests.fx('cust_b'), 'freq', 'week', 'local_start', '09:00',
          'start_date', (pg_temp.local_today() + 7)::text,
          'template_lines', jsonb_build_array(jsonb_build_object('service_id', tests.fx('svc_b'))))) ->> 'series_id')::uuid);
select tests.eq(tests.row_count($$delete from public.jobs where id = pg_temp.occ(tests.fx('ser_b'), 2)$$), 1::bigint,
                'shop B skips a visit');
select tests.ok((select skipped_seqs = '{2}' from public.job_series where id = tests.fx('ser_b')), 'recorded on B''s series');
select tests.as_superuser();
select tests.eq((select cardinality(skipped_seqs) from public.job_series where id = tests.fx('ser_sk')), 1,
                'shop A''s series is not affected');
select tests.lives($$delete from public.shops where id = tests.fx('shop_b')$$, 'the shop (series, occurrences) can be deleted');
select tests.eq((select count(*) from public.job_series where id = tests.fx('ser_b')), 0::bigint, 'its series is gone');
