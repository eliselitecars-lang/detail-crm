-- 00 foundation: a vehicle's owner change racing a document that starts
-- referencing the vehicle (two real sessions through dblink).
-- Regression: vehicles_keep_owner_history and the documents' ownership
-- validators were plain reads, the documents' composite FK check takes only
-- FOR KEY SHARE on the vehicle and a customer_id change takes FOR NO KEY
-- UPDATE, which do not conflict: a job for Ann and a move of her vehicle to
-- Bob both committed without waiting, leaving Ann's job with Bob's car.
--   job_first    the job insert is uncommitted when the move starts: the
--                move waits, then is refused (23514)
--   move_first   the move is uncommitted when the job insert starts: the
--                insert waits, then is refused (23514)
--   line_first / quote_first / membership_first
--                the same for a job line, a quote and a membership
--   free         a vehicle nothing references still moves (no false wait)
-- The quote and membership races run when the money migrations are present
-- (the rest needs only 0001-0009).
-- Other sessions only see committed rows, so this file commits a private
-- shop (random slug / emails) through its own connection and deletes it again
-- BEFORE asserting; outcomes are captured in a temp table first. Each race
-- waits (bounded) until the second session is actually blocked on a lock
-- before the first one commits, so the interleaving is deterministic.
create extension if not exists dblink with schema extensions;

select (to_regclass('public.quotes') is not null and to_regclass('public.memberships') is not null) as with_money \gset

create temp table race (key text primary key, val text);

create function pg_temp.q(p_conn text, p_sql text) returns text language plpgsql as $$
declare v text;
begin
  select t.v into v from extensions.dblink(p_conn, p_sql) as t(v text);
  return v;
end $$;

-- true once the backend waits on a lock; false if its query finished first
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

-- 'ok:<value>' or 'err:<sqlstate>'
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

-- One race. p_first runs in c1 and stays uncommitted; p_second is sent on c2
-- and must block; then c1 commits and c2's outcome is recorded under p_key
-- (plus '<key>_blocked'). Both statements return one text value.
create function pg_temp.run_race(p_key text, p_first text, p_second text) returns void language plpgsql as $$
declare
  v_pid integer;
begin
  perform extensions.dblink_exec('vr_c1', 'begin');
  perform pg_temp.q('vr_c1', p_first);
  perform extensions.dblink_exec('vr_c2', 'begin');
  v_pid := pg_temp.q('vr_c2', 'select pg_backend_pid()::text')::integer;
  perform extensions.dblink_send_query('vr_c2', p_second);
  insert into race values (p_key || '_blocked', pg_temp.wait_blocked('vr_c2', v_pid)::text);
  perform extensions.dblink_exec('vr_c1', 'commit');
  insert into race values (p_key, pg_temp.result('vr_c2'));
  perform extensions.dblink_exec('vr_c2', 'commit');   -- an aborted txn: commit = rollback
end $$;

do $race$
declare
  c_conn constant text := format('host=%s port=%s dbname=%s user=%s',
                                 split_part(current_setting('unix_socket_directories'), ',', 1),
                                 current_setting('port'), current_database(), current_user);
  v_sfx   text := substr(md5(random()::text || clock_timestamp()::text), 1, 12);
  v_owner text;
  v_shop  uuid;
  v_ann   uuid;
  v_bob   uuid;
  v_veh   uuid;
  v_plan  uuid;
  v_job   uuid;
  v_state text;
  v_msg   text;
  v_money constant boolean := to_regclass('public.quotes') is not null and to_regclass('public.memberships') is not null;
