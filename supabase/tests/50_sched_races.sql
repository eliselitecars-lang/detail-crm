-- 50 sched: concurrency (two real sessions through dblink).
--   gen_gen     two generate_series_jobs runs at once: the second waits on the
--               series' advisory lock, then creates nothing (no duplicate
--               occurrences, no unique violation)
--   edit_gen    a "this and following" edit (uncommitted) and the cron: the
--               cron waits, then creates nothing
--   confirm_edit  an occurrence confirmed (uncommitted) while a "this and
--               following" edit runs: the edit waits for the row, re-checks it
--               and keeps the confirmed job
--   detach_end  an occurrence rescheduled through the API (detached,
--               uncommitted) while end_job_series runs: kept as well
--   geo_addr    a job's address corrected (uncommitted) while a phone stores
--               the point it geocoded for the old address: the RPC waits for
--               the row, then refuses the stale point (40001)
--   feed_feed   the same member rotating their calendar feed twice at once:
--               the second waits, then revokes the first (one live token, no
--               23505)
--   edit_delete a "this and following" edit that is already waiting for the
--               series row when a manager deletes one visit through the API:
--               the delete (job row, then jobs_zz_series_skip on the series
--               row) and the edit (job_series_for_edit: jobs, then the series
--               row) take the locks in the same order, so the delete waits
--               for the edit instead of deadlocking (40P01); the skipped visit
--               is recorded and never re-created
--   delete_edit the same visit deleted (uncommitted) before the edit starts:
--               the edit waits, then sees the skip
-- Other sessions only see committed rows, so this file commits a private
-- shop (random slug / emails) through its own connection and deletes it again
-- BEFORE asserting. The races connect through dblink without a password,
-- which only a superuser may do: on a non-superuser connection the file is
-- skipped.
select rolsuper as is_superuser from pg_roles where rolname = current_user \gset
\if :is_superuser
create extension if not exists dblink with schema extensions;

create temp table race (key text primary key, val text);

create function pg_temp.q(p_conn text, p_sql text) returns text language plpgsql as $$
declare v text;
begin
  select t.v into v from extensions.dblink(p_conn, p_sql) as t(v text);
  return v;
end $$;

create function pg_temp.wait_blocked(p_conn text, p_pid integer) returns boolean language plpgsql as $$
begin
  for i in 1 .. 2000 loop
    if exists (select 1 from pg_catalog.pg_locks l where l.pid = p_pid and not l.granted) then
      return true;
    end if;
    if extensions.dblink_is_busy(p_conn) = 0 then
      return false;
    end if;
    perform pg_catalog.pg_sleep(0.01);
  end loop;
  return false;
end $$;

create function pg_temp.result(p_conn text) returns text language plpgsql as $$
declare
  v text;
  v_state text;
begin
  begin
    select t.v into v from extensions.dblink_get_result(p_conn) as t(v text);
    v := 'ok:' || coalesce(v, '');
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate;
    v := 'err:' || v_state;
  end;
  begin
    perform * from extensions.dblink_get_result(p_conn, false) as t(v text);   -- drain
  exception when others then
    null;
  end;
  return v;
end $$;

create function pg_temp.end_txn(p_conn text) returns void language plpgsql as $$
begin
  perform extensions.dblink_exec(p_conn, 'rollback', false);
exception when others then
  null;
end $$;

-- commits, or rolls back a transaction a failed statement aborted
create function pg_temp.end_txn_commit(p_conn text) returns void language plpgsql as $$
begin
  perform extensions.dblink_exec(p_conn, 'commit', false);
exception when others then
  perform pg_temp.end_txn(p_conn);
end $$;

-- p_first runs in c1 (as p_uid1 when given) and stays uncommitted; p_second
-- is sent on c2 (as p_uid2 when given) and must block; then c1 commits.
create function pg_temp.run_race(p_key text, p_first text, p_second text, p_uid1 uuid default null, p_uid2 uuid default null)
returns void language plpgsql as $$
declare
  v_pid integer;
