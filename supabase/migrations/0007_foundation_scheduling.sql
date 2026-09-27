-- ============================================================================
-- 0007 — Scheduling RPCs (SPEC §4.4): get_available_slots (public),
-- calendar_events (staff), plus foundation-wide privilege hardening.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- get_available_slots
--
-- Slots start on a wall-clock grid of slot_interval_minutes anchored at the
-- opening time of each (merged) business-hours interval, in the shop's time
-- zone (a stretch that is open around the clock is anchored at each local
-- midnight instead). The grid never depends on the requested date range.
-- Local times that do not exist (DST spring-forward gap) are skipped;
-- ambiguous local times (fall-back) appear once. A slot must fit entirely
-- inside one open interval (adjacent intervals — including across midnight —
-- are merged), must not overlap a shop-wide blocked time, must start at or
-- after now + lead time, must start no later than max_days_ahead days after
-- today (shop-local dates), and at every instant of the slot fewer than
-- max_concurrent_jobs non-cancelled / non-no-show jobs (each widened by
-- buffer_minutes on both sides) may be running.
--
-- "Now" is public.effective_now(p_now) (0001): trusted callers (service_role,
-- direct sessions, tests) may fix it; anon/authenticated requests always get
-- the server clock, so nobody can list past dates and read the gaps as a map
-- of the shop's past appointments. A null p_now also means the server clock.
-- Booking RPCs must re-validate against their own effective_now.
-- ---------------------------------------------------------------------------
create function public.get_available_slots(
  p_shop_slug            text,
  p_service_ids          uuid[],
  p_vehicle_category_id  uuid,
  p_from                 date,
  p_to                   date,
  p_now                  timestamptz default now()
) returns table (starts_at timestamptz, ends_at timestamptz)
language plpgsql stable security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  c_max_range_days constant integer := 62;
  v_shop      public.shops;
  v_bs        public.booking_settings;
  v_ids       uuid[];
  v_found     integer;
  v_duration  integer;
  v_today     date;
  v_from      date;
  v_to        date;
  v_tz        text;
  v_scan_start timestamptz;
  v_now       timestamptz := public.effective_now(p_now);
