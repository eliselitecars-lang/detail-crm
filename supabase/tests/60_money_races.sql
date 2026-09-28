-- 60 money: concurrency (two real sessions through dblink).
--   redeem_redeem  two redemptions of the same gift card at once: the second
--                  waits for the card's row lock, then finds it empty (one
--                  payment, balance never negative)
--   quote_booking  a customer scheduling their quote and an online booking
--                  for the same last slot: both take the per-shop booking
--                  lock; the second then finds the slot taken (23P01)
--   once_once      two jobs of one customer attaching a once-per-customer
--                  coupon at once: the second waits on the unique redemption
--                  index, then is refused (22023, no duplicate use)
--   move_move      two membership visits from later periods rescheduled into
--                  the same empty period of a 1-visit plan at once
--                  (jobs_zz_money_membership_uses): the second waits for the
--                  membership's row lock, then finds the period used up
--                  (22023, never 2 free visits in one period)
-- Other sessions only see committed rows, so this file commits a private
-- shop (random slug / emails) through its own connection and deletes it again
-- BEFORE asserting. dblink without a password needs a superuser: on a
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

-- p_first runs in c1 (as p_who1) and stays uncommitted; p_second is sent on
-- c2 (as p_who2) and must block; then c1 commits. p_who*: a user id, or
-- 'service'.
create function pg_temp.run_race(p_key text, p_first text, p_second text, p_who1 text, p_who2 text)
returns void language plpgsql as $$
declare
  v_pid integer;
begin
  perform extensions.dblink_exec('mr_c1', 'begin');
  perform pg_temp.q('mr_c1', case when p_who1 = 'service' then 'select tests.as_service()::text'
                                  else format('select tests.authenticate_as(%L)::text', p_who1) end);
  insert into race values (p_key || '_first', pg_temp.q('mr_c1', p_first));
  perform extensions.dblink_exec('mr_c2', 'begin');
  perform pg_temp.q('mr_c2', case when p_who2 = 'service' then 'select tests.as_service()::text'
                                  else format('select tests.authenticate_as(%L)::text', p_who2) end);
  v_pid := pg_temp.q('mr_c2', 'select pg_backend_pid()::text')::integer;
  perform extensions.dblink_send_query('mr_c2', p_second);
  insert into race values (p_key || '_blocked', pg_temp.wait_blocked('mr_c2', v_pid)::text);
  perform extensions.dblink_exec('mr_c1', 'commit');
  insert into race values (p_key, pg_temp.result('mr_c2'));
  perform extensions.dblink_exec('mr_c2', 'commit');
end $$;

do $race$
declare
  c_conn constant text := format('host=%s port=%s dbname=%s user=%s',
                                 split_part(current_setting('unix_socket_directories'), ',', 1),
                                 current_setting('port'), current_database(), current_user);
  v_sfx    text := substr(md5(random()::text || clock_timestamp()::text), 1, 12);
  v_slug   text := 'mrace-' || v_sfx;
  v_owner  text;
  v_uid    uuid;
  v_shop   uuid;
  v_cust   uuid;
  v_svc    uuid;
  v_inv1   uuid;
  v_inv2   uuid;
  v_code   text;
  v_card   uuid;
  v_quote  uuid;
  v_qtok   uuid;
  v_coupon uuid;
  v_plan   uuid;
  v_mem    uuid;
  v_jb     uuid;
  v_jc     uuid;
  v_day    text := to_char(current_date + 7, 'YYYY-MM-DD');
  v_state  text;
  v_msg    text;