begin
  perform extensions.dblink_exec('sr_c1', 'begin');
  if p_uid1 is not null then
    perform pg_temp.q('sr_c1', format('select tests.authenticate_as(%L)::text', p_uid1));
  end if;
  insert into race values (p_key || '_first', pg_temp.q('sr_c1', p_first));
  perform extensions.dblink_exec('sr_c2', 'begin');
  if p_uid2 is not null then
    perform pg_temp.q('sr_c2', format('select tests.authenticate_as(%L)::text', p_uid2));
  end if;
  v_pid := pg_temp.q('sr_c2', 'select pg_backend_pid()::text')::integer;
  perform extensions.dblink_send_query('sr_c2', p_second);
  insert into race values (p_key || '_blocked', pg_temp.wait_blocked('sr_c2', v_pid)::text);
  perform extensions.dblink_exec('sr_c1', 'commit');
  insert into race values (p_key, pg_temp.result('sr_c2'));
  perform extensions.dblink_exec('sr_c2', 'commit');
end $$;

do $race$
declare
  c_conn constant text := format('host=%s port=%s dbname=%s user=%s',
                                 split_part(current_setting('unix_socket_directories'), ',', 1),
                                 current_setting('port'), current_database(), current_user);
  v_sfx    text := substr(md5(random()::text || clock_timestamp()::text), 1, 12);
  v_owner  text;
  v_uid    uuid;
  v_shop   uuid;
  v_cust   uuid;
  v_svc    uuid;
  v_series uuid;
  v_job2   uuid;
  v_job3   uuid;
  v_geo    uuid;
  v_series2 uuid;
  v_job5   uuid;
  v_job6   uuid;
  v_pid1   integer;
  v_pid2   integer;
  v_state  text;
  v_msg    text;
