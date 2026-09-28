-- ============================================================================
-- 0056 — Geostamped clock in / clock out (P-24).
--
-- clock_in / clock_out take the device location (p_lat, p_lng, optional
-- p_accuracy_m in meters): both coordinates or neither (22023), latitude
-- -90..90, longitude -180..180, accuracy 0..10000 (22023; the accuracy is
-- ignored without coordinates). The location is stored on the entry being
-- opened / closed (clocking out of a shift also stamps the job entry it
-- closes). Everything else is unchanged from 0024 (read its header): the
-- functions are re-created with three trailing defaulted parameters, so
-- existing calls keep working.
--
-- The six geo columns are evidence: API roles (even managers, who may edit
-- times and notes) can neither set them on a manual entry nor change them
-- (time_entries_50_geo_guard, 42501). time_entries_client_guard (0024) is
-- unchanged.
-- ============================================================================

create function public.time_entry_check_geo(p_lat double precision, p_lng double precision, p_accuracy_m real)
returns void
language plpgsql immutable
set search_path = ''
as $$
begin
  if (p_lat is null) <> (p_lng is null) then
    raise exception 'send both latitude and longitude, or neither' using errcode = '22023';
  end if;
  if p_lat is not null and p_lat not between -90 and 90 then
    raise exception 'latitude must be between -90 and 90' using errcode = '22023';
  end if;
  if p_lng is not null and p_lng not between -180 and 180 then
    raise exception 'longitude must be between -180 and 180' using errcode = '22023';
  end if;
  if p_lat is not null and p_accuracy_m is not null and p_accuracy_m not between 0 and 10000 then
    raise exception 'location accuracy must be between 0 and 10000 meters' using errcode = '22023';
  end if;
end
$$;

create function public.time_entries_geo_guard() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not public.is_client_context() then
    return new;
  end if;
  if tg_op = 'INSERT' then
    if num_nonnulls(new.clock_in_lat, new.clock_in_lng, new.clock_in_accuracy_m,
                    new.clock_out_lat, new.clock_out_lng, new.clock_out_accuracy_m) > 0 then
      raise exception 'clock locations are recorded only by clock in / clock out' using errcode = '42501';
    end if;
  elsif (new.clock_in_lat, new.clock_in_lng, new.clock_in_accuracy_m,
         new.clock_out_lat, new.clock_out_lng, new.clock_out_accuracy_m)
        is distinct from
        (old.clock_in_lat, old.clock_in_lng, old.clock_in_accuracy_m,
         old.clock_out_lat, old.clock_out_lng, old.clock_out_accuracy_m) then
    raise exception 'clock locations cannot be edited' using errcode = '42501';
  end if;
  return new;
end
$$;

create trigger time_entries_50_geo_guard before insert or update on public.time_entries
  for each row execute function public.time_entries_geo_guard();

drop function public.clock_in(uuid, uuid, public.time_entry_kind, public.time_entry_source, timestamptz, text);
drop function public.clock_out(uuid, public.time_entry_kind, timestamptz, text);

-- p_kind defaults to 'shift' without a job and 'job' with one.
create function public.clock_in(
  p_shop_id  uuid,
  p_job_id   uuid default null,
  p_kind     public.time_entry_kind default null,
  p_source   public.time_entry_source default 'app',
  p_now      timestamptz default null,
  p_notes    text default null,
  p_lat         double precision default null,
  p_lng         double precision default null,
  p_accuracy_m  real default null
) returns public.time_entries
language plpgsql security definer
set search_path = ''
as $$
declare
  v_member  public.shop_members;
  v_kind    public.time_entry_kind := coalesce(p_kind, case when p_job_id is null then 'shift' else 'job' end::public.time_entry_kind);
  v_now     timestamptz := coalesce(p_now, now());
  v_status  public.job_status;
  v_entry   public.time_entries;
begin
  select * into v_member from public.shop_members m
   where m.shop_id = p_shop_id and m.user_id = auth.uid() and m.active;
  if not found then
    raise exception 'not a member of this shop' using errcode = '42501';
  end if;
  if p_now is not null and v_member.role not in ('owner', 'admin', 'manager') then
    raise exception 'only managers can clock in at a specific time' using errcode = '42501';
  end if;
  perform public.time_entry_check_geo(p_lat, p_lng, p_accuracy_m);
  if coalesce(p_source, 'app') = 'manual' then
    raise exception 'manual entries are added by managers on the timesheet' using errcode = '22023';
  end if;
  if v_kind = 'shift' and p_job_id is not null then
    raise exception 'a shift clock does not take a job' using errcode = '22023';
  end if;
  if v_kind = 'job' then
    if p_job_id is null then
      raise exception 'choose the job to clock in to' using errcode = '22023';
    end if;
    select j.status into v_status from public.jobs j where j.id = p_job_id and j.shop_id = p_shop_id;
    if not found then
      raise exception 'job not found' using errcode = 'P0002';
    end if;
    if not public.can_work_job(p_shop_id, p_job_id) then
      raise exception 'you are not assigned to this job' using errcode = '42501';
    end if;
    if v_status in ('cancelled', 'no_show') then
      raise exception 'cannot clock in to a % job', v_status using errcode = '22023';
    end if;
  end if;
  if exists (select 1 from public.time_entries te
             where te.member_id = v_member.id and te.kind = v_kind and te.clock_out is null) then
    raise exception 'already clocked in (%); clock out first', v_kind using errcode = '23505';
  end if;

  begin
    insert into public.time_entries (shop_id, member_id, job_id, kind, clock_in, source, notes,
                                     clock_in_lat, clock_in_lng, clock_in_accuracy_m)
    values (p_shop_id, v_member.id, p_job_id, v_kind, v_now, coalesce(p_source, 'app'),
            nullif(btrim(p_notes), ''), p_lat, p_lng, case when p_lat is not null then p_accuracy_m end)
    returning * into v_entry;
  exception
    when unique_violation then
      raise exception 'already clocked in (%); clock out first', v_kind using errcode = '23505';
    when exclusion_violation then
      raise exception 'this clock-in overlaps an existing % entry', v_kind using errcode = '23P01';
  end;
  return v_entry;
