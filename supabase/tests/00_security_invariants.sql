-- 00 foundation: schema-wide security invariants. These loops cover EVERY
-- table / function in schema public (including later domains' objects):
--   * RLS enabled on every table
--   * anon can neither read nor write any table directly
--   * an authenticated user of shop A cannot read/update/delete shop B rows
--     in any table with a shop_id column; a user with no shop sees nothing
--   * tenant tables expose UNIQUE (shop_id, id) and every FK between tenant
--     tables is composite on shop_id
--   * SECURITY DEFINER functions pin search_path = '' and are only
--     executable by anon when they are public_* entry points
-- plus foundation-specific grant and index checks.
\ir fixtures/two_shops.psql

-- ------------------------------------------------------------ RLS everywhere
select tests.eq((select coalesce(string_agg(c.relname, ', ' order by c.relname), '')
                   from pg_class c join pg_namespace n on n.oid = c.relnamespace
                  where n.nspname = 'public' and c.relkind in ('r', 'p') and not c.relrowsecurity),
                '', 'every public table has row level security enabled');
select tests.eq((select coalesce(string_agg(c.relname, ', ' order by c.relname), '')
                   from pg_class c join pg_namespace n on n.oid = c.relnamespace
                  where n.nspname = 'public' and c.relkind in ('r', 'p') and c.relforcerowsecurity),
                '', 'no table uses FORCE ROW LEVEL SECURITY (definer RPCs rely on owner bypass)');
select tests.eq((select coalesce(string_agg(c.relname, ', ' order by c.relname), '')
                   from pg_class c join pg_namespace n on n.oid = c.relnamespace
                  where n.nspname = 'public' and c.relkind = 'v'
                    and not coalesce((select option_value = 'true' from pg_options_to_table(c.reloptions)
                                       where option_name = 'security_invoker'), false)),
                '', 'every public view is security_invoker');

-- ------------------------------------------------------------ anon has no direct table access
do $$
declare
  t      text;
  v_n    bigint;
  v_ok   boolean;
begin
  for t in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'public' and c.relkind in ('r', 'p', 'v') order by 1 loop
    perform tests.as_anon();
    begin
      execute format('select count(*) from public.%I', t) into v_n;
      v_ok := v_n = 0;
    exception when insufficient_privilege then
      v_ok := true;
    end;
    perform tests.ok(v_ok, format('anon reads nothing from public.%s', t));
    begin
      execute format('delete from public.%I', t);
      get diagnostics v_n = row_count;
      v_ok := v_n = 0;
    exception when insufficient_privilege then
      v_ok := true;
    end;
    perform tests.ok(v_ok, format('anon deletes nothing from public.%s', t));
    begin
      execute format('insert into public.%I default values', t);
      v_ok := false;
    exception when others then
      v_ok := true;
    end;
    perform tests.ok(v_ok, format('anon cannot insert into public.%s', t));
  end loop;
  perform tests.as_superuser();
end
$$;

-- ------------------------------------------------------------ a user with no shop sees nothing
do $$
declare
  t    text;
  v_n  bigint;
  v_ok boolean;
begin
  perform tests.authenticate_as(tests.fx('u_outsider'));
  for t in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'public' and c.relkind in ('r', 'p')
              and c.relname not in ('job_status_transitions')   -- global reference data
            order by 1 loop
    begin
      if t = 'profiles' then
        execute 'select count(*) from public.profiles where id <> auth.uid()' into v_n;
      else
        execute format('select count(*) from public.%I', t) into v_n;
      end if;
      v_ok := v_n = 0;
    exception when insufficient_privilege then
      v_ok := true;
    end;
    perform tests.ok(v_ok, format('a user with no shop reads nothing from public.%s', t));
  end loop;
  perform tests.as_superuser();
end
$$;

-- ------------------------------------------------------------ cross-shop isolation (every table with shop_id)
do $$
declare
  t      text;
  u      text;
  v_n    bigint;
  v_ok   boolean;
  v_rows bigint;
begin
  foreach u in array array['u_owner_a', 'u_admin_a', 'u_manager_a', 'u_tech_a'] loop
    for t in select c.table_name from information_schema.columns c
              join pg_class pc on pc.relname = c.table_name
              join pg_namespace n on n.oid = pc.relnamespace and n.nspname = c.table_schema
              where c.table_schema = 'public' and c.column_name = 'shop_id' and pc.relkind in ('r', 'p')
              order by 1 loop
      -- make sure shop B actually has rows here when the fixture populated them
      perform tests.as_superuser();
      execute format('select count(*) from public.%I where shop_id = $1', t) into v_rows using tests.fx('shop_b');
      perform tests.authenticate_as(tests.fx(u));
      begin
        execute format('select count(*) from public.%I where shop_id = $1', t) into v_n using tests.fx('shop_b');
        v_ok := v_n = 0;
      exception when insufficient_privilege then
        v_ok := true;
      end;
      perform tests.ok(v_ok, format('%s cannot read shop B rows of %s (%s exist)', u, t, v_rows));
      begin
        execute format('update public.%I set shop_id = shop_id where shop_id = $1', t) using tests.fx('shop_b');
        get diagnostics v_n = row_count;
        v_ok := v_n = 0;
      exception when insufficient_privilege then
        v_ok := true;
      end;
      perform tests.ok(v_ok, format('%s cannot update shop B rows of %s', u, t));
      begin
        execute format('delete from public.%I where shop_id = $1', t) using tests.fx('shop_b');
        get diagnostics v_n = row_count;
        v_ok := v_n = 0;
      exception when insufficient_privilege then
        v_ok := true;
      end;
      perform tests.ok(v_ok, format('%s cannot delete shop B rows of %s', u, t));
    end loop;
  end loop;
  perform tests.as_superuser();
  -- B's data survived all of the above
  perform tests.eq((select count(*) from public.jobs where shop_id = tests.fx('shop_b')), 1::bigint, 'shop B jobs intact');
  perform tests.eq((select count(*) from public.shop_members where shop_id = tests.fx('shop_b')), 4::bigint, 'shop B members intact');
end
$$;

-- Owner of A cannot plant rows in B (foundation tables; RLS WITH CHECK runs
-- before NOT NULL/CHECK constraints, so a bare shop_id insert must hit RLS).
do $$
declare
  t       text;
  v_state text;
begin
  perform tests.authenticate_as(tests.fx('u_owner_a'));
  foreach t in array array['vehicle_categories', 'business_hours', 'blocked_times', 'resources', 'booking_settings',
                           'customers', 'vehicles', 'service_categories', 'services', 'service_prices', 'package_items',
                           'service_addons', 'coupons', 'jobs', 'job_line_items', 'member_compensation',
                           'shop_members', 'shop_invites', 'shop_stripe_accounts', 'shop_counters'] loop
    v_state := null;
    begin
      execute format('insert into public.%I (shop_id) values ($1)', t) using tests.fx('shop_b');
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate;
    end;
    perform tests.eq(v_state, '42501', format('owner of A cannot insert into %s for shop B', t));
  end loop;
  perform tests.as_superuser();
end
$$;

-- ------------------------------------------------------------ tenant keys
-- every table with both id and shop_id exposes UNIQUE (shop_id, id)
select tests.eq((
  select coalesce(string_agg(c.relname, ', ' order by c.relname), '')
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'r'
    and exists (select 1 from pg_attribute a where a.attrelid = c.oid and a.attname = 'id' and not a.attisdropped)
    and exists (select 1 from pg_attribute a where a.attrelid = c.oid and a.attname = 'shop_id' and not a.attisdropped)
    and not exists (
      select 1 from pg_index i
      where i.indrelid = c.oid and i.indisunique and i.indpred is null and i.indnkeyatts = 2
        and (select array_agg(a.attname::text order by a.attname)
               from unnest(i.indkey::int2[]) k join pg_attribute a on a.attrelid = c.oid and a.attnum = k)
            = array['id', 'shop_id'])),
  '', 'every tenant table has UNIQUE (shop_id, id)');

-- every FK from a tenant table to another tenant table includes shop_id
select tests.eq((
  select coalesce(string_agg(con.conrelid::regclass::text || '.' || con.conname, ', ' order by 1), '')
  from pg_constraint con
  join pg_class child on child.oid = con.conrelid
  join pg_namespace n on n.oid = child.relnamespace and n.nspname = 'public'
  join pg_class parent on parent.oid = con.confrelid
  where con.contype = 'f'
    and parent.relname <> 'shops'
    and parent.relnamespace = child.relnamespace
    and exists (select 1 from pg_attribute a where a.attrelid = child.oid and a.attname = 'shop_id' and not a.attisdropped)
    and exists (select 1 from pg_attribute a where a.attrelid = parent.oid and a.attname = 'shop_id' and not a.attisdropped)
    and not exists (
      select 1 from unnest(con.conkey) k join pg_attribute a on a.attrelid = con.conrelid and a.attnum = k
      where a.attname = 'shop_id')),
  '', 'every FK between tenant tables is composite on shop_id');

-- every FK on a foundation table has an index whose leading columns are the FK columns
select tests.eq((
  select coalesce(string_agg(con.conrelid::regclass::text || '.' || con.conname, ', ' order by 1), '')
  from pg_constraint con
  join pg_class child on child.oid = con.conrelid
  join pg_namespace n on n.oid = child.relnamespace and n.nspname = 'public'
  where con.contype = 'f'
    and child.relname in ('profiles', 'shops', 'shop_members', 'shop_invites', 'member_compensation', 'shop_stripe_accounts',
                          'shop_counters', 'vehicle_categories', 'business_hours', 'blocked_times', 'resources',
                          'booking_settings', 'customers', 'vehicles', 'service_categories', 'services', 'service_prices',
                          'package_items', 'service_addons', 'coupons', 'jobs', 'job_line_items', 'job_assignments')
    and not exists (
      select 1 from pg_index i
      where i.indrelid = con.conrelid
        and (select array_agg(x order by x) from unnest((i.indkey::int2[])[0:cardinality(con.conkey) - 1]) x)
            = (select array_agg(x order by x) from unnest(con.conkey) x))),
  '', 'every foundation FK is backed by an index');

-- ------------------------------------------------------------ functions
select tests.eq((
  select coalesce(string_agg(p.oid::regprocedure::text, ', ' order by 1), '')
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.prosecdef
    and not coalesce('search_path=""' = any (p.proconfig), false)),
  '', 'every SECURITY DEFINER function in public pins search_path to empty');

select tests.eq((
  select coalesce(string_agg(p.oid::regprocedure::text, ', ' order by 1), '')
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.prosecdef
    and has_function_privilege('anon', p.oid, 'execute')
    and p.proname not like 'public\_%'
    and p.proname not in ('get_available_slots', 'create_online_booking')),
  '', 'anon may execute only public_* / booking SECURITY DEFINER entry points');

select tests.eq((
  select coalesce(string_agg(p.oid::regprocedure::text, ', ' order by 1), '')
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.prorettype = 'trigger'::regtype
    and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))),
  '', 'trigger functions are not executable by API roles');

