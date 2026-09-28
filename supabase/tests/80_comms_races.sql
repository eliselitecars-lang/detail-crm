-- 80 comms: concurrency (two real sessions through dblink).
--   lead_limit      two submissions of the same email to a lead form that
--                   already has two in 24 hours: the second waits on the
--                   form's lock, then hits the limit (PT429) — never 4
--   followup_limit  two managers add the 4th and 5th follow-up of a service
--                   and channel at once: the second waits on the service
--                   lock, then is refused (23514) — never 5
--   import_dup      two imports of the same new email at once: the second
--                   waits for the first, then matches the customer it
--                   created (one customer, not two)
-- (The worker queues — claim_push_batch, claim_webhook_deliveries,
-- enqueue_document_followups — are global, so they are not raced here: a
-- committed claim would settle other shops' rows on a shared database.
-- Their single-session exactly-once behaviour is covered by 80_push,
-- 80_webhooks and 80_document_followups.)
-- Other sessions only see committed rows, so this file commits a private
-- shop (random slug / emails) through its own connection and deletes it
-- again BEFORE asserting. dblink without a password needs a superuser: on a
-- non-superuser connection the file is skipped.
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

create function pg_temp.who(p_who text) returns text language sql as $$
  select case p_who when 'service' then 'select tests.as_service()::text'
                    when 'anon' then 'select tests.as_anon()::text'
                    else format('select tests.authenticate_as(%L)::text', p_who) end
$$;

-- p_first runs in c1 (as p_who1) and stays uncommitted; p_second is sent on
-- c2 (as p_who2) and must block; then c1 commits.
create function pg_temp.run_race(p_key text, p_first text, p_second text, p_who1 text, p_who2 text)
returns void language plpgsql as $$
declare
  v_pid integer;
begin
  perform extensions.dblink_exec('cr_c1', 'begin');
  perform pg_temp.q('cr_c1', pg_temp.who(p_who1));
  insert into race values (p_key || '_first', pg_temp.q('cr_c1', p_first));
  perform extensions.dblink_exec('cr_c2', 'begin');
  perform pg_temp.q('cr_c2', pg_temp.who(p_who2));
  v_pid := pg_temp.q('cr_c2', 'select pg_backend_pid()::text')::integer;
  perform extensions.dblink_send_query('cr_c2', p_second);
  insert into race values (p_key || '_blocked', pg_temp.wait_blocked('cr_c2', v_pid)::text);
  perform extensions.dblink_exec('cr_c1', 'commit');
  insert into race values (p_key, pg_temp.result('cr_c2'));
  perform extensions.dblink_exec('cr_c2', 'commit');
end $$;

do $race$
declare
  c_conn constant text := format('host=%s port=%s dbname=%s user=%s',
                                 split_part(current_setting('unix_socket_directories'), ',', 1),
                                 current_setting('port'), current_database(), current_user);
  v_sfx     text := substr(md5(random()::text || clock_timestamp()::text), 1, 12);
  v_slug    text := 'crace-' || v_sfx;
  v_owner   text;
  v_mgr     text;
  v_uid     uuid;
  v_mgr_uid uuid;
  v_shop    uuid;
  v_svc     uuid;
  v_tok     uuid;
  v_state   text;
  v_msg     text;
