-- 10 money: races between two real sessions (dblink).
--   deposit  a deposit webhook recorded while create_invoice_from_job runs
--            waits for it and attaches to the new invoice (not orphaned)
--   lines    deleting an invoice line while a manual payment for the whole
--            balance is being recorded waits and is then refused (no
--            overpaid invoice with changed lines)
--   quote    editing a quote line while the customer approves waits and is
--            then refused
-- Other sessions only see committed rows, so this file commits a private
-- shop (random slug / emails) through its own connection and deletes it
-- again BEFORE asserting: outcomes are captured in a temp table first, so a
-- failed race never leaves data behind for later files. Each race waits
-- (bounded) until the second session is actually blocked on a lock before
-- the first one commits, so the interleaving is deterministic.
-- The races connect through dblink without a password, which only a
-- superuser may do: on a non-superuser connection the file is skipped.
select rolsuper as is_superuser from pg_roles where rolname = current_user \gset
\if :is_superuser
create extension if not exists dblink with schema extensions;

create temp table race (key text primary key, val text);

-- single-value query on a connection
create function pg_temp.q(p_conn text, p_sql text) returns text language plpgsql as $$
declare v text;
begin
  select t.v into v from extensions.dblink(p_conn, p_sql) as t(v text);
  return v;
end $$;

-- wait until the connection's backend waits on a lock (true) or its query
-- finished without waiting (false); at most ~20 s
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

-- collect an async result: 'ok:<value>' or 'err:<sqlstate>:<message>'
create function pg_temp.result(p_conn text) returns text language plpgsql as $$
declare
  v text;
  v_state text;
  v_msg text;
begin
  begin
    select t.v into v from extensions.dblink_get_result(p_conn) as t(v text);
    v := 'ok:' || coalesce(v, '');
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
    v := 'err:' || v_state || ':' || v_msg;
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

do $race$
declare
  c_conn  constant text := format('host=%s port=%s dbname=%s user=%s',
                                  split_part(current_setting('unix_socket_directories'), ',', 1),
                                  current_setting('port'), current_database(), current_user);
  v_sfx     text := substr(md5(random()::text || clock_timestamp()::text), 1, 12);
  v_owner   text;
  v_manager text;
  v_shop    uuid;
  v_u_owner uuid;
  v_u_mgr   uuid;
  v_cust    uuid;
  v_job     uuid;
  v_inv     uuid;
  v_quote   uuid;
  v_token   uuid;
  v_pid     integer;
  v_state   text;
  v_msg     text;
