-- ============================================================================
-- 0057 — Day map of mobile jobs + manual route order (P-18).
--
-- jobs.route_position (0050) is the stop order of a job within its
-- shop-local day; jobs.service_lat / service_lng hold the geocoded service
-- address (managers may also write them directly; calendar_events v2
-- returns them). Technicians cannot update these job columns directly
-- (jobs_client_guard), so the two RPCs below are their trusted path:
--   * set_route_order(shop, job ids) — 1..50 distinct jobs of the shop, all
--     scheduled on the same shop-local day; managers+ may order any jobs,
--     technicians only jobs they are assigned to (every one of them). Sets
--     route_position to the list index (0 = first stop). Other jobs of the
--     day keep their position. Returns the number of jobs ordered.
--   * set_job_coordinates(job, lat, lng, address) — managers+ or a
--     technician assigned to the job (the phone that geocoded the address
--     stores it); the job must have a service address; lat -90..90, lng
--     -180..180. p_address is the address the point was geocoded FOR, as
--     the client read it from the job: {service_address_line1,
--     service_address_line2, service_city, service_region,
--     service_postal_code} (a missing key or JSON null = no value; no other
--     keys). It is compared, under the job's row lock, with the job's
--     current address: when the address changed after the client loaded it
--     the point is refused (40001 'the job''s service address changed ...':
--     reload the job and geocode the current address), so a point found for
--     an old address is never stored on the corrected one.
-- Errors: not a member 42501; unknown / other shop's job P0002; bad input
-- 22023; a technician on a job not assigned to them 42501; a stale address
-- 40001.
--
-- jobs_56_route_geo_reset (BEFORE UPDATE, every context) keeps both columns
-- true to what they describe:
--   * a write that changes the location type or any service address field
--     without also writing new coordinates clears service_lat / service_lng
--     (the old address' point; the phone geocodes the new one — clients
--     geocode only jobs without coordinates);
--   * a write that moves scheduled_start to another shop-local day (or
--     unschedules the job) without also writing route_position clears it:
--     the stop order belonged to the old day's route.
-- update_job_series does the same for a series' address (job_series_apply,
-- 0051), so regenerated occurrences do not copy stale coordinates.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- jobs_56_route_geo_reset — see the header. Definer only so the shop's time
-- zone is readable whoever writes the job; it changes nothing but the row
-- being written.
-- ---------------------------------------------------------------------------
create function public.jobs_route_geo_reset() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_tz text;
begin
  if (new.location_type, new.service_address_line1, new.service_address_line2, new.service_city,
      new.service_region, new.service_postal_code)
     is distinct from
     (old.location_type, old.service_address_line1, old.service_address_line2, old.service_city,
      old.service_region, old.service_postal_code)
     and new.service_lat is not distinct from old.service_lat
     and new.service_lng is not distinct from old.service_lng then
    new.service_lat := null;
    new.service_lng := null;
  end if;

  if new.route_position is not null
     and new.route_position is not distinct from old.route_position
     and new.scheduled_start is distinct from old.scheduled_start then
    if new.scheduled_start is null or old.scheduled_start is null then
      new.route_position := null;
    else
      select s.timezone into v_tz from public.shops s where s.id = new.shop_id;
      if (new.scheduled_start at time zone v_tz)::date <> (old.scheduled_start at time zone v_tz)::date then
        new.route_position := null;
      end if;
    end if;
  end if;
  return new;
end
$$;

create trigger jobs_56_route_geo_reset before update on public.jobs
  for each row
  when (old.location_type is distinct from new.location_type
        or old.service_address_line1 is distinct from new.service_address_line1
        or old.service_address_line2 is distinct from new.service_address_line2
        or old.service_city is distinct from new.service_city
        or old.service_region is distinct from new.service_region
        or old.service_postal_code is distinct from new.service_postal_code
        or old.scheduled_start is distinct from new.scheduled_start)
  execute function public.jobs_route_geo_reset();

revoke execute on function public.jobs_route_geo_reset() from public, anon, authenticated;

create function public.set_route_order(p_shop_id uuid, p_job_ids uuid[]) returns integer
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_role   public.shop_role := public.shop_role_of(p_shop_id);
  v_tz     text;
  v_found  integer;
  v_days   integer;