begin
  if p_shop_slug is null or p_from is null or p_to is null then
    raise exception 'shop slug and date range are required' using errcode = '22023';
  end if;
  select * into v_shop from public.shops s where s.slug = lower(btrim(p_shop_slug));
  if not found then
    raise exception 'shop not found' using errcode = 'P0002';
  end if;
  select * into v_bs from public.booking_settings b where b.shop_id = v_shop.id;
  if not found or not v_bs.enabled then
    raise exception 'online booking is not enabled for this shop' using errcode = '55000';
  end if;
  if p_to < p_from then
    raise exception 'p_to must be on or after p_from' using errcode = '22023';
  end if;
  if p_to - p_from + 1 > c_max_range_days then
    raise exception 'date range cannot exceed % days', c_max_range_days using errcode = '22023';
  end if;

  v_ids := array(select distinct x from unnest(p_service_ids) as x where x is not null);
  if coalesce(cardinality(v_ids), 0) = 0 then
    raise exception 'choose at least one service' using errcode = '22023';
  end if;
  if cardinality(v_ids) > 50 then
    raise exception 'too many services' using errcode = '22023';
  end if;
  if p_vehicle_category_id is not null and not exists (
       select 1 from public.vehicle_categories vc
       where vc.id = p_vehicle_category_id and vc.shop_id = v_shop.id) then
    raise exception 'unknown vehicle category' using errcode = '22023';
  end if;

  select count(*), sum(sp.duration_minutes)
    into v_found, v_duration
    from public.services s
    cross join lateral public.service_price_for(s.id, p_vehicle_category_id) sp
   where s.id = any (v_ids)
     and s.shop_id = v_shop.id
     and s.active
     and s.online_bookable
     and s.archived_at is null;
  if v_found <> cardinality(v_ids) then
    raise exception 'one or more services are not available for online booking' using errcode = '22023';
  end if;
  if coalesce(v_duration, 0) <= 0 then
    raise exception 'the selected services have no duration' using errcode = '22023';
  end if;

  v_tz := v_shop.timezone;
  v_today := (v_now at time zone v_tz)::date;
  v_from := greatest(p_from, v_today);
  v_to := least(p_to, v_today + v_bs.max_days_ahead);
  if v_from > v_to then
    return;
  end if;

  -- The grid must not depend on the requested range (create_online_booking
  -- re-checks a chosen start with a one-day range). Business hours repeat
  -- weekly, so an open stretch that is not open around the clock lasts less
  -- than 7 days: scanning 8 days either side always finds the true opening
  -- (the grid anchor) and closing (the fit limit) of every stretch that can
  -- hold a slot starting in [v_from, v_to]. A stretch that reaches back to
  -- the scan start is open around the clock: its grid is anchored at each
  -- local midnight and it never closes.
  v_scan_start := (v_from - 8)::timestamp at time zone v_tz;

  return query
  with days as (
    select (v_from - 8 + i) as d
    from generate_series(0, v_to - v_from + 16) as i
  ),
  raw_intervals as (
    select ((dd.d + bh.opens_at)::timestamp at time zone v_tz)  as o,
           ((dd.d + bh.closes_at)::timestamp at time zone v_tz) as c
    from days dd
    join public.business_hours bh
      on bh.shop_id = v_shop.id and bh.weekday = extract(dow from dd.d)::smallint
  ),
  marked as (
    select ri.o, ri.c,
           case when ri.o <= max(ri.c) over (order by ri.o, ri.c
                                              rows between unbounded preceding and 1 preceding)
                then 0 else 1 end as is_new
    from raw_intervals ri
    where ri.c > ri.o
  ),
  grouped as (
    select mk.o, mk.c, sum(mk.is_new) over (order by mk.o, mk.c) as grp
    from marked mk
  ),
  islands as (
    select min(g.o) as o, max(g.c) as c from grouped g group by g.grp
  ),
  relevant as (
    select isl.o, isl.c, isl.o <= v_scan_start as around_the_clock
    from islands isl
    where isl.c > (v_from::timestamp at time zone v_tz)
      and isl.o < ((v_to + 1)::timestamp at time zone v_tz)
  ),
  local_starts as (
    -- a stretch with an opening time: grid anchored at that opening
    select lt, r.c as island_close
    from relevant r
    cross join lateral generate_series(r.o at time zone v_tz, r.c at time zone v_tz,
                                       make_interval(mins => v_bs.slot_interval_minutes)) as lt
    where not r.around_the_clock
    union all
    -- open around the clock: grid anchored at each local midnight
    select lt, 'infinity'::timestamptz
    from relevant r
    cross join generate_series(v_from::timestamp, v_to::timestamp, interval '1 day') as dd(d)
    cross join lateral generate_series(dd.d, dd.d + interval '1 day',
                                       make_interval(mins => v_bs.slot_interval_minutes)) as lt
    where r.around_the_clock and lt < dd.d + interval '1 day'
  ),
  candidates as (
    select distinct (ls.lt at time zone v_tz) as s, ls.island_close
    from local_starts ls
    where ((ls.lt at time zone v_tz) at time zone v_tz) = ls.lt       -- skip nonexistent local times
  ),
  slots as (
    select cd.s, cd.s + make_interval(mins => v_duration) as e
    from candidates cd
    where cd.s + make_interval(mins => v_duration) <= cd.island_close
      and (cd.s at time zone v_tz)::date between v_from and v_to
      and cd.s >= v_now + make_interval(mins => v_bs.lead_time_minutes)
  ),
  busy as materialized (
    select j.scheduled_start - make_interval(mins => v_bs.buffer_minutes) as bs,
           j.scheduled_end + make_interval(mins => v_bs.buffer_minutes)   as be
    from public.jobs j
    where j.shop_id = v_shop.id
      and j.scheduled_start is not null
      and j.status not in ('cancelled', 'no_show')
      and j.scheduled_start < ((v_to + 2)::timestamp at time zone v_tz)
                              + make_interval(mins => v_duration + v_bs.buffer_minutes)
      and j.scheduled_end > ((v_from - 1)::timestamp at time zone v_tz) - make_interval(mins => v_bs.buffer_minutes)
  )
  select sl.s, sl.e
  from slots sl
  where not exists (
          select 1 from public.blocked_times b
          where b.shop_id = v_shop.id and b.member_id is null
            and b.starts_at < sl.e and b.ends_at > sl.s)
    and not exists (
          -- concurrency peaks at the slot start or at a busy-interval start inside the slot
          select 1
          from (select sl.s as p
                union
                select bu.bs from busy bu where bu.bs > sl.s and bu.bs < sl.e) pts
          where (select count(*) from busy b2 where b2.bs <= pts.p and b2.be > pts.p)
                >= v_bs.max_concurrent_jobs)
  order by sl.s;
end
$$;

comment on function public.get_available_slots(text, uuid[], uuid, date, date, timestamptz) is
  'Public (anon) availability for online booking. Range capped at 62 days. p_now is honoured only for trusted callers (effective_now).';