begin
  v_owner := 'race-owner-' || v_sfx || '@test.local';
  v_manager := 'race-manager-' || v_sfx || '@test.local';
  perform extensions.dblink_connect('race_setup', c_conn);
  perform extensions.dblink_connect('race_c1', c_conn);
  perform extensions.dblink_connect('race_c2', c_conn);
  perform extensions.dblink_exec('race_c1', 'set lock_timeout = ''30s''');
  perform extensions.dblink_exec('race_c2', 'set lock_timeout = ''30s''');

  begin
    -- ---------------------------------------------------------------- committed fixture
    v_shop := pg_temp.q('race_setup', format('select tests.make_shop(%L, %L, %L)::text', v_owner, 'race-' || v_sfx, 'Race Shop'));
    v_u_owner := pg_temp.q('race_setup', format('select tests.user_id(%L)::text', v_owner));
    perform pg_temp.q('race_setup', format('select tests.add_member(%L, %L, %L)::text', v_shop, v_manager, 'manager'));
    v_u_mgr := pg_temp.q('race_setup', format('select tests.user_id(%L)::text', v_manager));
    v_cust := pg_temp.q('race_setup', format(
      'insert into public.customers (shop_id, first_name) values (%L, ''Race'') returning id::text', v_shop));
    v_job := pg_temp.q('race_setup', format(
      'insert into public.jobs (shop_id, customer_id, status) values (%L, %L, ''requested'') returning id::text', v_shop, v_cust));
    perform pg_temp.q('race_setup', format(
      'insert into public.job_line_items (shop_id, job_id, name, unit_price_cents, taxable)
       values (%L, %L, ''Full Detail'', 20000, false) returning id::text', v_shop, v_job));
    v_inv := pg_temp.q('race_setup', format(
      'select tests.authenticate_as(%L);
       select (public.mark_invoice_sent((public.create_invoice(%L,
         ''[{"name":"Coat","unit_price_cents":20000,"taxable":false},{"name":"Tint","unit_price_cents":10000,"taxable":false}]'')).id)
         ).id::text', v_u_mgr, v_cust));
    v_quote := pg_temp.q('race_setup', format(
      'select tests.authenticate_as(%L);
       insert into public.quotes (shop_id, customer_id) values (%L, %L) returning id::text', v_u_mgr, v_shop, v_cust));
    v_token := pg_temp.q('race_setup', format(
      'select tests.authenticate_as(%L);
       insert into public.quote_line_items (shop_id, quote_id, name, unit_price_cents) values (%L, %L, ''Ceramic'', 90000);
       select (public.mark_quote_sent(%L)).public_token::text', v_u_mgr, v_shop, v_quote, v_quote));

    -- ---------------------------------------------------------------- deposit vs create_invoice_from_job
    perform extensions.dblink_exec('race_c1', 'begin');
    perform pg_temp.q('race_c1', format('select tests.authenticate_as(%L)::text', v_u_owner));
    perform pg_temp.q('race_c1', format('select (public.create_invoice_from_job(%L)).id::text', v_job));
    perform extensions.dblink_exec('race_c2', 'begin');
    perform pg_temp.q('race_c2', 'select tests.as_service()::text');
    v_pid := pg_temp.q('race_c2', 'select pg_backend_pid()::text')::integer;
    perform extensions.dblink_send_query('race_c2', format(
      'select coalesce(invoice_id::text, ''none'') from public.upsert_stripe_payment(%L, ''pi_raceA'', ''succeeded'', 5000, 0,
         ''deposit'', ''card'', p_job_id => %L, p_paid_at => ''2025-06-01 12:00Z'')', v_shop, v_job));
    insert into race values ('deposit_blocked', pg_temp.wait_blocked('race_c2', v_pid)::text);
    perform extensions.dblink_exec('race_c1', 'commit');
    insert into race values ('deposit_result', pg_temp.result('race_c2'));
    perform extensions.dblink_exec('race_c2', 'commit');
    insert into race values ('deposit_invoice', pg_temp.q('race_setup', format(
      'select concat_ws(''/'', i.status, i.amount_paid_cents, i.balance_cents, p.invoice_id = i.id)
         from public.invoices i join public.payments p on p.shop_id = i.shop_id and p.stripe_payment_intent_id = ''pi_raceA''
        where i.job_id = %L', v_job)));

    -- ---------------------------------------------------------------- line delete vs manual payment
    perform extensions.dblink_exec('race_c1', 'begin');
    perform pg_temp.q('race_c1', format('select tests.authenticate_as(%L)::text', v_u_mgr));
    perform pg_temp.q('race_c1', format('select (public.record_manual_payment(%L, 30000, ''cash'')).id::text', v_inv));
    perform extensions.dblink_exec('race_c2', 'begin');
    perform pg_temp.q('race_c2', format('select tests.authenticate_as(%L)::text', v_u_mgr));
    v_pid := pg_temp.q('race_c2', 'select pg_backend_pid()::text')::integer;
    perform extensions.dblink_send_query('race_c2', format(
      'delete from public.invoice_line_items where invoice_id = %L and name = ''Tint''', v_inv));
    insert into race values ('lines_blocked', pg_temp.wait_blocked('race_c2', v_pid)::text);
    perform extensions.dblink_exec('race_c1', 'commit');
    insert into race values ('lines_result', pg_temp.result('race_c2'));
    perform extensions.dblink_exec('race_c2', 'commit');   -- a refused delete aborted the txn: commit = rollback
    insert into race values ('lines_invoice', pg_temp.q('race_setup', format(
      'select concat_ws(''/'', status, total_cents, amount_paid_cents, balance_cents) from public.invoices where id = %L', v_inv)));

    -- ---------------------------------------------------------------- quote line edit vs approval
    perform extensions.dblink_exec('race_c1', 'begin');
    perform pg_temp.q('race_c1', 'select tests.as_anon()::text');
    perform pg_temp.q('race_c1', format('select public.public_respond_quote(%L, ''approve'', ''Race Customer'') #>> ''{quote,status}''', v_token));
    perform extensions.dblink_exec('race_c2', 'begin');
    perform pg_temp.q('race_c2', format('select tests.authenticate_as(%L)::text', v_u_mgr));
    v_pid := pg_temp.q('race_c2', 'select pg_backend_pid()::text')::integer;
    perform extensions.dblink_send_query('race_c2', format(
      'update public.quote_line_items set unit_price_cents = 1 where quote_id = %L', v_quote));
    insert into race values ('quote_blocked', pg_temp.wait_blocked('race_c2', v_pid)::text);
    perform extensions.dblink_exec('race_c1', 'commit');
    insert into race values ('quote_result', pg_temp.result('race_c2'));
    perform extensions.dblink_exec('race_c2', 'commit');
    insert into race values ('quote_after', pg_temp.q('race_setup', format(
      'select concat_ws(''/'', status, total_cents) from public.quotes where id = %L', v_quote)));
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
    insert into race values ('scenario_error', v_state || ': ' || v_msg);
    perform pg_temp.end_txn('race_c1');
    perform pg_temp.end_txn('race_c2');
  end;

  -- ---------------------------------------------------------------- cleanup (always)
  perform pg_temp.end_txn('race_c1');
  perform pg_temp.end_txn('race_c2');
  if v_shop is not null then
    perform extensions.dblink_exec('race_setup', format(
      'begin;
       delete from public.payments where shop_id = %1$L;
       delete from public.invoices where shop_id = %1$L;
       delete from public.shops where id = %1$L;
       commit;', v_shop));
  end if;
  perform extensions.dblink_exec('race_setup', format('delete from auth.users where email in (%L, %L)', v_owner, v_manager));
  insert into race values ('leftovers', pg_temp.q('race_setup', format(
    'select (select count(*) from public.shops where slug = %L) + (select count(*) from auth.users where email in (%L, %L))',
    'race-' || v_sfx, v_owner, v_manager)));
  perform extensions.dblink_disconnect('race_setup');
  perform extensions.dblink_disconnect('race_c1');
  perform extensions.dblink_disconnect('race_c2');
end
$race$;

select tests.eq((select val from race where key = 'scenario_error'), null::text, 'the race scenarios ran to the end');
select tests.eq((select val from race where key = 'leftovers'), '0', 'the committed race fixture was removed');

select tests.eq((select val from race where key = 'deposit_blocked'), 'true',
                'the deposit waits for the invoice being created for its job');
select tests.ok((select val like 'ok:%' and val <> 'ok:none' from race where key = 'deposit_result'),
                'the webhook stored the deposit with an invoice');
select tests.eq((select val from race where key = 'deposit_invoice'), 'partially_paid/5000/15000/t',
                'the deposit is attached to the invoice created concurrently');

select tests.eq((select val from race where key = 'lines_blocked'), 'true',
                'the line delete waits for the payment being recorded');
select tests.ok((select val like 'err:23514:%payments have been received%' from race where key = 'lines_result'),
                'and is then refused: no line change after money received');
select tests.eq((select val from race where key = 'lines_invoice'), 'paid/30000/30000/0',
                'the invoice is paid exactly, never overpaid');

select tests.eq((select val from race where key = 'quote_blocked'), 'true',
                'the quote line edit waits for the approval in progress');
select tests.ok((select val like 'err:23514:%approved quote%' from race where key = 'quote_result'),
                'and is then refused');
select tests.eq((select val from race where key = 'quote_after'), 'approved/90000',
                'the approved quote keeps the lines the customer approved');
\else
\echo SKIP (needs superuser): the dblink money races were not run
select tests.ok(not :'is_superuser'::boolean, 'SKIP (needs superuser): the dblink money races were not run');
\endif