begin
  v_owner := 'srace-owner-' || v_sfx || '@test.local';
  perform extensions.dblink_connect('sr_setup', c_conn);
  perform extensions.dblink_connect('sr_c1', c_conn);
  perform extensions.dblink_connect('sr_c2', c_conn);
  perform extensions.dblink_exec('sr_c1', 'set lock_timeout = ''30s''');
  perform extensions.dblink_exec('sr_c2', 'set lock_timeout = ''30s''');

  begin
    v_shop := pg_temp.q('sr_setup', format('select tests.make_shop(%L, %L, %L)::text', v_owner, 'srace-' || v_sfx, 'SRace'));
    v_uid := pg_temp.q('sr_setup', format('select tests.user_id(%L)::text', v_owner));
    v_cust := pg_temp.q('sr_setup', format(
      'insert into public.customers (shop_id, first_name) values (%L, ''Ann'') returning id::text', v_shop));
    v_svc := pg_temp.q('sr_setup', format(
      'insert into public.services (shop_id, name, duration_minutes) values (%L, ''Wash'', 60) returning id::text', v_shop));
    perform pg_temp.q('sr_setup', format(
      'insert into public.service_prices (shop_id, service_id, price_cents) values (%L, %L, 5000) returning id::text', v_shop, v_svc));
    v_series := pg_temp.q('sr_setup', format(
      'insert into public.job_series (shop_id, customer_id, freq, by_weekday, start_date, local_start, duration_minutes, template_lines)
       values (%L, %L, ''week'', array[extract(dow from current_date + 1)::smallint], current_date + 1, ''09:00'', 60,
               jsonb_build_array(jsonb_build_object(''service_id'', %L, ''quantity'', 1)))
       returning id::text', v_shop, v_cust, v_svc));

    -- ---------------------------------------------------------------- cron vs cron
    perform pg_temp.run_race('gen_gen', 'select public.generate_series_jobs()::text', 'select public.generate_series_jobs()::text');
    insert into race values ('gen_gen_dupes', pg_temp.q('sr_setup', format(
      'select (count(*) - count(distinct series_seq))::text from public.jobs where series_id = %L', v_series)));
    insert into race values ('gen_gen_jobs', pg_temp.q('sr_setup', format(
      'select (count(*) > 10)::text from public.jobs where series_id = %L', v_series)));

    -- ---------------------------------------------------------------- an edit vs the cron
    perform pg_temp.run_race('edit_gen',
      format('select (public.update_job_series(%L, ''{"notes": "race"}'') ->> ''changed'')', v_series),
      'select public.generate_series_jobs()::text', v_uid, null);
    insert into race values ('edit_gen_dupes', pg_temp.q('sr_setup', format(
      'select (count(*) - count(distinct series_seq))::text from public.jobs where series_id = %L', v_series)));
    insert into race values ('edit_gen_notes', pg_temp.q('sr_setup', format(
      'select bool_and(notes = ''race'')::text from public.jobs where series_id = %L', v_series)));

    -- ---------------------------------------------------------------- a confirmation vs an edit
    v_job2 := pg_temp.q('sr_setup', format('select id::text from public.jobs where series_id = %L and series_seq = 2', v_series));
    perform pg_temp.run_race('confirm_edit',
      format('with x as (update public.jobs set status = ''confirmed'' where id = %L returning 1) select count(*)::text from x', v_job2),
      format('select (public.update_job_series(%L, ''{"notes": "after"}'') ->> ''kept'')', v_series), null, v_uid);
    insert into race values ('confirm_edit_job2', pg_temp.q('sr_setup', format(
      'select coalesce((select status::text || '':'' || series_seq::text || '':'' || coalesce(notes, '''')
                          from public.jobs where id = %L), ''deleted'')', v_job2)));
    insert into race values ('confirm_edit_dupes', pg_temp.q('sr_setup', format(
      'select (count(*) - count(distinct series_seq))::text from public.jobs where series_id = %L', v_series)));

    -- ---------------------------------------------------------------- a reschedule (detach) vs ending the series
    -- (the edits above updated occurrence 3 in place)
    v_job3 := pg_temp.q('sr_setup', format('select id::text from public.jobs where series_id = %L and series_seq = 3', v_series));
    perform pg_temp.run_race('detach_end',
      format('with x as (update public.jobs set scheduled_start = scheduled_start + interval ''1 hour'',
                                                scheduled_end = scheduled_end + interval ''1 hour''
                          where id = %L returning 1) select count(*)::text from x', v_job3),
      format('select public.end_job_series(%L, current_date)::text', v_series), v_uid, v_uid);
    insert into race values ('detach_end_job3', pg_temp.q('sr_setup', format(
      'select coalesce((select series_detached::text from public.jobs where id = %L and series_id = %L), ''deleted'')',
      v_job3, v_series)));
    insert into race values ('detach_end_left', pg_temp.q('sr_setup', format(
      'select string_agg(series_seq::text, '','' order by series_seq) from public.jobs where series_id = %L', v_series)));

    -- ---------------------------------------------------------------- an address correction vs a stale point
    v_geo := pg_temp.q('sr_setup', format(
      'insert into public.jobs (shop_id, customer_id, location_type, service_address_line1, service_city,
                                scheduled_start, scheduled_end)
       values (%L, %L, ''mobile'', ''9 Oak St'', ''Birmingham'', now() + interval ''2 days'', now() + interval ''2 days 1 hour'')
       returning id::text', v_shop, v_cust));
    perform pg_temp.run_race('geo_addr',
      format('with x as (update public.jobs set service_address_line1 = ''1200 Pine Ave'', service_city = ''Hoover''
                          where id = %L returning 1) select count(*)::text from x', v_geo),
      format('select public.set_job_coordinates(%L, 33.5186, -86.8104,
                 ''{"service_address_line1": "9 Oak St", "service_city": "Birmingham"}'')::text', v_geo),
      v_uid, v_uid);
    insert into race values ('geo_addr_point', pg_temp.q('sr_setup', format(
      'select coalesce(service_lat::text, ''none'') || '':'' || service_address_line1 from public.jobs where id = %L', v_geo)));

    -- ---------------------------------------------------------------- feed rotation vs feed rotation
    perform pg_temp.run_race('feed_feed',
      format('select public.create_calendar_feed(%L) ->> ''token''', v_shop),
      format('select public.create_calendar_feed(%L) ->> ''token''', v_shop), v_uid, v_uid);
    insert into race values ('feed_live', pg_temp.q('sr_setup', format(
      'select count(*)::text from public.calendar_feed_tokens where shop_id = %L and revoked_at is null', v_shop)));

    -- ---------------------------------------------------------------- a visit deleted while an edit runs
    perform extensions.dblink_exec('sr_setup', 'begin');
    perform pg_temp.q('sr_setup', format('select tests.authenticate_as(%L)::text', v_uid));
    v_series2 := pg_temp.q('sr_setup', format(
      'select public.create_job_series(%L, jsonb_build_object(''customer_id'', %L, ''freq'', ''week'',
         ''start_date'', (current_date + 2)::text, ''local_start'', ''09:00'',
         ''template_lines'', jsonb_build_array(jsonb_build_object(''service_id'', %L)))) ->> ''series_id''',
      v_shop, v_cust, v_svc));
    perform pg_temp.q('sr_setup', 'select tests.as_superuser()::text');
    perform extensions.dblink_exec('sr_setup', 'commit');
    v_job5 := pg_temp.q('sr_setup', format('select id::text from public.jobs where series_id = %L and series_seq = 5', v_series2));
    v_job6 := pg_temp.q('sr_setup', format('select id::text from public.jobs where series_id = %L and series_seq = 6', v_series2));
    -- a third session holds the series row (FOR SHARE) so the edit is queued
    -- on it first and the delete second, the interleaving that deadlocked
    perform extensions.dblink_exec('sr_setup', 'begin');
    perform pg_temp.q('sr_setup', format('select id::text from public.job_series where id = %L for share', v_series2));
    perform extensions.dblink_exec('sr_c1', 'begin');
    perform pg_temp.q('sr_c1', format('select tests.authenticate_as(%L)::text', v_uid));
    v_pid1 := pg_temp.q('sr_c1', 'select pg_backend_pid()::text')::integer;
    perform extensions.dblink_send_query('sr_c1', format(
      'select (public.update_job_series(%L, ''{"notes": "edited"}'') ->> ''changed'')', v_series2));
    insert into race values ('edit_delete_edit_blocked', pg_temp.wait_blocked('sr_c1', v_pid1)::text);
    perform extensions.dblink_exec('sr_c2', 'begin');
    perform pg_temp.q('sr_c2', format('select tests.authenticate_as(%L)::text', v_uid));
    v_pid2 := pg_temp.q('sr_c2', 'select pg_backend_pid()::text')::integer;
    perform extensions.dblink_send_query('sr_c2', format(
      'with x as (delete from public.jobs where id = %L returning 1) select count(*)::text from x', v_job5));
    insert into race values ('edit_delete_delete_blocked', pg_temp.wait_blocked('sr_c2', v_pid2)::text);
    perform extensions.dblink_exec('sr_setup', 'commit');
    insert into race values ('edit_delete_edit', pg_temp.result('sr_c1'));
    perform pg_temp.end_txn_commit('sr_c1');
    insert into race values ('edit_delete_delete', pg_temp.result('sr_c2'));
    perform pg_temp.end_txn_commit('sr_c2');
    insert into race values ('edit_delete_state', pg_temp.q('sr_setup', format(
      'select (select count(*) from public.jobs where id = %L)::text || '':''
              || (5 = any (js.skipped_seqs))::text || '':''
              || (select count(*) from public.jobs where series_id = js.id and series_seq = 5)::text || '':''
              || (select coalesce(notes, '''') from public.jobs where id = %L)
         from public.job_series js where js.id = %L', v_job5, v_job6, v_series2)));

    -- ---------------------------------------------------------------- a visit deleted before an edit starts
    perform pg_temp.run_race('delete_edit',
      format('with x as (delete from public.jobs where id = %L returning 1) select count(*)::text from x', v_job6),
      format('select (public.update_job_series(%L, ''{"notes": "again"}'') ->> ''changed'')', v_series2), v_uid, v_uid);
    insert into race values ('delete_edit_state', pg_temp.q('sr_setup', format(
      'select (6 = any (js.skipped_seqs) and 5 = any (js.skipped_seqs))::text || '':''
              || (select count(*) from public.jobs where series_id = js.id and series_seq in (5, 6))::text
         from public.job_series js where js.id = %L', v_series2)));
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
    insert into race values ('scenario_error', v_state || ': ' || v_msg);
  end;

  -- ---------------------------------------------------------------- cleanup (always)
  perform pg_temp.end_txn('sr_c1');
  perform pg_temp.end_txn('sr_c2');
  perform pg_temp.end_txn('sr_setup');
  if v_shop is not null then
    perform extensions.dblink_exec('sr_setup', format('delete from public.shops where id = %L', v_shop));
  end if;
  perform extensions.dblink_exec('sr_setup', format('delete from auth.users where email = %L', v_owner));
  insert into race values ('leftovers', pg_temp.q('sr_setup', format(
    'select (select count(*) from public.shops where slug = %L) + (select count(*) from auth.users where email = %L)',
    'srace-' || v_sfx, v_owner)));
  perform extensions.dblink_disconnect('sr_setup');
  perform extensions.dblink_disconnect('sr_c1');
  perform extensions.dblink_disconnect('sr_c2');
end
$race$;

select tests.eq((select val from race where key = 'scenario_error'), null, 'the race scenarios ran');
select tests.eq((select val from race where key = 'leftovers'), '0', 'the committed private shop was removed');

select tests.ok((select val::integer > 10 from race where key = 'gen_gen_first'), 'the first cron run generates the occurrences');
select tests.eq((select val from race where key = 'gen_gen_blocked'), 'true', 'a second run waits for the series lock');
select tests.eq((select val from race where key = 'gen_gen'), 'ok:0', 'then creates nothing');
select tests.eq((select val from race where key = 'gen_gen_dupes'), '0', 'no duplicate occurrence numbers');
select tests.eq((select val from race where key = 'gen_gen_jobs'), 'true', 'the occurrences exist once');

select tests.ok((select val::integer > 10 from race where key = 'edit_gen_first'), 'the edit updates the eligible occurrences in place');
select tests.eq((select val from race where key = 'edit_gen_blocked'), 'true', 'the cron waits for the uncommitted edit');
select tests.eq((select val from race where key = 'edit_gen'), 'ok:0', 'then creates nothing');
select tests.eq((select val from race where key = 'edit_gen_dupes'), '0', 'no duplicates after the edit');
select tests.eq((select val from race where key = 'edit_gen_notes'), 'true', 'every occurrence carries the edit');

select tests.eq((select val from race where key = 'confirm_edit_first'), '1', 'occurrence 2 confirmed (uncommitted)');
select tests.eq((select val from race where key = 'confirm_edit_blocked'), 'true', 'the edit waits for the confirmation');
select tests.eq((select val from race where key = 'confirm_edit'), 'ok:1', 'then counts it as kept');
select tests.eq((select val from race where key = 'confirm_edit_job2'), 'confirmed:2:race',
                'the confirmed occurrence survives, untouched by the edit');
select tests.eq((select val from race where key = 'confirm_edit_dupes'), '0', 'no duplicate occurrence numbers');
select tests.eq((select val from race where key = 'detach_end_first'), '1', 'occurrence 3 rescheduled (uncommitted)');
select tests.eq((select val from race where key = 'detach_end_blocked'), 'true', 'ending the series waits for the reschedule');
select tests.ok((select val like 'ok:%"kept": 2%' from race where key = 'detach_end'),
                'then keeps the confirmed and the detached occurrence');
select tests.eq((select val from race where key = 'detach_end_job3'), 'true', 'the detached occurrence survives');
select tests.eq((select val from race where key = 'detach_end_left'), '2,3', 'only the kept occurrences remain');

select tests.eq((select val from race where key = 'geo_addr_first'), '1', 'the address is corrected (uncommitted)');
select tests.eq((select val from race where key = 'geo_addr_blocked'), 'true',
                'storing a point waits for the address change on the job row');
select tests.eq((select val from race where key = 'geo_addr'), 'err:40001',
                'then refuses the point geocoded for the previous address');
select tests.eq((select val from race where key = 'geo_addr_point'), 'none:1200 Pine Ave',
                'the corrected job has no stale coordinates');

select tests.eq((select val from race where key = 'feed_feed_blocked'), 'true', 'a second rotation waits for the first');
select tests.ok((select val like 'ok:%' and val <> 'ok:' from race where key = 'feed_feed'), 'then succeeds (no unique violation)');
select tests.eq((select val from race where key = 'feed_live'), '1', 'one live feed token');

select tests.eq((select val from race where key = 'edit_delete_edit_blocked'), 'true', 'the edit waits for the series row');
select tests.eq((select val from race where key = 'edit_delete_delete_blocked'), 'true',
                'the visit''s delete waits for the edit (it holds the series'' jobs)');
select tests.ok((select val ~ '^ok:[0-9]+$' and val <> 'ok:0' from race where key = 'edit_delete_edit'),
                'the edit completes (no deadlock)');
select tests.eq((select val from race where key = 'edit_delete_delete'), 'ok:1',
                'deleting one visit while the series is being edited does not deadlock: it waits, then deletes');
select tests.eq((select val from race where key = 'edit_delete_state'), '0:true:0:edited',
                'the visit is gone, recorded as skipped, not re-created; the edit reached the other visits');
select tests.eq((select val from race where key = 'delete_edit_blocked'), 'true', 'an edit waits for an uncommitted visit delete');
select tests.ok((select val ~ '^ok:[0-9]+$' from race where key = 'delete_edit'), 'then completes');
select tests.eq((select val from race where key = 'delete_edit_state'), 'true:0',
                'both skips survive the edit (no lost update) and neither visit is re-created');
\else
\echo SKIP (needs superuser): the dblink scheduling races were not run
select tests.ok(not :'is_superuser'::boolean, 'SKIP (needs superuser): the dblink scheduling races were not run');
\endif