-- ---------------------------------------------------------------------------
-- calendar_events — staff calendar feed. Managers+ and assigned technicians
-- get full job details; technicians receive other jobs as anonymous busy
-- blocks. Blocked-time reasons are hidden from technicians unless the block
-- is shop-wide or their own.
-- ---------------------------------------------------------------------------
create function public.calendar_events(
  p_shop_id            uuid,
  p_from               timestamptz,
  p_to                 timestamptz,
  p_include_cancelled  boolean default false
) returns table (
  event_type           text,
  id                   uuid,
  job_number           bigint,
  status               public.job_status,
  starts_at            timestamptz,
  ends_at              timestamptz,
  is_busy_block        boolean,
  customer_id          uuid,
  customer_name        text,
  vehicle_id           uuid,
  vehicle_label        text,
  location_type        public.location_type,
  service_address      text,
  resource_id          uuid,
  assigned_member_ids  uuid[],
  member_id            uuid,
  title                text
)
language plpgsql stable security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_role    public.shop_role := public.shop_role_of(p_shop_id);
  v_is_tech boolean;
  v_self    uuid;
begin
  if v_role is null then
    raise exception 'not a member of this shop' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_to <= p_from then
    raise exception 'p_to must be after p_from' using errcode = '22023';
  end if;
  if p_to - p_from > interval '93 days' then
    raise exception 'calendar range cannot exceed 93 days' using errcode = '22023';
  end if;
  v_is_tech := v_role = 'technician';
  select m.id into v_self from public.shop_members m
   where m.shop_id = p_shop_id and m.user_id = auth.uid();

  return query
  with job_rows as (
    select j.*,
           coalesce(array_agg(ja.member_id order by ja.created_at) filter (where ja.member_id is not null),
                    '{}'::uuid[]) as members,
           coalesce(bool_or(ja.member_id = v_self), false) as mine
    from public.jobs j
    left join public.job_assignments ja on ja.job_id = j.id and ja.shop_id = j.shop_id
    where j.shop_id = p_shop_id
      and j.scheduled_start is not null
      and j.scheduled_start < p_to
      and j.scheduled_end > p_from
      and (p_include_cancelled or j.status <> 'cancelled')
    group by j.id
  )
  select 'job'::text,
         jr.id,
         case when full_view then jr.number end,
         jr.status,
         jr.scheduled_start,
         jr.scheduled_end,
         not full_view,
         case when full_view then jr.customer_id end,
         case when full_view then nullif(btrim(concat_ws(' ', c.first_name, c.last_name)), '') end,
         case when full_view then jr.vehicle_id end,
         case when full_view then nullif(btrim(concat_ws(' ', v.year::text, v.make, v.model)), '') end,
         case when full_view then jr.location_type end,
         case when full_view then nullif(concat_ws(', ', jr.service_address_line1, jr.service_city), '') end,
         jr.resource_id,
         jr.members,
         null::uuid,
         case when full_view then
           coalesce(nullif(btrim(concat_ws(' ', c.first_name, c.last_name)), ''), c.company)
           || coalesce(' — ' || (select string_agg(li.name, ', ' order by li.sort, li.created_at)
                                 from public.job_line_items li where li.job_id = jr.id), '')
         end
  from job_rows jr
  join public.customers c on c.id = jr.customer_id
  left join public.vehicles v on v.id = jr.vehicle_id
  cross join lateral (select (not v_is_tech or jr.mine) as full_view) fv
  union all
  select 'blocked_time'::text,
         b.id,
         null::bigint,
         null::public.job_status,
         b.starts_at,
         b.ends_at,
         true,
         null::uuid, null::text, null::uuid, null::text, null::public.location_type, null::text,
         null::uuid,
         '{}'::uuid[],
         b.member_id,
         case when not v_is_tech or b.member_id is null or b.member_id = v_self then b.reason end
  from public.blocked_times b
  where b.shop_id = p_shop_id
    and b.starts_at < p_to
    and b.ends_at > p_from
  order by 5, 1, 2;
end
$$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke execute on function public.get_available_slots(text, uuid[], uuid, date, date, timestamptz) from public;
grant execute on function public.get_available_slots(text, uuid[], uuid, date, date, timestamptz)
  to anon, authenticated, service_role;

revoke execute on function public.calendar_events(uuid, timestamptz, timestamptz, boolean) from public, anon;
grant execute on function public.calendar_events(uuid, timestamptz, timestamptz, boolean)
  to authenticated, service_role;

-- TRUNCATE / TRIGGER / REFERENCES bypass RLS or are never needed by API
-- roles: strip them from every foundation table.
do $$
declare
  t text;
begin
  foreach t in array array[
    'profiles', 'shops', 'shop_members', 'shop_invites', 'member_compensation', 'shop_stripe_accounts',
    'shop_counters', 'vehicle_categories', 'business_hours', 'blocked_times', 'resources',
    'booking_settings', 'customers', 'vehicles', 'service_categories', 'services', 'service_prices',
    'package_items', 'service_addons', 'coupons', 'job_status_transitions', 'jobs', 'job_line_items',
    'job_assignments'] loop
    execute format('revoke truncate, trigger, references on public.%I from anon, authenticated', t);
  end loop;
end
$$;