begin
  v_owner := 'mrace-owner-' || v_sfx || '@test.local';
  perform extensions.dblink_connect('mr_setup', c_conn);
  perform extensions.dblink_connect('mr_c1', c_conn);
  perform extensions.dblink_connect('mr_c2', c_conn);
  perform extensions.dblink_exec('mr_c1', 'set lock_timeout = ''30s''');
  perform extensions.dblink_exec('mr_c2', 'set lock_timeout = ''30s''');

  begin
    v_shop := pg_temp.q('mr_setup', format('select tests.make_shop(%L, %L, %L)::text', v_owner, v_slug, 'MRace'));
    v_uid := pg_temp.q('mr_setup', format('select tests.user_id(%L)::text', v_owner));
    v_cust := pg_temp.q('mr_setup', format(
      'insert into public.customers (shop_id, first_name, email) values (%L, ''Ann'', ''ann-%s@example.com'') returning id::text', v_shop, v_sfx));
    v_svc := pg_temp.q('mr_setup', format(
      'insert into public.services (shop_id, name, duration_minutes, online_bookable) values (%L, ''Wash'', 60, true) returning id::text', v_shop));
    perform pg_temp.q('mr_setup', format(
      'insert into public.service_prices (shop_id, service_id, price_cents) values (%L, %L, 5000) returning id::text', v_shop, v_svc));
    perform pg_temp.q('mr_setup', format(
      'update public.booking_settings set enabled = true, quote_self_schedule = true, slot_interval_minutes = 60, lead_time_minutes = 0,
              max_days_ahead = 365, buffer_minutes = 0, max_concurrent_jobs = 1
        where shop_id = %L returning shop_id::text', v_shop));
    perform pg_temp.q('mr_setup', format(
      'insert into public.business_hours (shop_id, weekday, opens_at, closes_at)
       select %L, d, ''08:00'', ''17:00'' from generate_series(0, 6) d returning shop_id::text', v_shop));
    -- two open invoices and one gift card (as the owner)
    v_inv1 := pg_temp.q('mr_setup', format(
      'select tests.authenticate_as(%L); select (public.mark_invoice_sent((public.create_invoice(%L, ''[{"name":"A","unit_price_cents":5000}]'')).id)).id::text',
      v_uid, v_cust));
    v_inv2 := pg_temp.q('mr_setup', format(
      'select tests.authenticate_as(%L); select (public.mark_invoice_sent((public.create_invoice(%L, ''[{"name":"B","unit_price_cents":5000}]'')).id)).id::text',
      v_uid, v_cust));
    v_code := pg_temp.q('mr_setup', format('select tests.authenticate_as(%L); select public.issue_gift_card(%L, 3000) ->> ''code''', v_uid, v_shop));
    v_card := pg_temp.q('mr_setup', format('select id::text from public.gift_cards where shop_id = %L', v_shop));
    -- an approved quote of one hour
    v_quote := pg_temp.q('mr_setup', format(
      'select tests.authenticate_as(%L);
       insert into public.quotes (shop_id, customer_id) values (%L, %L) returning id::text', v_uid, v_shop, v_cust));
    perform pg_temp.q('mr_setup', format(
      'select tests.authenticate_as(%L);
       insert into public.quote_line_items (shop_id, quote_id, service_id, name, unit_price_cents, duration_minutes)
       values (%L, %L, %L, ''Wash'', 5000, 60) returning id::text', v_uid, v_shop, v_quote, v_svc));
    perform pg_temp.q('mr_setup', format(
      'select tests.authenticate_as(%L); select public.mark_quote_sent(%L)::text;
       update public.quotes set status = ''approved'' where id = %L returning id::text', v_uid, v_quote, v_quote));
    v_qtok := pg_temp.q('mr_setup', format('select public_token::text from public.quotes where id = %L', v_quote));
    v_coupon := pg_temp.q('mr_setup', format(
      'insert into public.coupons (shop_id, code, kind, value, once_per_customer) values (%L, ''ONCE%s'', ''fixed'', 100, true) returning id::text',
      v_shop, upper(substr(v_sfx, 1, 6))));

    -- ---------------------------------------------------------------- redeem vs redeem
    perform pg_temp.run_race('redeem_redeem',
      format('select (public.redeem_gift_card(%L, %L)).amount_cents::text', v_inv1, v_code),
      format('select (public.redeem_gift_card(%L, %L)).amount_cents::text', v_inv2, v_code),
      v_uid::text, v_uid::text);
    insert into race values ('redeem_balance', pg_temp.q('mr_setup', format(
      'select balance_cents || ''/'' || status from public.gift_cards where id = %L', v_card)));
    insert into race values ('redeem_payments', pg_temp.q('mr_setup', format(
      'select count(*)::text from public.payments where shop_id = %L and method = ''gift_card''', v_shop)));

    -- ---------------------------------------------------------------- quote scheduling vs online booking
    perform pg_temp.run_race('quote_booking',
      format('select public.public_schedule_quote(%L, %L) ->> ''status''', v_qtok, v_day || 'T10:00:00'),
      format('select public.create_online_booking(%L, %L::jsonb) ->> ''status''', v_slug,
             jsonb_build_object('customer', jsonb_build_object('first_name', 'Bo', 'email', 'bo-' || v_sfx || '@example.com'),
                                'vehicle', jsonb_build_object('make', 'Kia', 'model', 'Rio'),
                                'service_ids', jsonb_build_array(v_svc),
                                'starts_at', v_day || 'T10:00:00')),
      'service', 'service');
    insert into race values ('quote_booking_jobs', pg_temp.q('mr_setup', format(
      'select count(*)::text from public.jobs where shop_id = %L and status <> ''cancelled''', v_shop)));

    -- ---------------------------------------------------------------- once-per-customer coupon, twice at once
    perform pg_temp.run_race('once_once',
      format('insert into public.jobs (shop_id, customer_id, status, coupon_id) values (%L, %L, ''requested'', %L) returning ''job''',
             v_shop, v_cust, v_coupon),
      format('insert into public.jobs (shop_id, customer_id, status, coupon_id) values (%L, %L, ''requested'', %L) returning ''job''',
             v_shop, v_cust, v_coupon),
      v_uid::text, v_uid::text);
    insert into race values ('once_rows', pg_temp.q('mr_setup', format(
      'select count(*)::text from public.coupon_redemptions where coupon_id = %L', v_coupon)));

    -- ---------------------------------------------------------------- two membership visits moved into one period
    -- 1 visit per month; the current period ends in 20 days (empty), the
    -- visits are in the next two periods (+25 and +55 days)
    v_plan := pg_temp.q('mr_setup', format(
      'insert into public.membership_plans (shop_id, name, price_cents, interval, interval_count, included_service_ids,
                                            included_uses_per_period)
       values (%L, ''Club'', 4000, ''month'', 1, array[%L::uuid], 1) returning id::text', v_shop, v_svc));
    v_mem := pg_temp.q('mr_setup', format(
      'insert into public.memberships (shop_id, plan_id, customer_id, status, current_period_end, created_by)
       values (%L, %L, %L, ''active'', now() + interval ''20 days'', %L) returning id::text', v_shop, v_plan, v_cust, v_uid));
    v_jb := pg_temp.q('mr_setup', format(
      'select tests.authenticate_as(%L);
       insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end)
       values (%L, %L, now() + interval ''25 days'', now() + interval ''25 days 1 hour'') returning id::text', v_uid, v_shop, v_cust));
    v_jc := pg_temp.q('mr_setup', format(
      'select tests.authenticate_as(%L);
       insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end)
       values (%L, %L, now() + interval ''55 days'', now() + interval ''55 days 1 hour'') returning id::text', v_uid, v_shop, v_cust));
    perform pg_temp.q('mr_setup', format(
      'select tests.authenticate_as(%L);
       insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents)
       select %L, j, %L, ''Wash'', 0 from unnest(array[%L::uuid, %L::uuid]) j returning ''x''', v_uid, v_shop, v_svc, v_jb, v_jc));
    insert into race values ('move_free', pg_temp.q('mr_setup', format(
      'select count(*)::text from public.job_line_items where membership_id = %L', v_mem)));
    perform pg_temp.run_race('move_move',
      format('update public.jobs set scheduled_start = now() + interval ''2 days'', scheduled_end = now() + interval ''2 days 1 hour''
               where id = %L returning ''moved''', v_jb),
      format('update public.jobs set scheduled_start = now() + interval ''3 days'', scheduled_end = now() + interval ''3 days 1 hour''
               where id = %L returning ''moved''', v_jc),
      v_uid::text, v_uid::text);
    insert into race values ('move_uses', pg_temp.q('mr_setup', format(
      'select public.membership_uses_in_period(%L, now() + interval ''2 days'')::text', v_mem)));
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
    insert into race values ('scenario_error', v_state || ': ' || v_msg);
  end;

  -- ---------------------------------------------------------------- cleanup (always)
  perform pg_temp.end_txn('mr_c1');
  perform pg_temp.end_txn('mr_c2');
  if v_shop is not null then
    -- an open membership keeps a shop from being deleted (0012 money guard)
    perform extensions.dblink_exec('mr_setup', format(
      'update public.memberships set status = ''cancelled'' where shop_id = %L and status <> ''cancelled''', v_shop));
    perform extensions.dblink_exec('mr_setup', format('delete from public.shops where id = %L', v_shop));
  end if;
  perform extensions.dblink_exec('mr_setup', format('delete from auth.users where email = %L', v_owner));
  insert into race values ('leftovers', pg_temp.q('mr_setup', format(
    'select (select count(*) from public.shops where slug = %L) + (select count(*) from auth.users where email = %L)',
    v_slug, v_owner)));
  perform extensions.dblink_disconnect('mr_setup');
  perform extensions.dblink_disconnect('mr_c1');
  perform extensions.dblink_disconnect('mr_c2');
end
$race$;

select tests.eq((select val from race where key = 'scenario_error'), null, 'the race scenarios ran');
select tests.eq((select val from race where key = 'leftovers'), '0', 'the committed private shop was removed');

select tests.eq((select val from race where key = 'redeem_redeem_first'), '3000', 'the first redemption takes the whole card');
select tests.eq((select val from race where key = 'redeem_redeem_blocked'), 'true', 'the second waits for the card''s row lock');
select tests.eq((select val from race where key = 'redeem_redeem'), 'err:22023', 'then finds it empty');
select tests.eq((select val from race where key = 'redeem_balance'), '0/depleted', 'the balance never goes negative');
select tests.eq((select val from race where key = 'redeem_payments'), '1', 'one gift card payment');

select tests.eq((select val from race where key = 'quote_booking_first'), 'requested', 'the customer schedules their quote');
select tests.eq((select val from race where key = 'quote_booking_blocked'), 'true', 'an online booking for the same slot waits');
select tests.eq((select val from race where key = 'quote_booking'), 'err:23P01', 'then finds the slot taken');
select tests.eq((select val from race where key = 'quote_booking_jobs'), '1', 'capacity 1: one job');

select tests.eq((select val from race where key = 'once_once_first'), 'job', 'the first job takes the coupon');
select tests.eq((select val from race where key = 'once_once_blocked'), 'true', 'the second waits on the redemption index');
select tests.eq((select val from race where key = 'once_once'), 'err:22023', 'then is refused');
select tests.eq((select val from race where key = 'once_rows'), '1', 'one use of a once-per-customer coupon');

select tests.eq((select val from race where key = 'move_free'), '2', 'one free visit in each of two later periods');
select tests.eq((select val from race where key = 'move_move_first'), 'moved', 'the first visit moves into the empty period');
select tests.eq((select val from race where key = 'move_move_blocked'), 'true', 'the second waits for the membership''s row lock');
select tests.eq((select val from race where key = 'move_move'), 'err:22023', 'then finds the period used up');
select tests.eq((select val from race where key = 'move_uses'), '1', 'the 1-visit period holds one free visit');
\else
\echo SKIP (needs superuser): the dblink money races were not run
select tests.ok(not :'is_superuser'::boolean, 'SKIP (needs superuser): the dblink money races were not run');
\endif