end
$$;


create function public.clock_out(
  p_shop_id  uuid,
  p_kind     public.time_entry_kind default 'shift',
  p_now      timestamptz default null,
  p_notes    text default null,
  p_lat         double precision default null,
  p_lng         double precision default null,
  p_accuracy_m  real default null
) returns public.time_entries
language plpgsql security definer
set search_path = ''
as $$
declare
  v_member  public.shop_members;
  v_kind    public.time_entry_kind := coalesce(p_kind, 'shift');
  v_now     timestamptz := coalesce(p_now, now());
  v_entry   public.time_entries;
begin
  select * into v_member from public.shop_members m
   where m.shop_id = p_shop_id and m.user_id = auth.uid() and m.active;
  if not found then
    raise exception 'not a member of this shop' using errcode = '42501';
  end if;
  if p_now is not null and v_member.role not in ('owner', 'admin', 'manager') then
    raise exception 'only managers can clock out at a specific time' using errcode = '42501';
  end if;
  perform public.time_entry_check_geo(p_lat, p_lng, p_accuracy_m);

  select * into v_entry from public.time_entries te
   where te.member_id = v_member.id and te.shop_id = p_shop_id and te.kind = v_kind and te.clock_out is null
   for update;
  if not found then
    raise exception 'not clocked in (%)', v_kind using errcode = 'P0002';
  end if;
  if v_now < v_entry.clock_in then
    raise exception 'clock-out cannot be before clock-in (%)', v_entry.clock_in using errcode = '22023';
  end if;

  -- leaving the shift ends any job clock too
  if v_kind = 'shift' then
    update public.time_entries te
       set clock_out = greatest(v_now, te.clock_in),
           clock_out_lat = p_lat,
           clock_out_lng = p_lng,
           clock_out_accuracy_m = case when p_lat is not null then p_accuracy_m end
     where te.member_id = v_member.id and te.shop_id = p_shop_id and te.kind = 'job' and te.clock_out is null;
  end if;

  update public.time_entries te
     set clock_out = v_now,
         notes = coalesce(nullif(btrim(p_notes), ''), te.notes),
         clock_out_lat = p_lat,
         clock_out_lng = p_lng,
         clock_out_accuracy_m = case when p_lat is not null then p_accuracy_m end
   where te.id = v_entry.id
  returning * into v_entry;
  return v_entry;
end
$$;


comment on function public.clock_in(uuid, uuid, public.time_entry_kind, public.time_entry_source, timestamptz, text,
                                    double precision, double precision, real) is
  'Clock the caller in (shift, or a job). p_now: managers only. p_lat/p_lng/p_accuracy_m: device location stored on the entry (0056).';
comment on function public.clock_out(uuid, public.time_entry_kind, timestamptz, text,
                                     double precision, double precision, real) is
  'Clock the caller out (a shift also closes the open job entry). p_now: managers only. p_lat/p_lng/p_accuracy_m: device location stored on the closed entry (0056).';

-- ---------------------------------------------------------------------------
-- Grants (same roles as 0024)
-- ---------------------------------------------------------------------------
revoke execute on function public.time_entries_geo_guard() from public, anon, authenticated;
-- (NaN and infinities fail the range checks: NaN sorts above every number)
revoke execute on function public.time_entry_check_geo(double precision, double precision, real)
  from public, anon, authenticated;
grant execute on function public.time_entry_check_geo(double precision, double precision, real) to service_role;

revoke execute on function
  public.clock_in(uuid, uuid, public.time_entry_kind, public.time_entry_source, timestamptz, text,
                  double precision, double precision, real),
  public.clock_out(uuid, public.time_entry_kind, timestamptz, text, double precision, double precision, real)
from public, anon;
grant execute on function
  public.clock_in(uuid, uuid, public.time_entry_kind, public.time_entry_source, timestamptz, text,
                  double precision, double precision, real),
  public.clock_out(uuid, public.time_entry_kind, timestamptz, text, double precision, double precision, real)
to authenticated, service_role;