begin
  if v_role is null then
    raise exception 'not a member of this shop' using errcode = '42501';
  end if;
  if p_job_ids is null or cardinality(p_job_ids) = 0 then
    raise exception 'list at least one job' using errcode = '22023';
  end if;
  if cardinality(p_job_ids) > 50 then
    raise exception 'a route can order at most 50 jobs' using errcode = '22023';
  end if;
  if array_position(p_job_ids, null) is not null
     or (select count(distinct x) from unnest(p_job_ids) as x) <> cardinality(p_job_ids) then
    raise exception 'the list must name each job once' using errcode = '22023';
  end if;
  select s.timezone into v_tz from public.shops s where s.id = p_shop_id;
  select count(*), count(distinct (j.scheduled_start at time zone v_tz)::date)
    into v_found, v_days
    from public.jobs j
   where j.shop_id = p_shop_id and j.id = any (p_job_ids);
  if v_found <> cardinality(p_job_ids) then
    raise exception 'job not found' using errcode = 'P0002';
  end if;
  if exists (select 1 from public.jobs j
             where j.shop_id = p_shop_id and j.id = any (p_job_ids) and j.scheduled_start is null)
     or v_days <> 1 then
    raise exception 'all jobs of a route must be scheduled on the same day' using errcode = '22023';
  end if;
  if v_role = 'technician'
     and exists (select 1 from unnest(p_job_ids) as x where not public.can_work_job(p_shop_id, x)) then
    raise exception 'technicians can only order the jobs they are assigned to' using errcode = '42501';
  end if;

  update public.jobs j
     set route_position = (x.o - 1)::integer
    from unnest(p_job_ids) with ordinality as x(id, o)
   where j.shop_id = p_shop_id and j.id = x.id
     and j.route_position is distinct from (x.o - 1)::integer;
  return cardinality(p_job_ids);
end
$$;

create function public.set_job_coordinates(
  p_job_id   uuid,
  p_lat      double precision,
  p_lng      double precision,
  p_address  jsonb
) returns void
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  c_keys constant text[] := array['service_address_line1', 'service_address_line2', 'service_city',
                                  'service_region', 'service_postal_code'];
  v_job  public.jobs;
  v_key  text;
begin
  select * into v_job from public.jobs j where j.id = p_job_id;
  if not found or not public.is_shop_member(v_job.shop_id) then
    raise exception 'job not found' using errcode = 'P0002';
  end if;
  if not public.can_work_job(v_job.shop_id, v_job.id) then
    raise exception 'technicians can only locate the jobs they are assigned to' using errcode = '42501';
  end if;
  if p_lat is null or p_lng is null then
    raise exception 'send both latitude and longitude' using errcode = '22023';
  end if;
  -- (NaN and infinities fail these ranges: NaN sorts above every number)
  if p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    raise exception 'coordinates are out of range' using errcode = '22023';
  end if;
  if p_address is null or jsonb_typeof(p_address) <> 'object' then
    raise exception 'p_address must be the address the point was found for (a JSON object)' using errcode = '22023';
  end if;
  select k into v_key from jsonb_object_keys(p_address) k where k <> all (c_keys) order by k limit 1;
  if v_key is not null then
    raise exception 'p_address: unknown field %', v_key using errcode = '22023';
  end if;
  select k into v_key from unnest(c_keys) k
   where coalesce(jsonb_typeof(p_address -> k), 'null') not in ('string', 'null') order by k limit 1;
  if v_key is not null then
    raise exception 'p_address: % must be text or null', v_key using errcode = '22023';
  end if;
  -- the current row, locked: a concurrent address change either commits
  -- first (and is compared) or waits for this write (and clears the point,
  -- jobs_56_route_geo_reset)
  select * into v_job from public.jobs j where j.id = v_job.id and j.shop_id = v_job.shop_id for update;
  if v_job.service_address_line1 is null and v_job.service_city is null and v_job.service_postal_code is null then
    raise exception 'this job has no service address to locate' using errcode = '22023';
  end if;
  if (p_address ->> 'service_address_line1', p_address ->> 'service_address_line2', p_address ->> 'service_city',
      p_address ->> 'service_region', p_address ->> 'service_postal_code')
     is distinct from
     (v_job.service_address_line1, v_job.service_address_line2, v_job.service_city, v_job.service_region,
      v_job.service_postal_code) then
    raise exception 'the job''s service address changed after it was located; geocode the current address'
      using errcode = '40001';
  end if;
  update public.jobs j
     set service_lat = p_lat, service_lng = p_lng
   where j.id = v_job.id and j.shop_id = v_job.shop_id;
end
$$;

revoke execute on function
  public.set_route_order(uuid, uuid[]),
  public.set_job_coordinates(uuid, double precision, double precision, jsonb)
from public, anon;
grant execute on function
  public.set_route_order(uuid, uuid[]),
  public.set_job_coordinates(uuid, double precision, double precision, jsonb)
to authenticated, service_role;
