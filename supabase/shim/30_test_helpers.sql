-- ============================================================================
-- LOCAL / CI ONLY — Supabase compatibility shim, part 4: SQL test helpers.
--
-- Schema "tests" holds assertion + identity-switching helpers used by
-- supabase/tests/*.sql. See supabase/tests/README.md for the full guide.
--
-- Fixture helpers that depend on application tables/RPCs (make_shop,
-- add_member) are plpgsql, whose bodies are only resolved when called, so
-- they can live here even though the shim is applied BEFORE migrations.
-- They require migrations 0001-0002 at call time.
--
-- Every assertion failure RAISEs 'FAIL: ...' so psql -v ON_ERROR_STOP=1
-- aborts the file. Every passing assertion bumps the transaction-local
-- setting tests.assertions, which scripts/test_db.sh reports per file.
-- ============================================================================

create schema if not exists tests;
grant usage on schema tests to anon, authenticated, service_role;

-- Per-transaction fixture registry (the runner rolls every file back).
create table if not exists tests.fixtures (
  key text primary key,
  id  uuid not null
);
grant select, insert, update, delete on tests.fixtures to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Assertion bookkeeping
-- ---------------------------------------------------------------------------
create or replace function tests._pass() returns void
language plpgsql
as $$
begin
  perform set_config(
    'tests.assertions',
    (coalesce(nullif(current_setting('tests.assertions', true), ''), '0')::bigint + 1)::text,
    true);
end
$$;

create or replace function tests.assertion_count() returns bigint
language sql stable
as $$ select coalesce(nullif(current_setting('tests.assertions', true), ''), '0')::bigint $$;

-- ---------------------------------------------------------------------------
-- Assertions
-- ---------------------------------------------------------------------------
create or replace function tests.ok(p_condition boolean, p_msg text) returns void
language plpgsql
as $$
begin
  if p_condition is distinct from true then
    raise exception 'FAIL: %', p_msg using errcode = 'P0001', detail = 'condition was ' || coalesce(p_condition::text, 'NULL');
  end if;
  perform tests._pass();
end
$$;

create or replace function tests.eq(p_got anycompatible, p_expected anycompatible, p_msg text) returns void
language plpgsql
as $$
begin
  if p_got is distinct from p_expected then
    raise exception 'FAIL: % (expected %, got %)',
      p_msg, coalesce(p_expected::text, 'NULL'), coalesce(p_got::text, 'NULL')
      using errcode = 'P0001';
  end if;
  perform tests._pass();
end
$$;

-- Runs p_sql (as the CURRENT role) and asserts it raises. When p_sqlstate is
-- given the error's SQLSTATE must match exactly.
create or replace function tests.throws(p_sql text, p_sqlstate text default null, p_msg text default null)
returns void
language plpgsql
as $$
declare
  v_state text;
  v_text  text;
begin
  begin
    execute p_sql;
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_text = message_text;
    if p_sqlstate is not null and v_state <> p_sqlstate then
      raise exception 'FAIL: % (expected SQLSTATE %, got % "%")',
        coalesce(p_msg, p_sql), p_sqlstate, v_state, v_text using errcode = 'P0001';
    end if;
    perform tests._pass();
    return;
  end;
  raise exception 'FAIL: % (expected an error, statement succeeded: %)',
    coalesce(p_msg, p_sql), p_sql using errcode = 'P0001';
end
$$;

-- Like throws() but also requires the error message to match p_pattern
-- (case-insensitive LIKE, e.g. '%row-level security%').
create or replace function tests.throws_like(p_sql text, p_sqlstate text, p_pattern text, p_msg text default null)
returns void
language plpgsql
as $$
declare
  v_state text;
  v_text  text;
begin
  begin
    execute p_sql;
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_text = message_text;
    if (p_sqlstate is not null and v_state <> p_sqlstate) or v_text not ilike p_pattern then
      raise exception 'FAIL: % (expected SQLSTATE % matching "%", got % "%")',
        coalesce(p_msg, p_sql), coalesce(p_sqlstate, 'any'), p_pattern, v_state, v_text using errcode = 'P0001';
    end if;
    perform tests._pass();
    return;
  end;
  raise exception 'FAIL: % (expected an error, statement succeeded: %)',
    coalesce(p_msg, p_sql), p_sql using errcode = 'P0001';
end
$$;

create or replace function tests.lives(p_sql text, p_msg text default null) returns void
language plpgsql
as $$
declare
  v_state text;
  v_text  text;
begin
  begin
    execute p_sql;
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_text = message_text;
    raise exception 'FAIL: % (unexpected error % "%")', coalesce(p_msg, p_sql), v_state, v_text
      using errcode = 'P0001';
  end;
  perform tests._pass();
end
$$;

-- Number of rows returned (SELECT) or affected (INSERT/UPDATE/DELETE) by
-- p_sql when run as the current role. Not an assertion by itself.
create or replace function tests.row_count(p_sql text) returns bigint
language plpgsql
as $$
declare
  v_count bigint;
begin
  execute p_sql;
  get diagnostics v_count = row_count;
  return v_count;
end
$$;

-- ---------------------------------------------------------------------------
-- Identity switching. All settings are transaction-local (set_config(...,
-- true)) so a rolled-back test file never leaks identity into the next one.
-- ---------------------------------------------------------------------------
create or replace function tests._claims_for(p_user_id uuid) returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_user auth.users;
begin
  select * into v_user from auth.users where id = p_user_id;
  if not found then
    raise exception 'tests: auth user % does not exist', p_user_id;
  end if;
  return jsonb_build_object(
    'sub', v_user.id,
    'email', v_user.email,
    'phone', coalesce(v_user.phone, ''),
    'role', 'authenticated',
    'aud', 'authenticated',
    'is_anonymous', v_user.is_anonymous,
    'app_metadata', coalesce(v_user.raw_app_meta_data, '{}'::jsonb),
    'user_metadata', coalesce(v_user.raw_user_meta_data, '{}'::jsonb));
end
$$;

create or replace function tests._set_claims(p_claims jsonb) returns void
language plpgsql
as $$
begin
  perform set_config('request.jwt.claims', coalesce(p_claims::text, ''), true);
  -- Legacy per-claim settings are cleared so auth.uid() reads the JSON.
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', '', true);
  perform set_config('request.jwt.claim.email', '', true);
end
$$;

create or replace function tests.authenticate_as(p_user_id uuid) returns void
language plpgsql
as $$
declare
  v_claims jsonb := tests._claims_for(p_user_id);
begin
  perform tests._set_claims(v_claims);
  perform set_config('role', 'authenticated', true);
end
$$;

create or replace function tests.as_anon() returns void
language plpgsql
as $$
begin
  perform tests._set_claims(jsonb_build_object('role', 'anon'));
  perform set_config('role', 'anon', true);
end
$$;

create or replace function tests.as_service() returns void
language plpgsql
as $$
begin
  perform tests._set_claims(jsonb_build_object('role', 'service_role'));
  perform set_config('role', 'service_role', true);
end
$$;

-- Back to the connecting superuser with no JWT claims.
create or replace function tests.as_superuser() returns void
language plpgsql
as $$
begin
  reset role;
  perform tests._set_claims(null);
end
$$;

create or replace function tests.reset() returns void
language plpgsql
as $$
begin
  perform tests.as_superuser();
end
$$;

-- ---------------------------------------------------------------------------
-- Users & fixtures
-- ---------------------------------------------------------------------------
create or replace function tests.create_user(
  p_email text,
  p_confirmed boolean default true,
  p_meta jsonb default '{}'::jsonb
) returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  insert into auth.users (email, email_confirmed_at, raw_user_meta_data, raw_app_meta_data)
  values (p_email,
          case when p_confirmed then now() end,
          coalesce(p_meta, '{}'::jsonb),
          jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email')))
  returning id into v_id;
  return v_id;
end
$$;

create or replace function tests.user_id(p_email text) returns uuid
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  select id into v_id from auth.users where lower(email) = lower(p_email);
  if v_id is null then
    raise exception 'tests: no auth user with email %', p_email;
  end if;
  return v_id;
end
$$;

create or replace function tests.fx_set(p_key text, p_id uuid) returns uuid
language plpgsql
as $$
begin
  insert into tests.fixtures (key, id) values (p_key, p_id)
  on conflict (key) do update set id = excluded.id;
  return p_id;
end
$$;

create or replace function tests.fx(p_key text) returns uuid
language plpgsql stable
as $$
declare
  v_id uuid;
begin
  select id into v_id from tests.fixtures where key = p_key;
  if v_id is null then
    raise exception 'tests: fixture "%" is not set', p_key;
  end if;
  return v_id;
end
$$;

-- Creates (or reuses) a confirmed owner user and a fully set-up shop through
-- the real public.create_shop RPC (so every domain's AFTER INSERT seeding
-- runs). Returns the shop id. Leaves the caller's identity unchanged.
create or replace function tests.make_shop(
  p_owner_email text,
  p_slug text default null,
  p_name text default null,
  p_timezone text default 'America/Chicago'
) returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  v_owner  uuid;
  v_prev   text := current_setting('request.jwt.claims', true);
  v_shop   uuid;
begin
  select id into v_owner from auth.users where lower(email) = lower(p_owner_email);
  if v_owner is null then
    v_owner := tests.create_user(p_owner_email);
  end if;
  perform set_config('request.jwt.claims', tests._claims_for(v_owner)::text, true);
  execute 'select (public.create_shop(p_name => $1, p_slug => $2, p_timezone => $3)).id'
    into v_shop
    using coalesce(p_name, 'Shop ' || split_part(p_owner_email, '@', 1)),
          coalesce(p_slug, 'shop-' || substr(md5(lower(p_owner_email)), 1, 12)),
          p_timezone;
  perform set_config('request.jwt.claims', coalesce(v_prev, ''), true);
  return v_shop;
end
$$;

-- Adds a staff member (creating a confirmed auth user when needed) directly,
-- bypassing invites. Returns the shop_members.id.
create or replace function tests.add_member(
  p_shop_id uuid,
  p_email text,
  p_role text,
  p_active boolean default true
) returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  v_user   uuid;
  v_member uuid;
begin
  select id into v_user from auth.users where lower(email) = lower(p_email);
  if v_user is null then
    v_user := tests.create_user(p_email);
  end if;
  execute 'insert into public.shop_members (shop_id, user_id, role, display_name, active)
           values ($1, $2, $3::public.shop_role, $4, $5) returning id'
    into v_member
    using p_shop_id, v_user, p_role, split_part(p_email, '@', 1), p_active;
  return v_member;
end
$$;

grant execute on all functions in schema tests to anon, authenticated, service_role;
