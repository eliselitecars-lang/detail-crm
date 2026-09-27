-- ============================================================================
-- REAL-STACK overlay for the SQL test helpers (applied by
-- scripts/stack/test_db_stack.sh AFTER supabase/shim/30_test_helpers.sql).
--
-- The shim's auth.users gives `id` a gen_random_uuid() default (and aud/role
-- defaults); GoTrue's real auth.users has NO default for id, so
-- tests.create_user() from the shim fails on a real Supabase database with
-- 23502 "null value in column id of relation users". This overlay inserts the
-- same row with explicit id / aud / role / instance_id, exactly like GoTrue's
-- own admin API does. Local/CI only; never apply to a hosted project.
-- ============================================================================
create or replace function tests.create_user(
  p_email text,
  p_confirmed boolean default true,
  p_meta jsonb default '{}'::jsonb
) returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                          raw_user_meta_data, raw_app_meta_data, created_at, updated_at)
  values ('00000000-0000-0000-0000-000000000000', v_id, 'authenticated', 'authenticated', p_email,
          case when p_confirmed then now() end,
          coalesce(p_meta, '{}'::jsonb),
          jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email')),
          now(), now());
  return v_id;
end
$$;