select tests.ok(not has_function_privilege('authenticated', 'public.next_document_number(uuid, public.document_kind)', 'execute'),
                'next_document_number is service-only');
select tests.ok(has_function_privilege('service_role', 'public.next_document_number(uuid, public.document_kind)', 'execute'),
                'service_role may call next_document_number');
select tests.ok(has_function_privilege('anon', 'public.get_available_slots(text, uuid[], date, date, uuid, timestamptz)', 'execute'),
                'anon may call get_available_slots');
select tests.ok(has_function_privilege('anon', 'public.public_get_invite(uuid)', 'execute'), 'anon may call public_get_invite');
select tests.ok(not has_function_privilege('anon', 'public.create_shop(text, text, text, public.business_type, text, text, text, text)', 'execute'),
                'anon may not call create_shop');
select tests.ok(not has_function_privilege('anon', 'public.calendar_events(uuid, timestamptz, timestamptz, boolean)', 'execute'),
                'anon may not call calendar_events');

-- ------------------------------------------------------------ foundation grants
select tests.eq((
  select coalesce(string_agg(table_name || ':' || grantee || ':' || privilege_type, ', ' order by 1), '')
  from information_schema.table_privileges
  where table_schema = 'public' and grantee in ('anon', 'authenticated')
    and privilege_type in ('TRUNCATE', 'TRIGGER', 'REFERENCES')
    and table_name in ('profiles', 'shops', 'shop_members', 'shop_invites', 'member_compensation', 'shop_stripe_accounts',
                       'shop_counters', 'vehicle_categories', 'business_hours', 'blocked_times', 'resources',
                       'booking_settings', 'customers', 'vehicles', 'service_categories', 'services', 'service_prices',
                       'package_items', 'service_addons', 'coupons', 'job_status_transitions', 'jobs', 'job_line_items',
                       'job_assignments')),
  '', 'no TRUNCATE/TRIGGER/REFERENCES for API roles on foundation tables');
select tests.eq((
  select coalesce(string_agg(table_name, ', ' order by 1), '')
  from information_schema.table_privileges
  where table_schema = 'public' and grantee = 'anon'
    and table_name in ('profiles', 'shops', 'shop_members', 'shop_invites', 'member_compensation', 'shop_stripe_accounts',
                       'shop_counters', 'vehicle_categories', 'business_hours', 'blocked_times', 'resources',
                       'booking_settings', 'customers', 'vehicles', 'service_categories', 'services', 'service_prices',
                       'package_items', 'service_addons', 'coupons', 'job_status_transitions', 'jobs', 'job_line_items',
                       'job_assignments')),
  '', 'anon holds no privileges on foundation tables');

-- the database default search_path mirrors Supabase (extensions reachable)
select tests.ok(current_setting('search_path') like '%extensions%', 'default search_path includes extensions (like Supabase)');
