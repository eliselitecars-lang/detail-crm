-- 70 ops: concurrency (two real sessions through dblink).
--   publish_publish  two managers publish the same job's report at once: the
--                    second waits on the one-live-report index, then updates
--                    the first's report (one live report, one link)
--   ack_ack          two sign-offs of the same pre-inspection through the
--                    report link: the second waits for the inspection row,
--                    then finds it signed (22023)
--   count_complete   a stock count and a job completion that consumes the
--                    same product: the completion waits for the product row,
--                    then deducts from the counted level (the ledger always
--                    adds up to on_hand)
--   complete_line    a job completion and a service line added to that job
--                    at once: the line waits for the job row (its job touch),
--                    then finds the job completed and deducts only its own
--                    materials (nothing missed, nothing twice)
--   merge_crossed    merging A into B and B into A at once: both lock the
--                    two customers in id order, so there is no deadlock; the
--                    second then finds its target merged (22023)
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
  perform extensions.dblink_exec('or_c1', 'begin');
  perform pg_temp.q('or_c1', pg_temp.who(p_who1));
  insert into race values (p_key || '_first', pg_temp.q('or_c1', p_first));
  perform extensions.dblink_exec('or_c2', 'begin');
  perform pg_temp.q('or_c2', pg_temp.who(p_who2));
  v_pid := pg_temp.q('or_c2', 'select pg_backend_pid()::text')::integer;
  perform extensions.dblink_send_query('or_c2', p_second);
  insert into race values (p_key || '_blocked', pg_temp.wait_blocked('or_c2', v_pid)::text);
  perform extensions.dblink_exec('or_c1', 'commit');
  insert into race values (p_key, pg_temp.result('or_c2'));
  perform extensions.dblink_exec('or_c2', 'commit');
end $$;

do $race$
declare
  c_conn constant text := format('host=%s port=%s dbname=%s user=%s',
                                 split_part(current_setting('unix_socket_directories'), ',', 1),
                                 current_setting('port'), current_database(), current_user);
  v_sfx     text := substr(md5(random()::text || clock_timestamp()::text), 1, 12);
  v_slug    text := 'orace-' || v_sfx;
  v_owner   text;
  v_mgr     text;
  v_uid     uuid;
  v_mgr_uid uuid;
  v_shop    uuid;
  v_cust    uuid;
  v_cust2   uuid;
  v_job     uuid;
  v_job2    uuid;
  v_job3    uuid;
  v_ins     uuid;
  v_tok     uuid;
  v_prod    uuid;
  v_state   text;
  v_msg     text;