begin
  v_owner := 'crace-owner-' || v_sfx || '@test.local';
  v_mgr := 'crace-mgr-' || v_sfx || '@test.local';
  perform extensions.dblink_connect('cr_setup', c_conn);
  perform extensions.dblink_connect('cr_c1', c_conn);
  perform extensions.dblink_connect('cr_c2', c_conn);
  perform extensions.dblink_exec('cr_c1', 'set lock_timeout = ''30s''');
  perform extensions.dblink_exec('cr_c2', 'set lock_timeout = ''30s''');

  begin
    v_shop := pg_temp.q('cr_setup', format('select tests.make_shop(%L, %L, %L)::text', v_owner, v_slug, 'CRace'));
    v_uid := pg_temp.q('cr_setup', format('select tests.user_id(%L)::text', v_owner));
    perform pg_temp.q('cr_setup', format('select tests.add_member(%L, %L, ''manager'')::text', v_shop, v_mgr));
    v_mgr_uid := pg_temp.q('cr_setup', format('select tests.user_id(%L)::text', v_mgr));
    v_svc := pg_temp.q('cr_setup', format(
      'insert into public.services (shop_id, name, duration_minutes) values (%L, ''Coating'', 240) returning id::text', v_shop));
    v_tok := pg_temp.q('cr_setup', format(
      'insert into public.lead_forms (shop_id, name, notify_staff) values (%L, ''Race form'', false) returning token::text', v_shop));

    -- ---------------------------------------------------------------- lead form limit
    perform pg_temp.q('cr_setup', format(
      'select tests.as_anon();
       select count(public.public_submit_lead(%1$L, jsonb_build_object(''first_name'', ''Ann'', ''email'', ''ann-%2$s@example.com'')))::text
         from generate_series(1, 2)', v_tok, v_sfx));
    perform pg_temp.run_race('lead_limit',
      format('select public.public_submit_lead(%L, jsonb_build_object(''first_name'', ''Ann'', ''email'', ''ann-%s@example.com'')) ->> ''ok''',
             v_tok, v_sfx),
      format('select public.public_submit_lead(%L, jsonb_build_object(''first_name'', ''Ann'', ''email'', ''ANN-%s@example.com'')) ->> ''ok''',
             v_tok, v_sfx),
      'anon', 'anon');
    insert into race values ('lead_count', pg_temp.q('cr_setup', format(
      'select count(*)::text from public.lead_submissions where shop_id = %L', v_shop)));

    -- ---------------------------------------------------------------- follow-up limit
    perform pg_temp.q('cr_setup', format(
      'insert into public.service_followups (shop_id, service_id, channel, offset_days, body)
       select %L, %L, ''sms'', d, ''Follow-up '' || d from unnest(array[30, 60, 90]) d returning 1::text', v_shop, v_svc));
    perform pg_temp.run_race('followup_limit',
      format('insert into public.service_followups (shop_id, service_id, channel, offset_days, body)
              values (%L, %L, ''sms'', 120, ''Fourth'') returning offset_days::text', v_shop, v_svc),
      format('insert into public.service_followups (shop_id, service_id, channel, offset_days, body)
              values (%L, %L, ''sms'', 150, ''Fifth'') returning offset_days::text', v_shop, v_svc),
      v_mgr_uid::text, v_uid::text);
    insert into race values ('followup_count', pg_temp.q('cr_setup', format(
      'select count(*)::text from public.service_followups where shop_id = %L and service_id = %L', v_shop, v_svc)));

    -- ---------------------------------------------------------------- imports of the same new email
    perform pg_temp.run_race('import_dup',
      format('select public.import_customers(%L, ''[{"first_name": "Zoe", "email": "zoe-%s@example.com"}]'', false) -> ''rows'' -> 0 ->> ''action''',
             v_shop, v_sfx),
      format('select public.import_customers(%L, ''[{"first_name": "Zoe", "last_name": "Z", "email": "ZOE-%s@example.com"}]'', false) -> ''rows'' -> 0 ->> ''action''',
             v_shop, v_sfx),
      v_mgr_uid::text, v_uid::text);
    insert into race values ('import_count', pg_temp.q('cr_setup', format(
      'select count(*)::text || ''/'' || max(last_name) from public.customers where shop_id = %L and first_name = ''Zoe''', v_shop)));
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
    insert into race values ('scenario_error', v_state || ': ' || v_msg);
  end;

  -- ---------------------------------------------------------------- cleanup (always)
  perform pg_temp.end_txn('cr_c1');
  perform pg_temp.end_txn('cr_c2');
  if v_shop is not null then
    perform extensions.dblink_exec('cr_setup', format('delete from public.shops where id = %L', v_shop));
    perform extensions.dblink_exec('cr_setup', format('delete from public.storage_purge_requests where shop_id = %L', v_shop));
  end if;
  perform extensions.dblink_exec('cr_setup', format('delete from auth.users where email in (%L, %L)', v_owner, v_mgr));
  insert into race values ('leftovers', pg_temp.q('cr_setup', format(
    'select (select count(*) from public.shops where slug = %L) + (select count(*) from auth.users where email in (%L, %L))',
    v_slug, v_owner, v_mgr)));
  perform extensions.dblink_disconnect('cr_setup');
  perform extensions.dblink_disconnect('cr_c1');
  perform extensions.dblink_disconnect('cr_c2');
end
$race$;

select tests.eq((select val from race where key = 'scenario_error'), null, 'the race scenarios ran');
select tests.eq((select val from race where key = 'leftovers'), '0', 'the committed private shop was removed');

select tests.eq((select val from race where key = 'lead_limit_first'), 'true', 'the third submission goes through');
select tests.eq((select val from race where key = 'lead_limit_blocked'), 'true', 'the concurrent fourth waits on the form');
select tests.eq((select val from race where key = 'lead_limit'), 'err:PT429', 'then hits the limit');
select tests.eq((select val from race where key = 'lead_count'), '3', 'three submissions, never four');

select tests.eq((select val from race where key = 'followup_limit_first'), '120', 'the fourth follow-up is added');
select tests.eq((select val from race where key = 'followup_limit_blocked'), 'true', 'the concurrent fifth waits on the service');
select tests.eq((select val from race where key = 'followup_limit'), 'err:23514', 'then is refused');
select tests.eq((select val from race where key = 'followup_count'), '4', 'four, never five');

select tests.eq((select val from race where key = 'import_dup_first'), 'create', 'the first import creates the customer');
select tests.eq((select val from race where key = 'import_dup_blocked'), 'true', 'the concurrent import waits');
select tests.eq((select val from race where key = 'import_dup'), 'ok:update', 'then matches the new customer');
select tests.eq((select val from race where key = 'import_count'), '1/Z', 'one customer, completed by the second file');
\else
\echo SKIP (needs superuser): the dblink comms races were not run
select tests.ok(not :'is_superuser'::boolean, 'SKIP (needs superuser): the dblink comms races were not run');
\endif