begin
  v_owner := 'vrace-owner-' || v_sfx || '@test.local';
  perform extensions.dblink_connect('vr_setup', c_conn);
  perform extensions.dblink_connect('vr_c1', c_conn);
  perform extensions.dblink_connect('vr_c2', c_conn);
  perform extensions.dblink_exec('vr_c1', 'set lock_timeout = ''30s''');
  perform extensions.dblink_exec('vr_c2', 'set lock_timeout = ''30s''');

  begin
    v_shop := pg_temp.q('vr_setup', format('select tests.make_shop(%L, %L, %L)::text', v_owner, 'vrace-' || v_sfx, 'VRace'));
    v_ann := pg_temp.q('vr_setup', format(
      'insert into public.customers (shop_id, first_name) values (%L, ''Ann'') returning id::text', v_shop));
    v_bob := pg_temp.q('vr_setup', format(
      'insert into public.customers (shop_id, first_name) values (%L, ''Bob'') returning id::text', v_shop));
    v_job := pg_temp.q('vr_setup', format(
      'insert into public.jobs (shop_id, customer_id, status) values (%L, %L, ''requested'') returning id::text', v_shop, v_ann));

    -- ---------------------------------------------------------------- job insert first, then the move
    v_veh := pg_temp.q('vr_setup', format(
      'insert into public.vehicles (shop_id, customer_id, make, model) values (%L, %L, ''Honda'', ''Civic'') returning id::text', v_shop, v_ann));
    perform pg_temp.run_race('job_first',
      format('insert into public.jobs (shop_id, customer_id, vehicle_id, status) values (%L, %L, %L, ''requested'') returning id::text',
             v_shop, v_ann, v_veh),
      format('update public.vehicles set customer_id = %L where id = %L returning id::text', v_bob, v_veh));
    insert into race values ('job_first_mismatch', pg_temp.q('vr_setup', format(
      'select count(*)::text from public.jobs j join public.vehicles v on v.shop_id = j.shop_id and v.id = j.vehicle_id
        where j.shop_id = %L and j.customer_id <> v.customer_id', v_shop)));

    -- ---------------------------------------------------------------- the move first, then the job insert
    v_veh := pg_temp.q('vr_setup', format(
      'insert into public.vehicles (shop_id, customer_id, make, model) values (%L, %L, ''Mazda'', ''3'') returning id::text', v_shop, v_ann));
    perform pg_temp.run_race('move_first',
      format('update public.vehicles set customer_id = %L where id = %L returning id::text', v_bob, v_veh),
      format('insert into public.jobs (shop_id, customer_id, vehicle_id, status) values (%L, %L, %L, ''requested'') returning id::text',
             v_shop, v_ann, v_veh));
    insert into race values ('move_first_owner', pg_temp.q('vr_setup', format(
      'select (customer_id = %L)::text from public.vehicles where id = %L', v_bob, v_veh)));

    -- ---------------------------------------------------------------- a job line first, then the move
    v_veh := pg_temp.q('vr_setup', format(
      'insert into public.vehicles (shop_id, customer_id, make, model) values (%L, %L, ''Kia'', ''Soul'') returning id::text', v_shop, v_ann));
    perform pg_temp.run_race('line_first',
      format('insert into public.job_line_items (shop_id, job_id, vehicle_id, name, unit_price_cents) values (%L, %L, %L, ''Wash'', 1000) returning id::text',
             v_shop, v_job, v_veh),
      format('update public.vehicles set customer_id = %L where id = %L returning id::text', v_bob, v_veh));

    if v_money then
      -- ---------------------------------------------------------------- the move first, then a quote
      v_veh := pg_temp.q('vr_setup', format(
        'insert into public.vehicles (shop_id, customer_id, make, model) values (%L, %L, ''Ford'', ''Focus'') returning id::text', v_shop, v_ann));
      perform pg_temp.run_race('quote_second',
        format('update public.vehicles set customer_id = %L where id = %L returning id::text', v_bob, v_veh),
        format('insert into public.quotes (shop_id, customer_id, vehicle_id) values (%L, %L, %L) returning id::text', v_shop, v_ann, v_veh));

      -- ---------------------------------------------------------------- a membership first, then the move
      v_plan := pg_temp.q('vr_setup', format(
        'insert into public.membership_plans (shop_id, name, price_cents, interval) values (%L, ''Monthly'', 5000, ''month'') returning id::text', v_shop));
      v_veh := pg_temp.q('vr_setup', format(
        'insert into public.vehicles (shop_id, customer_id, make, model) values (%L, %L, ''Audi'', ''A4'') returning id::text', v_shop, v_ann));
      perform pg_temp.run_race('membership_first',
        format('insert into public.memberships (shop_id, plan_id, customer_id, vehicle_id, status) values (%L, %L, %L, %L, ''incomplete'') returning id::text',
               v_shop, v_plan, v_ann, v_veh),
        format('update public.vehicles set customer_id = %L where id = %L returning id::text', v_bob, v_veh));
    end if;

    -- ---------------------------------------------------------------- nothing references it: moves at once
    v_veh := pg_temp.q('vr_setup', format(
      'insert into public.vehicles (shop_id, customer_id, make, model) values (%L, %L, ''Fiat'', ''500'') returning id::text', v_shop, v_ann));
    insert into race values ('free', pg_temp.q('vr_setup', format(
      'update public.vehicles set customer_id = %L where id = %L returning (customer_id = %L)::text', v_bob, v_veh, v_bob)));
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
    insert into race values ('scenario_error', v_state || ': ' || v_msg);
  end;

  -- ---------------------------------------------------------------- cleanup (always)
  perform pg_temp.end_txn('vr_c1');
  perform pg_temp.end_txn('vr_c2');
  if v_shop is not null then
    -- memberships RESTRICT vehicle deletes: remove them before the shop
    perform extensions.dblink_exec('vr_setup', format(
      'begin;
       %2$s
       delete from public.shops where id = %1$L;
       commit;', v_shop,
      case when v_money then format('delete from public.memberships where shop_id = %L;', v_shop) else '' end));
  end if;
  perform extensions.dblink_exec('vr_setup', format('delete from auth.users where email = %L', v_owner));
  insert into race values ('leftovers', pg_temp.q('vr_setup', format(
    'select (select count(*) from public.shops where slug = %L) + (select count(*) from auth.users where email = %L)',
    'vrace-' || v_sfx, v_owner)));
  perform extensions.dblink_disconnect('vr_setup');
  perform extensions.dblink_disconnect('vr_c1');
  perform extensions.dblink_disconnect('vr_c2');
end
$race$;

select tests.eq((select val from race where key = 'scenario_error'), null, 'the race scenarios ran');
select tests.eq((select val from race where key = 'leftovers'), '0', 'the committed private shop was removed');

select tests.eq((select val from race where key = 'job_first_blocked'), 'true',
                'moving the vehicle waits for the uncommitted job that references it');
select tests.eq((select val from race where key = 'job_first'), 'err:23514',
                'once the job commits, the move is refused');
select tests.eq((select val from race where key = 'job_first_mismatch'), '0',
                'a job never ends up with a vehicle that belongs to another customer');

select tests.eq((select val from race where key = 'move_first_blocked'), 'true',
                'a job for the old owner waits for the uncommitted move');
select tests.eq((select val from race where key = 'move_first'), 'err:23514',
                'once the move commits, the job for the old owner is refused');
select tests.eq((select val from race where key = 'move_first_owner'), 'true', 'the move itself went through');

select tests.eq((select val from race where key = 'line_first_blocked'), 'true', 'the move waits for an uncommitted job line');
select tests.eq((select val from race where key = 'line_first'), 'err:23514', 'then refuses: the line references the vehicle');

\if :with_money
select tests.eq((select val from race where key = 'quote_second_blocked'), 'true', 'a quote for the old owner waits for the move');
select tests.eq((select val from race where key = 'quote_second'), 'err:23514', 'then is refused');

select tests.eq((select val from race where key = 'membership_first_blocked'), 'true', 'the move waits for an uncommitted membership');
select tests.eq((select val from race where key = 'membership_first'), 'err:23514', 'then is refused');
\endif

select tests.eq((select val from race where key = 'free'), 'true', 'a vehicle nothing references still changes owner');