begin
  v_owner := 'orace-owner-' || v_sfx || '@test.local';
  v_mgr := 'orace-mgr-' || v_sfx || '@test.local';
  perform extensions.dblink_connect('or_setup', c_conn);
  perform extensions.dblink_connect('or_c1', c_conn);
  perform extensions.dblink_connect('or_c2', c_conn);
  perform extensions.dblink_exec('or_c1', 'set lock_timeout = ''30s''');
  perform extensions.dblink_exec('or_c2', 'set lock_timeout = ''30s''');

  begin
    v_shop := pg_temp.q('or_setup', format('select tests.make_shop(%L, %L, %L)::text', v_owner, v_slug, 'ORace'));
    v_uid := pg_temp.q('or_setup', format('select tests.user_id(%L)::text', v_owner));
    perform pg_temp.q('or_setup', format('select tests.add_member(%L, %L, ''manager'')::text', v_shop, v_mgr));
    v_mgr_uid := pg_temp.q('or_setup', format('select tests.user_id(%L)::text', v_mgr));
    v_cust := pg_temp.q('or_setup', format(
      'insert into public.customers (shop_id, first_name) values (%L, ''Ann'') returning id::text', v_shop));
    v_cust2 := pg_temp.q('or_setup', format(
      'insert into public.customers (shop_id, first_name) values (%L, ''Ann B'') returning id::text', v_shop));
    v_job := pg_temp.q('or_setup', format(
      'insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end)
       values (%L, %L, now() + interval ''1 day'', now() + interval ''1 day 1 hour'') returning id::text', v_shop, v_cust));
    v_ins := pg_temp.q('or_setup', format(
      'insert into public.inspections (shop_id, job_id, kind) values (%L, %L, ''pre'') returning id::text', v_shop, v_job));
    v_tok := pg_temp.q('or_setup', format(
      'select tests.authenticate_as(%L); select public.publish_job_report(%L) ->> ''token''', v_uid, v_job));
    -- stock: a product the job's service consumes
    v_prod := pg_temp.q('or_setup', format(
      'insert into public.products (shop_id, name, unit, on_hand) values (%L, ''Soap'', ''oz'', 50) returning id::text', v_shop));
    v_job2 := pg_temp.q('or_setup', format(
      'with s as (insert into public.services (shop_id, name, duration_minutes) values (%1$L, ''Wash'', 60) returning id),
            r as (insert into public.service_consumables (shop_id, service_id, product_id, quantity) select %1$L, s.id, %2$L, 5 from s)
       insert into public.jobs (shop_id, customer_id, status) values (%1$L, %3$L, ''requested'') returning id::text',
      v_shop, v_prod, v_cust));
    perform pg_temp.q('or_setup', format(
      'insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents)
       select %L, %L, s.id, ''Wash'', 5000 from public.services s where s.shop_id = %L and s.name = ''Wash'' returning id::text',
      v_shop, v_job2, v_shop));
    perform pg_temp.q('or_setup', format(
      'update public.jobs set status = ''scheduled'', scheduled_start = now(), scheduled_end = now() + interval ''1 hour''
        where id = %L returning id::text', v_job2));

    -- ---------------------------------------------------------------- publish vs publish
    perform pg_temp.q('or_setup', format(
      'select tests.authenticate_as(%L);
       select count(*)::text from (select public.revoke_job_report(r.id) from public.job_reports r where r.job_id = %L) x',
      v_uid, v_job));
    perform pg_temp.run_race('publish_publish',
      format('select public.publish_job_report(%L) ->> ''token''', v_job),
      format('select public.publish_job_report(%L, false) ->> ''token''', v_job),
      v_uid::text, v_mgr_uid::text);
    insert into race values ('publish_same_token',
      ((select val from race where key = 'publish_publish_first') = replace((select val from race where key = 'publish_publish'), 'ok:', ''))::text);
    insert into race values ('publish_live', pg_temp.q('or_setup', format(
      'select count(*) || ''/'' || bool_and(not include_inspections)::text from public.job_reports where job_id = %L and revoked_at is null', v_job)));
    v_tok := pg_temp.q('or_setup', format('select token::text from public.job_reports where job_id = %L and revoked_at is null', v_job));
    perform pg_temp.q('or_setup', format(
      'select tests.authenticate_as(%L); select public.publish_job_report(%L)::text', v_uid, v_job));
    perform pg_temp.q('or_setup', format(
      'insert into storage.objects (bucket_id, name) values (''signatures'', %L), (''signatures'', %L) returning name',
      v_shop || '/reports/' || v_tok || '/one.png', v_shop || '/reports/' || v_tok || '/two.png'));

    -- ---------------------------------------------------------------- sign-off vs sign-off
    perform pg_temp.run_race('ack_ack',
      format('select public.public_ack_inspection(%L, %L, ''Ann'', %L) -> ''inspections'' -> 0 ->> ''signed_by_name''',
             v_tok, v_ins, v_shop || '/reports/' || v_tok || '/one.png'),
      format('select public.public_ack_inspection(%L, %L, ''Ann B'', %L) -> ''inspections'' -> 0 ->> ''signed_by_name''',
             v_tok, v_ins, v_shop || '/reports/' || v_tok || '/two.png'),
      'anon', 'anon');
    insert into race values ('ack_signed', pg_temp.q('or_setup', format(
      'select signed_by_name || '' '' || customer_signature_path from public.inspections where id = %L', v_ins)));

    -- ---------------------------------------------------------------- count vs completion
    perform pg_temp.run_race('count_complete',
      format('select (public.record_inventory_movement(%L, ''count'', 40)).quantity::text', v_prod),
      format('update public.jobs set status = ''completed'' where id = %L returning status::text', v_job2),
      v_uid::text, v_mgr_uid::text);
    insert into race values ('count_complete_stock', pg_temp.q('or_setup', format(
      'select p.on_hand::text || ''/'' || (select sum(m.quantity) from public.inventory_movements m where m.product_id = p.id)::text
         from public.products p where p.id = %L', v_prod)));

    -- ---------------------------------------------------------------- completion vs a new line
    v_job3 := pg_temp.q('or_setup', format(
      'insert into public.jobs (shop_id, customer_id, status) values (%L, %L, ''requested'') returning id::text', v_shop, v_cust));
    perform pg_temp.q('or_setup', format(
      'insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents)
       select %L, %L, s.id, ''Wash'', 5000 from public.services s where s.shop_id = %L and s.name = ''Wash'' returning id::text',
      v_shop, v_job3, v_shop));
    perform pg_temp.q('or_setup', format(
      'update public.jobs set status = ''scheduled'', scheduled_start = now(), scheduled_end = now() + interval ''1 hour''
        where id = %L returning id::text', v_job3));
    perform pg_temp.run_race('complete_line',
      format('update public.jobs set status = ''completed'' where id = %L returning status::text', v_job3),
      format('insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents)
              select %L, %L, s.id, ''Wash'', 5000 from public.services s where s.shop_id = %L and s.name = ''Wash''
              returning name', v_shop, v_job3, v_shop),
      v_mgr_uid::text, v_uid::text);
    insert into race values ('complete_line_stock', pg_temp.q('or_setup', format(
      'select p.on_hand::text || ''/'' || (select sum(m.quantity) from public.inventory_movements m where m.product_id = p.id)::text
              || ''/'' || (select count(*) || '':'' || sum(m.quantity) from public.inventory_movements m where m.job_id = %L)
         from public.products p where p.id = %L', v_job3, v_prod)));

    -- ---------------------------------------------------------------- crossed merges
    perform pg_temp.run_race('merge_crossed',
      format('select public.merge_customers(%L, %L) ->> ''target_id''', v_cust2, v_cust),
      format('select public.merge_customers(%L, %L) ->> ''target_id''', v_cust, v_cust2),
      v_uid::text, v_uid::text);
    insert into race values ('merge_state', pg_temp.q('or_setup', format(
      'select string_agg(first_name || '':'' || (merged_into_id is not null)::text, '','' order by first_name)
         from public.customers where shop_id = %L', v_shop)));
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
    insert into race values ('scenario_error', v_state || ': ' || v_msg);
  end;

  -- ---------------------------------------------------------------- cleanup (always)
  perform pg_temp.end_txn('or_c1');
  perform pg_temp.end_txn('or_c2');
  if v_shop is not null then
    perform extensions.dblink_exec('or_setup', format('delete from public.shops where id = %L', v_shop));
    perform extensions.dblink_exec('or_setup', format('delete from public.storage_purge_requests where shop_id = %L', v_shop));
    perform extensions.dblink_exec('or_setup', format(
      'select set_config(''storage.allow_delete_query'', ''true'', false); delete from storage.objects where name like %L', v_shop || '/%'));
  end if;
  perform extensions.dblink_exec('or_setup', format('delete from auth.users where email in (%L, %L)', v_owner, v_mgr));
  insert into race values ('leftovers', pg_temp.q('or_setup', format(
    'select (select count(*) from public.shops where slug = %L) + (select count(*) from auth.users where email in (%L, %L))
          + (select count(*) from storage.objects where name like %L)',
    v_slug, v_owner, v_mgr, coalesce(v_shop::text, 'x') || '/%')));
  perform extensions.dblink_disconnect('or_setup');
  perform extensions.dblink_disconnect('or_c1');
  perform extensions.dblink_disconnect('or_c2');
end
$race$;

select tests.eq((select val from race where key = 'scenario_error'), null, 'the race scenarios ran');
select tests.eq((select val from race where key = 'leftovers'), '0', 'the committed private shop was removed');

select tests.eq((select val from race where key = 'publish_publish_blocked'), 'true', 'the second publish waits on the live-report index');
select tests.eq((select val from race where key = 'publish_same_token'), 'true', 'then updates the same report (same link)');
select tests.eq((select val from race where key = 'publish_live'), '1/true', 'one live report, with the later settings');

select tests.eq((select val from race where key = 'ack_ack_first'), 'Ann', 'the first sign-off signs');
select tests.eq((select val from race where key = 'ack_ack_blocked'), 'true', 'the second waits for the inspection');
select tests.eq((select val from race where key = 'ack_ack'), 'err:22023', 'then finds it signed');
select tests.ok((select val like 'Ann %/one.png' from race where key = 'ack_signed'), 'the first signature stands');

select tests.eq((select val from race where key = 'count_complete_first'), '-10.000', 'the count sets 40');
select tests.eq((select val from race where key = 'count_complete_blocked'), 'true', 'the completion waits for the product row');
select tests.eq((select val from race where key = 'count_complete'), 'ok:completed', 'then completes');
select tests.eq((select val from race where key = 'count_complete_stock'), '35.000/35.000', 'from the counted level; the ledger adds up');

select tests.eq((select val from race where key = 'complete_line_first'), 'completed', 'the job completes');
select tests.eq((select val from race where key = 'complete_line_blocked'), 'true', 'the new line waits for the job row');
select tests.eq((select val from race where key = 'complete_line'), 'ok:Wash', 'then is added');
select tests.eq((select val from race where key = 'complete_line_stock'), '25.000/25.000/2:-10.000',
                'completion used the first line''s 5, the late line its own 5; the ledger adds up');

select tests.ok((select val is not null from race where key = 'merge_crossed_first'), 'the first merge runs');
select tests.eq((select val from race where key = 'merge_crossed_blocked'), 'true', 'the crossed merge waits (no deadlock)');
select tests.eq((select val from race where key = 'merge_crossed'), 'err:22023', 'then finds its target merged');
select tests.eq((select val from race where key = 'merge_state'), 'Ann:false,Ann B:true', 'one merge happened');
\else
\echo SKIP (needs superuser): the dblink ops races were not run
select tests.ok(not :'is_superuser'::boolean, 'SKIP (needs superuser): the dblink ops races were not run');
\endif
