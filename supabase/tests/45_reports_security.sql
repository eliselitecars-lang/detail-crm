-- 45 reports: privilege matrix for the dashboard / report / search RPCs and
-- their helpers — grants, SECURITY DEFINER hygiene, and who may call what:
-- owner/admin/manager everything; technician only dashboard_summary,
-- report_team and search_shop; clients (portal users), inactive members,
-- other shops' staff, service_role without a membership and anon nothing.
\ir fixtures/45_reports_seed.psql

-- ============================================================ catalog checks
select tests.eq((
  select coalesce(string_agg(f, ', ' order by f), '')
  from unnest(array[
    'public.dashboard_summary(uuid, timestamptz)',
    'public.report_revenue(uuid, date, date, text)',
    'public.report_payments(uuid, date, date)',
    'public.report_outstanding(uuid, timestamptz)',
    'public.report_sales_by_service(uuid, date, date)',
    'public.report_team(uuid, date, date, timestamptz)',
    'public.report_customers(uuid, date, date, integer)',
    'public.search_shop(uuid, text, integer)']) as f
  where has_function_privilege('anon', f, 'execute')
     or not has_function_privilege('authenticated', f, 'execute')
     or not (select p.prosecdef and 'search_path=""' = any (p.proconfig) from pg_proc p where p.oid = f::regprocedure)),
  '', 'report RPCs: SECURITY DEFINER, search_path pinned, authenticated only (never anon)');

select tests.eq((
  select coalesce(string_agg(f, ', ' order by f), '')
  from unnest(array[
    'public.report_caller_role(uuid, boolean)',
    'public.report_caller_member(uuid)',
    'public.report_check_range(date, date)',
    'public.report_local_start(date, text)']) as f
  where has_function_privilege('anon', f, 'execute')
     or has_function_privilege('authenticated', f, 'execute')
     or not has_function_privilege('service_role', f, 'execute')),
  '', 'internal report helpers are not API surface');

select tests.eq((
  select coalesce(string_agg(f, ', ' order by f), '')
  from unnest(array[
    'public.report_customer_label(text, text, text)',
    'public.report_vehicle_label(smallint, text, text)',
    'public.like_escape(text)']) as f
  where has_function_privilege('anon', f, 'execute')
     or not has_function_privilege('authenticated', f, 'execute')),
  '', 'pure display helpers: staff yes, anon no');

select tests.ok(not (select prosecdef from pg_proc where oid = 'public.report_caller_role(uuid, boolean)'::regprocedure),
                'report_caller_role is SECURITY INVOKER');
select tests.ok(exists (select 1 from pg_indexes where schemaname = 'public' and indexname = 'jobs_shop_number_text_idx'),
                'job number prefix index exists');
select tests.ok(exists (select 1 from pg_indexes where schemaname = 'public' and indexname = 'time_entries_shop_open_idx'),
                'open time entry index exists');

-- pure helpers
select tests.eq(public.report_customer_label(' Ann ', null, 'Co'), 'Ann', 'label prefers the person name');
select tests.eq(public.report_customer_label(null, '  ', 'Fleet Co'), 'Fleet Co', 'label falls back to the company');
select tests.eq(public.report_vehicle_label(2020::smallint, 'Tesla', ' '), '2020 Tesla', 'vehicle label skips blanks');
select tests.eq(public.report_vehicle_label(null, null, null), null::text, 'empty vehicle label is null');

-- ============================================================ the call matrix
-- Every RPC with shop A arguments; "tech" marks the ones technicians may call.
create temporary table report_calls (name text primary key, sql text not null, tech boolean not null) on commit drop;
grant select on report_calls to authenticated, anon, service_role;
insert into report_calls values
  ('dashboard_summary',       format('select public.dashboard_summary(%L::uuid, %L)', tests.fx('rshop_a'), '2025-03-05 16:00+00'), true),
  ('report_revenue',          format('select * from public.report_revenue(%L::uuid, %L, %L)', tests.fx('rshop_a'), '2025-03-01', '2025-03-31'), false),
  ('report_payments',         format('select * from public.report_payments(%L::uuid, %L, %L)', tests.fx('rshop_a'), '2025-03-01', '2025-03-31'), false),
  ('report_outstanding',      format('select public.report_outstanding(%L::uuid, %L)', tests.fx('rshop_a'), '2025-03-05 16:00+00'), false),
  ('report_sales_by_service', format('select * from public.report_sales_by_service(%L::uuid, %L, %L)', tests.fx('rshop_a'), '2025-03-01', '2025-03-31'), false),
  ('report_team',             format('select * from public.report_team(%L::uuid, %L, %L, %L)', tests.fx('rshop_a'), '2025-03-01', '2025-03-31', '2025-03-05 16:00+00'), true),
  ('report_customers',        format('select public.report_customers(%L::uuid, %L, %L)', tests.fx('rshop_a'), '2025-03-01', '2025-03-31'), false),
  ('search_shop',             format('select * from public.search_shop(%L::uuid, %L)', tests.fx('rshop_a'), 'alice'), true);

-- a client with a portal account linked to a shop A customer
select tests.fx_set('ru_client', tests.create_user('client-r@test.local'));
update public.customers set portal_user_id = tests.fx('ru_client') where id = tests.fx('rc_alice');
select tests.fx_set('ru_tech3_a', tests.user_id('tech3-ra@test.local'));

do $$
declare
  c   record;
  u   text;
begin
  for c in select * from report_calls order by name loop
    -- staff of shop A with shop-wide access
    foreach u in array array['ru_owner_a', 'ru_admin_a', 'ru_manager_a'] loop
      perform tests.authenticate_as(tests.fx(u));
      perform tests.lives(c.sql, format('%s may call %s', u, c.name));
    end loop;
    -- technician of shop A
    perform tests.authenticate_as(tests.fx('ru_tech1_a'));
    if c.tech then
      perform tests.lives(c.sql, format('technician may call %s', c.name));
    else
      perform tests.throws(c.sql, '42501', format('technician may not call %s', c.name));
    end if;
    -- everyone else
    foreach u in array array['ru_owner_b', 'ru_tech_b', 'ru_outsider', 'ru_client', 'ru_tech3_a'] loop
      perform tests.authenticate_as(tests.fx(u));
      perform tests.throws(c.sql, '42501', format('%s may not call %s for shop A', u, c.name));
    end loop;
    perform tests.as_service();
    perform tests.throws(c.sql, '42501', format('service_role without a membership gets nothing from %s', c.name));
    perform tests.as_anon();
    perform tests.throws(c.sql, '42501', format('anon may not call %s', c.name));
  end loop;
  perform tests.as_superuser();
end
$$;

-- helpers cannot be called directly by API roles
select tests.authenticate_as(tests.fx('ru_owner_a'));
select tests.throws(format('select public.report_caller_role(%L::uuid, true)', tests.fx('rshop_a')), '42501',
                    'report_caller_role is not callable by authenticated');
select tests.throws(format('select public.report_caller_member(%L::uuid)', tests.fx('rshop_a')), '42501',
                    'report_caller_member is not callable by authenticated');
select tests.as_superuser();
