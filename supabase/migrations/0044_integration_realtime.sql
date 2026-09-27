-- ============================================================================
-- 0044 — Realtime publication (SPEC §4.7): jobs, messages, notifications,
-- payments, time_entries.
--
-- Supabase Realtime streams changes of tables in the supabase_realtime
-- publication; postgres_changes subscribers only receive rows their RLS
-- policies let them read, so publishing never widens access. Idempotent:
-- a table already in the publication is skipped.
-- ============================================================================
do $$
declare
  t text;
begin
  if not exists (select 1 from pg_catalog.pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
  foreach t in array array['jobs', 'messages', 'notifications', 'payments', 'time_entries'] loop
    if not exists (select 1 from pg_catalog.pg_publication_tables
                   where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end
$$;
