-- ============================================================================
-- LOCAL / CI ONLY — Supabase compatibility shim, part 1: roles, schemas,
-- extensions, default privileges.
--
-- Never apply anything under supabase/shim/ to a real Supabase project: the
-- real platform already provides all of this. The shim exists so migrations
-- and SQL tests run unchanged on a throwaway vanilla Postgres cluster.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- API roles (mirrors Supabase): anon / authenticated are the PostgREST roles
-- for signed-out and signed-in requests; service_role bypasses RLS (edge
-- functions, cron); authenticator is the login role PostgREST switches from.
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin noinherit bypassrls;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticator') then
    create role authenticator login noinherit;
  end if;
end
$$;

grant anon, authenticated, service_role to authenticator;

-- ---------------------------------------------------------------------------
-- Schemas that exist on every Supabase project.
-- ---------------------------------------------------------------------------
create schema if not exists auth;
create schema if not exists storage;
create schema if not exists extensions;

grant usage on schema public     to anon, authenticated, service_role;
grant usage on schema auth       to anon, authenticated, service_role;
grant usage on schema storage    to anon, authenticated, service_role;
grant usage on schema extensions to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Extensions live in schema "extensions" on Supabase.
-- ---------------------------------------------------------------------------
create extension if not exists citext     with schema extensions;
create extension if not exists pg_trgm    with schema extensions;
create extension if not exists btree_gist with schema extensions;
create extension if not exists pgcrypto   with schema extensions;

-- Supabase databases default to search_path "$user", public, extensions so
-- extension types/operators (citext =, pg_trgm %, ...) resolve for API
-- queries. SECURITY DEFINER functions still pin search_path = ''.
do $$
begin
  execute format('alter database %I set search_path = "$user", public, extensions', current_database());
end
$$;

-- ---------------------------------------------------------------------------
-- Default privileges mirroring Supabase: everything the migration role
-- creates in public is granted to the API roles; RLS (and explicit REVOKEs in
-- migrations) are what actually restrict access. Functions are additionally
-- EXECUTE-able by PUBLIC (Postgres default), exactly like the real platform.
-- ---------------------------------------------------------------------------
alter default privileges in schema public grant all on tables    to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
alter default privileges in schema public grant execute on functions to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Realtime publication (empty; domain migrations add tables to it).
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
end
$$;
