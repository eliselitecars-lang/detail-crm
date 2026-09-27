-- ============================================================================
-- LOCAL / CI ONLY — Supabase compatibility shim, part 2: auth schema.
-- Only the columns and functions application code relies on. Function bodies
-- match Supabase's (GoTrue) definitions.
-- ============================================================================

create table if not exists auth.users (
  instance_id          uuid,
  id                   uuid primary key default gen_random_uuid(),
  aud                  varchar(255) default 'authenticated',
  role                 varchar(255) default 'authenticated',
  email                varchar(255),
  encrypted_password   varchar(255),
  email_confirmed_at   timestamptz,
  invited_at           timestamptz,
  phone                text default null,
  phone_confirmed_at   timestamptz,
  confirmed_at         timestamptz generated always as (least(email_confirmed_at, phone_confirmed_at)) stored,
  last_sign_in_at      timestamptz,
  raw_app_meta_data    jsonb,
  raw_user_meta_data   jsonb,
  is_super_admin       boolean,
  is_sso_user          boolean not null default false,
  is_anonymous         boolean not null default false,
  banned_until         timestamptz,
  created_at           timestamptz default now(),
  updated_at           timestamptz default now(),
  deleted_at           timestamptz
);

-- Supabase: emails unique among non-SSO users; phones unique.
create unique index if not exists users_email_partial_key on auth.users (email) where (is_sso_user = false);
create unique index if not exists users_phone_key on auth.users (phone);

alter table auth.users enable row level security;
-- API roles never read auth.users directly on Supabase.
revoke all on auth.users from anon, authenticated;
grant all on auth.users to service_role;

-- request.jwt.claim.* (legacy PostgREST) or request.jwt.claims (current).
create or replace function auth.uid() returns uuid
language sql stable
as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
  )::uuid
$$;

create or replace function auth.role() returns text
language sql stable
as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role')
  )::text
$$;

create or replace function auth.email() returns text
language sql stable
as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.email', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'email')
  )::text
$$;

create or replace function auth.jwt() returns jsonb
language sql stable
as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim', true), ''),
    nullif(current_setting('request.jwt.claims', true), '')
  )::jsonb
$$;

grant execute on function auth.uid(), auth.role(), auth.email(), auth.jwt()
  to anon, authenticated, service_role;
