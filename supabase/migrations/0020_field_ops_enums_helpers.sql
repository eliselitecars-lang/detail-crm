-- ============================================================================
-- 0020 — Field operations (SPEC §4.6): enums and shared helpers used by the
-- checklist, inspection, photo, form, time-clock and storage migrations
-- (0021-0025).
--
-- Storage path conventions (object names are stored WITHOUT the bucket):
--   job-photos   <shop_id>/<job_id>/<file>
--   signatures   <shop_id>/...                      (staff uploads)
--                <shop_id>/forms/<public_token>/<file>  (public form signers)
--   shop-assets  <shop_id>/...
-- ============================================================================

create type public.inspection_kind   as enum ('pre', 'post');
create type public.vehicle_view      as enum ('front', 'rear', 'left', 'right', 'top', 'interior');
create type public.damage_kind       as enum ('scratch', 'dent', 'chip', 'crack', 'stain', 'swirl', 'other');
create type public.job_photo_kind    as enum ('before', 'after', 'inspection', 'other');
create type public.form_attach_to    as enum ('all_jobs', 'online_booking', 'manual');
create type public.time_entry_kind   as enum ('shift', 'job');
create type public.time_entry_source as enum ('app', 'web', 'manual');

-- ---------------------------------------------------------------------------
-- Storage path helpers (pure).
-- ---------------------------------------------------------------------------

-- A relative object name: 1-1024 chars, no leading/trailing slash, no empty,
-- "." or ".." segments, no backslashes or control characters.
create function public.is_safe_storage_path(p_path text) returns boolean
language sql immutable
set search_path = ''
as $$
  select p_path is not null
     and char_length(p_path) between 1 and 1024
     and p_path !~ '^/'
     and p_path !~ '/$'
     and p_path !~ '//'
     and p_path !~ '(^|/)\.{1,2}(/|$)'
     and p_path !~ '[\\[:cntrl:]]'
$$;

-- The uuid in folder position p_index (1-based) of an object name, or null
-- when that segment is not a folder (the last segment is the file name) or
-- is not a canonical uuid. Never raises, so it is safe inside RLS policies.
-- Canonical means the lower-case text form Postgres prints (uuid::text):
-- object names are case-sensitive, and the purge queue (0025) matches the
-- folders of deleted shops, jobs and forms by that exact text, so a folder
-- spelled in upper or mixed case must not be accepted by any storage policy
-- or path validator (its files would never be purged).
create function public.storage_path_uuid(p_name text, p_index integer) returns uuid
language sql immutable
set search_path = ''
as $$
  select case
           when p_index >= 1
            and cardinality(parts) > p_index
            and parts[p_index] ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
           then parts[p_index]::uuid
         end
  from (select string_to_array(p_name, '/') as parts) s
$$;

-- Does an object exist in a bucket? Used only by SECURITY DEFINER validators
-- (not callable by API roles: object names of other shops stay private).
create function public.storage_object_exists(p_bucket text, p_name text) returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (select 1 from storage.objects o where o.bucket_id = p_bucket and o.name = p_name)
$$;

-- ---------------------------------------------------------------------------
-- can_work_job — the caller is manager+ of the shop, or an active member of
-- the shop assigned to the job; and the job belongs to that shop. This is
-- the "staff on the job" rule for checklists, inspections, photos, forms,
-- job storage objects and job time entries.
-- ---------------------------------------------------------------------------
create function public.can_work_job(p_shop_id uuid, p_job_id uuid) returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.jobs j
    where j.id = p_job_id
      and j.shop_id = p_shop_id
      and (public.is_shop_manager(p_shop_id)
           or exists (select 1
                      from public.job_assignments ja
                      join public.shop_members m on m.id = ja.member_id and m.shop_id = ja.shop_id
                      where ja.job_id = j.id and ja.shop_id = j.shop_id
                        and m.user_id = auth.uid() and m.active)))
$$;

-- ---------------------------------------------------------------------------
-- Client IP of the current PostgREST request, or null when unavailable or
-- malformed. Never raises. Used as audit evidence (form_submissions.signer_ip),
-- so it must not be a value the client chose:
--   1. cf-connecting-ip — set (overwritten) by the edge network in front of
--      the Supabase API gateway;
--   2. x-real-ip        — set by the API gateway from the peer it accepted;
--   3. the RIGHT-most x-forwarded-for hop — the one the last trusted proxy
--      appended. Earlier hops (in particular the first) are whatever the
--      client sent and are never used.
-- A header that is present but not a valid address is skipped.
-- ---------------------------------------------------------------------------
create function public.form_signer_ip() returns inet
language plpgsql stable
set search_path = ''
as $$
declare
  v_raw       text := current_setting('request.headers', true);
  v_headers   jsonb;
  v_forwarded text[];
  v_candidate text;
begin
  if v_raw is null or btrim(v_raw) = '' then
    return null;
  end if;
  begin
    v_headers := v_raw::jsonb;
  exception when others then
    return null;
  end;
  if jsonb_typeof(v_headers) <> 'object' then
    return null;
  end if;
  v_forwarded := string_to_array(coalesce(v_headers ->> 'x-forwarded-for', ''), ',');
  foreach v_candidate in array array[
    v_headers ->> 'cf-connecting-ip',
    v_headers ->> 'x-real-ip',
    case when cardinality(v_forwarded) > 0 then v_forwarded[cardinality(v_forwarded)] end]
  loop
    v_candidate := btrim(coalesce(v_candidate, ''));
    continue when v_candidate = '';
    begin
      return host(v_candidate::inet)::inet;
    exception when others then
      null; -- malformed: try the next source
    end;
  end loop;
  return null;
end
$$;

revoke execute on function public.storage_object_exists(text, text) from public, anon, authenticated;
grant execute on function public.storage_object_exists(text, text) to service_role;

revoke execute on function public.can_work_job(uuid, uuid) from public, anon;
grant execute on function public.can_work_job(uuid, uuid) to authenticated, service_role;

revoke execute on function public.form_signer_ip() from public, anon, authenticated;
grant execute on function public.form_signer_ip() to service_role;
